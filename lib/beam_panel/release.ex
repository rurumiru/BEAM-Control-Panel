defmodule BeamPanel.Release do
  @moduledoc """
  Release tasks that run without Mix — used by the systemd unit and the installer.

      bin/beam_panel eval "BeamPanel.Release.migrate"
      bin/beam_panel eval "BeamPanel.Release.setup"
      bin/beam_panel eval "BeamPanel.Release.create_admin(\\"admin@example.com\\", \\"password\\")"
  """

  @app :beam_panel

  @doc "Creates the database if needed and runs all pending migrations."
  def setup do
    load_app()
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

  @doc "Creates an administrator account (no-op when the e-mail already exists)."
  def create_admin(email, password) do
    start_app()

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
  end

  @doc "Makes sure the local (main) server row exists."
  def ensure_main_server do
    start_app()
    server = BeamPanel.Servers.ensure_main_server!()
    IO.puts("Main server: #{server.name} (#{server.hostname})")
    :ok
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app do
    Application.load(@app)
    Application.ensure_all_started(:ssl)
  end

  defp start_app do
    load_app()
    Application.ensure_all_started(@app)
  end
end
