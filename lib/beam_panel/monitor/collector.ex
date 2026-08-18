defmodule BeamPanel.Monitor.Collector do
  @moduledoc """
  One GenServer per monitored server.

  Keeps a single SSH connection open across ticks, samples `/proc`, derives rates
  from the previous sample, pushes the result into `BeamPanel.Monitor.Store` and
  broadcasts it over PubSub. Persists a row to PostgreSQL every `@persist_every`
  ticks so history survives restarts.

  On repeated failures the server is flagged `unreachable` and the poll interval
  backs off exponentially, up to five minutes.
  """

  use GenServer, restart: :transient
  require Logger

  alias BeamPanel.{Servers, Remote}
  alias BeamPanel.Remote.{Metrics, SSH}
  alias BeamPanel.Monitor.Store

  @persist_every 6
  @max_backoff 300_000
  @failures_before_unreachable 2

  def start_link(server), do: GenServer.start_link(__MODULE__, server, name: via(server.id))

  def via(server_id), do: {:via, Registry, {BeamPanel.Monitor.Registry, server_id}}

  @doc "Triggers an immediate poll."
  def poll_now(server_id) do
    case Registry.lookup(BeamPanel.Monitor.Registry, server_id) do
      [{pid, _}] -> send(pid, :tick)
      [] -> :not_running
    end
  end

  @impl true
  def init(server) do
    send(self(), :tick)

    {:ok,
     %{
       server: server,
       conn: nil,
       previous: nil,
       failures: 0,
       ticks: 0,
       interval: (server.monitor_interval || 10) * 1000
     }}
  end

  @impl true
  def handle_info(:tick, state) do
    state = tick(state)
    Process.send_after(self(), :tick, next_interval(state))
    {:noreply, state}
  end

  def handle_info({:server_updated, server}, state) when is_map(server) do
    {:noreply, %{state | server: server, interval: (server.monitor_interval || 10) * 1000}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{conn: conn}) when not is_nil(conn), do: SSH.close(conn)
  def terminate(_reason, _state), do: :ok

  ## ---------------------------------------------------------------- internals

  defp tick(state) do
    with {:ok, state} <- ensure_connection(state),
         {:ok, raw} <- Metrics.sample(state.server, conn: state.conn, timeout: 25_000) do
      metrics = Metrics.derive(state.previous, raw)

      Store.put(state.server.id, metrics)

      Phoenix.PubSub.broadcast(
        BeamPanel.PubSub,
        Servers.topic(state.server),
        {:metrics, state.server.id, metrics}
      )

      Phoenix.PubSub.broadcast(
        BeamPanel.PubSub,
        Servers.topic(),
        {:metrics, state.server.id, metrics}
      )

      state = maybe_persist(state, metrics)
      state = maybe_mark_online(state)

      %{state | previous: raw, failures: 0, ticks: state.ticks + 1}
    else
      {:error, reason} -> handle_failure(state, reason)
    end
  end

  defp ensure_connection(%{server: server} = state) do
    cond do
      Remote.local?(server) ->
        {:ok, state}

      is_nil(state.conn) ->
        case SSH.connect(server, connect_timeout: 15_000) do
          {:ok, conn} -> {:ok, %{state | conn: conn}}
          {:error, reason} -> {:error, reason}
        end

      true ->
        {:ok, state}
    end
  end

  defp maybe_persist(state, metrics) do
    if rem(state.ticks, @persist_every) == 0 do
      Servers.record_sample(state.server.id, metrics)
    end

    state
  rescue
    error ->
      Logger.warning("failed to persist metric sample: #{Exception.message(error)}")
      state
  end

  defp maybe_mark_online(%{server: server} = state) do
    if server.status != "online" do
      case Servers.mark_online(server, %{}) do
        {:ok, server} -> %{state | server: server}
        _ -> state
      end
    else
      touch_last_seen(state)
    end
  end

  defp touch_last_seen(%{server: server, ticks: ticks} = state) when rem(ticks, 30) == 0 do
    case Servers.mark_online(server, %{}) do
      {:ok, server} -> %{state | server: server}
      _ -> state
    end
  end

  defp touch_last_seen(state), do: state

  defp handle_failure(state, reason) do
    if state.conn, do: SSH.close(state.conn)

    failures = state.failures + 1

    state =
      if failures == @failures_before_unreachable do
        Logger.warning(
          "server #{state.server.name} unreachable: #{Servers.format_reason(reason)}"
        )

        case Servers.mark_unreachable(state.server, reason) do
          {:ok, server} -> %{state | server: server}
          _ -> state
        end
      else
        state
      end

    %{state | conn: nil, previous: nil, failures: failures}
  end

  defp next_interval(%{failures: 0, interval: interval}), do: interval

  defp next_interval(%{failures: failures, interval: interval}) do
    min(interval * :math.pow(2, min(failures, 6)), @max_backoff) |> round()
  end
end
