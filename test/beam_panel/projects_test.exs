defmodule BeamPanel.ProjectsTest do
  use BeamPanel.DataCase, async: true

  import BeamPanel.Fixtures

  alias BeamPanel.Projects
  alias BeamPanel.Projects.{Project, Systemd}

  describe "create_project/1" do
    test "fills in derived defaults" do
      project = project_fixture(nil, %{"name" => "My Shop"})

      assert project.slug == "my-shop"
      assert project.release_name == "my_shop"
      assert project.service_name == "my-shop.service"
      assert project.deploy_path == "/opt/beam/my-shop"
      assert project.node_name == "my_shop@127.0.0.1"
    end

    test "keeps explicitly provided values" do
      project =
        project_fixture(nil, %{
          "name" => "Custom",
          "release_name" => "custom_rel",
          "service_name" => "custom-unit",
          "deploy_path" => "/srv/custom"
        })

      assert project.release_name == "custom_rel"
      assert project.service_name == "custom-unit.service"
      assert project.deploy_path == "/srv/custom"
    end

    test "rejects an unknown kind" do
      server = server_fixture()

      {:error, changeset} =
        Projects.create_project(%{"server_id" => server.id, "name" => "x", "kind" => "ruby"})

      assert errors_on(changeset).kind != []
    end

    test "slugs are unique per server" do
      server = server_fixture()
      project_fixture(server, %{"name" => "Duplicate"})

      {:error, changeset} =
        Projects.create_project(%{"server_id" => server.id, "name" => "Duplicate"})

      assert errors_on(changeset).slug != []
    end

    test "rejects a deploy path that is a system directory" do
      server = server_fixture()

      for path <- ["/", "/opt", "/opt/beam", "/usr/local", "/var/www"] do
        {:error, changeset} =
          Projects.create_project(%{
            "server_id" => server.id,
            "name" => "Bad #{System.unique_integer([:positive])}",
            "deploy_path" => path
          })

        assert errors_on(changeset).deploy_path != [],
               "expected #{path} to be rejected as a deploy path"
      end
    end

    test "rejects a relative deploy path" do
      server = server_fixture()

      {:error, changeset} =
        Projects.create_project(%{
          "server_id" => server.id,
          "name" => "Relative",
          "deploy_path" => "opt/beam/app"
        })

      assert "must be an absolute path, e.g. /opt/beam/my-app" in errors_on(changeset).deploy_path
    end

    test "normalises trailing slashes and duplicate separators" do
      project = project_fixture(nil, %{"name" => "Slashes", "deploy_path" => "/opt//beam/app/"})
      assert project.deploy_path == "/opt/beam/app"
    end

    test "the same slug may exist on different servers" do
      project_fixture(server_fixture(), %{"name" => "Shared"})
      assert %Project{} = project_fixture(server_fixture(), %{"name" => "Shared"})
    end
  end

  describe "paths" do
    test "derive from the deploy path" do
      project = project_fixture(nil, %{"name" => "app", "deploy_path" => "/opt/beam/app"})

      assert Project.current_path(project) == "/opt/beam/app/current"
      assert Project.releases_path(project) == "/opt/beam/app/releases"
      assert Project.source_path(project) == "/opt/beam/app/source"
      assert Project.bin_path(project) == "/opt/beam/app/current/bin/app"
      assert Project.unit_base(project) == "app"
    end

    test "health_endpoint/1 falls back to the http port" do
      assert Project.health_endpoint(%Project{http_port: 4000}) == "http://127.0.0.1:4000/"

      assert Project.health_endpoint(%Project{health_url: "https://x/health"}) ==
               "https://x/health"

      assert Project.health_endpoint(%Project{}) == nil
    end
  end

  describe "environment variables" do
    test "normalises keys and enforces the format" do
      project = project_fixture()

      {:ok, env} = Projects.create_env_var(project, %{"key" => "database url", "value" => "x"})
      assert env.key == "DATABASE_URL"
    end

    test "encrypts values at rest" do
      project = project_fixture()

      {:ok, env} =
        Projects.create_env_var(project, %{
          "key" => "SECRET",
          "value" => "swordfish",
          "secret" => true
        })

      raw =
        BeamPanel.Repo.query!("SELECT value FROM project_env_vars WHERE id = $1", [env.id])
        |> Map.get(:rows)
        |> List.first()
        |> List.first()

      refute raw == "swordfish"

      assert Enum.find(Projects.list_env_vars(project.id), &(&1.key == "SECRET")).value ==
               "swordfish"
    end

    test "rejects duplicate keys within a project" do
      project = project_fixture()
      {:ok, _} = Projects.create_env_var(project, %{"key" => "PORT", "value" => "4000"})

      {:error, changeset} =
        Projects.create_env_var(project, %{"key" => "PORT", "value" => "4001"})

      assert errors_on(changeset).key != []
    end

    test "import_env/2 parses dotenv text and flags secrets" do
      project = project_fixture()

      text = """
      # comment
      DATABASE_URL=ecto://user:pass@localhost/db
      SECRET_KEY_BASE="abc123"
      PORT=4000

      broken line
      """

      assert {3, 1} = Projects.import_env(project, text)

      vars = Map.new(Projects.list_env_vars(project.id), &{&1.key, &1})
      assert vars["SECRET_KEY_BASE"].value == "abc123"
      assert vars["SECRET_KEY_BASE"].secret
      refute vars["PORT"].secret
    end

    test "import_env/2 updates an existing key" do
      project = project_fixture()
      {:ok, _} = Projects.create_env_var(project, %{"key" => "PORT", "value" => "4000"})

      assert {1, 0} = Projects.import_env(project, "PORT=5000")
      assert Enum.find(Projects.list_env_vars(project.id), &(&1.key == "PORT")).value == "5000"
    end
  end

  describe "systemd rendering" do
    setup do
      server = server_fixture(%{"deploy_user" => "deploy"})

      project =
        project_fixture(server, %{
          "name" => "shop",
          "deploy_path" => "/opt/beam/shop",
          "http_port" => 4001,
          "node_cookie" => "supersecret"
        })

      %{server: server, project: Projects.get_project!(project.id)}
    end

    test "unit points at the release script", %{project: project, server: server} do
      unit = Systemd.render_unit(project, server)

      assert unit =~ "ExecStart=/opt/beam/shop/current/bin/shop start"
      assert unit =~ "ExecStop=/opt/beam/shop/current/bin/shop stop"
      assert unit =~ "User=deploy"
      assert unit =~ "EnvironmentFile=-/opt/beam/shop/shared/env"
      assert unit =~ "WantedBy=multi-user.target"
    end

    test "mix_app units run mix instead of a release", %{server: server} do
      project = project_fixture(server, %{"name" => "worker", "kind" => "mix_app"})
      unit = Systemd.render_unit(project, server)

      assert unit =~ "mix run --no-halt"
      refute unit =~ "ExecStop="
    end

    test "env file carries release variables", %{project: project} do
      env = Systemd.render_env(project, project.env_vars)

      assert env =~ "MIX_ENV=prod"
      assert env =~ "PORT=4001"
      assert env =~ "RELEASE_COOKIE=supersecret"
      assert env =~ "RELEASE_DISTRIBUTION=name"
    end

    test "user variables override the defaults", %{project: project} do
      {:ok, _} = Projects.create_env_var(project, %{"key" => "PORT", "value" => "9999"})
      project = Projects.get_project!(project.id)

      env = Systemd.render_env(project, project.env_vars)
      lines = String.split(env, "\n")

      assert Enum.count(lines, &String.starts_with?(&1, "PORT=")) == 1
      assert "PORT=4001" in lines
    end

    test "values with whitespace are quoted", %{project: project} do
      {:ok, _} =
        Projects.create_env_var(project, %{"key" => "GREETING", "value" => "hello world"})

      project = Projects.get_project!(project.id)

      assert Systemd.render_env(project, project.env_vars) =~ ~s(GREETING="hello world")
    end

    test "nginx template proxies to the project port", %{project: project} do
      conf = Systemd.render_nginx(project, "shop.example.com")

      assert conf =~ "server_name shop.example.com;"
      assert conf =~ "server 127.0.0.1:4001"
      assert conf =~ "proxy_set_header Upgrade $http_upgrade;"
    end
  end

  describe "status" do
    test "set_status/2 validates the value" do
      project = project_fixture()

      assert {:ok, updated} = Projects.set_status(project, %{status: "running"})
      assert updated.status == "running"

      assert {:error, changeset} = Projects.set_status(project, %{status: "banana"})
      assert errors_on(changeset).status != []
    end
  end
end
