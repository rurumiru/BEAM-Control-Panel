defmodule BeamPanel.ConfigCompatibilityTest do
  @moduledoc """
  Guards against config that only parses on a newer Elixir than the project
  declares.

  `config/runtime.exs` is evaluated by the release at boot, and sigils in it are
  compiled even inside a branch that will not run — so a single `~r"..."E`
  (Elixir 1.19+) crashed every production start on Elixir 1.18 with
  `(Regex.CompileError) invalid_option at position E`.
  """

  use ExUnit.Case, async: true

  @config_files ~w(config/config.exs config/runtime.exs config/dev.exs config/prod.exs config/test.exs)

  test "declares a minimum Elixir version" do
    requirement = Keyword.fetch!(Mix.Project.config(), :elixir)

    assert Version.match?("1.18.4", requirement),
           "the installer ships Elixir 1.18.x, so it must satisfy #{requirement}"
  end

  test "no regex sigil uses a modifier newer than the declared Elixir" do
    for file <- @config_files, File.exists?(file) do
      contents = File.read!(file)

      # `E` (no auto capture) only exists from Elixir 1.19 onwards.
      refute contents =~ ~r/~r["'\/|(\[{<].*["'\/|)\]}>]E/,
             """
             #{file} uses the `E` regex modifier, which does not exist on Elixir 1.18.
             Sigils in config files are compiled at boot regardless of branching,
             so this crashes the release on the Elixir version the installer ships.
             """
    end
  end

  test "runtime.exs parses without evaluating it" do
    # Code.string_to_quoted!/1 performs exactly the parse step that failed in
    # production, without running any of the configuration.
    contents = File.read!("config/runtime.exs")

    assert {:ok, _ast} = Code.string_to_quoted(contents)
  end
end
