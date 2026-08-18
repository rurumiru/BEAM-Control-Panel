defmodule BeamPanel.Release do
  @moduledoc """
  Release tasks that run without Mix — used by the systemd unit and the installer.

      bin/beam_panel eval "BeamPanel.Release.setup"
      bin/beam_panel eval "BeamPanel.Release.migrate"
      bin/beam_panel eval "BeamPanel.Release.create_admin(\\"admin@example.com\\", \\"password\\")"

  Every task starts **only the repository** (plus the encryption vault), never the
  full application. Starting the whole app would boot the web endpoint, which
  fails with `:eaddrinuse` whenever the service is already running — and then
  every later call dies with "could not lookup Ecto repo".
  """

  @app :beam_panel

  @doc "Creates the database if needed, runs migrations, ensures the main server row."
  def setup do
    create_database()
    migrate()
    ensure_main_server()
    :ok
  end

  @doc "Runs all pending migrations."
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc "Rolls `repo` back to `version`."
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
    :ok
  end

  @doc "Creates the database if it does not exist yet."
  def create_database do
    load_app()

    for repo <- repos() do
      case repo.__adapter__().storage_up(repo.config()) do
        :ok -> IO.puts("Database created for #{inspect(repo)}")
        {:error, :already_up} -> :ok
        {:error, term} -> IO.puts("Could not create database: #{inspect(term)}")
      end
    end

    :ok
  end

  @doc """
  Creates an administrator account. A no-op when the e-mail already exists.

  Safe to run while the panel is serving traffic.
  """
  def create_admin(email, password) do
    with_repo(fn ->
      case BeamPanel.Accounts.get_user_by_email(email) do
        nil ->
          case BeamPanel.Accounts.create_root_user(%{
                 "email" => email,
                 "name" => "Administrator",
                 "password" => password
               }) do
            {:ok, user} ->
              IO.puts("Administrator created: #{user.email}")
              :ok

            {:error, changeset} ->
              IO.puts("Failed to create administrator: #{inspect(changeset.errors)}")
              :error
          end

        user ->
          IO.puts("User already exists: #{user.email}")
          :ok
      end
    end)
  end

  @doc "Resets the password of an existing user."
  def reset_password(email, password) do
    with_repo(fn ->
      case BeamPanel.Accounts.get_user_by_email(email) do
        nil ->
          IO.puts("No such user: #{email}")
          :error

        user ->
          case BeamPanel.Accounts.update_user_password(user, %{
                 "password" => password,
                 "password_confirmation" => password
               }) do
            {:ok, _} ->
              IO.puts("Password updated for #{email}")
              :ok

            {:error, changeset} ->
              IO.puts("Failed: #{inspect(changeset.errors)}")
              :error
          end
      end
    end)
  end

  @doc "Makes sure the local (main) server row exists."
  def ensure_main_server do
    with_repo(fn ->
      server = BeamPanel.Servers.ensure_main_server!()
      IO.puts("Main server: #{server.name} (#{server.hostname})")
      :ok
    end)
  end

  ## ---------------------------------------------------------------- internals

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app do
    Application.load(@app)
    {:ok, _} = Application.ensure_all_started(:ssl)
    :ok
  end

  # Starts the repo (and the Cloak vault, so encrypted columns work), runs `fun`,
  # then shuts everything down again. Deliberately does NOT start the endpoint.
  defp with_repo(fun) do
    load_app()
    {:ok, _} = Application.ensure_all_started(:cloak)

    vault =
      case BeamPanel.Vault.start_link([]) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    repo = hd(repos())

    try do
      {:ok, result, _apps} = Ecto.Migrator.with_repo(repo, fn _repo -> fun.() end)
      result
    after
      if Process.alive?(vault), do: GenServer.stop(vault)
    end
  end
end
