defmodule BeamPanel.Remote.Metrics do
  @moduledoc """
  System metrics sampling.

  One shell round-trip returns raw counters from `/proc`; `derive/2` turns two
  consecutive raw samples into rates (CPU %, network bytes/s).
  """

  alias BeamPanel.Remote
  alias BeamPanel.Remote.Result

  @script """
  echo '@stat'; grep '^cpu ' /proc/stat
  echo '@mem'; grep -E '^(MemTotal|MemAvailable|MemFree|Buffers|Cached|SwapTotal|SwapFree):' /proc/meminfo
  echo '@load'; cat /proc/loadavg
  echo '@uptime'; cat /proc/uptime
  echo '@disk'; df -kP / | tail -n +2
  echo '@net'; grep -E ':' /proc/net/dev | grep -v -E '^\\s*(lo|docker|veth|br-)'
  echo '@beam'; ps -eo pid=,rss=,etimes=,args= 2>/dev/null | grep -F 'beam.smp' | grep -v grep
  echo '@procs'; ps -e --no-headers 2>/dev/null | wc -l
  echo '@end'
  """

  @doc "Takes a raw sample from the server."
  @spec sample(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def sample(server, opts \\ []) do
    case Remote.run(server, @script, Keyword.put_new(opts, :timeout, 30_000)) do
      {:ok, %Result{exit_status: 0} = result} -> {:ok, parse(result.stdout)}
      {:ok, %Result{} = result} -> {:error, Result.combined(result)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Parses the raw script output into a structured sample."
  @spec parse(String.t()) :: map()
  def parse(output) do
    sections = split_sections(output)

    %{
      cpu: parse_cpu(sections["stat"]),
      memory: parse_mem(sections["mem"]),
      load: parse_load(sections["load"]),
      uptime: parse_uptime(sections["uptime"]),
      disk: parse_disk(sections["disk"]),
      net: parse_net(sections["net"]),
      beam_processes: parse_beam(sections["beam"]),
      process_count: parse_int(List.first(sections["procs"] || [])),
      taken_at: System.monotonic_time(:millisecond),
      recorded_at: DateTime.utc_now()
    }
  end

  defp split_sections(output) do
    output
    |> String.split(~r/\r?\n/)
    |> Enum.reduce({nil, %{}}, fn line, {current, acc} ->
      case Regex.run(~r/^@(\w+)$/, String.trim(line)) do
        [_, name] ->
          {name, Map.put_new(acc, name, [])}

        nil ->
          if current,
            do: {current, Map.update(acc, current, [line], &(&1 ++ [line]))},
            else: {current, acc}
      end
    end)
    |> elem(1)
  end

  ## cpu -----------------------------------------------------------------

  defp parse_cpu([line | _]) do
    case String.split(String.trim(line)) do
      ["cpu" | values] ->
        nums = Enum.map(values, &parse_int/1) |> Enum.reject(&is_nil/1)
        idle = Enum.at(nums, 3, 0) + Enum.at(nums, 4, 0)
        total = Enum.sum(nums)
        %{total: total, idle: idle}

      _ ->
        nil
    end
  end

  defp parse_cpu(_), do: nil

  ## memory --------------------------------------------------------------

  defp parse_mem(lines) when is_list(lines) do
    map =
      Enum.reduce(lines, %{}, fn line, acc ->
        case Regex.run(~r/^(\w+):\s+(\d+)/, String.trim(line)) do
          [_, key, value] -> Map.put(acc, key, String.to_integer(value) * 1024)
          nil -> acc
        end
      end)

    total = map["MemTotal"] || 0
    available = map["MemAvailable"] || map["MemFree"] || 0
    swap_total = map["SwapTotal"] || 0
    swap_free = map["SwapFree"] || 0

    %{
      total: total,
      available: available,
      used: max(total - available, 0),
      cached: map["Cached"] || 0,
      buffers: map["Buffers"] || 0,
      swap_total: swap_total,
      swap_used: max(swap_total - swap_free, 0),
      percent: percent(total - available, total)
    }
  end

  defp parse_mem(_),
    do: %{total: 0, used: 0, available: 0, percent: 0.0, swap_total: 0, swap_used: 0}

  ## load ----------------------------------------------------------------

  defp parse_load([line | _]) do
    case String.split(String.trim(line)) do
      [l1, l5, l15 | _] ->
        %{load1: parse_float(l1), load5: parse_float(l5), load15: parse_float(l15)}

      _ ->
        %{load1: 0.0, load5: 0.0, load15: 0.0}
    end
  end

  defp parse_load(_), do: %{load1: 0.0, load5: 0.0, load15: 0.0}

  ## uptime --------------------------------------------------------------

  defp parse_uptime([line | _]) do
    case String.split(String.trim(line)) do
      [seconds | _] -> seconds |> parse_float() |> trunc()
      _ -> 0
    end
  end

  defp parse_uptime(_), do: 0

  ## disk ----------------------------------------------------------------

  defp parse_disk(lines) when is_list(lines) do
    case Enum.find(lines, &(String.trim(&1) != "")) do
      nil ->
        %{total: 0, used: 0, available: 0, percent: 0.0}

      line ->
        case String.split(String.trim(line)) do
          [_fs, total, used, available | _] ->
            total = (parse_int(total) || 0) * 1024
            used = (parse_int(used) || 0) * 1024
            available = (parse_int(available) || 0) * 1024
            %{total: total, used: used, available: available, percent: percent(used, total)}

          _ ->
            %{total: 0, used: 0, available: 0, percent: 0.0}
        end
    end
  end

  defp parse_disk(_), do: %{total: 0, used: 0, available: 0, percent: 0.0}

  ## network -------------------------------------------------------------

  defp parse_net(lines) when is_list(lines) do
    Enum.reduce(lines, %{rx: 0, tx: 0}, fn line, acc ->
      case String.split(String.trim(line), ":", parts: 2) do
        [_iface, rest] ->
          case String.split(String.trim(rest)) do
            [rx, _, _, _, _, _, _, _, tx | _] ->
              %{acc | rx: acc.rx + (parse_int(rx) || 0), tx: acc.tx + (parse_int(tx) || 0)}

            _ ->
              acc
          end

        _ ->
          acc
      end
    end)
  end

  defp parse_net(_), do: %{rx: 0, tx: 0}

  ## beam ----------------------------------------------------------------

  defp parse_beam(lines) when is_list(lines) do
    lines
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn line ->
      case String.split(line, ~r/\s+/, parts: 4) do
        [pid, rss, etimes, args] ->
          %{
            pid: parse_int(pid),
            rss: (parse_int(rss) || 0) * 1024,
            uptime: parse_int(etimes),
            node: extract_flag(args, ~w(-name -sname)),
            release: extract_release(args),
            args: String.slice(args, 0, 400)
          }

        _ ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_beam(_), do: []

  @doc "Extracts the value that follows one of `flags` in a command line."
  def extract_flag(args, flags) do
    tokens = String.split(args, ~r/\s+/)

    Enum.find_value(flags, fn flag ->
      case Enum.find_index(tokens, &(&1 == flag)) do
        nil -> nil
        index -> Enum.at(tokens, index + 1)
      end
    end)
  end

  defp extract_release(args) do
    case Regex.run(~r{-root\s+(\S+)}, args) do
      [_, root] -> root
      _ -> nil
    end
  end

  ## derivation ----------------------------------------------------------

  @doc """
  Combines the previous and current raw samples into displayable metrics.
  `prev` may be `nil` on the first tick.
  """
  @spec derive(map() | nil, map()) :: map()
  def derive(prev, current) do
    cpu_percent = cpu_percent(prev, current)
    {rx_rate, tx_rate} = net_rates(prev, current)

    %{
      cpu_percent: cpu_percent,
      memory: current.memory,
      disk: current.disk,
      load: current.load,
      uptime: current.uptime,
      net: Map.merge(current.net, %{rx_rate: rx_rate, tx_rate: tx_rate}),
      process_count: current.process_count,
      beam_processes: current.beam_processes,
      recorded_at: current.recorded_at
    }
  end

  defp cpu_percent(%{cpu: %{total: pt, idle: pi}}, %{cpu: %{total: ct, idle: ci}})
       when is_integer(pt) and is_integer(ct) and ct > pt do
    total_delta = ct - pt
    idle_delta = ci - pi
    Float.round((total_delta - idle_delta) / total_delta * 100, 1)
  end

  defp cpu_percent(_, _), do: 0.0

  defp net_rates(%{net: prev_net, taken_at: prev_at}, %{net: net, taken_at: at})
       when is_integer(prev_at) and at > prev_at do
    seconds = (at - prev_at) / 1000

    {round(max(net.rx - prev_net.rx, 0) / seconds), round(max(net.tx - prev_net.tx, 0) / seconds)}
  end

  defp net_rates(_, _), do: {0, 0}

  ## helpers -------------------------------------------------------------

  defp percent(_used, 0), do: 0.0
  defp percent(used, total), do: Float.round(used / total * 100, 1)

  defp parse_int(nil), do: nil

  defp parse_int(value) do
    case Integer.parse(String.trim(to_string(value))) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp parse_float(value) do
    case Float.parse(String.trim(to_string(value))) do
      {float, _} -> float
      :error -> 0.0
    end
  end
end
