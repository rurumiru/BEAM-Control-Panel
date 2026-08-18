defmodule BeamPanel.Servers.MetricSample do
  @moduledoc "Persisted metric point, used for history beyond the in-memory ring buffer."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  schema "metric_samples" do
    field :cpu_percent, :float
    field :load1, :float
    field :load5, :float
    field :load15, :float
    field :mem_total, :integer
    field :mem_used, :integer
    field :swap_total, :integer
    field :swap_used, :integer
    field :disk_total, :integer
    field :disk_used, :integer
    field :net_rx, :integer
    field :net_tx, :integer
    field :processes, :integer
    field :uptime, :integer
    field :recorded_at, :utc_datetime_usec

    belongs_to :server, BeamPanel.Servers.Server
  end

  @fields ~w(server_id cpu_percent load1 load5 load15 mem_total mem_used swap_total swap_used
             disk_total disk_used net_rx net_tx processes uptime recorded_at)a

  def changeset(sample, attrs) do
    sample
    |> cast(attrs, @fields)
    |> validate_required([:server_id, :recorded_at])
  end

  @doc "Builds attrs from a derived metrics map."
  def from_metrics(server_id, metrics) do
    %{
      server_id: server_id,
      cpu_percent: metrics.cpu_percent,
      load1: metrics.load.load1,
      load5: metrics.load.load5,
      load15: metrics.load.load15,
      mem_total: metrics.memory.total,
      mem_used: metrics.memory.used,
      swap_total: metrics.memory.swap_total,
      swap_used: metrics.memory.swap_used,
      disk_total: metrics.disk.total,
      disk_used: metrics.disk.used,
      net_rx: metrics.net.rx_rate,
      net_tx: metrics.net.tx_rate,
      processes: metrics.process_count,
      uptime: metrics.uptime,
      recorded_at: metrics.recorded_at
    }
  end
end
