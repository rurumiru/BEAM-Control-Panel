defmodule BeamPanelWeb.ApiAuth do
  @moduledoc "Bearer-token authentication for the REST API."

  import Plug.Conn

  alias BeamPanel.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, token} <- bearer_token(conn),
         {:ok, api_token} <- Accounts.authenticate_api_token(token) do
      conn
      |> assign(:current_user, api_token.user)
      |> assign(:api_token, api_token)
    else
      {:error, reason} -> deny(conn, reason)
    end
  end

  @doc "Halts unless the token carries `scope`."
  def require_scope(conn, scope) do
    if Accounts.token_scope?(conn.assigns[:api_token], scope) do
      conn
    else
      conn
      |> put_status(:forbidden)
      |> Phoenix.Controller.json(%{error: "insufficient_scope", required: to_string(scope)})
      |> halt()
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> {:ok, String.trim(token)}
      ["bearer " <> token | _] -> {:ok, String.trim(token)}
      _ -> {:error, :missing_token}
    end
  end

  defp deny(conn, reason) do
    conn
    |> put_status(:unauthorized)
    |> put_resp_header("www-authenticate", ~s(Bearer realm="beam-control-panel"))
    |> Phoenix.Controller.json(%{error: to_string(reason)})
    |> halt()
  end
end
