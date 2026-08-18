defmodule BeamPanel.Notifications.Channel do
  @moduledoc "A delivery target for panel events."

  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(webhook telegram slack discord email)
  @events ~w(deploy_success deploy_failed server_unreachable server_online project_down provision_finished)

  schema "notification_channels" do
    field :name, :string
    field :kind, :string
    field :config, BeamPanel.Encrypted.Map, redact: true
    field :events, {:array, :string}, default: []
    field :enabled, :boolean, default: true
    field :last_error, :string
    field :last_sent_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds
  def events, do: @events

  def changeset(channel, attrs) do
    channel
    |> cast(attrs, [:name, :kind, :config, :events, :enabled])
    |> validate_required([:name, :kind])
    |> validate_inclusion(:kind, @kinds)
    |> validate_subset(:events, @events)
    |> validate_config()
    |> unique_constraint(:name)
  end

  defp validate_config(changeset) do
    kind = get_field(changeset, :kind)
    config = get_field(changeset, :config) || %{}

    required =
      case kind do
        "webhook" -> ["url"]
        "slack" -> ["url"]
        "discord" -> ["url"]
        "telegram" -> ["bot_token", "chat_id"]
        "email" -> ["to"]
        _ -> []
      end

    missing = Enum.reject(required, &(config[&1] not in [nil, ""]))

    if missing == [] do
      changeset
    else
      add_error(changeset, :config, "не заполнено: #{Enum.join(missing, ", ")}")
    end
  end
end
