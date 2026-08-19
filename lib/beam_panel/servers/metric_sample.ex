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

  @doc """
  Rebuilds the in-memory metrics shape from a persisted row.

  Used to warm the ETS ring at boot so charts show history immediately instead
  of starting empty after every restart. `beam_processes` is not persisted, so
  it comes back empty until the next live poll.
  """
  def to_metrics(%__MODULE__{} = sample) do
    total = sample.mem_total || 0
    used = sample.mem_used || 0
    disk_total = sample.disk_total || 0
    disk_used = sample.disk_used || 0

    %{
      cpu_percent: sample.cpu_percent || 0.0,
      memory: %{
        total: total,
        used: used,
        available: max(total - used, 0),
        cached: 0,
        buffers: 0,
        swap_total: sample.swap_total || 0,
        swap_used: sample.swap_used || 0,
        percent: percent(used, total)
      },
      disk: %{
        total: disk_total,
        used: disk_used,
        available: max(disk_total - disk_used, 0),
        percent: percent(disk_used, disk_total)
      },
      load: %{
        load1: sample.load1 || 0.0,
        load5: sample.load5 || 0.0,
        load15: sample.load15 || 0.0
      },
      uptime: sample.uptime || 0,
      net: %{rx: 0, tx: 0, rx_rate: sample.net_rx || 0, tx_rate: sample.net_tx || 0},
      process_count: sample.processes,
      beam_processes: [],
      recorded_at: sample.recorded_at
    }
  end

  defp percent(_used, total) when total in [nil, 0], do: 0.0
  defp percent(used, total), do: Float.round(used / total * 100, 1)

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
