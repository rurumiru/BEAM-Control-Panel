defmodule BeamPanel.Projects.Project do
  @moduledoc """
  A BEAM application deployed on a server.

  `kind` decides which build steps the deploy pipeline runs:

    * `phoenix`        — deps, assets, release, migrations
    * `elixir_release` — deps, release
    * `mix_app`        — deps, compile, `mix run --no-halt` under systemd
    * `erlang_release` — `rebar3 as prod release`
  """

  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(phoenix elixir_release mix_app erlang_release)
  @statuses ~w(unknown running stopped failed deploying)

  schema "projects" do
    field :name, :string
    field :slug, :string
    field :description, :string
    field :kind, :string, default: "phoenix"
    field :repo_url, :string
    field :branch, :string, default: "main"
    field :git_ref, :string
    field :deploy_path, :string
    field :release_name, :string
    field :service_name, :string
    field :http_port, :integer
    field :health_url, :string
    field :node_name, :string
    field :node_cookie, BeamPanel.Encrypted.Binary, redact: true
    field :mix_env, :string, default: "prod"
    field :build_command, :string
    field :auto_migrate, :boolean, default: true
    field :migrate_command, :string
    field :autostart, :boolean, default: true
    field :status, :string, default: "unknown"
    field :current_version, :string
    field :previous_version, :string
    field :last_deployed_at, :utc_datetime
    field :discovered, :boolean, default: false
    field :notes, :string

    belongs_to :server, BeamPanel.Servers.Server
    has_many :env_vars, BeamPanel.Projects.EnvVar, on_replace: :delete
    has_many :deployments, BeamPanel.Deploy.Deployment

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds
  def statuses, do: @statuses

  def changeset(project, attrs) do
    project
    |> cast(attrs, [
      :server_id,
      :name,
      :slug,
      :description,
      :kind,
      :repo_url,
      :branch,
      :git_ref,
      :deploy_path,
      :release_name,
      :service_name,
      :http_port,
      :health_url,
      :node_name,
      :node_cookie,
      :mix_env,
      :build_command,
      :auto_migrate,
      :migrate_command,
      :autostart,
      :discovered,
      :notes
    ])
    |> validate_required([:server_id, :name])
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:http_port, greater_than: 0, less_than: 65_536)
    |> BeamPanel.Slug.put_slug(:name)
    |> put_defaults()
    |> validate_required([:deploy_path, :release_name, :service_name])
    |> unique_constraint(:slug, name: :projects_server_id_slug_index)
    |> foreign_key_constraint(:server_id)
  end

  def status_changeset(project, attrs) do
    project
    |> cast(attrs, [:status, :current_version, :previous_version, :last_deployed_at])
    |> validate_inclusion(:status, @statuses)
  end

  defp put_defaults(changeset) do
    slug = get_field(changeset, :slug)

    changeset
    |> put_default(:release_name, fn -> String.replace(slug || "", "-", "_") end)
    |> put_default(:service_name, fn -> "#{slug}.service" end)
    |> put_default(:deploy_path, fn -> "/opt/beam/#{slug}" end)
    |> put_default(:node_name, fn -> "#{String.replace(slug || "", "-", "_")}@127.0.0.1" end)
    |> normalize_service_name()
  end

  defp put_default(changeset, field, fun) do
    case get_field(changeset, field) do
      value when is_binary(value) and value != "" -> changeset
      _ -> put_change(changeset, field, fun.())
    end
  end

  defp normalize_service_name(changeset) do
    case get_field(changeset, :service_name) do
      nil ->
        changeset

      name ->
        name = String.replace(name, ~r/[^A-Za-z0-9._@\-]/, "")
        name = if String.ends_with?(name, ".service"), do: name, else: name <> ".service"
        put_change(changeset, :service_name, name)
    end
  end

  @doc "Path of the current release symlink."
  def current_path(%__MODULE__{deploy_path: path}), do: Path.join(path, "current")

  @doc "Path of the checked-out source tree."
  def source_path(%__MODULE__{deploy_path: path}), do: Path.join(path, "source")

  @doc "Directory holding timestamped releases."
  def releases_path(%__MODULE__{deploy_path: path}), do: Path.join(path, "releases")

  @doc "Path to the release control script."
  def bin_path(%__MODULE__{release_name: name} = project),
    do: Path.join([current_path(project), "bin", name])

  @doc "systemd unit name without the .service suffix."
  def unit_base(%__MODULE__{service_name: name}), do: String.replace_suffix(name, ".service", "")

  @doc "Effective health check URL."
  def health_endpoint(%__MODULE__{health_url: url}) when is_binary(url) and url != "", do: url

  def health_endpoint(%__MODULE__{http_port: port}) when is_integer(port),
    do: "http://127.0.0.1:#{port}/"

  def health_endpoint(_), do: nil
end
