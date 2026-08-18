defmodule BeamPanelWeb.DeploymentLive.Index do
  @moduledoc "Deployment history across all projects."

  use BeamPanelWeb, :live_view

  alias BeamPanel.Deploy

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(10_000, self(), :tick)

    {:ok, socket |> assign(page_title: "Деплои", status: nil) |> load()}
  end

  defp load(socket) do
    opts = [limit: 100]

    opts =
      if socket.assigns.status, do: Keyword.put(opts, :status, socket.assigns.status), else: opts

    assign(socket, deployments: Deploy.list_deployments(opts), stats: Deploy.stats(7))
  end

  @impl true
  def handle_event("filter", %{"status" => status}, socket) do
    status = if status == "", do: nil, else: status
    {:noreply, socket |> assign(:status, status) |> load()}
  end

  @impl true
  def handle_info(:tick, socket), do: {:noreply, load(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header
      title="Деплои"
      subtitle="История развёртываний за всё время"
    >
      <:actions>
        <form phx-change="filter">
          <select name="status" class="select select-sm select-bordered">
            <option value="">Все статусы</option>
            <option
              :for={status <- ~w(running success failed rolled_back cancelled)}
              value={status}
              selected={@status == status}
            >
              {status_label(status)}
            </option>
          </select>
        </form>
      </:actions>
    </.page_header>

    <div class="mb-6 grid grid-cols-2 gap-4 lg:grid-cols-4">
      <.stat_tile
        label="Всего за 7 дней"
        value={to_string(Enum.sum(Map.values(@stats)))}
        icon="hero-rocket-launch"
      />
      <.stat_tile
        label="Успешно"
        value={to_string(Map.get(@stats, "success", 0))}
        tone="text-success"
      />
      <.stat_tile
        label="С ошибкой"
        value={to_string(Map.get(@stats, "failed", 0))}
        tone="text-error"
      />
      <.stat_tile
        label="Откаты"
        value={to_string(Map.get(@stats, "rolled_back", 0))}
        tone="text-warning"
      />
    </div>

    <.card title={"Записей: #{length(@deployments)}"}>
      <.empty_state :if={@deployments == []} title="Деплоев нет" icon="hero-rocket-launch" />

      <div :if={@deployments != []} class="overflow-x-auto">
        <table class="table table-sm">
          <thead>
            <tr>
              <th>Проект</th>
              <th>Статус</th>
              <th>Стратегия</th>
              <th>Версия</th>
              <th>Коммит</th>
              <th>Длительность</th>
              <th>Кто</th>
              <th>Когда</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={deployment <- @deployments} class="hover">
              <td>
                <.link
                  :if={deployment.project}
                  navigate={~p"/projects/#{deployment.project}"}
                  class="link link-hover"
                >
                  {deployment.project.name}
                </.link>
              </td>
              <td><.status_badge status={deployment.status} /></td>
              <td class="text-xs">{deployment.strategy}</td>
              <td class="font-mono text-xs">{deployment.release_version || "—"}</td>
              <td class="font-mono text-xs">{deployment.commit_sha || "—"}</td>
              <td class="tabular-nums text-xs">{duration_ms(deployment.duration_ms)}</td>
              <td class="text-xs">{(deployment.user && deployment.user.email) || "—"}</td>
              <td class="text-xs text-base-content/60">{relative(deployment.inserted_at)}</td>
              <td class="text-right">
                <.link navigate={~p"/deployments/#{deployment}"} class="btn btn-xs">Лог</.link>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </.card>
    """
  end
end
