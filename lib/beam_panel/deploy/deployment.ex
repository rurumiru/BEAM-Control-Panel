defmodule BeamPanel.Deploy.Deployment do
  @moduledoc "One execution of the deploy pipeline."

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending running success failed rolled_back cancelled)
  @strategies ~w(release rollback restart)

  schema "deployments" do
    field :ref, :string
    field :commit_sha, :string
    field :commit_message, :string
    field :status, :string, default: "pending"
    field :strategy, :string, default: "release"
    field :log, :string, default: ""
    field :error, :string
    field :release_version, :string
    field :previous_version, :string
    field :duration_ms, :integer
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime

    belongs_to :project, BeamPanel.Projects.Project
    belongs_to :user, BeamPanel.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses
  def strategies, do: @strategies

  def changeset(deployment, attrs) do
    deployment
    |> cast(attrs, [
      :project_id,
      :user_id,
      :ref,
      :commit_sha,
      :commit_message,
      :status,
      :strategy,
      :log,
      :error,
      :release_version,
      :previous_version,
      :duration_ms,
      :started_at,
      :finished_at
    ])
    |> validate_required([:project_id])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:strategy, @strategies)
  end

  def finished?(%__MODULE__{status: status}),
    do: status in ~w(success failed rolled_back cancelled)

  def duration(%__MODULE__{duration_ms: ms}) when is_integer(ms), do: ms

  def duration(%__MODULE__{started_at: %DateTime{} = started, finished_at: nil}),
    do: DateTime.diff(DateTime.utc_now(), started, :millisecond)

  def duration(_), do: nil
end
