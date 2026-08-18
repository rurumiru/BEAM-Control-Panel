defmodule BeamPanel.Deploy.Runner do
  @moduledoc """
  Executes a deployment.

  Runs as a supervised `Task`, registered by deployment id so it can be
  cancelled. Every line of output is appended to `BeamPanel.Deploy.LogStore` and
  broadcast on `deployment:<id>`.
  """

  require Logger

  alias BeamPanel.Repo
  alias BeamPanel.Deploy
  alias BeamPanel.Deploy.{Deployment, Pipeline, LogStore}
  alias BeamPanel.Projects
  alias BeamPanel.Projects.Project
  alias BeamPanel.Remote

  @registry BeamPanel.Deploy.Registry

  @doc "Entry point for the supervised task."
  def run(deployment_id) do
    Registry.register(@registry, deployment_id, :running)

    deployment =
      Deployment
      |> Repo.get!(deployment_id)
      |> Repo.preload(project: [:server, :env_vars])

    project = deployment.project
    server = project.server

    started = System.monotonic_time(:millisecond)

    deployment =
      deployment
      |> Deploy.update_deployment!(%{
        status: "running",
        started_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    Projects.set_status(project, %{status: "deploying"})
    broadcast(deployment_id, {:deploy_status, "running"})

    previous_release = current_release_target(project)

    log = logger(deployment_id)
    log.("── Деплой #{project.name} на #{server.name} ──")

    result =
      Remote.with_connection(server, fn conn ->
        ctx = %{
          project: project,
          server: server,
          deployment: deployment,
          conn: conn,
          log: log,
          version: version_for(deployment)
        }

        execute(Pipeline.steps(project), ctx, log)
      end)

    duration = System.monotonic_time(:millisecond) - started

    case result do
      {:ok, ctx} ->
        finish_success(deployment, project, ctx, duration, log)

      {:error, step, reason, ctx} ->
        finish_failure(deployment, project, step, reason, ctx, previous_release, duration, log)

      {:error, reason} ->
        finish_failure(
          deployment,
          project,
          :connect,
          reason,
          nil,
          previous_release,
          duration,
          log
        )
    end
  catch
    kind, reason ->
      Logger.error("deploy #{deployment_id} crashed: #{inspect({kind, reason})}")

      Deploy.get_deployment(deployment_id)
      |> case do
        nil ->
          :ok

        deployment ->
          Deploy.update_deployment!(deployment, %{
            status: "failed",
            error: "внутренняя ошибка: #{inspect(reason)}",
            log: LogStore.text(deployment_id),
            finished_at: DateTime.utc_now() |> DateTime.truncate(:second)
          })
      end

      broadcast(deployment_id, {:deploy_status, "failed"})
      {:error, reason}
  end

  ## ---------------------------------------------------------------- internals

  defp execute(steps, ctx, log) do
    Enum.reduce_while(steps, {:ok, ctx}, fn {name, title, fun}, {:ok, ctx} ->
      log.("▸ #{title}")
      broadcast(ctx.deployment.id, {:deploy_step, name, :running})

      case safe_apply(fun, ctx) do
        {:ok, ctx} ->
          broadcast(ctx.deployment.id, {:deploy_step, name, :done})
          {:cont, {:ok, ctx}}

        {:error, reason} ->
          log.("✗ #{title}: #{reason}")
          broadcast(ctx.deployment.id, {:deploy_step, name, :failed})
          {:halt, {:error, name, reason, ctx}}
      end
    end)
  end

  defp safe_apply(fun, ctx) do
    fun.(ctx)
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
  end

  defp finish_success(deployment, project, ctx, duration, log) do
    version = ctx[:release_version] || Pipeline.release_version(ctx)
    log.("✓ Деплой завершён за #{format_duration(duration)}")

    deployment =
      Deploy.update_deployment!(deployment, %{
        status: "success",
        commit_sha: ctx[:commit_sha],
        commit_message: ctx[:commit_message],
        release_version: version,
        previous_version: project.current_version,
        duration_ms: duration,
        log: LogStore.text(deployment.id),
        finished_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    Projects.set_status(project, %{
      status: "running",
      current_version: version,
      previous_version: project.current_version,
      last_deployed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })

    broadcast(deployment.id, {:deploy_status, "success"})
    BeamPanel.Notifications.dispatch(:deploy_success, %{deployment: deployment, project: project})
    {:ok, deployment}
  end

  defp finish_failure(deployment, project, step, reason, ctx, previous_release, duration, log) do
    reason = to_string_reason(reason)
    log.("✗ Ошибка на шаге #{step}: #{reason}")

    rolled_back? =
      if previous_release && ctx && step in [:link, :service, :migrate, :restart, :healthcheck] do
        log.("↩ Откат на предыдущий релиз: #{previous_release}")

        case Pipeline.rollback(ctx, previous_release) do
          {:ok, _} ->
            log.("↩ Откат выполнен")
            true

          {:error, rollback_error} ->
            log.("✗ Откат не удался: #{to_string_reason(rollback_error)}")
            false
        end
      else
        false
      end

    deployment =
      Deploy.update_deployment!(deployment, %{
        status: if(rolled_back?, do: "rolled_back", else: "failed"),
        error: "#{step}: #{reason}",
        commit_sha: ctx && ctx[:commit_sha],
        commit_message: ctx && ctx[:commit_message],
        duration_ms: duration,
        log: LogStore.text(deployment.id),
        finished_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    Projects.refresh_status(project)
    broadcast(deployment.id, {:deploy_status, deployment.status})
    BeamPanel.Notifications.dispatch(:deploy_failed, %{deployment: deployment, project: project})
    {:error, reason}
  end

  defp logger(deployment_id) do
    fn line ->
      line = String.trim_trailing(to_string(line))
      LogStore.append(deployment_id, line)
      broadcast(deployment_id, {:deploy_log, line})
      :ok
    end
  end

  defp broadcast(deployment_id, message) do
    Phoenix.PubSub.broadcast(BeamPanel.PubSub, Deploy.topic(deployment_id), message)
  end

  defp version_for(%Deployment{inserted_at: nil}), do: timestamp()

  defp version_for(%Deployment{inserted_at: inserted_at}) do
    inserted_at |> DateTime.to_iso8601(:basic) |> String.replace(~r/[^0-9T]/, "")
  end

  defp timestamp,
    do: DateTime.utc_now() |> DateTime.to_iso8601(:basic) |> String.replace(~r/[^0-9T]/, "")

  defp current_release_target(%Project{} = project) do
    case Remote.capture(
           project.server,
           "readlink -f #{Remote.shell_quote(Project.current_path(project))} 2>/dev/null"
         ) do
      "" -> nil
      path -> path
    end
  end

  defp to_string_reason(reason) when is_binary(reason), do: reason
  defp to_string_reason(reason), do: inspect(reason)

  defp format_duration(ms) when ms < 1000, do: "#{ms} мс"
  defp format_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)} с"
  defp format_duration(ms), do: "#{div(ms, 60_000)} мин #{rem(div(ms, 1000), 60)} с"
end
