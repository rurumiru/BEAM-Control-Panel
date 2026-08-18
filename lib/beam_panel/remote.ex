defmodule BeamPanel.Remote do
  @moduledoc """
  Unified execution facade for the main server and every additional server.

  Whether a server is `connection: "local"` (the host running the panel) or
  `connection: "ssh"` is invisible to callers — contexts, the deploy pipeline and
  LiveViews all speak this single API:

      {:ok, result} = Remote.run(server, "uptime")
      Remote.stream(server, "journalctl -fu app", fn _io, chunk -> ... end)
      Remote.write_file(server, "/etc/systemd/system/app.service", unit)

  ## Options

    * `:conn`    — reuse an already open SSH connection
    * `:sudo`    — wrap the command with `sudo` (no-op when the user is root)
    * `:env`     — map/keyword of environment variables to export
    * `:cd`      — working directory
    * `:timeout` — command timeout in milliseconds
  """

  alias BeamPanel.Remote.{SSH, Local, Result}

  @type server :: map()

  @doc "Runs a command and returns a `BeamPanel.Remote.Result`."
  @spec run(server, String.t(), keyword()) :: {:ok, Result.t()} | {:error, term()}
  def run(server, command, opts \\ []) do
    command = build(server, command, opts)

    if local?(server) do
      Local.exec(command, opts)
    else
      case opts[:conn] do
        nil -> SSH.with_connection(server, &SSH.exec(&1, command, opts), opts)
        conn -> SSH.exec(conn, command, opts)
      end
    end
  end

  @doc "Like `run/3` but raises when the command fails."
  @spec run!(server, String.t(), keyword()) :: Result.t()
  def run!(server, command, opts \\ []) do
    case run(server, command, opts) do
      {:ok, %Result{exit_status: 0} = result} ->
        result

      {:ok, %Result{} = result} ->
        raise "command failed (#{result.exit_status}): #{command}\n#{Result.combined(result)}"

      {:error, reason} ->
        raise "command errored: #{command}\n#{inspect(reason)}"
    end
  end

  @doc "Runs a command, returning trimmed stdout, or `default` when it fails."
  @spec capture(server, String.t(), keyword()) :: String.t()
  def capture(server, command, opts \\ []) do
    default = Keyword.get(opts, :default, "")

    case run(server, command, opts) do
      {:ok, %Result{exit_status: 0} = result} -> Result.out(result)
      _ -> default
    end
  end

  @doc "Streams output chunk by chunk into `fun`."
  @spec stream(server, String.t(), (atom(), binary() -> any()), keyword()) ::
          {:ok, map()} | {:error, term()}
  def stream(server, command, fun, opts \\ []) do
    command = build(server, command, opts)

    if local?(server) do
      Local.stream(command, fun, opts)
    else
      case opts[:conn] do
        nil -> SSH.with_connection(server, &SSH.stream(&1, command, fun, opts), opts)
        conn -> SSH.stream(conn, command, fun, opts)
      end
    end
  end

  @doc """
  Opens one connection and hands it to `fun`, so several commands share a single
  SSH handshake. For local servers `fun` receives `nil`.
  """
  @spec with_connection(server, (term() -> result), keyword()) :: result | {:error, term()}
        when result: any()
  def with_connection(server, fun, opts \\ []) do
    if local?(server), do: fun.(nil), else: SSH.with_connection(server, fun, opts)
  end

  @doc "Writes a file on the target host."
  @spec write_file(server, String.t(), iodata(), keyword()) :: :ok | {:error, term()}
  def write_file(server, path, content, opts \\ []) do
    if local?(server) do
      Local.write_file(path, content, opts)
    else
      case opts[:conn] do
        nil -> SSH.with_connection(server, &SSH.write_file(&1, path, content, opts), opts)
        conn -> SSH.write_file(conn, path, content, opts)
      end
    end
  end

  @doc "Reads a file from the target host."
  @spec read_file(server, String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def read_file(server, path, opts \\ []) do
    if local?(server) do
      Local.read_file(path)
    else
      case opts[:conn] do
        nil -> SSH.with_connection(server, &SSH.read_file(&1, path), opts)
        conn -> SSH.read_file(conn, path)
      end
    end
  end

  @doc """
  Verifies the panel can reach and authenticate to `server`.

  Returns `{:ok, facts}` on success.
  """
  @spec test_connection(server) :: {:ok, map()} | {:error, term()}
  def test_connection(server) do
    with_connection(server, fn conn ->
      case run(server, "echo beam-panel-ok", conn: conn, timeout: 20_000) do
        {:ok, %Result{exit_status: 0, stdout: out}} ->
          if String.contains?(out, "beam-panel-ok") do
            {:ok, BeamPanel.Remote.Facts.gather(server, conn: conn)}
          else
            {:error, {:unexpected_output, String.trim(out)}}
          end

        {:ok, %Result{} = result} ->
          {:error, Result.combined(result)}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  @doc "True when the server is the host the panel runs on."
  @spec local?(server) :: boolean()
  def local?(%{connection: connection}), do: to_string(connection) == "local"
  def local?(_), do: false

  @doc "Shell-escapes a value."
  defdelegate shell_quote(value), to: SSH

  ## ---------------------------------------------------------------- internals

  defp build(server, command, opts) do
    command
    |> with_cd(opts[:cd])
    |> with_env(opts[:env])
    |> with_sudo(server, opts[:sudo])
  end

  defp with_cd(command, nil), do: command
  defp with_cd(command, dir), do: "cd #{shell_quote(dir)} && #{command}"

  defp with_env(command, nil), do: command
  defp with_env(command, env) when env == %{}, do: command

  defp with_env(command, env) do
    exports =
      env
      |> Enum.map(fn {k, v} -> "#{k}=#{shell_quote(to_string(v))}" end)
      |> Enum.join(" ")

    case exports do
      "" -> command
      _ -> "env #{exports} sh -c #{shell_quote(command)}"
    end
  end

  defp with_sudo(command, _server, falsy) when falsy in [nil, false], do: command

  defp with_sudo(command, server, true) do
    cond do
      to_string(Map.get(server, :ssh_user) || "root") == "root" and not local?(server) ->
        command

      password = Map.get(server, :sudo_password) ->
        "printf '%s\\n' #{shell_quote(password)} | sudo -S -p '' bash -lc #{shell_quote(command)}"

      true ->
        "sudo -n bash -lc #{shell_quote(command)}"
    end
  end
end
