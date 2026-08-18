defmodule BeamPanel.AccountsTest do
  use BeamPanel.DataCase, async: true

  import BeamPanel.Fixtures

  alias BeamPanel.Accounts
  alias BeamPanel.Accounts.{User, ApiToken}

  describe "register_user/1" do
    test "requires a strong password" do
      {:error, changeset} =
        Accounts.register_user(%{"email" => unique_email(), "password" => "short"})

      assert "should be at least 12 character(s)" in errors_on(changeset).password
    end

    test "rejects duplicate e-mails case-insensitively" do
      user = user_fixture()

      {:error, changeset} =
        Accounts.register_user(%{
          "email" => String.upcase(user.email),
          "password" => valid_password()
        })

      assert "has already been taken" in errors_on(changeset).email
    end

    test "hashes the password and never stores it in the clear" do
      user = user_fixture()

      assert is_binary(user.hashed_password)
      refute user.hashed_password == valid_password()
      assert User.valid_password?(user, valid_password())
      refute User.valid_password?(user, "wrong password entirely")
    end
  end

  describe "authenticate/2" do
    test "returns the user for correct credentials" do
      user = user_fixture()
      assert {:ok, authenticated} = Accounts.authenticate(user.email, valid_password())
      assert authenticated.id == user.id
    end

    test "rejects a wrong password and counts the attempt" do
      user = user_fixture()

      assert {:error, :invalid_credentials} = Accounts.authenticate(user.email, "nope nope nope")
      assert Accounts.get_user!(user.id).failed_attempts == 1
    end

    test "rejects unknown e-mails" do
      assert {:error, :invalid_credentials} =
               Accounts.authenticate("nobody@example.com", "whatever")
    end

    test "rejects inactive accounts" do
      user = user_fixture()
      {:ok, _} = Accounts.update_user(user, %{"active" => false})

      assert {:error, :inactive} = Accounts.authenticate(user.email, valid_password())
    end

    test "locks the account after ten failures" do
      user = user_fixture()

      for _ <- 1..10, do: Accounts.authenticate(user.email, "still wrong")

      assert {:error, :locked} = Accounts.authenticate(user.email, valid_password())
    end
  end

  describe "roles" do
    test "can?/2 respects the hierarchy" do
      admin = %User{role: "admin"}
      operator = %User{role: "operator"}
      viewer = %User{role: "viewer"}

      assert Accounts.can?(admin, :admin)
      assert Accounts.can?(admin, :operator)
      assert Accounts.can?(operator, :operator)
      refute Accounts.can?(operator, :admin)
      assert Accounts.can?(viewer, :viewer)
      refute Accounts.can?(viewer, :operator)
      refute Accounts.can?(nil, :viewer)
    end
  end

  describe "session tokens" do
    test "round-trips a session token" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)

      assert Accounts.get_user_by_session_token(token).id == user.id

      Accounts.delete_user_session_token(token)
      refute Accounts.get_user_by_session_token(token)
    end

    test "changing the password invalidates every session" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)

      {:ok, _} =
        Accounts.update_user_password(user, %{
          "password" => "another-very-long-password",
          "password_confirmation" => "another-very-long-password"
        })

      refute Accounts.get_user_by_session_token(token)
    end
  end

  describe "api tokens" do
    test "returns the plaintext once and stores only a hash" do
      user = user_fixture()

      {:ok, token} = Accounts.create_api_token(user, %{"name" => "CI", "scopes" => ["deploy"]})

      assert String.starts_with?(token.plaintext, "bcp_")
      assert token.token_hash == ApiToken.hash(token.plaintext)
      refute token.token_hash == token.plaintext
    end

    test "authenticates and records usage" do
      user = user_fixture()
      {:ok, token} = Accounts.create_api_token(user, %{"name" => "CI"})

      assert {:ok, resolved} = Accounts.authenticate_api_token(token.plaintext)
      assert resolved.user.id == user.id
      assert resolved.last_used_at
    end

    test "rejects revoked tokens" do
      user = user_fixture()
      {:ok, token} = Accounts.create_api_token(user, %{"name" => "CI"})
      {:ok, _} = Accounts.revoke_api_token(token)

      assert {:error, :expired} = Accounts.authenticate_api_token(token.plaintext)
    end

    test "rejects garbage" do
      assert {:error, :invalid_token} = Accounts.authenticate_api_token("bcp_nonsense")
      assert {:error, :invalid_token} = Accounts.authenticate_api_token(nil)
    end

    test "scope checks honour admin" do
      assert Accounts.token_scope?(%ApiToken{scopes: ["admin"]}, :deploy)
      assert Accounts.token_scope?(%ApiToken{scopes: ["deploy"]}, :deploy)
      refute Accounts.token_scope?(%ApiToken{scopes: ["read"]}, :deploy)
    end
  end

  describe "two-factor authentication" do
    test "enables TOTP only with a valid code" do
      user = user_fixture()
      secret = Accounts.generate_totp_secret()

      assert {:error, :invalid_code} = Accounts.enable_totp(user, secret, "000000")

      code = NimbleTOTP.verification_code(secret)
      assert {:ok, user} = Accounts.enable_totp(user, secret, code)
      assert user.totp_enabled
      assert Accounts.valid_totp?(user, code)
    end

    test "decrypts the stored secret transparently" do
      user = user_fixture()
      secret = Accounts.generate_totp_secret()
      {:ok, user} = Accounts.enable_totp(user, secret, NimbleTOTP.verification_code(secret))

      reloaded = Accounts.get_user!(user.id)
      assert reloaded.totp_secret == secret
    end
  end
end
