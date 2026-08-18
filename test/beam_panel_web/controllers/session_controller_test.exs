defmodule BeamPanelWeb.SessionControllerTest do
  use BeamPanelWeb.ConnCase, async: true

  import BeamPanel.Fixtures

  alias BeamPanel.{Accounts, Audit}

  describe "GET /login" do
    test "renders the sign-in form", %{conn: conn} do
      user_fixture()
      conn = get(conn, ~p"/login")

      assert html_response(conn, 200) =~ "Войти"
    end

    test "redirects to setup when no users exist", %{conn: conn} do
      conn = get(conn, ~p"/login")
      assert redirected_to(conn) == ~p"/setup"
    end

    test "redirects authenticated users to the dashboard", %{conn: conn} do
      user = user_fixture()
      conn = conn |> log_in_user(user) |> get(~p"/login")

      assert redirected_to(conn) == ~p"/"
    end
  end

  describe "POST /login" do
    test "signs in with valid credentials", %{conn: conn} do
      user = user_fixture()

      conn =
        post(conn, ~p"/login", %{
          "user" => %{"email" => user.email, "password" => valid_password()}
        })

      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, :user_token)
    end

    test "rejects a wrong password", %{conn: conn} do
      user = user_fixture()

      conn =
        post(conn, ~p"/login", %{
          "user" => %{"email" => user.email, "password" => "wrong-password!"}
        })

      assert html_response(conn, 200) =~ "Неверный e-mail или пароль"
      refute get_session(conn, :user_token)
    end

    test "records failed attempts in the audit log", %{conn: conn} do
      user = user_fixture()

      post(conn, ~p"/login", %{"user" => %{"email" => user.email, "password" => "nope-nope-nope"}})

      assert [log | _] = Audit.list(action: "auth.failed")
      assert log.actor == user.email
      assert log.result == "error"
    end

    test "asks for a TOTP code when 2FA is enabled", %{conn: conn} do
      user = user_fixture()
      secret = Accounts.generate_totp_secret()
      {:ok, user} = Accounts.enable_totp(user, secret, NimbleTOTP.verification_code(secret))

      conn =
        post(conn, ~p"/login", %{
          "user" => %{"email" => user.email, "password" => valid_password()}
        })

      assert html_response(conn, 401) =~ "Введите код"
      refute get_session(conn, :user_token)
    end

    test "signs in with a valid TOTP code", %{conn: conn} do
      user = user_fixture()
      secret = Accounts.generate_totp_secret()
      {:ok, user} = Accounts.enable_totp(user, secret, NimbleTOTP.verification_code(secret))

      conn =
        post(conn, ~p"/login", %{
          "user" => %{
            "email" => user.email,
            "password" => valid_password(),
            "totp_code" => NimbleTOTP.verification_code(secret)
          }
        })

      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, :user_token)
    end
  end

  describe "DELETE /logout" do
    test "clears the session", %{conn: conn} do
      user = user_fixture()
      conn = conn |> log_in_user(user) |> delete(~p"/logout")

      assert redirected_to(conn) == ~p"/login"
      refute get_session(conn, :user_token)
    end
  end

  describe "GET /setup" do
    test "renders the wizard when the panel is empty", %{conn: conn} do
      conn = get(conn, ~p"/setup")
      assert html_response(conn, 200) =~ "Создать администратора"
    end

    test "creates the first administrator", %{conn: conn} do
      conn =
        post(conn, ~p"/setup", %{
          "user" => %{
            "email" => "root@example.com",
            "name" => "Root",
            "password" => valid_password(),
            "password_confirmation" => valid_password()
          }
        })

      assert redirected_to(conn) == ~p"/"
      assert Accounts.get_user_by_email("root@example.com").role == "admin"
    end

    test "is closed once a user exists", %{conn: conn} do
      user_fixture()
      conn = get(conn, ~p"/setup")

      assert redirected_to(conn) == ~p"/login"
    end
  end

  describe "authentication guard" do
    test "protected pages redirect anonymous visitors", %{conn: conn} do
      user_fixture()

      for path <- ["/", "/servers", "/projects", "/deployments", "/audit", "/settings"] do
        conn = get(build_conn(), path)
        assert redirected_to(conn) == ~p"/login"
      end
    end
  end
end
