defmodule BeamPanel.Repo.Migrations.CreateServers do
  use Ecto.Migration

  def change do
    create table(:server_groups) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :description, :string
      add :color, :string, default: "primary"
      add :cluster_cookie, :binary

      timestamps(type: :utc_datetime)
    end

    create unique_index(:server_groups, [:slug])

    create table(:servers) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :description, :string
      add :hostname, :string, null: false
      add :connection, :string, null: false, default: "ssh"
      add :ssh_port, :integer, null: false, default: 22
      add :ssh_user, :string, null: false, default: "root"
      add :auth_method, :string, null: false, default: "key"
      add :ssh_private_key, :binary
      add :ssh_passphrase, :binary
      add :ssh_password, :binary
      add :sudo_password, :binary
      add :group_id, references(:server_groups, on_delete: :nilify_all)
      add :tags, {:array, :string}, null: false, default: []
      add :role, :string, null: false, default: "secondary"
      add :status, :string, null: false, default: "unknown"
      add :status_message, :text
      add :facts, :map, null: false, default: %{}
      add :last_seen_at, :utc_datetime
      add :monitor_enabled, :boolean, null: false, default: true
      add :monitor_interval, :integer, null: false, default: 10
      add :deploy_user, :string, default: "deploy"
      add :deploy_root, :string, default: "/opt/beam"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:servers, [:slug])
    create index(:servers, [:group_id])
    create index(:servers, [:status])

    create table(:metric_samples) do
      add :server_id, references(:servers, on_delete: :delete_all), null: false
      add :cpu_percent, :float
      add :load1, :float
      add :load5, :float
      add :load15, :float
      add :mem_total, :bigint
      add :mem_used, :bigint
      add :swap_total, :bigint
      add :swap_used, :bigint
      add :disk_total, :bigint
      add :disk_used, :bigint
      add :net_rx, :bigint
      add :net_tx, :bigint
      add :processes, :integer
      add :uptime, :bigint
      add :recorded_at, :utc_datetime_usec, null: false
    end

    create index(:metric_samples, [:server_id, :recorded_at])
  end
end
