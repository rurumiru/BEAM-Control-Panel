defmodule BeamPanel.Projects.EnvVar do
  @moduledoc "An environment variable rendered into the project's systemd env file."

  use Ecto.Schema
  import Ecto.Changeset

  schema "project_env_vars" do
    field :key, :string
    field :value, BeamPanel.Encrypted.Binary, redact: true
    field :secret, :boolean, default: false

    belongs_to :project, BeamPanel.Projects.Project

    timestamps(type: :utc_datetime)
  end

  def changeset(env_var, attrs) do
    env_var
    |> cast(attrs, [:project_id, :key, :value, :secret])
    |> validate_required([:key])
    |> update_change(:key, &normalize_key/1)
    |> validate_format(:key, ~r/^[A-Z_][A-Z0-9_]*$/,
      message: "must be uppercase letters, digits and underscores"
    )
    |> unique_constraint(:key, name: :project_env_vars_project_id_key_index)
  end

  defp normalize_key(key) do
    key
    |> to_string()
    |> String.trim()
    |> String.upcase()
    |> String.replace(~r/[^A-Z0-9_]/, "_")
  end

  @doc "Masks secret values for display."
  def display_value(%__MODULE__{secret: true}), do: "••••••••"
  def display_value(%__MODULE__{value: value}), do: value
end
