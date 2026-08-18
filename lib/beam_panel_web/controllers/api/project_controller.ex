defmodule BeamPanelWeb.Api.ProjectController do
  @moduledoc "Project listing and deployment triggers for CI/CD."

  use BeamPanelWeb, :controller

  alias BeamPanel.{Projects, Deploy}
  alias BeamPanelWeb.ApiAuth

  def index(conn, _params) do
    json(conn, %{data: Enum.map(Projects.list_projects(), &serialize/1)})
  end

  def show(conn, %{"id" => id}) do
    case Projects.get_project(id) do
      nil -> not_found(conn)
      project -> json(conn, %{data: serialize(project)})
    end
  end

  def deploy(conn, %{"id" => id} = params) do
    with_project(conn, id, :deploy, fn conn, project ->
      opts = if params["ref"], do: [ref: params["ref"]], else: []

      case Deploy.deploy(project, conn.assigns.current_user, opts) do
        {:ok, deployment} ->
          conn
          |> put_status(:accepted)
          |> json(%{data: %{deployment_id: deployment.id, status: deployment.status}})

        {:error, :already_running} ->
          conn |> put_status(:conflict) |> json(%{error: "deployment_already_running"})

        {:error, reason} ->
          conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
      end
    end)
  end

  def restart(conn, %{"id" => id}) do
    with_project(conn, id, :deploy, fn conn, project ->
      case Projects.control(project, "restart") do
        {:ok, output} -> json(conn, %{data: %{restarted: true, output: output}})
        {:error, reason} -> conn |> put_status(:unprocessable_entity) |> json(%{error: reason})
      end
    end)
  end

  def rollback(conn, %{"id" => id} = params) do
    with_project(conn, id, :deploy, fn conn, project ->
      case Deploy.rollback(project, conn.assigns.current_user, params["release"]) do
        {:ok, deployment} ->
          json(conn, %{data: %{deployment_id: deployment.id, status: deployment.status}})

        {:error, reason} ->
          conn |> put_status(:unprocessable_entity) |> json(%{error: to_string(reason)})
      end
    end)
  end

  defp with_project(conn, id, scope, fun) do
    conn = ApiAuth.require_scope(conn, scope)

    cond do
      conn.halted -> conn
      project = Projects.get_project(id) -> fun.(conn, project)
      true -> not_found(conn)
    end
  end

  defp serialize(project) do
    %{
      id: project.id,
      name: project.name,
      slug: project.slug,
      kind: project.kind,
      status: project.status,
      server_id: project.server_id,
      server: project.server && project.server.name,
      deploy_path: project.deploy_path,
      service_name: project.service_name,
      release_name: project.release_name,
      branch: project.branch,
      repo_url: project.repo_url,
      http_port: project.http_port,
      node_name: project.node_name,
      current_version: project.current_version,
      previous_version: project.previous_version,
      last_deployed_at: project.last_deployed_at
    }
  end

  defp not_found(conn), do: conn |> put_status(:not_found) |> json(%{error: "not_found"})
end
