defmodule BeamPanel.Remote.SSH do
  @moduledoc """
  Thin, dependency-free SSH client built on Erlang/OTP's `:ssh` application.

  A connection is an opaque `t:conn/0` that can be reused for many commands —
  the metrics collector keeps one open per server, while ad-hoc actions open and
  close a connection per call.
  """

  alias BeamPanel.Remote.{Result, KeyProvider}

  @type conn :: :ssh.connection_ref()

  @default_connect_timeout 15_000
  @default_exec_timeout 120_000

  @doc """
  Opens a connection to `server`.

  `server` is any map/struct exposing `hostname`, `ssh_port`, `ssh_user`,
  `auth_method`, `ssh_private_key`, `ssh_passphrase` and `ssh_password`.
  """
  @spec connect(map(), keyword()) :: {:ok, conn} | {:error, term()}
  def connect(server, opts \\ []) do
    timeout = Keyword.get(opts, :connect_timeout, @default_connect_timeout)
    host = to_charlist(server.hostname)
    port = server.ssh_port || 22

    case :ssh.connect(host, port, ssh_options(server, timeout), timeout) do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc "Closes a connection. Always returns `:ok`."
  @spec close(conn) :: :ok
  def close(conn) do
    :ssh.close(conn)
  catch
    _, _ -> :ok
  end

  @doc "Runs `command`, buffering stdout/stderr, and returns a `Result`."
  @spec exec(conn, String.t(), keyword()) :: {:ok, Result.t()} | {:error, term()}
  def exec(conn, command, opts \\ []) do
    started = System.monotonic_time(:millisecond)

    case stream(conn, command, fn _stream, _chunk -> :ok end, Keyword.put(opts, :collect, true)) do
      {:ok, %{exit_status: status, stdout: out, stderr: err}} ->
        {:ok,
         %Result{
           command: command,
           stdout: out,
           stderr: err,
           exit_status: status,
           duration_ms: System.monotonic_time(:millisecond) - started
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Runs `command`, invoking `fun.(:stdout | :stderr, chunk)` for every chunk as it
  arrives. Returns `{:ok, %{exit_status: status, stdout: .., stderr: ..}}`.

  Pass `collect: false` to avoid buffering output (useful for `journalctl -f`).
  """
  @spec stream(conn, String.t(), (atom(), binary() -> any()), keyword()) ::
          {:ok, map()} | {:error, term()}
  def stream(conn, command, fun, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_exec_timeout)
    collect? = Keyword.get(opts, :collect, true)

    with {:ok, chan} <- open_channel(conn, timeout),
         :success <- exec_channel(conn, chan, command, timeout) do
      loop(conn, chan, fun, collect?, timeout, %{stdout: [], stderr: [], exit_status: nil})
    else
      :failure -> {:error, :exec_rejected}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  @doc "Opens a connection, runs `fun.(conn)` and always closes the connection."
  @spec with_connection(map(), (conn -> result), keyword()) :: result | {:error, term()}
        when result: any()
  def with_connection(server, fun, opts \\ []) do
    case connect(server, opts) do
      {:ok, conn} ->
        try do
          fun.(conn)
        after
          close(conn)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Writes `content` to `path` on the remote host (SFTP, with a base64 fallback)."
  @spec write_file(conn, String.t(), iodata(), keyword()) :: :ok | {:error, term()}
  def write_file(conn, path, content, opts \\ []) do
    content = IO.iodata_to_binary(content)

    case sftp_write(conn, path, content) do
      :ok -> post_write(conn, path, opts)
      {:error, _} -> base64_write(conn, path, content, opts)
    end
  end

  @doc "Reads a remote file. Falls back to `cat` when SFTP is unavailable."
  @spec read_file(conn, String.t()) :: {:ok, binary()} | {:error, term()}
  def read_file(conn, path) do
    case :ssh_sftp.start_channel(conn) do
      {:ok, chan} ->
        result = :ssh_sftp.read_file(chan, to_charlist(path))
        :ssh_sftp.stop_channel(chan)
        result

      {:error, _} ->
        case exec(conn, "cat #{shell_quote(path)}") do
          {:ok, %Result{exit_status: 0, stdout: out}} -> {:ok, out}
          {:ok, %Result{} = r} -> {:error, Result.combined(r)}
          error -> error
        end
    end
  end

  @doc "Escapes a value for safe interpolation into a POSIX shell command."
  @spec shell_quote(String.t() | atom() | number()) :: String.t()
  def shell_quote(value) do
    "'" <> String.replace(to_string(value), "'", "'\\''") <> "'"
  end

  ## ---------------------------------------------------------------- internals

  defp ssh_options(server, timeout) do
    base = [
      user: to_charlist(server.ssh_user || "root"),
      silently_accept_hosts: true,
      save_accepted_host: false,
      user_interaction: false,
      quiet_mode: true,
      connect_timeout: timeout
    ]

    case auth_method(server) do
      :password ->
        base ++
          [
            password: to_charlist(server.ssh_password || ""),
            auth_methods: ~c"password,keyboard-interactive"
          ]

      :key ->
        base ++
          [
            auth_methods: ~c"publickey",
            key_cb:
              {KeyProvider,
               [private_key: server.ssh_private_key, passphrase: server.ssh_passphrase]}
          ]

      :agent ->
        base ++ [auth_methods: ~c"publickey"]
    end
  end

  defp auth_method(server) do
    case to_string(server.auth_method || "key") do
      "password" -> :password
      "agent" -> :agent
      _ -> :key
    end
  end

  defp open_channel(conn, timeout) do
    case :ssh_connection.session_channel(conn, timeout) do
      {:ok, chan} -> {:ok, chan}
      {:error, reason} -> {:error, reason}
    end
  end

  defp exec_channel(conn, chan, command, timeout) do
    :ssh_connection.exec(conn, chan, to_charlist(command), timeout)
  end

  defp loop(conn, chan, fun, collect?, timeout, acc) do
    receive do
      {:ssh_cm, ^conn, {:data, ^chan, 0, data}} ->
        fun.(:stdout, data)
        loop(conn, chan, fun, collect?, timeout, accumulate(acc, :stdout, data, collect?))

      {:ssh_cm, ^conn, {:data, ^chan, 1, data}} ->
        fun.(:stderr, data)
        loop(conn, chan, fun, collect?, timeout, accumulate(acc, :stderr, data, collect?))

      {:ssh_cm, ^conn, {:exit_status, ^chan, status}} ->
        loop(conn, chan, fun, collect?, timeout, %{acc | exit_status: status})

      {:ssh_cm, ^conn, {:exit_signal, ^chan, signal, _msg, _lang}} ->
        loop(conn, chan, fun, collect?, timeout, %{acc | exit_status: {:signal, signal}})

      {:ssh_cm, ^conn, {:eof, ^chan}} ->
        loop(conn, chan, fun, collect?, timeout, acc)

      {:ssh_cm, ^conn, {:closed, ^chan}} ->
        {:ok, finalize(acc)}

      {:ssh_cm, ^conn, _other} ->
        loop(conn, chan, fun, collect?, timeout, acc)

      {:beam_panel_ssh_abort, ^chan} ->
        :ssh_connection.close(conn, chan)
        {:ok, finalize(%{acc | exit_status: acc.exit_status || 130})}
    after
      timeout ->
        :ssh_connection.close(conn, chan)
        {:error, :timeout}
    end
  end

  defp accumulate(acc, _key, _data, false), do: acc

  defp accumulate(acc, key, data, true),
    do: Map.update!(acc, key, &[&1 | [data]])

  defp finalize(acc) do
    %{
      exit_status: acc.exit_status || 0,
      stdout: acc.stdout |> List.flatten() |> IO.iodata_to_binary(),
      stderr: acc.stderr |> List.flatten() |> IO.iodata_to_binary()
    }
  end

  defp sftp_write(conn, path, content) do
    case :ssh_sftp.start_channel(conn) do
      {:ok, chan} ->
        result = :ssh_sftp.write_file(chan, to_charlist(path), content)
        :ssh_sftp.stop_channel(chan)
        result

      {:error, reason} ->
        {:error, reason}
    end
  catch
    _, reason -> {:error, reason}
  end

  defp base64_write(conn, path, content, opts) do
    encoded = Base.encode64(content)
    dir = Path.dirname(path)

    command =
      "mkdir -p #{shell_quote(dir)} && printf '%s' #{shell_quote(encoded)} | base64 -d > #{shell_quote(path)}"

    case exec(conn, command) do
      {:ok, %Result{exit_status: 0}} -> post_write(conn, path, opts)
      {:ok, %Result{} = r} -> {:error, Result.combined(r)}
      error -> error
    end
  end

  defp post_write(conn, path, opts) do
    cmds =
      []
      |> maybe_cmd(opts[:mode], &"chmod #{&1} #{shell_quote(path)}")
      |> maybe_cmd(opts[:owner], &"chown #{&1} #{shell_quote(path)}")

    Enum.reduce_while(cmds, :ok, fn cmd, _acc ->
      case exec(conn, cmd) do
        {:ok, %Result{exit_status: 0}} -> {:cont, :ok}
        {:ok, %Result{} = r} -> {:halt, {:error, Result.combined(r)}}
        error -> {:halt, error}
      end
    end)
  end

  defp maybe_cmd(list, nil, _fun), do: list
  defp maybe_cmd(list, value, fun), do: list ++ [fun.(value)]

  defp normalize_error({:options, reason}), do: {:ssh_options, reason}
  defp normalize_error(reason), do: reason
end
