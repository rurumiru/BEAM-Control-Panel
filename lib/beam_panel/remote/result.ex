defmodule BeamPanel.Remote.Result do
  @moduledoc "Outcome of a remote (or local) command execution."

  @type t :: %__MODULE__{
          command: String.t(),
          stdout: String.t(),
          stderr: String.t(),
          exit_status: integer() | nil,
          duration_ms: non_neg_integer()
        }

  defstruct command: "", stdout: "", stderr: "", exit_status: nil, duration_ms: 0

  @doc "True when the command exited with status 0."
  def ok?(%__MODULE__{exit_status: 0}), do: true
  def ok?(_), do: false

  @doc "stdout with surrounding whitespace removed."
  def out(%__MODULE__{stdout: stdout}), do: String.trim(stdout)

  @doc "stdout split into non-empty trimmed lines."
  def lines(%__MODULE__{stdout: stdout}) do
    stdout
    |> String.split(~r/\r?\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  @doc "Combined output, useful for logs and error messages."
  def combined(%__MODULE__{stdout: out, stderr: err}) do
    [out, err] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("\n") |> String.trim()
  end
end
