defmodule BeamPanel.Audit.AuditLog do
  @moduledoc "Append-only record of every mutating action performed in the panel."

  use Ecto.Schema
  import Ecto.Changeset

  schema "audit_logs" do
    field :actor, :string
    field :action, :string
    field :resource_type, :string
    field :resource_id, :string
    field :metadata, :map, default: %{}
    field :ip, :string
    field :result, :string, default: "ok"
    belongs_to :user, BeamPanel.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(log, attrs) do
    log
    |> cast(attrs, [
      :user_id,
      :actor,
      :action,
      :resource_type,
      :resource_id,
      :metadata,
      :ip,
      :result
    ])
    |> validate_required([:action])
  end
end
