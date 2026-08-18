defmodule BeamPanel.Projects.Discovery do
  @moduledoc """
  Finds BEAM applications that already exist on a server.

  Three independent probes are merged into one candidate list:

    1. **systemd units** whose `ExecStart` points at a release control script
    2. **source trees** containing `mix.exs` or `rebar.config`
    3. **running `beam.smp` processes**, which reveal node names and cookies

  Candidates are returned as plain maps ready to be turned into projects.
  """

  alias BeamPanel.Remote
  alias BeamPanel.Remote.Result
  alias BeamPanel.Servers.Server

  @default_roots ~w(/opt /srv /home /var/www /usr/local/lib)

  @doc "Scans `server` and returns a deduplicated list of candidates."
  @spec scan(Server.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def scan(%Server{} = server, opts \\ []) do
    roots = Keyword.get(opts, :roots, [server.deploy_root || "/opt/beam" | @default_roots])

    Remote.with_connection(server, fn conn ->
      units = scan_units(server, conn)
      sources = scan_sources(server, conn, roots)
      processes = scan_processes(server, conn)

      {:ok, merge(units, sources, processes)}
    end)
  end

  ## ------------------------------------------------------------------ probes

  defp scan_units(server, conn) do
    cmd = """
    for unit in $(systemctl list-units --type=service --all --no-pager --no-legend --plain 2>/dev/null | awk '{print $1}'); do
      exec_start=$(systemctl show -p ExecStart --value "$unit" 2>/dev/null)
      case "$exec_start" in
        *"/bin/"*" start"*|*mix*run*|*rebar3*|*erl\\ *)
          frag=$(systemctl show -p FragmentPath --value "$unit" 2>/dev/null)
          wd=$(systemctl show -p WorkingDirectory --value "$unit" 2>/dev/null)
          state=$(systemctl show -p ActiveState --value "$unit" 2>/dev/null)
          echo "UNIT|$unit|$state|$wd|$exec_start|$frag"
          ;;
      esac
    done
    """

    case Remote.run(server, cmd, conn: conn, timeout: 60_000) do
      {:ok, %Result{} = result} ->
        result
        |> Result.lines()
        |> Enum.filter(&String.starts_with?(&1, "UNIT|"))
        |> Enum.map(&parse_unit_line/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp parse_unit_line(line) do
    case String.split(line, "|") do
      ["UNIT", unit, state, wd, exec_start | _] ->
        release = release_from_exec(exec_start)

        %{
          source: :systemd,
          service_name: unit,
          name: String.replace_suffix(unit, ".service", ""),
          status: normalize_state(state),
          working_directory: nilify(wd),
          release_name: release,
          deploy_path: deploy_path_from(wd, exec_start),
          exec_start: exec_start
        }

      _ ->
        nil
    end
  end

  defp release_from_exec(exec_start) do
    case Regex.run(~r{([^/\s]+)/bin/([^/\s]+)\s+start}, exec_start) do
      [_, _dir, release] -> release
      _ -> nil
    end
  end

  defp deploy_path_from(wd, exec_start) do
    cond do
      is_binary(wd) and wd != "" -> String.replace_suffix(wd, "/current", "")
      true -> exec_dir(exec_start)
    end
  end

  defp exec_dir(exec_start) do
    case Regex.run(~r{(\S+)/bin/\S+\s+start}, exec_start) do
      [_, dir] -> String.replace_suffix(dir, "/current", "")
      _ -> nil
    end
  end

  defp normalize_state("active"), do: "running"
  defp normalize_state("failed"), do: "failed"
  defp normalize_state("inactive"), do: "stopped"
  defp normalize_state(_), do: "unknown"

  defp scan_sources(server, conn, roots) do
    roots = roots |> Enum.uniq() |> Enum.map(&Remote.shell_quote/1) |> Enum.join(" ")

    cmd = """
    find #{roots} -maxdepth 4 \\( -name mix.exs -o -name rebar.config \\) \
      -not -path '*/deps/*' -not -path '*/_build/*' -not -path '*/node_modules/*' 2>/dev/null | head -100
    """

    case Remote.run(server, cmd, conn: conn, timeout: 90_000) do
      {:ok, %Result{} = result} ->
        result
        |> Result.lines()
        |> Enum.map(&describe_source(server, conn, &1))
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp describe_source(server, conn, file) do
    dir = Path.dirname(file)
    is_mix = String.ends_with?(file, "mix.exs")

    app =
      if is_mix do
        Remote.capture(
          server,
          "grep -m1 -oE 'app:\\s*:[a-z0-9_]+' #{Remote.shell_quote(file)} | sed 's/.*://'",
          conn: conn
        )
      else
        Path.basename(dir)
      end

    app = if app == "", do: Path.basename(dir), else: app

    phoenix? =
      is_mix and
        Remote.capture(server, "grep -c ':phoenix' #{Remote.shell_quote(file)} || true",
          conn: conn
        ) not in ["", "0"]

    %{
      source: :source_tree,
      name: app,
      release_name: app,
      deploy_path: dir,
      kind:
        cond do
          not is_mix -> "erlang_release"
          phoenix? -> "phoenix"
          true -> "elixir_release"
        end,
      repo_url: git_remote(server, conn, dir),
      branch: git_branch(server, conn, dir)
    }
  end

  defp git_remote(server, conn, dir) do
    nilify(
      Remote.capture(
        server,
        "git -C #{Remote.shell_quote(dir)} remote get-url origin 2>/dev/null", conn: conn)
    )
  end

  defp git_branch(server, conn, dir) do
    nilify(
      Remote.capture(
        server,
        "git -C #{Remote.shell_quote(dir)} rev-parse --abbrev-ref HEAD 2>/dev/null",
        conn: conn
      )
    )
  end

  defp scan_processes(server, conn) do
    cmd = "ps -eo pid=,args= 2>/dev/null | grep -F 'beam.smp' | grep -v grep | head -50"

    case Remote.run(server, cmd, conn: conn, timeout: 30_000) do
      {:ok, %Result{} = result} ->
        result
        |> Result.lines()
        |> Enum.map(&parse_process_line/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp parse_process_line(line) do
    case String.split(line, ~r/\s+/, parts: 2) do
      [pid, args] ->
        node = BeamPanel.Remote.Metrics.extract_flag(args, ~w(-name -sname))
        root = BeamPanel.Remote.Metrics.extract_flag(args, ~w(-root))
        cookie = BeamPanel.Remote.Metrics.extract_flag(args, ~w(-setcookie))

        name =
          case node do
            nil -> root && Path.basename(root)
            node -> node |> String.split("@") |> List.first()
          end

        if name do
          %{
            source: :process,
            name: name,
            release_name: name,
            node_name: node,
            node_cookie: cookie,
            pid: pid,
            status: "running",
            deploy_path: root && root |> Path.dirname() |> Path.dirname()
          }
        end

      _ ->
        nil
    end
  end

  ## ------------------------------------------------------------------- merge

  defp merge(units, sources, processes) do
    (units ++ sources ++ processes)
    |> Enum.reduce(%{}, fn candidate, acc ->
      key = candidate[:release_name] || candidate[:name]
      Map.update(acc, key, candidate, &deep_merge(&1, candidate))
    end)
    |> Map.values()
    |> Enum.map(&finalize/1)
    |> Enum.sort_by(& &1.name)
  end

  defp deep_merge(existing, new) do
    Map.merge(existing, new, fn
      :source, a, _b -> a
      _key, a, nil -> a
      _key, a, "" -> a
      _key, nil, b -> b
      _key, "", b -> b
      _key, a, _b -> a
    end)
  end

  defp finalize(candidate) do
    name = candidate[:name] || candidate[:release_name] || "unknown"

    %{
      name: name,
      slug: BeamPanel.Slug.slugify(name),
      kind: candidate[:kind] || "elixir_release",
      release_name: candidate[:release_name] || name,
      service_name: candidate[:service_name] || "#{BeamPanel.Slug.slugify(name)}.service",
      deploy_path: candidate[:deploy_path] || "/opt/beam/#{BeamPanel.Slug.slugify(name)}",
      repo_url: candidate[:repo_url],
      branch: candidate[:branch] || "main",
      node_name: candidate[:node_name],
      node_cookie: candidate[:node_cookie],
      status: candidate[:status] || "unknown",
      pid: candidate[:pid],
      sources: [candidate[:source]] |> List.flatten() |> Enum.reject(&is_nil/1)
    }
  end

  defp nilify(""), do: nil
  defp nilify(value), do: value
end
