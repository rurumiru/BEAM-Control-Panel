defmodule BeamPanel.Servers do
  @moduledoc """
  Server inventory: the main server plus every additional server, their groups,
  reachability, facts, services and system-level actions.
  """

  import Ecto.Query, warn: false

  alias BeamPanel.Repo
  alias BeamPanel.Servers.{Server, ServerGroup, MetricSample}
  alias BeamPanel.Remote
  alias BeamPanel.Remote.{Facts, Result}

  @topic "servers"

  def topic, do: @topic
  def topic(%Server{id: id}), do: "server:#{id}"
  def topic(id) when is_integer(id), do: "server:#{id}"

  defp broadcast(event, payload) do
    BeamPanel.Broadcast.publish(@topic, {event, payload})
  end

  defp broadcast_to(server, event, payload) do
    BeamPanel.Broadcast.publish(topic(server), {event, payload})
  end

  ## ------------------------------------------------------------------ queries

  def list_servers do
    Repo.all(from s in Server, order_by: [desc: s.connection, asc: s.name], preload: [:group])
  end

  def list_servers_with_counts do
    project_counts =
      from(p in BeamPanel.Projects.Project,
        group_by: p.server_id,
        select: {p.server_id, count(p.id)}
      )
      |> Repo.all()
      |> Map.new()

    Enum.map(list_servers(), &Map.put(&1, :project_count, Map.get(project_counts, &1.id, 0)))
  end

  def list_monitored_servers do
    Repo.all(from s in Server, where: s.monitor_enabled == true)
  end

  def get_server!(id), do: Repo.get!(Server, id) |> Repo.preload([:group])
  def get_server(id), do: Repo.get(Server, id) |> Repo.preload([:group])
  def get_server_by_slug(slug), do: Repo.get_by(Server, slug: slug) |> Repo.preload([:group])

  def main_server, do: Repo.one(from s in Server, where: s.connection == "local", limit: 1)

  def count_servers, do: Repo.aggregate(Server, :count)

  def count_by_status do
    from(s in Server, group_by: s.status, select: {s.status, count(s.id)})
    |> Repo.all()
    |> Map.new()
  end

  ## --------------------------------------------------------------- mutations

  def change_server(%Server{} = server, attrs \\ %{}), do: Server.changeset(server, attrs)

  def create_server(attrs) do
    %Server{}
    |> Server.changeset(attrs)
    |> Repo.insert()
    |> tap_ok(fn server ->
      broadcast(:server_created, server)
      BeamPanel.Monitor.start_server(server)
    end)
  end

  def update_server(%Server{} = server, attrs) do
    server
    |> Server.changeset(attrs)
    |> Repo.update()
    |> tap_ok(fn server ->
      broadcast(:server_updated, server)
      BeamPanel.Monitor.restart_server(server)
    end)
  end

  def delete_server(%Server{} = server) do
    BeamPanel.Monitor.stop_server(server)

    server
    |> Repo.delete()
    |> tap_ok(fn server -> broadcast(:server_deleted, server) end)
  end

  defp tap_ok({:ok, value} = result, fun) do
    fun.(value)
    result
  end

  defp tap_ok(other, _fun), do: other

  @doc """
  Makes sure a `local` server row exists for the host running the panel.

  Called at boot so the panel can manage itself out of the box.
  """
  def ensure_main_server! do
    case main_server() do
      nil ->
        hostname =
          case :inet.gethostname() do
            {:ok, name} -> to_string(name)
            _ -> "localhost"
          end

        {:ok, server} =
          create_server(%{
            "name" => "Main server",
            "slug" => "main",
            "hostname" => hostname,
            "connection" => "local",
            "role" => "primary",
            "ssh_user" => System.get_env("USER") || System.get_env("USERNAME") || "root",
            "description" => "The host running BEAM Control Panel"
          })

        server

      server ->
        server
    end
  end

  ## ------------------------------------------------------------ connectivity

  @doc "Probes the server and records the outcome (status + facts)."
  def check_connection(%Server{} = server) do
    case Remote.test_connection(server) do
      {:ok, facts} ->
        {:ok, server} = mark_online(server, facts)
        {:ok, server}

      {:error, reason} ->
        {:ok, server} = mark_unreachable(server, reason)
        {:error, format_reason(reason), server}
    end
  end

  def mark_online(%Server{} = server, facts) do
    server
    |> Server.status_changeset(%{
      status: "online",
      status_message: nil,
      last_seen_at: DateTime.utc_now() |> DateTime.truncate(:second),
      facts: (facts == %{} && server.facts) || facts
    })
    |> Repo.update()
    |> tap_ok(&broadcast(:server_status, &1))
  end

  def mark_unreachable(%Server{} = server, reason) do
    server
    |> Server.status_changeset(%{status: "unreachable", status_message: format_reason(reason)})
    |> Repo.update()
    |> tap_ok(&broadcast(:server_status, &1))
  end

  @doc "Sets a transient status such as `provisioning`."
  def mark_status(%Server{} = server, status) do
    server
    |> Server.status_changeset(%{status: status})
    |> Repo.update()
    |> tap_ok(&broadcast(:server_status, &1))
  end

  def refresh_facts(%Server{} = server) do
    facts = Facts.gather(server)

    if facts == %{} do
      {:error, :unreachable}
    else
      mark_online(server, facts)
    end
  end

  def format_reason(reason) when is_binary(reason), do: String.slice(reason, 0, 500)
  def format_reason(reason), do: reason |> inspect() |> String.slice(0, 500)

  ## ---------------------------------------------------------------- services

  @doc "Lists systemd services, optionally filtered by a substring."
  def list_services(%Server{} = server, filter \\ nil) do
    pattern = if filter, do: "'#{String.replace(filter, "'", "")}'", else: "''"

    cmd = """
    systemctl list-units --type=service --all --no-pager --no-legend --plain 2>/dev/null \
      | grep -i #{pattern} | head -300
    """

    case Remote.run(server, cmd) do
      {:ok, %Result{} = result} ->
        services =
          result
          |> Result.lines()
          |> Enum.map(&parse_service_line/1)
          |> Enum.reject(&is_nil/1)

        {:ok, services}

      {:error, reason} ->
        {:error, format_reason(reason)}
    end
  end

  defp parse_service_line(line) do
    case String.split(line, ~r/\s+/, parts: 5) do
      [unit, load, active, sub | rest] ->
        %{
          unit: unit,
          load: load,
          active: active,
          sub: sub,
          description: rest |> List.first() |> Kernel.||("") |> String.trim()
        }

      _ ->
        nil
    end
  end

  @actions ~w(start stop restart reload enable disable status)

  @doc "Runs a systemctl action against a unit."
  def service_action(%Server{} = server, unit, action) when action in @actions do
    unit = sanitize_unit(unit)

    case Remote.run(server, "systemctl #{action} #{Remote.shell_quote(unit)} 2>&1", sudo: true) do
      {:ok, %Result{exit_status: 0} = result} ->
        broadcast_to(server, :service_changed, %{unit: unit, action: action})
        {:ok, Result.combined(result)}

      {:ok, %Result{} = result} ->
        {:error, Result.combined(result)}

      {:error, reason} ->
        {:error, format_reason(reason)}
    end
  end

  def service_action(_server, _unit, action), do: {:error, "unsupported action: #{action}"}

  @doc "Reads the status block of a unit."
  def service_status(%Server{} = server, unit) do
    unit = sanitize_unit(unit)

    {:ok,
     Remote.capture(
       server,
       "systemctl status #{Remote.shell_quote(unit)} --no-pager -n 20 2>&1 | head -60",
       default: "unavailable"
     )}
  end

  defp sanitize_unit(unit), do: String.replace(to_string(unit), ~r/[^A-Za-z0-9._@\-]/, "")

  ## ------------------------------------------------------------ system tasks

  @doc "Reboots the machine (delayed by one second so the response can be returned)."
  def reboot(%Server{} = server) do
    Remote.run(server, "(sleep 1 && systemctl reboot) >/dev/null 2>&1 &",
      sudo: true,
      timeout: 10_000
    )

    {:ok, :rebooting}
  end

  def shutdown(%Server{} = server) do
    Remote.run(server, "(sleep 1 && systemctl poweroff) >/dev/null 2>&1 &",
      sudo: true,
      timeout: 10_000
    )

    {:ok, :shutting_down}
  end

  @doc "Counts pending apt upgrades."
  def pending_updates(%Server{} = server) do
    out =
      Remote.capture(
        server,
        "apt-get -s -o Debug::NoLocking=true upgrade 2>/dev/null | grep -c '^Inst' || true"
      )

    case Integer.parse(out) do
      {count, _} -> count
      :error -> 0
    end
  end

  @doc "Runs `apt-get update && apt-get upgrade -y`, streaming output to `fun`."
  def system_upgrade(%Server{} = server, fun) do
    cmd =
      "DEBIAN_FRONTEND=noninteractive apt-get update && " <>
        "DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confdef upgrade"

    Remote.stream(server, cmd, fun, sudo: true, timeout: 30 * 60_000, collect: false)
  end

  @doc "Top processes by CPU."
  def top_processes(%Server{} = server, limit \\ 15) do
    cmd = "ps -eo pid,user,pcpu,pmem,rss,comm --sort=-pcpu --no-headers | head -#{limit}"

    case Remote.run(server, cmd) do
      {:ok, %Result{} = result} ->
        processes =
          result
          |> Result.lines()
          |> Enum.map(fn line ->
            case String.split(line, ~r/\s+/, parts: 6) do
              [pid, user, cpu, mem, rss, comm] ->
                %{
                  pid: pid,
                  user: user,
                  cpu: to_float(cpu),
                  mem: to_float(mem),
                  rss: (to_int(rss) || 0) * 1024,
                  command: comm
                }

              _ ->
                nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        {:ok, processes}

      {:error, reason} ->
        {:error, format_reason(reason)}
    end
  end

  @doc "Sends SIGTERM (or SIGKILL) to a PID."
  def kill_process(%Server{} = server, pid, signal \\ "TERM") do
    pid = to_string(pid) |> String.replace(~r/\D/, "")
    signal = if signal in ["TERM", "KILL", "HUP", "USR1", "USR2"], do: signal, else: "TERM"

    case Remote.run(server, "kill -#{signal} #{pid}", sudo: true) do
      {:ok, %Result{exit_status: 0}} -> :ok
      {:ok, %Result{} = r} -> {:error, Result.combined(r)}
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  defp to_float(value) do
    case Float.parse(to_string(value)) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp to_int(value) do
    case Integer.parse(to_string(value)) do
      {i, _} -> i
      :error -> nil
    end
  end

  ## ------------------------------------------------------------------ groups

  def list_groups do
    Repo.all(from g in ServerGroup, order_by: [asc: g.name], preload: [:servers])
  end

  def get_group!(id), do: Repo.get!(ServerGroup, id) |> Repo.preload([:servers])

  def change_group(%ServerGroup{} = group, attrs \\ %{}), do: ServerGroup.changeset(group, attrs)

  def create_group(attrs) do
    %ServerGroup{} |> ServerGroup.changeset(attrs) |> Repo.insert()
  end

  def update_group(%ServerGroup{} = group, attrs) do
    group |> ServerGroup.changeset(attrs) |> Repo.update()
  end

  def delete_group(%ServerGroup{} = group), do: Repo.delete(group)

  ## ----------------------------------------------------------------- metrics

  @doc "Persists a metric sample (called by the collector on a slower cadence)."
  def record_sample(server_id, metrics) do
    %MetricSample{}
    |> MetricSample.changeset(MetricSample.from_metrics(server_id, metrics))
    |> Repo.insert()
  end

  @doc "Historical samples for charts."
  def metric_history(server_id, opts \\ []) do
    since = Keyword.get(opts, :since, DateTime.add(DateTime.utc_now(), -24, :hour))
    limit = Keyword.get(opts, :limit, 500)

    Repo.all(
      from m in MetricSample,
        where: m.server_id == ^server_id and m.recorded_at >= ^since,
        order_by: [asc: m.recorded_at],
        limit: ^limit
    )
  end

  @doc "Deletes samples older than `days`."
  def prune_metrics(days \\ 14) do
    cutoff = DateTime.add(DateTime.utc_now(), -days * 24, :hour)
    Repo.delete_all(from m in MetricSample, where: m.recorded_at < ^cutoff)
  end
end
