defmodule BeamPanel.Maintenance do
  @moduledoc """
  Periodic housekeeping: prunes old metric samples, expires stale deployments
  left behind by a crash, and refreshes project statuses.
  """

  use GenServer
  require Logger

  @interval :timer.minutes(15)
  @stale_deploy_minutes 120

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @doc "Runs one housekeeping pass. Safe to call manually."
  def sweep do
    prune_metrics()
    expire_stale_deployments()
    refresh_project_statuses()
    :ok
  rescue
    error ->
      Logger.warning("maintenance sweep failed: #{Exception.message(error)}")
      :ok
  end

  defp prune_metrics do
    days = Application.get_env(:beam_panel, :metric_retention_days, 14)
    {count, _} = BeamPanel.Servers.prune_metrics(days)
    if count > 0, do: Logger.debug("pruned #{count} metric samples")
    :ok
  end

  defp expire_stale_deployments do
    cutoff = DateTime.add(DateTime.utc_now(), -@stale_deploy_minutes, :minute)

    BeamPanel.Deploy.running_deployments()
    |> Enum.filter(fn d ->
      started = d.started_at || d.inserted_at
      started && DateTime.compare(started, cutoff) == :lt
    end)
    |> Enum.each(fn deployment ->
      BeamPanel.Deploy.update_deployment!(deployment, %{
        status: "failed",
        error: "деплой прерван: превышено время выполнения",
        finished_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
    end)
  end

  defp refresh_project_statuses do
    if Application.get_env(:beam_panel, :start_collectors, true) do
      BeamPanel.Projects.list_projects()
      |> Enum.filter(&(&1.server && &1.server.status == "online"))
      |> Enum.each(fn project ->
        Task.Supervisor.start_child(BeamPanel.TaskSupervisor, fn ->
          BeamPanel.Projects.refresh_status(project)
        end)
      end)
    end
  end

  defp schedule, do: Process.send_after(self(), :sweep, @interval)
end
