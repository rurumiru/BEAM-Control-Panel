defmodule BeamPanel.Remote.Facts do
  @moduledoc """
  Collects a description of a server: distribution, kernel, CPU, RAM, and which
  parts of the BEAM toolchain are already installed.

  Everything is gathered in a **single** shell round-trip, so the cost is one SSH
  exec regardless of how many facts are returned.
  """

  alias BeamPanel.Remote
  alias BeamPanel.Remote.Result

  @script """
  echo "hostname=$(hostname -f 2>/dev/null || hostname)"
  if [ -r /etc/os-release ]; then . /etc/os-release; echo "os_name=$NAME"; echo "os_version=$VERSION_ID"; echo "os_id=$ID"; echo "os_pretty=$PRETTY_NAME"; fi
  echo "kernel=$(uname -r)"
  echo "arch=$(uname -m)"
  echo "cpu_cores=$(nproc 2>/dev/null || echo 1)"
  echo "cpu_model=$(awk -F': ' '/model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null)"
  echo "mem_total_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null)"
  echo "uptime_seconds=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)"
  echo "virt=$(systemd-detect-virt 2>/dev/null || echo unknown)"
  echo "init=$(cat /proc/1/comm 2>/dev/null)"
  echo "package_manager=$(command -v apt-get >/dev/null 2>&1 && echo apt || (command -v dnf >/dev/null 2>&1 && echo dnf || echo unknown))"
  echo "erlang=$(erl -noshell -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().' 2>/dev/null)"
  echo "erts=$(erl -noshell -eval 'io:format("~s", [erlang:system_info(version)]), halt().' 2>/dev/null)"
  echo "elixir=$(elixir --short-version 2>/dev/null)"
  echo "mix=$(command -v mix >/dev/null 2>&1 && echo yes || echo no)"
  echo "rebar3=$(command -v rebar3 >/dev/null 2>&1 && echo yes || echo no)"
  echo "node=$(node --version 2>/dev/null)"
  echo "git=$(git --version 2>/dev/null | awk '{print $3}')"
  echo "docker=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ,)"
  echo "nginx=$(nginx -v 2>&1 | awk -F/ '{print $2}')"
  echo "postgres=$(psql --version 2>/dev/null | awk '{print $3}')"
  echo "systemd=$(systemctl --version 2>/dev/null | head -1 | awk '{print $2}')"
  echo "epmd_names=$(epmd -names 2>/dev/null | tail -n +2 | tr '\\n' ';')"
  """

  @doc "Returns a map of facts. Never raises — unreachable hosts yield `%{}`."
  @spec gather(map(), keyword()) :: map()
  def gather(server, opts \\ []) do
    case Remote.run(server, @script, Keyword.put_new(opts, :timeout, 45_000)) do
      {:ok, %Result{} = result} -> parse(result.stdout)
      {:error, _} -> %{}
    end
  end

  @doc "Parses `key=value` lines into a normalised fact map."
  @spec parse(String.t()) :: map()
  def parse(output) do
    output
    |> String.split(~r/\r?\n/)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, "=", parts: 2) do
        [key, value] ->
          value = String.trim(value)
          if value == "", do: acc, else: Map.put(acc, String.trim(key), value)

        _ ->
          acc
      end
    end)
    |> normalize()
  end

  defp normalize(facts) do
    facts
    |> put_int("cpu_cores")
    |> put_int("uptime_seconds")
    |> put_mem()
    |> Map.put("collected_at", DateTime.utc_now() |> DateTime.to_iso8601())
  end

  defp put_int(facts, key) do
    case Map.get(facts, key) do
      nil -> facts
      value -> Map.put(facts, key, parse_int(value))
    end
  end

  defp put_mem(facts) do
    case Map.get(facts, "mem_total_kb") do
      nil ->
        facts

      value ->
        kb = parse_int(value)

        facts
        |> Map.put("mem_total_kb", kb)
        |> Map.put("mem_total_mb", div(kb || 0, 1024))
    end
  end

  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) do
    case Integer.parse(to_string(value)) do
      {int, _} -> int
      :error -> nil
    end
  end

  @doc "Human readable one-liner used in the UI."
  @spec summary(map()) :: String.t()
  def summary(facts) do
    [
      facts["os_pretty"] || facts["os_name"],
      facts["arch"],
      facts["cpu_cores"] && "#{facts["cpu_cores"]} vCPU",
      facts["mem_total_mb"] && "#{facts["mem_total_mb"]} MB RAM"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  @doc "Whether the BEAM toolchain (Erlang + Elixir) is present."
  @spec beam_ready?(map()) :: boolean()
  def beam_ready?(facts), do: is_binary(facts["erlang"]) and is_binary(facts["elixir"])
end
