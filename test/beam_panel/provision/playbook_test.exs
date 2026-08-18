defmodule BeamPanel.Provision.PlaybookTest do
  use ExUnit.Case, async: true

  alias BeamPanel.Provision.Playbook

  test "exposes components with defaults" do
    keys = Enum.map(Playbook.components(), & &1.key)

    assert "base" in keys
    assert "erlang" in keys
    assert "elixir" in keys
    assert "erlang" in Playbook.default_components()
    refute "docker" in Playbook.default_components()
  end

  test "renders a bash script with a shebang and strict mode" do
    script = Playbook.render(["base"], %{})

    assert String.starts_with?(script, "#!/usr/bin/env bash")
    assert script =~ "set -Eeuo pipefail"
    assert script =~ "apt_install"
  end

  test "substitutes versions into the header" do
    script =
      Playbook.render(["erlang", "elixir"], %{"otp_version" => "28", "elixir_version" => "1.19.0"})

    assert script =~ ~s(OTP_VERSION="28")
    assert script =~ ~s(ELIXIR_VERSION="1.19.0")
  end

  test "only renders the selected components" do
    script = Playbook.render(["docker"], %{})

    assert script =~ "download.docker.com"
    refute script =~ "erlang-solutions"
  end

  test "ignores unknown component keys" do
    script = Playbook.render(["definitely-not-a-component"], %{})

    # the header and footer are always present, but no component body is emitted
    assert script =~ "set -Eeuo pipefail"
    refute script =~ "apt_install ca-certificates"
    refute script =~ "erlang-solutions"
  end

  test "generates a database password when none is supplied" do
    a = Playbook.render(["postgres"], %{})
    b = Playbook.render(["postgres"], %{})

    refute extract_password(a) == extract_password(b)
  end

  test "honours an explicit database password" do
    script = Playbook.render(["postgres"], %{"db_password" => "s3cret"})
    assert extract_password(script) == "s3cret"
  end

  defp extract_password(script) do
    [_, password] = Regex.run(~r/DB_PASSWORD="([^"]*)"/, script)
    password
  end
end
