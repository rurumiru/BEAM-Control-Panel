defmodule BeamPanelWeb.Api.ServerController do
  @moduledoc "Read-only server inventory plus a connectivity probe."

  use BeamPanelWeb, :controller

  alias BeamPanel.{Servers, Monitor}
  alias BeamPanelWeb.ApiAuth

  def index(conn, _params) do
    json(conn, %{data: Enum.map(Servers.list_servers(), &serialize/1)})
  end

  def show(conn, %{"id" => id}) do
    case Servers.get_server(id) do
      nil -> not_found(conn)
      server -> json(conn, %{data: serialize(server, Monitor.latest(server.id))})
    end
  end

  def metrics(conn, %{"id" => id} = params) do
    case Servers.get_server(id) do
      nil ->
        not_found(conn)

      server ->
        limit = parse_int(params["limit"], 120)

        json(conn, %{
          data: %{
            latest: Monitor.latest(server.id),
            series: Monitor.series(server.id, limit)
          }
        })
    end
  end

  def check(conn, %{"id" => id}) do
    conn = ApiAuth.require_scope(conn, :deploy)

    if conn.halted do
      conn
    else
      case Servers.get_server(id) do
        nil ->
          not_found(conn)

        server ->
          case Servers.check_connection(server) do
            {:ok, server} ->
              json(conn, %{data: serialize(server), reachable: true})

            {:error, reason, server} ->
              json(conn, %{data: serialize(server), reachable: false, error: reason})
          end
      end
    end
  end

  defp serialize(server, metrics \\ nil) do
    %{
      id: server.id,
      name: server.name,
      slug: server.slug,
      hostname: server.hostname,
      connection: server.connection,
      role: server.role,
      status: server.status,
      status_message: server.status_message,
      tags: server.tags,
      last_seen_at: server.last_seen_at,
      facts: server.facts,
      metrics: metrics
    }
  end

  defp not_found(conn), do: conn |> put_status(:not_found) |> json(%{error: "not_found"})

  defp parse_int(nil, default), do: default

  defp parse_int(value, default) do
    case Integer.parse(to_string(value)) do
      {int, _} -> min(int, 720)
      :error -> default
    end
  end
end
