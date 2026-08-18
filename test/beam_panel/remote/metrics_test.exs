defmodule BeamPanel.Remote.MetricsTest do
  use ExUnit.Case, async: true

  alias BeamPanel.Remote.Metrics

  @sample """
  @stat
  cpu  100 20 50 800 30 0 10 0 0 0
  @mem
  MemTotal:        8000000 kB
  MemFree:         1000000 kB
  MemAvailable:    4000000 kB
  Buffers:          200000 kB
  Cached:          1500000 kB
  SwapTotal:       2000000 kB
  SwapFree:        1800000 kB
  @load
  0.42 0.31 0.25 2/512 12345
  @uptime
  123456.78 987654.32
  @disk
  /dev/vda1 41152000 20576000 18480000 53% /
  @net
  eth0: 1000000 100 0 0 0 0 0 0 2000000 200 0 0 0 0 0 0
  @beam
   1234 512000 3600 /usr/lib/erlang/erts-14.2/bin/beam.smp -root /opt/beam/app/current -name app@127.0.0.1 -setcookie secret
  @procs
  312
  @end
  """

  describe "parse/1" do
    setup do
      %{sample: Metrics.parse(@sample)}
    end

    test "extracts cpu counters", %{sample: sample} do
      assert sample.cpu.total == 1010
      # idle + iowait
      assert sample.cpu.idle == 830
    end

    test "converts memory to bytes and computes usage", %{sample: sample} do
      assert sample.memory.total == 8_000_000 * 1024
      assert sample.memory.used == (8_000_000 - 4_000_000) * 1024
      assert sample.memory.swap_used == (2_000_000 - 1_800_000) * 1024
      assert sample.memory.percent == 50.0
    end

    test "extracts load averages", %{sample: sample} do
      assert sample.load == %{load1: 0.42, load5: 0.31, load15: 0.25}
    end

    test "extracts uptime as whole seconds", %{sample: sample} do
      assert sample.uptime == 123_456
    end

    test "extracts disk usage", %{sample: sample} do
      assert sample.disk.total == 41_152_000 * 1024
      assert sample.disk.used == 20_576_000 * 1024
      assert sample.disk.percent == 50.0
    end

    test "sums network counters", %{sample: sample} do
      assert sample.net == %{rx: 1_000_000, tx: 2_000_000}
    end

    test "describes running beam processes", %{sample: sample} do
      assert [process] = sample.beam_processes
      assert process.pid == 1234
      assert process.rss == 512_000 * 1024
      assert process.uptime == 3600
      assert process.node == "app@127.0.0.1"
      assert process.release == "/opt/beam/app/current"
    end

    test "extracts the process count", %{sample: sample} do
      assert sample.process_count == 312
    end
  end

  describe "derive/2" do
    test "computes cpu percentage from two samples" do
      previous = %{cpu: %{total: 1000, idle: 900}, net: %{rx: 0, tx: 0}, taken_at: 0}

      current =
        Metrics.parse(@sample)
        |> Map.put(:taken_at, 10_000)

      derived = Metrics.derive(previous, current)

      # total delta 10, idle delta -70 -> clamped by formula to a busy value
      assert is_float(derived.cpu_percent)
      assert derived.memory.percent == 50.0
    end

    test "returns zero rates without a previous sample" do
      derived = Metrics.derive(nil, Metrics.parse(@sample))

      assert derived.cpu_percent == 0.0
      assert derived.net.rx_rate == 0
      assert derived.net.tx_rate == 0
    end

    test "computes network rates over the elapsed interval" do
      previous = %{
        cpu: %{total: 0, idle: 0},
        net: %{rx: 500_000, tx: 1_000_000},
        taken_at: 0
      }

      current = Map.put(Metrics.parse(@sample), :taken_at, 10_000)
      derived = Metrics.derive(previous, current)

      assert derived.net.rx_rate == 50_000
      assert derived.net.tx_rate == 100_000
    end
  end

  describe "extract_flag/2" do
    test "reads the value following a flag" do
      args = "beam.smp -root /opt/app -name app@host -setcookie abc"
      assert Metrics.extract_flag(args, ~w(-name -sname)) == "app@host"
      assert Metrics.extract_flag(args, ~w(-setcookie)) == "abc"
      assert Metrics.extract_flag(args, ~w(-missing)) == nil
    end
  end
end
