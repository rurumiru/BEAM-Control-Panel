defmodule BeamPanelWeb.DashboardLive do
  @moduledoc "Fleet overview: servers, projects, deployments and live metrics."

  use BeamPanelWeb, :live_view

  alias BeamPanel.{Servers, Projects, Deploy, Monitor}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(BeamPanel.PubSub, Servers.topic())
      Phoenix.PubSub.subscribe(BeamPanel.PubSub, Projects.topic())
      :timer.send_interval(5_000, self(), :refresh)
    end

    {:ok, socket |> assign(page_title: "Обзор") |> load()}
  end

  @impl true
  def handle_info({:metrics, server_id, metrics}, socket) do
    {:noreply, assign(socket, :metrics, Map.put(socket.assigns.metrics, server_id, metrics))}
  end

  def handle_info(:refresh, socket), do: {:noreply, load(socket)}
  def handle_info(_message, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    servers = Servers.list_servers_with_counts()
    projects = Projects.list_projects()

    assign(socket,
      servers: servers,
      projects: projects,
      deployments: Deploy.list_deployments(limit: 8),
      metrics: Monitor.latest_all(Enum.map(servers, & &1.id)),
      server_stats: Servers.count_by_status(),
      project_stats: Projects.count_by_status(),
      deploy_stats: Deploy.stats(7)
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header
      title="Обзор"
      subtitle="Состояние инфраструктуры и BEAM-приложений"
    >
      <:actions>
        <.link navigate={~p"/servers/new"} class="btn btn-sm btn-primary">
          <.icon name="hero-plus" class="size-4" /> Добавить сервер
        </.link>
      </:actions>
    </.page_header>

    <div class="grid grid-cols-2 gap-4 lg:grid-cols-4">
      <.stat_tile
        label="Серверы"
        value={to_string(length(@servers))}
        hint={"онлайн: #{Map.get(@server_stats, "online", 0)} · недоступны: #{Map.get(@server_stats, "unreachable", 0)}"}
        icon="hero-server-stack"
      />
      <.stat_tile
        label="Проекты"
        value={to_string(length(@projects))}
        hint={"работают: #{Map.get(@project_stats, "running", 0)} · остановлены: #{Map.get(@project_stats, "stopped", 0)}"}
        icon="hero-cube"
      />
      <.stat_tile
        label="Деплои за 7 дней"
        value={to_string(Enum.sum(Map.values(@deploy_stats)))}
        hint={"успешно: #{Map.get(@deploy_stats, "success", 0)} · ошибок: #{Map.get(@deploy_stats, "failed", 0)}"}
        icon="hero-rocket-launch"
      />
      <.stat_tile
        label="Суммарная память"
        value={bytes(total_memory(@metrics))}
        hint={"использовано: #{bytes(used_memory(@metrics))}"}
        icon="hero-circle-stack"
      />
    </div>

    <div class="mt-6 grid gap-6 lg:grid-cols-3">
      <div class="lg:col-span-2 space-y-6">
        <.card title="Серверы">
          <:actions>
            <.link navigate={~p"/servers"} class="btn btn-xs btn-ghost">Все</.link>
          </:actions>

          <.empty_state
            :if={@servers == []}
            title="Серверов пока нет"
            description="Добавьте основной или дополнительный сервер, чтобы начать мониторинг."
            icon="hero-server-stack"
          >
            <:actions>
              <.link navigate={~p"/servers/new"} class="btn btn-sm btn-primary">Добавить сервер</.link>
            </:actions>
          </.empty_state>

          <div :if={@servers != []} class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Сервер</th>
                  <th>Статус</th>
                  <th class="text-right">CPU</th>
                  <th class="text-right">RAM</th>
                  <th class="text-right">Диск</th>
                  <th class="text-right">Проекты</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={server <- @servers} class="hover">
                  <td>
                    <.link navigate={~p"/servers/#{server}"} class="link link-hover font-medium">
                      {server.name}
                    </.link>
                    <div class="text-xs text-base-content/50">
                      {server.hostname}
                      <span
                        :if={server.connection == "local"}
                        class="badge badge-xs badge-outline ml-1"
                      >
                        основной
                      </span>
                    </div>
                  </td>
                  <td><.status_badge status={server.status} /></td>
                  <td class="text-right tabular-nums">
                    {metric(@metrics, server.id, fn m -> percent(m.cpu_percent) end)}
                  </td>
                  <td class="text-right tabular-nums">
                    {metric(@metrics, server.id, fn m -> percent(m.memory.percent) end)}
                  </td>
                  <td class="text-right tabular-nums">
                    {metric(@metrics, server.id, fn m -> percent(m.disk.percent) end)}
                  </td>
                  <td class="text-right tabular-nums">{server.project_count}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </.card>

        <.card title="Последние деплои">
          <:actions>
            <.link navigate={~p"/deployments"} class="btn btn-xs btn-ghost">Все</.link>
          </:actions>

          <.empty_state
            :if={@deployments == []}
            title="Деплоев ещё не было"
            icon="hero-rocket-launch"
          />

          <div :if={@deployments != []} class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Проект</th>
                  <th>Статус</th>
                  <th>Версия</th>
                  <th>Длительность</th>
                  <th>Когда</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={deployment <- @deployments} class="hover">
                  <td>
                    <.link navigate={~p"/deployments/#{deployment}"} class="link link-hover">
                      {deployment.project && deployment.project.name}
                    </.link>
                  </td>
                  <td><.status_badge status={deployment.status} /></td>
                  <td class="font-mono text-xs">{deployment.release_version || "—"}</td>
                  <td class="tabular-nums">{duration_ms(deployment.duration_ms)}</td>
                  <td class="text-xs text-base-content/60">{relative(deployment.inserted_at)}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </.card>
      </div>

      <div class="space-y-6">
        <.card title="Проекты">
          <:actions>
            <.link navigate={~p"/projects"} class="btn btn-xs btn-ghost">Все</.link>
          </:actions>

          <.empty_state
            :if={@projects == []}
            title="Проектов нет"
            description="Добавьте проект вручную или найдите существующие приложения на сервере."
            icon="hero-cube"
          />

          <ul :if={@projects != []} class="divide-y divide-base-300">
            <li
              :for={project <- Enum.take(@projects, 10)}
              class="flex items-center justify-between py-2"
            >
              <div class="min-w-0">
                <.link navigate={~p"/projects/#{project}"} class="link link-hover text-sm font-medium">
                  {project.name}
                </.link>
                <div class="text-xs text-base-content/50">
                  {project.server && project.server.name} · {project.kind}
                </div>
              </div>
              <.status_badge status={project.status} />
            </li>
          </ul>
        </.card>

        <.card title="Панель">
          <dl>
            <.kv label="Elixir">{System.version()}</.kv>
            <.kv label="Erlang/OTP">{:erlang.system_info(:otp_release)}</.kv>
            <.kv label="Процессов">{number(:erlang.system_info(:process_count))}</.kv>
            <.kv label="Память BEAM">{bytes(:erlang.memory(:total))}</.kv>
            <.kv label="Аптайм">
              {uptime(div(elem(:erlang.statistics(:wall_clock), 0), 1000))}
            </.kv>
          </dl>
        </.card>
      </div>
    </div>
    """
  end

  defp metric(metrics, server_id, fun) do
    case Map.get(metrics, server_id) do
      nil -> "—"
      m -> fun.(m)
    end
  rescue
    _ -> "—"
  end

  defp total_memory(metrics) do
    metrics |> Map.values() |> Enum.reject(&is_nil/1) |> Enum.map(& &1.memory.total) |> Enum.sum()
  end

  defp used_memory(metrics) do
    metrics |> Map.values() |> Enum.reject(&is_nil/1) |> Enum.map(& &1.memory.used) |> Enum.sum()
  end
end
