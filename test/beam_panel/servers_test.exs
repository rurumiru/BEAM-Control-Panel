defmodule BeamPanel.ServersTest do
  use BeamPanel.DataCase, async: true

  import BeamPanel.Fixtures

  alias BeamPanel.Servers
  alias BeamPanel.Servers.Server

  describe "create_server/1" do
    test "derives a slug from the name" do
      server = server_fixture(%{"name" => "Продакшн Узел"})
      assert server.slug == "prodakshn-uzel"
    end

    test "requires a private key for key authentication" do
      {:error, changeset} =
        Servers.create_server(%{
          "name" => "No key",
          "hostname" => "example.com",
          "auth_method" => "key"
        })

      assert "is required for key authentication" in errors_on(changeset).ssh_private_key
    end

    test "requires a password for password authentication" do
      {:error, changeset} =
        Servers.create_server(%{
          "name" => "No password",
          "hostname" => "example.com",
          "auth_method" => "password"
        })

      assert "is required for password authentication" in errors_on(changeset).ssh_password
    end

    test "local servers need no credentials" do
      assert {:ok, server} =
               Servers.create_server(%{
                 "name" => "Main",
                 "hostname" => "localhost",
                 "connection" => "local"
               })

      assert server.connection == "local"
    end

    test "parses the tag input field" do
      server = server_fixture(%{"tags_input" => "prod, eu-central  web"})
      assert server.tags == ["prod", "eu-central", "web"]
    end

    test "validates the SSH port range" do
      {:error, changeset} =
        Servers.create_server(%{"name" => "x", "hostname" => "h", "ssh_port" => 99_999})

      assert errors_on(changeset).ssh_port != []
    end
  end

  describe "secret storage" do
    test "the private key is encrypted at rest but readable through the schema" do
      server = server_fixture()

      assert server.ssh_private_key == dummy_key()

      raw =
        BeamPanel.Repo.query!("SELECT ssh_private_key FROM servers WHERE id = $1", [server.id])
        |> Map.get(:rows)
        |> List.first()
        |> List.first()

      refute raw == dummy_key()
      assert is_binary(raw)
    end
  end

  describe "status transitions" do
    test "mark_online/2 records facts and the timestamp" do
      server = server_fixture()

      {:ok, server} = Servers.mark_online(server, %{"os_pretty" => "Ubuntu 24.04"})

      assert server.status == "online"
      assert server.facts["os_pretty"] == "Ubuntu 24.04"
      assert server.last_seen_at
    end

    test "mark_online/2 keeps existing facts when handed an empty map" do
      server = server_fixture()
      {:ok, server} = Servers.mark_online(server, %{"arch" => "x86_64"})
      {:ok, server} = Servers.mark_online(server, %{})

      assert server.facts["arch"] == "x86_64"
    end

    test "mark_unreachable/2 stores a truncated reason" do
      server = server_fixture()
      {:ok, server} = Servers.mark_unreachable(server, {:error, :econnrefused})

      assert server.status == "unreachable"
      assert server.status_message =~ "econnrefused"
    end

    test "mark_status/2 sets transient states" do
      server = server_fixture()
      {:ok, server} = Servers.mark_status(server, "provisioning")
      assert server.status == "provisioning"
    end
  end

  describe "ensure_main_server!/0" do
    test "creates exactly one local server" do
      first = Servers.ensure_main_server!()
      second = Servers.ensure_main_server!()

      assert first.id == second.id
      assert first.connection == "local"
      assert first.role == "primary"
    end
  end

  describe "groups" do
    test "creates a group and associates servers" do
      {:ok, group} = Servers.create_group(%{"name" => "EU cluster"})
      server = server_fixture(%{"group_id" => group.id})

      assert server.group_id == group.id
      assert [loaded] = Servers.get_group!(group.id).servers
      assert loaded.id == server.id
    end
  end

  describe "counters" do
    test "count_by_status/0 groups servers" do
      server_fixture()
      s = server_fixture()
      {:ok, _} = Servers.mark_online(s, %{})

      counts = Servers.count_by_status()
      assert counts["online"] == 1
      assert counts["unknown"] == 1
    end

    test "list_servers_with_counts/0 attaches project counts" do
      server = server_fixture()
      project_fixture(server)
      project_fixture(server)

      found = Enum.find(Servers.list_servers_with_counts(), &(&1.id == server.id))
      assert found.project_count == 2
    end
  end

  describe "helpers" do
    test "label/1 and online?/1" do
      server = %Server{name: "web", hostname: "10.0.0.1", status: "online"}
      assert Server.label(server) == "web (10.0.0.1)"
      assert Server.online?(server)
      refute Server.online?(%Server{status: "offline"})
    end
  end
end
