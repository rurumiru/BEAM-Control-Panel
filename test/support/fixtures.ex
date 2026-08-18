defmodule BeamPanel.Fixtures do
  @moduledoc "Test fixtures for accounts, servers and projects."

  alias BeamPanel.{Accounts, Servers, Projects}

  def unique_email, do: "user#{System.unique_integer([:positive])}@example.com"
  def valid_password, do: "correct-horse-battery-staple"

  def user_fixture(attrs \\ %{}) do
    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put_new("email", unique_email())
      |> Map.put_new("password", valid_password())
      |> Map.put_new("role", "admin")

    {:ok, user} = Accounts.register_user(attrs)
    user
  end

  def server_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put_new("name", "Server #{n}")
      |> Map.put_new("hostname", "host-#{n}.example.com")
      |> Map.put_new("connection", "ssh")
      |> Map.put_new("auth_method", "key")
      |> Map.put_new("ssh_private_key", dummy_key())
      |> Map.put_new("monitor_enabled", false)

    {:ok, server} = Servers.create_server(attrs)
    server
  end

  def project_fixture(server \\ nil, attrs \\ %{}) do
    server = server || server_fixture()
    n = System.unique_integer([:positive])

    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put_new("server_id", server.id)
      |> Map.put_new("name", "App #{n}")
      |> Map.put_new("kind", "phoenix")
      |> Map.put_new("http_port", 4000 + rem(n, 1000))

    {:ok, project} = Projects.create_project(attrs)
    project
  end

  @doc "A syntactically valid, non-functional key blob for changeset validation."
  def dummy_key do
    """
    -----BEGIN OPENSSH PRIVATE KEY-----
    dGVzdC1rZXktZm9yLXZhbGlkYXRpb24tb25seQ==
    -----END OPENSSH PRIVATE KEY-----
    """
  end
end
