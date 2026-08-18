defmodule BeamPanelWeb.Api.DeploymentController do
  @moduledoc "Deployment history and logs over the API."

  use BeamPanelWeb, :controller

  alias BeamPanel.Deploy

  def index(conn, params) do
    opts =
      [limit: min(parse_int(params["limit"], 50), 200)]
      |> maybe_put(:project_id, parse_int(params["project_id"], nil))
      |> maybe_put(:status, params["status"])

    json(conn, %{data: Enum.map(Deploy.list_deployments(opts), &serialize/1)})
  end

  def show(conn, %{"id" => id}) do
    case Deploy.get_deployment(id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      deployment ->
        json(conn, %{data: Map.put(serialize(deployment), :log, Deploy.log_lines(deployment))})
    end
  end

  defp serialize(deployment) do
    %{
      id: deployment.id,
      project_id: deployment.project_id,
      project: deployment.project && deployment.project.name,
      status: deployment.status,
      strategy: deployment.strategy,
      ref: deployment.ref,
      commit_sha: deployment.commit_sha,
      commit_message: deployment.commit_message,
      release_version: deployment.release_version,
      previous_version: deployment.previous_version,
      error: deployment.error,
      duration_ms: deployment.duration_ms,
      started_at: deployment.started_at,
      finished_at: deployment.finished_at,
      user: deployment.user && deployment.user.email,
      inserted_at: deployment.inserted_at
    }
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp parse_int(nil, default), do: default

  defp parse_int(value, default) do
    case Integer.parse(to_string(value)) do
      {int, _} -> int
      :error -> default
    end
  end
end
