defmodule BeamPanel.Monitor.Store do
  @moduledoc """
  In-memory ring buffer of recent metric points, one ring per server.

  Keeps the last #{720} samples so charts can be rendered instantly without
  touching PostgreSQL.
  """

  use GenServer

  @table :beam_panel_metrics
  @capacity 720

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, %{}}
  end

  @doc "Appends a derived metrics map to the server ring."
  def put(server_id, metrics) do
    ensure_table()
    history = get(server_id)
    updated = Enum.take([metrics | history], @capacity)
    :ets.insert(@table, {server_id, updated})
    :ok
  end

  @doc "Most recent samples, newest first."
  def get(server_id) do
    ensure_table()

    case :ets.lookup(@table, server_id) do
      [{^server_id, history}] -> history
      [] -> []
    end
  end

  @doc "Most recent samples, oldest first, capped at `limit`."
  def series(server_id, limit \\ 120) do
    server_id |> get() |> Enum.take(limit) |> Enum.reverse()
  end

  @doc "The latest sample, or `nil`."
  def latest(server_id) do
    case get(server_id) do
      [latest | _] -> latest
      [] -> nil
    end
  end

  @doc "Latest sample for every server, as a map."
  def latest_all(server_ids) do
    Map.new(server_ids, &{&1, latest(&1)})
  end

  def clear(server_id) do
    ensure_table()
    :ets.delete(@table, server_id)
    :ok
  end

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  rescue
    ArgumentError -> :ok
  end
end
