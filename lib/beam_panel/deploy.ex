defmodule BeamPanel.Deploy do
  @moduledoc """
  Deployment context: starting runs, streaming their output, rolling back and
  querying history.
  """

  use Supervisor

  import Ecto.Query, warn: false

  alias BeamPanel.Repo
  alias BeamPanel.Deploy.{Deployment, Runner, LogStore, Pipeline}
  alias BeamPanel.Projects
  alias BeamPanel.Projects.Project
  alias BeamPanel.Remote

  ## ------------------------------------------------------------- supervision

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: BeamPanel.Deploy.Registry},
      LogStore,
      {Task.Supervisor, name: BeamPanel.Deploy.TaskSupervisor}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  ## ------------------------------------------------------------------- topics

  def topic(%Deployment{id: id}), do: "deployment:#{id}"
  def topic(id) when is_integer(id), do: "deployment:#{id}"

  ## ------------------------------------------------------------------ queries

  def list_deployments(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    Deployment
    |> maybe_where(:project_id, opts[:project_id])
    |> maybe_where(:status, opts[:status])
    |> order_by(desc: :inserted_at, desc: :id)
    |> limit(^limit)
    |> preload([:project, :user])
    |> Repo.all()
  end

  defp maybe_where(query, _field, nil), do: query
  defp maybe_where(query, field, value), do: where(query, [d], field(d, ^field) == ^value)

  def get_deployment(id) do
    Deployment |> Repo.get(id) |> Repo.preload([:user, project: :server])
  end

  def get_deployment!(id) do
    Deployment |> Repo.get!(id) |> Repo.preload([:user, project: :server])
  end

  def running_deployments do
    Repo.all(from d in Deployment, where: d.status == "running", preload: [:project])
  end

  def update_deployment!(%Deployment{} = deployment, attrs) do
    deployment |> Deployment.changeset(attrs) |> Repo.update!()
  end

  ## ---------------------------------------------------------------- launching

  @doc """
  Starts a deployment for `project`.

  Options:

    * `:ref`      — git ref to deploy (defaults to `origin/<branch>`)
    * `:strategy` — `"release"` (default) or `"restart"`
  """
  def deploy(%Project{} = project, user, opts \\ []) do
    if deploying?(project) do
      {:error, :already_running}
    else
      attrs = %{
        project_id: project.id,
        user_id: user && user.id,
        ref: opts[:ref],
        strategy: to_string(opts[:strategy] || "release"),
        status: "pending"
      }

      with {:ok, deployment} <- %Deployment{} |> Deployment.changeset(attrs) |> Repo.insert() do
        LogStore.clear(deployment.id)

        {:ok, _pid} =
          Task.Supervisor.start_child(BeamPanel.Deploy.TaskSupervisor, fn ->
            Runner.run(deployment.id)
          end)

        BeamPanel.Audit.log(user, "deploy.start",
          resource_type: "project",
          resource_id: project.id,
          metadata: %{deployment_id: deployment.id, ref: attrs.ref}
        )

        {:ok, deployment}
      end
    end
  end

  @doc "Whether a deployment for this project is currently running."
  def deploying?(%Project{id: id}) do
    Repo.exists?(
      from d in Deployment, where: d.project_id == ^id and d.status in ["pending", "running"]
    )
  end

  @doc "Kills a running deployment."
  def cancel(%Deployment{} = deployment) do
    case Registry.lookup(BeamPanel.Deploy.Registry, deployment.id) do
      [{pid, _}] ->
        Process.exit(pid, :kill)

        deployment =
          update_deployment!(deployment, %{
            status: "cancelled",
            log: LogStore.text(deployment.id),
            finished_at: DateTime.utc_now() |> DateTime.truncate(:second)
          })

        Phoenix.PubSub.broadcast(
          BeamPanel.PubSub,
          topic(deployment),
          {:deploy_status, "cancelled"}
        )

        {:ok, deployment}

      [] ->
        {:error, :not_running}
    end
  end

  ## ----------------------------------------------------------------- rollback

  @doc "Lists release directories available on the server, newest first."
  def available_releases(%Project{} = project) do
    project = Repo.preload(project, :server)
    Pipeline.list_releases(project)
  end

  @doc """
  Points `current` at `release_dir` (or the previous release when omitted) and
  restarts the service.
  """
  def rollback(%Project{} = project, user, release_dir \\ nil) do
    project = Repo.preload(project, :server)
    releases = available_releases(project)

    current =
      Remote.capture(
        project.server,
        "readlink -f #{Remote.shell_quote(Project.current_path(project))}"
      )

    target = release_dir || Enum.find(releases, &(&1 != current))

    cond do
      is_nil(target) ->
        {:error, :no_previous_release}

      true ->
        {:ok, deployment} =
          %Deployment{}
          |> Deployment.changeset(%{
            project_id: project.id,
            user_id: user && user.id,
            strategy: "rollback",
            status: "running",
            started_at: DateTime.utc_now() |> DateTime.truncate(:second)
          })
          |> Repo.insert()

        log = fn line ->
          LogStore.append(deployment.id, line)
          Phoenix.PubSub.broadcast(BeamPanel.PubSub, topic(deployment), {:deploy_log, line})
        end

        log.("↩ Откат на #{target}")

        ctx = %{
          project: project,
          server: project.server,
          deployment: deployment,
          log: log,
          conn: nil
        }

        result = Pipeline.rollback(ctx, target)

        {status, error} =
          case result do
            {:ok, _} ->
              log.("✓ Откат выполнен")
              {"rolled_back", nil}

            {:error, reason} ->
              log.("✗ Откат не удался: #{inspect(reason)}")
              {"failed", inspect(reason)}
          end

        deployment =
          update_deployment!(deployment, %{
            status: status,
            error: error,
            release_version: Path.basename(target),
            previous_version: project.current_version,
            log: LogStore.text(deployment.id),
            finished_at: DateTime.utc_now() |> DateTime.truncate(:second)
          })

        if status == "rolled_back" do
          Projects.set_status(project, %{
            status: "running",
            current_version: Path.basename(target)
          })
        end

        BeamPanel.Audit.log(user, "deploy.rollback",
          resource_type: "project",
          resource_id: project.id,
          metadata: %{target: target},
          result: if(status == "rolled_back", do: :ok, else: :error)
        )

        Phoenix.PubSub.broadcast(BeamPanel.PubSub, topic(deployment), {:deploy_status, status})

        {:ok, deployment}
    end
  end

  ## --------------------------------------------------------------------- logs

  @doc "Log lines for a deployment — live buffer while running, DB once finished."
  def log_lines(%Deployment{} = deployment) do
    case LogStore.lines(deployment.id) do
      [] -> String.split(deployment.log || "", ~r/\r?\n/)
      lines -> lines
    end
  end

  @doc "Deployment statistics for the dashboard."
  def stats(days \\ 7) do
    since = DateTime.add(DateTime.utc_now(), -days * 24, :hour)

    from(d in Deployment,
      where: d.inserted_at >= ^since,
      group_by: d.status,
      select: {d.status, count(d.id)}
    )
    |> Repo.all()
    |> Map.new()
  end
end
