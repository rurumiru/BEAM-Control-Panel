defmodule BeamPanel.Accounts do
  @moduledoc "Users, sessions, two-factor authentication and API tokens."

  import Ecto.Query, warn: false

  alias BeamPanel.Repo
  alias BeamPanel.Accounts.{User, UserToken, ApiToken}

  @totp_issuer "BEAM Control Panel"

  ## Users

  def list_users do
    Repo.all(from u in User, order_by: [asc: u.email])
  end

  def get_user!(id), do: Repo.get!(User, id)
  def get_user(id), do: Repo.get(User, id)

  def get_user_by_email(email) when is_binary(email),
    do: Repo.get_by(User, email: String.downcase(email))

  def get_user_by_email(_), do: nil

  def count_users, do: Repo.aggregate(User, :count)

  @doc "Authenticates by email and password. Handles lockout and attempt counters."
  def authenticate(email, password) do
    user = get_user_by_email(email)

    cond do
      is_nil(user) ->
        Pbkdf2.no_user_verify()
        {:error, :invalid_credentials}

      not user.active ->
        {:error, :inactive}

      User.locked?(user) ->
        {:error, :locked}

      User.valid_password?(user, password) ->
        {:ok, user}

      true ->
        user |> User.failure_changeset() |> Repo.update()
        {:error, :invalid_credentials}
    end
  end

  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  @doc "Creates the very first user; forces the admin role."
  def create_root_user(attrs) do
    attrs
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Map.put("role", "admin")
    |> Map.put("active", true)
    |> register_user()
  end

  def update_user(%User{} = user, attrs) do
    user |> User.profile_changeset(attrs) |> Repo.update()
  end

  def update_user_password(%User{} = user, attrs) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, User.password_changeset(user, attrs))
    |> Ecto.Multi.delete_all(:tokens, UserToken.by_user_and_contexts_query(user, :all))
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, :user, changeset, _} -> {:error, changeset}
    end
  end

  def delete_user(%User{} = user), do: Repo.delete(user)

  def change_user_registration(%User{} = user, attrs \\ %{}),
    do: User.registration_changeset(user, attrs, hash_password: false)

  def change_user_profile(%User{} = user, attrs \\ %{}), do: User.profile_changeset(user, attrs)

  def change_user_password(%User{} = user, attrs \\ %{}),
    do: User.password_changeset(user, attrs, hash_password: false)

  def record_login(%User{} = user, ip) do
    user |> User.login_changeset(ip) |> Repo.update()
  end

  ## Roles

  @role_rank %{"viewer" => 0, "operator" => 1, "admin" => 2}

  @doc "Whether `user` has at least the given role."
  def can?(%User{role: role}, required) do
    Map.get(@role_rank, role, -1) >= Map.get(@role_rank, to_string(required), 99)
  end

  def can?(_, _), do: false

  ## Two-factor authentication

  def totp_issuer, do: @totp_issuer

  def generate_totp_secret, do: NimbleTOTP.secret()

  def totp_uri(%User{email: email}, secret),
    do: NimbleTOTP.otpauth_uri("#{@totp_issuer}:#{email}", secret, issuer: @totp_issuer)

  def valid_totp?(%User{totp_enabled: true, totp_secret: secret}, code)
      when is_binary(secret) and is_binary(code) do
    NimbleTOTP.valid?(secret, String.trim(code))
  end

  def valid_totp?(_, _), do: false

  def enable_totp(%User{} = user, secret, code) do
    if NimbleTOTP.valid?(secret, String.trim(code || "")) do
      user
      |> User.totp_changeset(%{totp_secret: secret, totp_enabled: true})
      |> Repo.update()
    else
      {:error, :invalid_code}
    end
  end

  def disable_totp(%User{} = user) do
    user |> User.totp_changeset(%{totp_secret: nil, totp_enabled: false}) |> Repo.update()
  end

  ## Session tokens

  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  def delete_user_session_token(token) do
    Repo.delete_all(UserToken.by_token_and_context_query(token, "session"))
    :ok
  end

  def delete_all_sessions(%User{} = user) do
    Repo.delete_all(UserToken.by_user_and_contexts_query(user, :all))
    :ok
  end

  ## API tokens

  def list_api_tokens(%User{} = user) do
    Repo.all(from t in ApiToken, where: t.user_id == ^user.id, order_by: [desc: t.inserted_at])
  end

  def list_api_tokens do
    Repo.all(from t in ApiToken, order_by: [desc: t.inserted_at], preload: :user)
  end

  def create_api_token(%User{} = user, attrs) do
    changeset = ApiToken.build(user, attrs)

    case Repo.insert(changeset) do
      {:ok, token} ->
        {:ok, %{token | plaintext: Ecto.Changeset.get_change(changeset, :plaintext)}}

      error ->
        error
    end
  end

  def change_api_token(%ApiToken{} = token, attrs \\ %{}), do: ApiToken.changeset(token, attrs)

  def revoke_api_token(%ApiToken{} = token) do
    token
    |> Ecto.Changeset.change(revoked_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update()
  end

  @doc "Resolves a plaintext bearer token into `{user, token}`."
  def authenticate_api_token(plaintext) when is_binary(plaintext) do
    hash = ApiToken.hash(plaintext)

    case Repo.one(from t in ApiToken, where: t.token_hash == ^hash, preload: :user) do
      nil ->
        {:error, :invalid_token}

      token ->
        cond do
          not ApiToken.valid?(token) -> {:error, :expired}
          is_nil(token.user) or not token.user.active -> {:error, :inactive}
          true -> {:ok, touch_api_token(token)}
        end
    end
  end

  def authenticate_api_token(_), do: {:error, :invalid_token}

  defp touch_api_token(token) do
    {:ok, token} =
      token
      |> Ecto.Changeset.change(last_used_at: DateTime.utc_now() |> DateTime.truncate(:second))
      |> Repo.update()

    token
  end

  def token_scope?(%ApiToken{scopes: scopes}, required) do
    required = to_string(required)
    "admin" in scopes or required in scopes or (required == "read" and scopes != [])
  end
end
