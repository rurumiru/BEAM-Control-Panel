defmodule BeamPanel.Repo.Migrations.CreateProvisioningAndNotifications do
  use Ecto.Migration

  def change do
    create table(:provision_runs) do
      add :server_id, references(:servers, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :nilify_all)
      add :components, {:array, :string}, null: false, default: []
      add :options, :map, null: false, default: %{}
      add :status, :string, null: false, default: "pending"
      add :log, :text, default: ""
      add :error, :text
      add :started_at, :utc_datetime
      add :finished_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:provision_runs, [:server_id, :inserted_at])

    create table(:notification_channels) do
      add :name, :string, null: false
      add :kind, :string, null: false
      add :config, :binary
      add :events, {:array, :string}, null: false, default: []
      add :enabled, :boolean, null: false, default: true
      add :last_error, :text
      add :last_sent_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:notification_channels, [:name])

    create table(:settings, primary_key: false) do
      add :key, :string, primary_key: true
      add :value, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end
  end
end
