defmodule BeamPanel.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      BeamPanelWeb.Telemetry,
      # the vault must be up before anything reads an encrypted column
      BeamPanel.Vault,
      BeamPanel.Repo,
      {DNSCluster, query: Application.get_env(:beam_panel, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: BeamPanel.PubSub},
      {Task.Supervisor, name: BeamPanel.TaskSupervisor},
      BeamPanel.Deploy,
      BeamPanel.Monitor,
      BeamPanel.Maintenance,
      BeamPanelWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: BeamPanel.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    BeamPanelWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
