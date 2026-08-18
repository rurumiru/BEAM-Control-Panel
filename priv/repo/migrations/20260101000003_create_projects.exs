defmodule BeamPanel.Repo.Migrations.CreateProjects do
  use Ecto.Migration

  def change do
    create table(:projects) do
      add :server_id, references(:servers, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :slug, :string, null: false
      add :description, :string
      add :kind, :string, null: false, default: "phoenix"
      add :repo_url, :string
      add :branch, :string, null: false, default: "main"
      add :git_ref, :string
      add :deploy_path, :string, null: false
      add :release_name, :string
      add :service_name, :string
      add :http_port, :integer
      add :health_url, :string
      add :node_name, :string
      add :node_cookie, :binary
      add :mix_env, :string, null: false, default: "prod"
      add :build_command, :text
      add :auto_migrate, :boolean, null: false, default: true
      add :migrate_command, :text
      add :autostart, :boolean, null: false, default: true
      add :status, :string, null: false, default: "unknown"
      add :current_version, :string
      add :previous_version, :string
      add :last_deployed_at, :utc_datetime
      add :discovered, :boolean, null: false, default: false
      add :notes, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:projects, [:server_id, :slug])
    create index(:projects, [:server_id])

    create table(:project_env_vars) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :key, :string, null: false
      add :value, :binary
      add :secret, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:project_env_vars, [:project_id, :key])

    create table(:deployments) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :nilify_all)
      add :ref, :string
      add :commit_sha, :string
      add :commit_message, :text
      add :status, :string, null: false, default: "pending"
      add :strategy, :string, null: false, default: "release"
      add :log, :text, default: ""
      add :error, :text
      add :release_version, :string
      add :previous_version, :string
      add :duration_ms, :integer
      add :started_at, :utc_datetime
      add :finished_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:deployments, [:project_id, :inserted_at])
    create index(:deployments, [:status])
  end
end
