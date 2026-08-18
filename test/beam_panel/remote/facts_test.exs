defmodule BeamPanel.Remote.FactsTest do
  use ExUnit.Case, async: true

  alias BeamPanel.Remote.Facts

  @output """
  hostname=node-1.example.com
  os_name=Ubuntu
  os_version=24.04
  os_id=ubuntu
  os_pretty=Ubuntu 24.04.1 LTS
  kernel=6.8.0-45-generic
  arch=x86_64
  cpu_cores=4
  cpu_model=AMD EPYC 7763
  mem_total_kb=8123456
  uptime_seconds=98765
  virt=kvm
  erlang=27
  elixir=1.18.4
  node=
  docker=27.3.1
  """

  test "parses key=value output and drops empty values" do
    facts = Facts.parse(@output)

    assert facts["os_pretty"] == "Ubuntu 24.04.1 LTS"
    assert facts["arch"] == "x86_64"
    assert facts["erlang"] == "27"
    refute Map.has_key?(facts, "node")
  end

  test "normalises numeric facts" do
    facts = Facts.parse(@output)

    assert facts["cpu_cores"] == 4
    assert facts["uptime_seconds"] == 98_765
    assert facts["mem_total_kb"] == 8_123_456
    assert facts["mem_total_mb"] == 7933
  end

  test "stamps a collection time" do
    assert {:ok, _, _} = DateTime.from_iso8601(Facts.parse(@output)["collected_at"])
  end

  test "summary/1 renders a one-liner" do
    summary = @output |> Facts.parse() |> Facts.summary()

    assert summary =~ "Ubuntu 24.04.1 LTS"
    assert summary =~ "4 vCPU"
    assert summary =~ "MB RAM"
  end

  test "beam_ready?/1 requires both Erlang and Elixir" do
    assert @output |> Facts.parse() |> Facts.beam_ready?()
    refute Facts.parse("os_name=Ubuntu\n") |> Facts.beam_ready?()
  end
end
