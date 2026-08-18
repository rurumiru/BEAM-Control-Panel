defmodule BeamPanel.Provision.ProvisionRun do
  @moduledoc "One execution of a provisioning playbook against a server."

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending running success failed cancelled)

  schema "provision_runs" do
    field :components, {:array, :string}, default: []
    field :options, :map, default: %{}
    field :status, :string, default: "pending"
    field :log, :string, default: ""
    field :error, :string
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime

    belongs_to :server, BeamPanel.Servers.Server
    belongs_to :user, BeamPanel.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :server_id,
      :user_id,
      :components,
      :options,
      :status,
      :log,
      :error,
      :started_at,
      :finished_at
    ])
    |> validate_required([:server_id])
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:components, min: 1)
  end
end
