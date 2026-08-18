defmodule BeamPanel.Servers.ServerGroup do
  @moduledoc "A logical group of servers — typically one BEAM cluster."

  use Ecto.Schema
  import Ecto.Changeset

  schema "server_groups" do
    field :name, :string
    field :slug, :string
    field :description, :string
    field :color, :string, default: "primary"
    field :cluster_cookie, BeamPanel.Encrypted.Binary, redact: true

    has_many :servers, BeamPanel.Servers.Server, foreign_key: :group_id

    timestamps(type: :utc_datetime)
  end

  def changeset(group, attrs) do
    group
    |> cast(attrs, [:name, :description, :color, :cluster_cookie])
    |> validate_required([:name])
    |> BeamPanel.Slug.put_slug(:name)
    |> unique_constraint(:slug)
  end
end
