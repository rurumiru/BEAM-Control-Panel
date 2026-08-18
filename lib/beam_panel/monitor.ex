defmodule BeamPanel.Monitor do
  @moduledoc """
  Supervision tree for metric collection.

  A `DynamicSupervisor` runs one `BeamPanel.Monitor.Collector` per monitored
  server, addressed through a `Registry` keyed by server id.
  """

  use Supervisor
  require Logger

  alias BeamPanel.Monitor.{Collector, Store}

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: BeamPanel.Monitor.Registry},
      Store,
      {DynamicSupervisor, name: BeamPanel.Monitor.DynamicSupervisor, strategy: :one_for_one},
      {Task, &boot_collectors/0}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc "Starts collectors for every monitored server (called at boot)."
  def boot_collectors do
    if start_collectors?() do
      BeamPanel.Servers.ensure_main_server!()

      BeamPanel.Servers.list_monitored_servers()
      |> Enum.each(&start_server/1)
    end
  rescue
    error ->
      Logger.warning("monitor bootstrap skipped: #{Exception.message(error)}")
      :ok
  end

  defp start_collectors? do
    Application.get_env(:beam_panel, :start_collectors, true)
  end

  @doc "Starts a collector for `server` unless one is already running."
  def start_server(%{monitor_enabled: false}), do: :ignored

  def start_server(server) do
    if not start_collectors?() do
      :ignored
    else
      do_start_server(server)
    end
  end

  defp do_start_server(server) do
    case DynamicSupervisor.start_child(BeamPanel.Monitor.DynamicSupervisor, {Collector, server}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      error -> error
    end
  end

  @doc "Stops the collector for `server`."
  def stop_server(server) do
    case Registry.lookup(BeamPanel.Monitor.Registry, server.id) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(BeamPanel.Monitor.DynamicSupervisor, pid)
        Store.clear(server.id)
        :ok

      [] ->
        :ok
    end
  end

  @doc "Restarts the collector so configuration changes take effect."
  def restart_server(server) do
    stop_server(server)
    if server.monitor_enabled, do: start_server(server), else: :ok
  end

  @doc "Forces an immediate poll."
  defdelegate poll_now(server_id), to: Collector

  @doc "Latest metrics for a server."
  defdelegate latest(server_id), to: Store

  @doc "Latest metrics for many servers, keyed by id."
  defdelegate latest_all(server_ids), to: Store

  @doc "Recent series for charts (oldest first)."
  defdelegate series(server_id, limit \\ 120), to: Store

  @doc "Whether a collector is currently running for the server."
  def running?(server_id), do: Registry.lookup(BeamPanel.Monitor.Registry, server_id) != []
end
