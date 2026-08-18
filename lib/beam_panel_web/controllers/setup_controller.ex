defmodule BeamPanelWeb.SetupController do
  @moduledoc "First-run wizard: creates the initial administrator."

  use BeamPanelWeb, :controller

  alias BeamPanel.Accounts
  alias BeamPanel.Accounts.User
  alias BeamPanelWeb.UserAuth

  plug :redirect_if_configured

  def new(conn, _params) do
    changeset = Accounts.change_user_registration(%User{role: "admin"})
    render(conn, :new, changeset: changeset, page_title: "Первоначальная настройка")
  end

  def create(conn, %{"user" => user_params}) do
    case Accounts.create_root_user(user_params) do
      {:ok, user} ->
        BeamPanel.Audit.log(user, "setup.completed", resource_type: "user", resource_id: user.id)

        conn
        |> put_flash(:info, "Администратор создан. Добро пожаловать!")
        |> UserAuth.log_in_user(user)

      {:error, changeset} ->
        render(conn, :new, changeset: changeset, page_title: "Первоначальная настройка")
    end
  end

  defp redirect_if_configured(conn, _opts) do
    if Accounts.count_users() > 0 do
      conn
      |> put_flash(:error, "Панель уже настроена.")
      |> redirect(to: ~p"/login")
      |> halt()
    else
      conn
    end
  end
end
