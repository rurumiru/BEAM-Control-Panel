defmodule BeamPanel.Remote.Local do
  @moduledoc """
  Executes commands on the machine the panel itself runs on — the "main server".

  Exposes the same shape as `BeamPanel.Remote.SSH` so every layer above can treat
  the local host and remote hosts identically.
  """

  alias BeamPanel.Remote.Result

  @default_timeout 120_000

  @spec exec(String.t(), keyword()) :: {:ok, Result.t()} | {:error, term()}
  def exec(command, opts \\ []) do
    started = System.monotonic_time(:millisecond)

    case stream(command, fn _s, _c -> :ok end, Keyword.put(opts, :collect, true)) do
      {:ok, %{exit_status: status, stdout: out, stderr: err}} ->
        {:ok,
         %Result{
           command: command,
           stdout: out,
           stderr: err,
           exit_status: status,
           duration_ms: System.monotonic_time(:millisecond) - started
         }}

      error ->
        error
    end
  end

  @spec stream(String.t(), (atom(), binary() -> any()), keyword()) ::
          {:ok, map()} | {:error, term()}
  def stream(command, fun, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    collect? = Keyword.get(opts, :collect, true)

    case shell_invocation(command) do
      {:ok, {executable, args}} ->
        port =
          Port.open({:spawn_executable, executable}, [
            :binary,
            :exit_status,
            :hide,
            :stderr_to_stdout,
            args: args
          ])

        loop(port, fun, collect?, timeout, [], nil)

      :error ->
        {:error, :no_shell_available}
    end
  end

  @spec write_file(String.t(), iodata(), keyword()) :: :ok | {:error, term()}
  def write_file(path, content, opts \\ []) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, content) do
      case opts[:mode] do
        nil -> :ok
        mode when is_integer(mode) -> File.chmod(path, mode)
        mode when is_binary(mode) -> File.chmod(path, String.to_integer(mode, 8))
      end
    end
  end

  @spec read_file(String.t()) :: {:ok, binary()} | {:error, term()}
  def read_file(path), do: File.read(path)

  ## ---------------------------------------------------------------- internals

  defp shell_invocation(command) do
    cond do
      sh = System.find_executable("sh") -> {:ok, {sh, ["-c", command]}}
      bash = System.find_executable("bash") -> {:ok, {bash, ["-c", command]}}
      cmd = System.find_executable("cmd") -> {:ok, {cmd, ["/c", command]}}
      true -> :error
    end
  end

  defp loop(port, fun, collect?, timeout, acc, _status) do
    receive do
      {^port, {:data, data}} ->
        fun.(:stdout, data)
        loop(port, fun, collect?, timeout, if(collect?, do: [data | acc], else: acc), nil)

      {^port, {:exit_status, status}} ->
        {:ok,
         %{
           exit_status: status,
           stdout: acc |> Enum.reverse() |> IO.iodata_to_binary(),
           stderr: ""
         }}
    after
      timeout ->
        safe_close(port)
        {:error, :timeout}
    end
  end

  defp safe_close(port) do
    Port.close(port)
  catch
    _, _ -> :ok
  end
end
