defmodule BeamPanel.Provision do
  @moduledoc """
  Prepares servers to build and run BEAM applications.

  A run renders `BeamPanel.Provision.Playbook` into a bash script, uploads it to
  the target host and executes it with streaming output.
  """

  import Ecto.Query, warn: false
  require Logger

  alias BeamPanel.Repo
  alias BeamPanel.Provision.{ProvisionRun, Playbook}
  alias BeamPanel.{Servers, Remote, Audit, Notifications}
  alias BeamPanel.Servers.Server
  alias BeamPanel.Deploy.LogStore

  @script_path "/tmp/beam-panel-bootstrap.sh"

  def topic(%ProvisionRun{id: id}), do: "provision:#{id}"
  def topic(id) when is_integer(id), do: "provision:#{id}"

  ## ------------------------------------------------------------------ queries

  def list_runs(server_id \\ nil) do
    ProvisionRun
    |> then(fn q -> if server_id, do: where(q, [r], r.server_id == ^server_id), else: q end)
    |> order_by(desc: :inserted_at)
    |> limit(50)
    |> preload([:server, :user])
    |> Repo.all()
  end

  def get_run!(id), do: ProvisionRun |> Repo.get!(id) |> Repo.preload([:server, :user])
  def get_run(id), do: ProvisionRun |> Repo.get(id) |> Repo.preload([:server, :user])

  def running?(%Server{id: id}) do
    Repo.exists?(
      from r in ProvisionRun, where: r.server_id == ^id and r.status in ["pending", "running"]
    )
  end

  ## --------------------------------------------------------------- launching

  @doc """
  Starts provisioning `server` with the given component keys and options.

  Returns `{:ok, run}`; progress is broadcast on `provision:<id>`.
  """
  def provision(%Server{} = server, components, options, user) do
    components = Enum.filter(components, &(Playbook.component(&1) != nil))

    cond do
      components == [] ->
        {:error, :no_components}

      running?(server) ->
        {:error, :already_running}

      true ->
        {:ok, run} =
          %ProvisionRun{}
          |> ProvisionRun.changeset(%{
            server_id: server.id,
            user_id: user && user.id,
            components: components,
            options: stringify(options),
            status: "pending"
          })
          |> Repo.insert()

        LogStore.clear(log_key(run))

        Task.Supervisor.start_child(BeamPanel.TaskSupervisor, fn -> execute(run.id) end)

        Audit.log(user, "provision.start",
          resource_type: "server",
          resource_id: server.id,
          metadata: %{components: components}
        )

        {:ok, run}
    end
  end

  @doc "Renders the script without executing it — used for preview and export."
  def preview(components, options), do: Playbook.render(components, options)

  ## ---------------------------------------------------------------- execution

  defp execute(run_id) do
    run = get_run!(run_id)
    server = run.server
    script = Playbook.render(run.components, run.options)

    log = logger(run)

    run =
      update_run!(run, %{
        status: "running",
        started_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    Servers.mark_status(server, "provisioning")
    broadcast(run, {:provision_status, "running"})

    log.("── Провижининг #{server.name} (#{server.hostname}) ──")
    log.("Компоненты: #{Enum.join(run.components, ", ")}")

    result =
      Remote.with_connection(server, fn conn ->
        with :ok <- Remote.write_file(server, @script_path, script, conn: conn, mode: "700"),
             {:ok, %{exit_status: status}} <-
               Remote.stream(
                 server,
                 # `rc=$?` обязателен: без него статус берётся от `rm`,
                 # и провалившийся скрипт выглядел бы как успешный.
                 "bash #{@script_path} 2>&1; rc=$?; rm -f #{@script_path}; exit $rc",
                 fn _io, chunk ->
                   chunk
                   |> String.split(~r/\r?\n/)
                   |> Enum.reject(&(String.trim(&1) == ""))
                   |> Enum.each(log)
                 end,
                 conn: conn,
                 sudo: true,
                 collect: false,
                 timeout: 60 * 60_000
               ) do
          if status == 0, do: :ok, else: {:error, "скрипт завершился с кодом #{status}"}
        end
      end)

    {status, error} =
      case result do
        :ok ->
          log.("✓ Провижининг завершён успешно")
          {"success", nil}

        {:error, reason} ->
          reason = Servers.format_reason(reason)
          log.("✗ Провижининг провален: #{reason}")
          {"failed", reason}
      end

    update_run!(run, %{
      status: status,
      error: error,
      log: LogStore.text(log_key(run)),
      finished_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })

    # refresh facts so the UI immediately reflects the newly installed toolchain
    Servers.refresh_facts(server)

    broadcast(run, {:provision_status, status})
    Notifications.dispatch(:provision_finished, %{server: server, status: status})

    :ok
  rescue
    error ->
      Logger.error("provision run #{run_id} crashed: #{Exception.message(error)}")

      case get_run(run_id) do
        nil ->
          :ok

        run ->
          update_run!(run, %{
            status: "failed",
            error: Exception.message(error),
            log: LogStore.text(log_key(run)),
            finished_at: DateTime.utc_now() |> DateTime.truncate(:second)
          })

          broadcast(run, {:provision_status, "failed"})
      end
  end

  defp logger(run) do
    key = log_key(run)

    fn line ->
      line = String.trim_trailing(to_string(line))
      LogStore.append(key, line)
      broadcast(run, {:provision_log, line})
      :ok
    end
  end

  defp broadcast(run, message),
    do: BeamPanel.Broadcast.publish(topic(run), message)

  defp log_key(%ProvisionRun{id: id}), do: {:provision, id}

  @doc "Log lines for a run — live buffer while running, DB once finished."
  def log_lines(%ProvisionRun{} = run) do
    case LogStore.lines(log_key(run)) do
      [] -> String.split(run.log || "", ~r/\r?\n/)
      lines -> lines
    end
  end

  defp update_run!(%ProvisionRun{} = run, attrs) do
    run |> ProvisionRun.changeset(attrs) |> Repo.update!()
  end

  defp stringify(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp stringify(_), do: %{}
end
