defmodule BeamPanelWeb.ApiTest do
  use BeamPanelWeb.ConnCase, async: true

  import BeamPanel.Fixtures

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: put_req_header(conn, "accept", "application/json"), user: user}
  end

  describe "authentication" do
    test "rejects requests without a token", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/status")

      assert json_response(conn, 401)["error"] == "missing_token"
      assert get_resp_header(conn, "www-authenticate") != []
    end

    test "rejects an unknown token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer bcp_nope")
        |> get(~p"/api/v1/status")

      assert json_response(conn, 401)["error"] == "invalid_token"
    end

    test "accepts a valid token", %{conn: conn, user: user} do
      conn = conn |> authenticate_api(user) |> get(~p"/api/v1/status")

      body = json_response(conn, 200)
      assert body["status"] == "ok"
      assert body["user"] == user.email
    end
  end

  describe "servers" do
    test "lists servers", %{conn: conn, user: user} do
      server = server_fixture(%{"name" => "API server"})

      conn = conn |> authenticate_api(user) |> get(~p"/api/v1/servers")
      [entry] = json_response(conn, 200)["data"]

      assert entry["name"] == "API server"
      assert entry["hostname"] == server.hostname
      refute Map.has_key?(entry, "ssh_private_key")
    end

    test "returns 404 for an unknown server", %{conn: conn, user: user} do
      conn = conn |> authenticate_api(user) |> get(~p"/api/v1/servers/999999")
      assert json_response(conn, 404)["error"] == "not_found"
    end

    test "exposes metrics", %{conn: conn, user: user} do
      server = server_fixture()
      conn = conn |> authenticate_api(user) |> get(~p"/api/v1/servers/#{server.id}/metrics")

      assert %{"data" => %{"series" => []}} = json_response(conn, 200)
    end
  end

  describe "projects" do
    test "lists projects with their server", %{conn: conn, user: user} do
      server = server_fixture(%{"name" => "prod-1"})
      project_fixture(server, %{"name" => "Shop"})

      conn = conn |> authenticate_api(user) |> get(~p"/api/v1/projects")
      [entry] = json_response(conn, 200)["data"]

      assert entry["name"] == "Shop"
      assert entry["server"] == "prod-1"
    end

    test "deploy requires the deploy scope", %{conn: conn, user: user} do
      project = project_fixture()

      conn =
        conn
        |> authenticate_api(user, ["read"])
        |> post(~p"/api/v1/projects/#{project.id}/deploy")

      assert json_response(conn, 403)["error"] == "insufficient_scope"
    end
  end

  describe "deployments" do
    test "returns an empty list initially", %{conn: conn, user: user} do
      conn = conn |> authenticate_api(user) |> get(~p"/api/v1/deployments")
      assert json_response(conn, 200)["data"] == []
    end

    test "returns 404 for an unknown deployment", %{conn: conn, user: user} do
      conn = conn |> authenticate_api(user) |> get(~p"/api/v1/deployments/424242")
      assert json_response(conn, 404)["error"] == "not_found"
    end
  end
end
