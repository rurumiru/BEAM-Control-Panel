defmodule BeamPanel.Repo.Migrations.CreateAccounts do
  use Ecto.Migration

  def change do
    # No citext: creating an extension requires superuser, which the panel's
    # database role deliberately does not have. Emails are normalised to
    # lowercase in BeamPanel.Accounts.User before they ever reach the database.
    create table(:users) do
      add :email, :string, null: false
      add :name, :string
      add :hashed_password, :string, null: false
      add :role, :string, null: false, default: "viewer"
      add :active, :boolean, null: false, default: true
      add :totp_secret, :binary
      add :totp_enabled, :boolean, null: false, default: false
      add :confirmed_at, :utc_datetime
      add :last_login_at, :utc_datetime
      add :last_login_ip, :string
      add :failed_attempts, :integer, null: false, default: 0
      add :locked_until, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:email])

    create table(:users_tokens) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :token, :binary, null: false
      add :context, :string, null: false
      add :sent_to, :string

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:users_tokens, [:user_id])
    create unique_index(:users_tokens, [:context, :token])

    create table(:api_tokens) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :token_hash, :binary, null: false
      add :scopes, {:array, :string}, null: false, default: []
      add :last_used_at, :utc_datetime
      add :expires_at, :utc_datetime
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:api_tokens, [:token_hash])
    create index(:api_tokens, [:user_id])

    create table(:audit_logs) do
      add :user_id, references(:users, on_delete: :nilify_all)
      add :actor, :string
      add :action, :string, null: false
      add :resource_type, :string
      add :resource_id, :string
      add :metadata, :map, null: false, default: %{}
      add :ip, :string
      add :result, :string, null: false, default: "ok"

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:audit_logs, [:user_id])
    create index(:audit_logs, [:resource_type, :resource_id])
    create index(:audit_logs, [:inserted_at])
  end
end
