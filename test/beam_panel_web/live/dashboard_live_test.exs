defmodule BeamPanelWeb.DashboardLiveTest do
  use BeamPanelWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import BeamPanel.Fixtures

  setup :register_and_log_in_user

  describe "dashboard" do
    test "renders an empty state when nothing is registered", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/")

      assert html =~ "Обзор"
      assert html =~ "Серверов пока нет"
    end

    test "lists servers and projects", %{conn: conn} do
      server = server_fixture(%{"name" => "Prod EU"})
      project_fixture(server, %{"name" => "Storefront"})

      {:ok, _live, html} = live(conn, ~p"/")

      assert html =~ "Prod EU"
      assert html =~ "Storefront"
    end
  end

  describe "servers page" do
    test "shows the create form", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/servers/new")
      assert has_element?(live, "#server-modal")
      assert render(live) =~ "Новый сервер"
    end

    test "validates the form", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/servers/new")

      html =
        live
        |> form("#server-modal form", server: %{name: "", hostname: ""})
        |> render_change()

      assert html =~ "can&#39;t be blank" or html =~ "can't be blank"
    end

    test "creates a server", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/servers/new")

      live
      |> form("#server-modal form",
        server: %{
          name: "Новый узел",
          hostname: "10.10.0.5",
          ssh_user: "root",
          ssh_port: 22,
          auth_method: "key",
          ssh_private_key: dummy_key(),
          monitor_enabled: false
        }
      )
      |> render_submit()

      assert render(live) =~ "Новый узел"
      assert BeamPanel.Servers.get_server_by_slug("novyy-uzel")
    end

    test "shows a single server", %{conn: conn} do
      server = server_fixture(%{"name" => "Single"})
      {:ok, _live, html} = live(conn, ~p"/servers/#{server.id}")

      assert html =~ "Single"
      assert html =~ "Окружение"
    end
  end

  describe "projects page" do
    test "renders the empty state", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/projects")
      assert html =~ "Проектов пока нет"
    end

    test "creates a project", %{conn: conn} do
      server = server_fixture()
      {:ok, live, _html} = live(conn, ~p"/projects/new")

      live
      |> form("#project-modal form",
        project: %{name: "Каталог", server_id: server.id, kind: "phoenix", branch: "main"}
      )
      |> render_submit()

      assert render(live) =~ "Каталог"
    end
  end

  describe "provisioning page" do
    test "lists installable components", %{conn: conn} do
      server = server_fixture()
      {:ok, _live, html} = live(conn, ~p"/servers/#{server.id}/provision")

      assert html =~ "Erlang/OTP"
      assert html =~ "Elixir"
      assert html =~ "Ubuntu 24.04 / 26.04"
    end

    test "previews the generated script", %{conn: conn} do
      server = server_fixture()
      {:ok, live, _html} = live(conn, ~p"/servers/#{server.id}/provision")

      html = live |> element("button", "Показать скрипт") |> render_click()

      assert html =~ "#!/usr/bin/env bash"
      assert html =~ "OTP_VERSION"
    end
  end

  describe "role restrictions" do
    setup %{conn: conn} do
      register_and_log_in_user(%{conn: conn}, role: "viewer")
    end

    test "viewers cannot create servers", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/servers/new")

      html =
        live
        |> form("#server-modal form",
          server: %{
            name: "Nope",
            hostname: "1.2.3.4",
            auth_method: "key",
            ssh_private_key: dummy_key()
          }
        )
        |> render_submit()

      assert html =~ "Недостаточно прав"
    end

    test "viewers are redirected away from user management", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/settings/users")
    end
  end
end
