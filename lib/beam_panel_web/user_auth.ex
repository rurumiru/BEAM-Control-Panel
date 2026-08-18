defmodule BeamPanelWeb.UserAuth do
  @moduledoc "Session handling, plugs and LiveView hooks for authentication and RBAC."

  use BeamPanelWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias BeamPanel.Accounts
  alias BeamPanel.Audit

  @remember_me_cookie "_beam_panel_web_user_remember_me"
  @max_age 60 * 60 * 24 * 30

  @doc "Logs the user in, renews the session and redirects."
  def log_in_user(conn, user, params \\ %{}) do
    token = Accounts.generate_user_session_token(user)
    user_return_to = get_session(conn, :user_return_to)

    Accounts.record_login(user, remote_ip(conn))

    Audit.log(user, "auth.login",
      ip: remote_ip(conn),
      resource_type: "user",
      resource_id: user.id
    )

    conn
    |> renew_session()
    |> put_token_in_session(token)
    |> maybe_write_remember_me_cookie(token, params)
    |> redirect(to: user_return_to || signed_in_path(conn))
  end

  @doc "Logs the user out and drops every trace of the session."
  def log_out_user(conn) do
    user_token = get_session(conn, :user_token)
    user = conn.assigns[:current_user]

    if user_token do
      Accounts.delete_user_session_token(user_token)
    end

    if user do
      Audit.log(user, "auth.logout", ip: remote_ip(conn))
    end

    if live_socket_id = get_session(conn, :live_socket_id) do
      BeamPanelWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session()
    |> delete_resp_cookie(@remember_me_cookie)
    |> redirect(to: ~p"/login")
  end

  @doc "Assigns `:current_user` from the session or the remember-me cookie."
  def fetch_current_user(conn, _opts) do
    {user_token, conn} = ensure_user_token(conn)
    user = user_token && Accounts.get_user_by_session_token(user_token)
    assign(conn, :current_user, user)
  end

  @doc "Redirects signed-in users away from the login page."
  def redirect_if_user_is_authenticated(conn, _opts) do
    if conn.assigns[:current_user] do
      conn |> redirect(to: signed_in_path(conn)) |> halt()
    else
      conn
    end
  end

  @doc "Requires a signed-in user."
  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_flash(:error, "Требуется вход в систему.")
      |> maybe_store_return_to()
      |> redirect(to: ~p"/login")
      |> halt()
    end
  end

  @doc "Requires the user to hold at least `role`."
  def require_role(conn, role) do
    if Accounts.can?(conn.assigns[:current_user], role) do
      conn
    else
      conn
      |> put_flash(:error, "Недостаточно прав.")
      |> redirect(to: ~p"/")
      |> halt()
    end
  end

  @doc "Redirects to the setup wizard until the first user exists."
  def require_setup(conn, _opts) do
    if Accounts.count_users() == 0 do
      conn |> redirect(to: ~p"/setup") |> halt()
    else
      conn
    end
  end

  ## ------------------------------------------------------------- LiveView

  def on_mount(:mount_current_user, _params, session, socket) do
    {:cont, mount_current_user(socket, session)}
  end

  def on_mount(:ensure_authenticated, _params, session, socket) do
    socket = mount_current_user(socket, session)

    if socket.assigns.current_user do
      {:cont, socket}
    else
      {:halt,
       socket
       |> Phoenix.LiveView.put_flash(:error, "Требуется вход в систему.")
       |> Phoenix.LiveView.redirect(to: ~p"/login")}
    end
  end

  def on_mount({:ensure_role, role}, _params, session, socket) do
    socket = mount_current_user(socket, session)

    cond do
      is_nil(socket.assigns.current_user) ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/login")}

      Accounts.can?(socket.assigns.current_user, role) ->
        {:cont, socket}

      true ->
        {:halt,
         socket
         |> Phoenix.LiveView.put_flash(:error, "Недостаточно прав.")
         |> Phoenix.LiveView.redirect(to: ~p"/")}
    end
  end

  defp mount_current_user(socket, session) do
    Phoenix.Component.assign_new(socket, :current_user, fn ->
      if token = session["user_token"], do: Accounts.get_user_by_session_token(token)
    end)
  end

  ## ------------------------------------------------------------- internals

  defp ensure_user_token(conn) do
    if token = get_session(conn, :user_token) do
      {token, conn}
    else
      conn = fetch_cookies(conn, signed: [@remember_me_cookie])

      if token = conn.cookies[@remember_me_cookie] do
        {token, put_token_in_session(conn, token)}
      else
        {nil, conn}
      end
    end
  end

  defp maybe_write_remember_me_cookie(conn, token, %{"remember_me" => "true"}) do
    put_resp_cookie(conn, @remember_me_cookie, token,
      sign: true,
      max_age: @max_age,
      same_site: "Lax"
    )
  end

  defp maybe_write_remember_me_cookie(conn, _token, _params), do: conn

  defp renew_session(conn) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  defp put_token_in_session(conn, token) do
    conn
    |> put_session(:user_token, token)
    |> put_session(:live_socket_id, "users_sessions:#{Base.url_encode64(token)}")
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn

  defp signed_in_path(_conn), do: ~p"/"

  @doc "Best-effort client IP, honouring `x-forwarded-for`."
  def remote_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [value | _] -> value |> String.split(",") |> List.first() |> String.trim()
      [] -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  rescue
    _ -> "unknown"
  end
end
