defmodule BeamPanel.Servers.Server do
  @moduledoc """
  A managed machine.

  `connection: "local"` marks the **main server** — the host the panel itself runs
  on, reached through `System.cmd/3` instead of SSH. Everything else is an
  additional server reached over SSH.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @connections ~w(local ssh)
  @auth_methods ~w(key password agent)
  @roles ~w(primary secondary build database)
  @statuses ~w(unknown online offline unreachable provisioning)

  schema "servers" do
    field :name, :string
    field :slug, :string
    field :description, :string
    field :hostname, :string
    field :connection, :string, default: "ssh"
    field :ssh_port, :integer, default: 22
    field :ssh_user, :string, default: "root"
    field :auth_method, :string, default: "key"
    field :ssh_private_key, BeamPanel.Encrypted.Binary, redact: true
    field :ssh_passphrase, BeamPanel.Encrypted.Binary, redact: true
    field :ssh_password, BeamPanel.Encrypted.Binary, redact: true
    field :sudo_password, BeamPanel.Encrypted.Binary, redact: true
    field :tags, {:array, :string}, default: []
    field :role, :string, default: "secondary"
    field :status, :string, default: "unknown"
    field :status_message, :string
    field :facts, :map, default: %{}
    field :last_seen_at, :utc_datetime
    field :monitor_enabled, :boolean, default: true
    field :monitor_interval, :integer, default: 10
    field :deploy_user, :string, default: "deploy"
    field :deploy_root, :string, default: "/opt/beam"

    field :tags_input, :string, virtual: true

    belongs_to :group, BeamPanel.Servers.ServerGroup
    has_many :projects, BeamPanel.Projects.Project

    timestamps(type: :utc_datetime)
  end

  def connections, do: @connections
  def auth_methods, do: @auth_methods
  def roles, do: @roles
  def statuses, do: @statuses

  def changeset(server, attrs) do
    server
    |> cast(attrs, [
      :name,
      :slug,
      :description,
      :hostname,
      :connection,
      :ssh_port,
      :ssh_user,
      :auth_method,
      :ssh_private_key,
      :ssh_passphrase,
      :ssh_password,
      :sudo_password,
      :group_id,
      :tags,
      :tags_input,
      :role,
      :monitor_enabled,
      :monitor_interval,
      :deploy_user,
      :deploy_root
    ])
    |> validate_required([:name, :hostname])
    |> validate_inclusion(:connection, @connections)
    |> validate_inclusion(:auth_method, @auth_methods)
    |> validate_inclusion(:role, @roles)
    |> validate_number(:ssh_port, greater_than: 0, less_than: 65_536)
    |> validate_number(:monitor_interval,
      greater_than_or_equal_to: 5,
      less_than_or_equal_to: 3600
    )
    |> put_tags()
    |> BeamPanel.Slug.put_slug(:name)
    |> validate_credentials()
    |> unique_constraint(:slug)
    |> foreign_key_constraint(:group_id)
  end

  @doc "Changeset used by the monitor to record reachability."
  def status_changeset(server, attrs) do
    server
    |> cast(attrs, [:status, :status_message, :last_seen_at, :facts])
    |> validate_inclusion(:status, @statuses)
  end

  defp put_tags(changeset) do
    case get_change(changeset, :tags_input) do
      nil ->
        changeset

      input ->
        tags =
          input
          |> String.split(~r/[,\s]+/)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq()

        put_change(changeset, :tags, tags)
    end
  end

  defp validate_credentials(changeset) do
    connection = get_field(changeset, :connection)
    auth = get_field(changeset, :auth_method)

    cond do
      connection == "local" ->
        changeset

      auth == "key" and blank?(get_field(changeset, :ssh_private_key)) ->
        add_error(changeset, :ssh_private_key, "is required for key authentication")

      auth == "password" and blank?(get_field(changeset, :ssh_password)) ->
        add_error(changeset, :ssh_password, "is required for password authentication")

      true ->
        changeset
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  @doc "Display label combining name and address."
  def label(%__MODULE__{name: name, hostname: hostname}), do: "#{name} (#{hostname})"

  @doc "Whether the server is currently considered reachable."
  def online?(%__MODULE__{status: status}), do: status == "online"
end
