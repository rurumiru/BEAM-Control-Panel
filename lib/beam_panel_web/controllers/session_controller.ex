defmodule BeamPanelWeb.SessionController do
  @moduledoc "Sign in and sign out, including the TOTP second factor."

  use BeamPanelWeb, :controller

  alias BeamPanel.{Accounts, Audit}
  alias BeamPanelWeb.UserAuth

  def new(conn, _params) do
    render(conn, :new, error_message: nil, email: nil, page_title: "Вход")
  end

  def create(conn, %{"user" => %{"email" => email, "password" => password} = params}) do
    case Accounts.authenticate(email, password) do
      {:ok, user} ->
        if user.totp_enabled do
          verify_totp(conn, user, params)
        else
          UserAuth.log_in_user(conn, user, params)
        end

      {:error, reason} ->
        Audit.log(email, "auth.failed",
          ip: UserAuth.remote_ip(conn),
          result: :error,
          metadata: %{reason: reason}
        )

        render(conn, :new,
          error_message: error_message(reason),
          email: email,
          page_title: "Вход"
        )
    end
  end

  def create(conn, _params) do
    render(conn, :new,
      error_message: "Заполните e-mail и пароль.",
      email: nil,
      page_title: "Вход"
    )
  end

  def delete(conn, _params) do
    UserAuth.log_out_user(conn)
  end

  defp verify_totp(conn, user, params) do
    code = params["totp_code"] || ""

    if Accounts.valid_totp?(user, code) do
      UserAuth.log_in_user(conn, user, params)
    else
      message =
        if code == "",
          do: "Введите код из приложения-аутентификатора.",
          else: "Неверный код подтверждения."

      conn
      |> put_status(:unauthorized)
      |> render(:new,
        error_message: message,
        email: user.email,
        require_totp: true,
        page_title: "Вход"
      )
    end
  end

  defp error_message(:locked),
    do: "Аккаунт временно заблокирован после нескольких неудачных попыток. Повторите позже."

  defp error_message(:inactive), do: "Аккаунт отключён."
  defp error_message(_), do: "Неверный e-mail или пароль."
end
