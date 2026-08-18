defmodule BeamPanel.Projects do
  @moduledoc """
  BEAM projects: registration, discovery, environment variables, service control
  and log streaming.
  """

  import Ecto.Query, warn: false

  alias BeamPanel.Repo
  alias BeamPanel.Projects.{Project, EnvVar, Systemd, Discovery}
  alias BeamPanel.Servers
  alias BeamPanel.Servers.Server
  alias BeamPanel.Remote
  alias BeamPanel.Remote.Result

  @topic "projects"

  def topic, do: @topic
  def topic(%Project{id: id}), do: "project:#{id}"
  def topic(id) when is_integer(id), do: "project:#{id}"

  defp broadcast(event, payload),
    do: BeamPanel.Broadcast.publish(@topic, {event, payload})

  defp broadcast_to(project, event, payload),
    do: BeamPanel.Broadcast.publish(topic(project), {event, payload})

  ## ------------------------------------------------------------------ queries

  def list_projects do
    Repo.all(from p in Project, order_by: [asc: p.name], preload: [:server])
  end

  def list_projects_for_server(server_id) do
    Repo.all(from p in Project, where: p.server_id == ^server_id, order_by: [asc: p.name])
  end

  def get_project!(id), do: Repo.get!(Project, id) |> Repo.preload([:server, :env_vars])
  def get_project(id), do: Repo.get(Project, id) |> Repo.preload([:server, :env_vars])

  def count_projects, do: Repo.aggregate(Project, :count)

  def count_by_status do
    from(p in Project, group_by: p.status, select: {p.status, count(p.id)})
    |> Repo.all()
    |> Map.new()
  end

  ## ---------------------------------------------------------------- mutations

  def change_project(%Project{} = project, attrs \\ %{}), do: Project.changeset(project, attrs)

  def create_project(attrs) do
    %Project{}
    |> Project.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, project} ->
        project = Repo.preload(project, [:server, :env_vars])
        broadcast(:project_created, project)
        {:ok, project}

      error ->
        error
    end
  end

  def update_project(%Project{} = project, attrs) do
    project
    |> Project.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, project} ->
        project = Repo.preload(project, [:server, :env_vars], force: true)
        broadcast(:project_updated, project)
        {:ok, project}

      error ->
        error
    end
  end

  def delete_project(%Project{} = project) do
    case Repo.delete(project) do
      {:ok, project} ->
        broadcast(:project_deleted, project)
        {:ok, project}

      error ->
        error
    end
  end

  def set_status(%Project{} = project, attrs) do
    project
    |> Project.status_changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, project} ->
        broadcast(:project_updated, project)
        broadcast_to(project, :status, project.status)
        {:ok, project}

      error ->
        error
    end
  end

  ## ---------------------------------------------------------------- discovery

  @doc "Scans a server for BEAM applications that are not registered yet."
  def discover(%Server{} = server) do
    known =
      server.id
      |> list_projects_for_server()
      |> Enum.flat_map(&[&1.slug, &1.service_name, &1.release_name])
      |> MapSet.new()

    case Discovery.scan(server) do
      {:ok, candidates} ->
        {:ok,
         Enum.map(candidates, fn candidate ->
           registered =
             MapSet.member?(known, candidate.slug) or
               MapSet.member?(known, candidate.service_name) or
               MapSet.member?(known, candidate.release_name)

           Map.put(candidate, :registered, registered)
         end)}

      {:error, reason} ->
        {:error, Servers.format_reason(reason)}
    end
  end

  @doc "Turns a discovery candidate into a persisted project."
  def import_candidate(%Server{} = server, candidate) do
    attrs = %{
      "server_id" => server.id,
      "name" => candidate["name"] || candidate[:name],
      "slug" => candidate["slug"] || candidate[:slug],
      "kind" => candidate["kind"] || candidate[:kind] || "elixir_release",
      "release_name" => candidate["release_name"] || candidate[:release_name],
      "service_name" => candidate["service_name"] || candidate[:service_name],
      "deploy_path" => candidate["deploy_path"] || candidate[:deploy_path],
      "repo_url" => candidate["repo_url"] || candidate[:repo_url],
      "branch" => candidate["branch"] || candidate[:branch] || "main",
      "node_name" => candidate["node_name"] || candidate[:node_name],
      "node_cookie" => candidate["node_cookie"] || candidate[:node_cookie],
      "discovered" => true
    }

    create_project(attrs)
  end

  ## -------------------------------------------------------------- env vars

  def list_env_vars(project_id) do
    Repo.all(from e in EnvVar, where: e.project_id == ^project_id, order_by: [asc: e.key])
  end

  def change_env_var(%EnvVar{} = env_var, attrs \\ %{}), do: EnvVar.changeset(env_var, attrs)

  def create_env_var(%Project{} = project, attrs) do
    %EnvVar{project_id: project.id}
    |> EnvVar.changeset(attrs)
    |> Repo.insert()
  end

  def update_env_var(%EnvVar{} = env_var, attrs) do
    env_var |> EnvVar.changeset(attrs) |> Repo.update()
  end

  def delete_env_var(%EnvVar{} = env_var), do: Repo.delete(env_var)

  @doc "Bulk-imports variables from `KEY=value` text (dotenv style)."
  def import_env(%Project{} = project, text) do
    text
    |> String.split(~r/\r?\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.reduce({0, 0}, fn line, {ok, failed} ->
      case String.split(line, "=", parts: 2) do
        [key, value] ->
          value = value |> String.trim() |> String.trim("\"") |> String.trim("'")

          attrs = %{"key" => String.trim(key), "value" => value, "secret" => secret_key?(key)}

          case upsert_env_var(project, attrs) do
            {:ok, _} -> {ok + 1, failed}
            _ -> {ok, failed + 1}
          end

        _ ->
          {ok, failed + 1}
      end
    end)
  end

  defp secret_key?(key) do
    key = String.upcase(key)
    Enum.any?(~w(SECRET PASSWORD TOKEN KEY DSN CREDENTIAL), &String.contains?(key, &1))
  end

  defp upsert_env_var(project, attrs) do
    key = attrs["key"] |> to_string() |> String.upcase()

    case Repo.get_by(EnvVar, project_id: project.id, key: key) do
      nil -> create_env_var(project, attrs)
      existing -> update_env_var(existing, attrs)
    end
  end

  ## ------------------------------------------------------------ service sync

  @doc """
  Writes the systemd unit and environment file for a project, then reloads
  systemd. Returns `{:ok, unit_path}`.
  """
  def sync_service(%Project{} = project) do
    project = Repo.preload(project, [:server, :env_vars])
    server = project.server
    unit = Systemd.render_unit(project, server)
    env = Systemd.render_env(project, project.env_vars)

    Remote.with_connection(server, fn conn ->
      opts = [conn: conn]

      with :ok <- ensure_directories(server, project, opts),
           :ok <- Remote.write_file(server, Systemd.env_path(project), env, opts ++ [mode: "600"]),
           :ok <- write_unit(server, project, unit, opts),
           {:ok, _} <- run(server, "systemctl daemon-reload", opts),
           :ok <- maybe_enable(server, project, opts) do
        {:ok, Systemd.unit_path(project)}
      else
        {:error, reason} -> {:error, Servers.format_reason(reason)}
      end
    end)
  end

  defp ensure_directories(server, project, opts) do
    user = server.deploy_user || "deploy"

    dirs =
      [
        project.deploy_path,
        Path.join(project.deploy_path, "shared"),
        Path.join(project.deploy_path, "releases"),
        Path.join(project.deploy_path, "tmp"),
        Path.join(project.deploy_path, "source")
      ]
      |> Enum.map_join(" ", &Remote.shell_quote/1)

    cmd =
      "mkdir -p #{dirs} && chown -R #{user}:#{user} #{Remote.shell_quote(project.deploy_path)} || true"

    case run(server, cmd, opts ++ [sudo: true]) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp write_unit(server, project, unit, opts) do
    tmp = "/tmp/#{Project.unit_base(project)}.service"

    with :ok <- Remote.write_file(server, tmp, unit, opts),
         {:ok, _} <-
           run(
             server,
             "install -m 0644 #{Remote.shell_quote(tmp)} #{Remote.shell_quote(Systemd.unit_path(project))} && rm -f #{Remote.shell_quote(tmp)}",
             opts ++ [sudo: true]
           ) do
      :ok
    end
  end

  defp maybe_enable(server, %Project{autostart: true} = project, opts) do
    case run(
           server,
           "systemctl enable #{Remote.shell_quote(project.service_name)}",
           opts ++ [sudo: true]
         ) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp maybe_enable(_server, _project, _opts), do: :ok

  defp run(server, command, opts) do
    case Remote.run(server, command, opts) do
      {:ok, %Result{exit_status: 0} = result} -> {:ok, result}
      {:ok, %Result{} = result} -> {:error, Result.combined(result)}
      {:error, reason} -> {:error, reason}
    end
  end

  ## ------------------------------------------------------------ service ctl

  @doc "start | stop | restart | reload the project's systemd unit."
  def control(%Project{} = project, action) when action in ~w(start stop restart reload) do
    project = Repo.preload(project, :server)

    case Servers.service_action(project.server, project.service_name, action) do
      {:ok, output} ->
        refresh_status(project)
        {:ok, output}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def control(_project, action), do: {:error, "unsupported action: #{action}"}

  @doc "Reads the unit state and updates the project status."
  def refresh_status(%Project{} = project) do
    project = Repo.preload(project, :server)

    state =
      Remote.capture(
        project.server,
        "systemctl is-active #{Remote.shell_quote(project.service_name)} 2>/dev/null",
        default: "unknown"
      )

    status =
      case String.trim(state) do
        "active" -> "running"
        "activating" -> "deploying"
        "failed" -> "failed"
        "inactive" -> "stopped"
        _ -> "unknown"
      end

    set_status(project, %{status: status})
  end

  @doc "Detailed runtime info for the project's unit."
  def service_details(%Project{} = project) do
    project = Repo.preload(project, :server)
    unit = Remote.shell_quote(project.service_name)

    cmd = """
    systemctl show #{unit} -p ActiveState -p SubState -p MainPID -p ExecMainStartTimestamp \
      -p MemoryCurrent -p CPUUsageNSec -p NRestarts -p FragmentPath 2>/dev/null
    """

    case Remote.run(project.server, cmd) do
      {:ok, %Result{} = result} ->
        details =
          result
          |> Result.lines()
          |> Enum.reduce(%{}, fn line, acc ->
            case String.split(line, "=", parts: 2) do
              [key, value] -> Map.put(acc, key, value)
              _ -> acc
            end
          end)

        {:ok, details}

      {:error, reason} ->
        {:error, Servers.format_reason(reason)}
    end
  end

  @doc "Runs the project's health check over HTTP from the target server."
  def health_check(%Project{} = project) do
    project = Repo.preload(project, :server)

    case Project.health_endpoint(project) do
      nil ->
        {:error, :no_health_endpoint}

      url ->
        cmd =
          "curl -s -o /dev/null -w '%{http_code} %{time_total}' --max-time 10 #{Remote.shell_quote(url)}"

        case Remote.run(project.server, cmd, timeout: 20_000) do
          {:ok, %Result{stdout: out}} ->
            case String.split(String.trim(out)) do
              [code, time] -> {:ok, %{status: String.to_integer(code), time: time, url: url}}
              _ -> {:error, :unparsable}
            end

          {:error, reason} ->
            {:error, Servers.format_reason(reason)}
        end
    end
  end

  ## ----------------------------------------------------------------- logging

  @doc "Returns the last `lines` journal entries for the project."
  def logs(%Project{} = project, lines \\ 200) do
    project = Repo.preload(project, :server)
    unit = Remote.shell_quote(project.service_name)

    {:ok,
     Remote.capture(
       project.server,
       "journalctl -u #{unit} -n #{lines} --no-pager -o short-iso 2>&1",
       default: "",
       timeout: 60_000
     )}
  end

  @doc """
  Follows the journal, invoking `fun.(line)` for every line.

  Runs until the caller's process exits or the connection drops; intended to be
  spawned from a LiveView under a `Task`.
  """
  def follow_logs(%Project{} = project, fun) do
    project = Repo.preload(project, :server)
    unit = Remote.shell_quote(project.service_name)

    Remote.stream(
      project.server,
      "journalctl -u #{unit} -f -n 100 --no-pager -o short-iso 2>&1",
      fn _io, chunk -> chunk |> String.split(~r/\r?\n/) |> Enum.each(fun) end,
      collect: false,
      timeout: :infinity
    )
  end

  ## --------------------------------------------------------------- remote ops

  @doc "Executes `bin/<release> <args>` (for example `remote`, `rpc`, `eval`)."
  def release_command(%Project{} = project, args, opts \\ []) do
    project = Repo.preload(project, :server)
    bin = Project.bin_path(project)

    cmd = "#{Remote.shell_quote(bin)} #{args}"

    Remote.run(
      project.server,
      cmd,
      Keyword.merge(
        [sudo: true, timeout: 60_000, env: %{"RELEASE_NODE" => project.node_name || ""}],
        opts
      )
    )
  end

  @doc "Runs Elixir code inside the release via `rpc` and returns stdout."
  def rpc(%Project{} = project, code) do
    case release_command(project, "rpc #{Remote.shell_quote(code)}") do
      {:ok, %Result{exit_status: 0} = result} -> {:ok, Result.out(result)}
      {:ok, %Result{} = result} -> {:error, Result.combined(result)}
      {:error, reason} -> {:error, Servers.format_reason(reason)}
    end
  end
end
