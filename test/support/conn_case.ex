defmodule BeamPanelWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use BeamPanelWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint BeamPanelWeb.Endpoint

      use BeamPanelWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import BeamPanelWeb.ConnCase
    end
  end

  setup tags do
    BeamPanel.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Registers a user with the given role and logs them in.

  Use as `setup :register_and_log_in_user` (admin) or

      setup %{conn: conn} do
        register_and_log_in_user(%{conn: conn}, role: "operator")
      end
  """
  def register_and_log_in_user(context, opts \\ [])

  def register_and_log_in_user(%{conn: conn}, opts) do
    user = BeamPanel.Fixtures.user_fixture(%{"role" => Keyword.get(opts, :role, "admin")})
    %{conn: log_in_user(conn, user), user: user}
  end

  @doc "Puts a valid session token for `user` into the connection."
  def log_in_user(conn, user) do
    token = BeamPanel.Accounts.generate_user_session_token(user)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  @doc "Adds a bearer token header for API requests."
  def authenticate_api(conn, user, scopes \\ ["admin"]) do
    {:ok, token} =
      BeamPanel.Accounts.create_api_token(user, %{"name" => "test", "scopes" => scopes})

    Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token.plaintext)
  end
end
