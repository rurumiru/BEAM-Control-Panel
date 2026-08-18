defmodule BeamPanel.Accounts.ApiToken do
  @moduledoc """
  Bearer tokens for the REST API.

  Only a SHA-256 hash of the token is persisted; the plaintext value is shown
  exactly once, at creation time.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @scopes ~w(read deploy admin)
  @prefix "bcp_"

  schema "api_tokens" do
    field :name, :string
    field :token_hash, :binary, redact: true
    field :scopes, {:array, :string}, default: ["read"]
    field :last_used_at, :utc_datetime
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime
    field :plaintext, :string, virtual: true, redact: true
    belongs_to :user, BeamPanel.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def scopes, do: @scopes

  def changeset(token, attrs) do
    token
    |> cast(attrs, [:name, :scopes, :expires_at])
    |> validate_required([:name])
    |> validate_subset(:scopes, @scopes)
    |> validate_length(:scopes, min: 1)
  end

  @doc "Builds a token struct plus the plaintext value to show to the user."
  def build(user, attrs) do
    plaintext = @prefix <> (:crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false))

    %__MODULE__{user_id: user.id}
    |> changeset(attrs)
    |> put_change(:token_hash, hash(plaintext))
    |> put_change(:plaintext, plaintext)
  end

  def hash(plaintext), do: :crypto.hash(:sha256, plaintext)

  def valid?(%__MODULE__{revoked_at: nil, expires_at: nil}), do: true

  def valid?(%__MODULE__{revoked_at: nil, expires_at: expires_at}),
    do: DateTime.compare(expires_at, DateTime.utc_now()) == :gt

  def valid?(_), do: false
end
