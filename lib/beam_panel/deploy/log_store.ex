defmodule BeamPanel.Deploy.LogStore do
  @moduledoc """
  Buffers deployment output in ETS while a run is in progress, so LiveViews that
  join mid-deploy can render everything that happened so far.
  """

  use GenServer

  @table :beam_panel_deploy_logs

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  def append(id, line) do
    ensure()
    :ets.insert(@table, {id, [line | fetch(id)]})
    :ok
  end

  def fetch(id) do
    ensure()

    case :ets.lookup(@table, id) do
      [{^id, lines}] -> lines
      [] -> []
    end
  end

  @doc "Lines in chronological order."
  def lines(id), do: id |> fetch() |> Enum.reverse()

  @doc "Full log as a single string."
  def text(id), do: id |> lines() |> Enum.join("\n")

  def clear(id) do
    ensure()
    :ets.delete(@table, id)
    :ok
  end

  defp ensure do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  rescue
    ArgumentError -> :ok
  end
end
