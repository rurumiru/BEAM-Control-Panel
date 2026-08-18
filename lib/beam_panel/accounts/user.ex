defmodule BeamPanel.Accounts.User do
  @moduledoc """
  A panel operator.

  Roles, from most to least privileged:

    * `admin`    — everything, including user management and server credentials
    * `operator` — deploy, restart, provision, edit projects
    * `viewer`   — read-only access to dashboards, logs and metrics
  """

  use Ecto.Schema
  import Ecto.Changeset

  @roles ~w(admin operator viewer)

  schema "users" do
    field :email, :string
    field :name, :string
    field :hashed_password, :string, redact: true
    field :password, :string, virtual: true, redact: true
    field :password_confirmation, :string, virtual: true, redact: true
    field :role, :string, default: "viewer"
    field :active, :boolean, default: true
    field :totp_secret, BeamPanel.Encrypted.Binary, redact: true
    field :totp_enabled, :boolean, default: false
    field :confirmed_at, :utc_datetime
    field :last_login_at, :utc_datetime
    field :last_login_ip, :string
    field :failed_attempts, :integer, default: 0
    field :locked_until, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def roles, do: @roles

  @doc "Changeset for registering or inviting a user."
  def registration_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email, :name, :password, :password_confirmation, :role, :active])
    |> validate_email()
    |> validate_role()
    |> validate_password(opts)
  end

  @doc "Changeset for editing profile data (no password)."
  def profile_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name, :role, :active])
    |> validate_email()
    |> validate_role()
  end

  @doc "Changeset used when the user changes their own password."
  def password_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:password, :password_confirmation])
    |> validate_password(opts)
  end

  @doc "Changeset toggling TOTP two-factor authentication."
  def totp_changeset(user, attrs) do
    cast(user, attrs, [:totp_secret, :totp_enabled])
  end

  @doc "Records a successful sign-in."
  def login_changeset(user, ip) do
    change(user, %{
      last_login_at: DateTime.utc_now() |> DateTime.truncate(:second),
      last_login_ip: ip,
      failed_attempts: 0,
      locked_until: nil
    })
  end

  @doc "Records a failed sign-in and locks the account after 10 attempts."
  def failure_changeset(user) do
    attempts = user.failed_attempts + 1

    locked_until =
      if attempts >= 10 do
        DateTime.utc_now() |> DateTime.add(15, :minute) |> DateTime.truncate(:second)
      end

    change(user, %{failed_attempts: attempts, locked_until: locked_until})
  end

  def confirm_changeset(user) do
    change(user, confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second))
  end

  defp validate_email(changeset) do
    changeset
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+\.[^@,;\s]+$/,
      message: "must be a valid email address"
    )
    |> validate_length(:email, max: 160)
    |> update_change(:email, &String.downcase/1)
    |> unsafe_validate_unique(:email, BeamPanel.Repo)
    |> unique_constraint(:email)
  end

  defp validate_role(changeset) do
    validate_inclusion(changeset, :role, @roles)
  end

  defp validate_password(changeset, opts) do
    changeset
    |> validate_required([:password])
    |> validate_length(:password, min: 12, max: 200)
    |> validate_confirmation_when_present()
    |> maybe_hash_password(opts)
  end

  defp validate_confirmation_when_present(changeset) do
    case get_change(changeset, :password_confirmation) do
      nil -> changeset
      _ -> validate_confirmation(changeset, :password, required: true)
    end
  end

  defp maybe_hash_password(changeset, opts) do
    hash? = Keyword.get(opts, :hash_password, true)
    password = get_change(changeset, :password)

    if hash? && password && changeset.valid? do
      changeset
      |> put_change(:hashed_password, Pbkdf2.hash_pwd_salt(password))
      |> delete_change(:password)
      |> delete_change(:password_confirmation)
    else
      changeset
    end
  end

  @doc "Constant-time password verification."
  def valid_password?(%__MODULE__{hashed_password: hash}, password)
      when is_binary(hash) and byte_size(password) > 0 do
    Pbkdf2.verify_pass(password, hash)
  end

  def valid_password?(_, _) do
    Pbkdf2.no_user_verify()
    false
  end

  @doc "Whether the account is currently locked out."
  def locked?(%__MODULE__{locked_until: nil}), do: false

  def locked?(%__MODULE__{locked_until: until}),
    do: DateTime.compare(until, DateTime.utc_now()) == :gt
end
