defmodule BeamPanelWeb.ServerLive.Show do
  @moduledoc "Single server: live metrics, environment facts, projects and system actions."

  use BeamPanelWeb, :live_view

  alias BeamPanel.{Servers, Projects, Monitor, Accounts, Audit}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    server = Servers.get_server!(id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(BeamPanel.PubSub, Servers.topic(server))
      Phoenix.PubSub.subscribe(BeamPanel.PubSub, Servers.topic())
      Monitor.poll_now(server.id)
    end

    {:ok,
     socket
     |> assign(
       server: server,
       page_title: server.name,
       metrics: Monitor.latest(server.id),
       series: Monitor.series(server.id, 90),
       projects: Projects.list_projects_for_server(server.id),
       processes: [],
       pending_updates: nil,
       busy: nil
     )}
  end

  ## ------------------------------------------------------------------ events

  @impl true
  def handle_event("check", _params, socket) do
    server = socket.assigns.server

    case Servers.check_connection(server) do
      {:ok, server} ->
        {:noreply,
         socket |> assign(:server, server) |> put_flash(:info, "Связь есть, данные обновлены.")}

      {:error, reason, server} ->
        {:noreply, socket |> assign(:server, server) |> put_flash(:error, "Нет связи: #{reason}")}
    end
  end

  def handle_event("refresh_facts", _params, socket) do
    case Servers.refresh_facts(socket.assigns.server) do
      {:ok, server} -> {:noreply, assign(socket, :server, server)}
      _ -> {:noreply, put_flash(socket, :error, "Не удалось получить данные о сервере.")}
    end
  end

  def handle_event("load_processes", _params, socket) do
    case Servers.top_processes(socket.assigns.server, 15) do
      {:ok, processes} -> {:noreply, assign(socket, :processes, processes)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, reason)}
    end
  end

  def handle_event("check_updates", _params, socket) do
    count = Servers.pending_updates(socket.assigns.server)
    {:noreply, assign(socket, :pending_updates, count)}
  end

  def handle_event("kill", %{"pid" => pid}, socket) do
    if Accounts.can?(socket.assigns.current_user, :operator) do
      case Servers.kill_process(socket.assigns.server, pid) do
        :ok ->
          Audit.log(socket.assigns.current_user, "server.kill_process",
            resource_type: "server",
            resource_id: socket.assigns.server.id,
            metadata: %{pid: pid}
          )

          {:noreply, put_flash(socket, :info, "Сигнал отправлен процессу #{pid}.")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, reason)}
      end
    else
      {:noreply, put_flash(socket, :error, "Недостаточно прав.")}
    end
  end

  def handle_event("reboot", _params, socket) do
    if Accounts.can?(socket.assigns.current_user, :admin) do
      Servers.reboot(socket.assigns.server)

      Audit.log(socket.assigns.current_user, "server.reboot",
        resource_type: "server",
        resource_id: socket.assigns.server.id
      )

      {:noreply, put_flash(socket, :info, "Команда перезагрузки отправлена.")}
    else
      {:noreply, put_flash(socket, :error, "Перезагружать сервер может только администратор.")}
    end
  end

  @impl true
  def handle_info({:metrics, server_id, metrics}, socket) do
    if server_id == socket.assigns.server.id do
      {:noreply,
       socket
       |> assign(:metrics, metrics)
       |> assign(:series, Monitor.series(server_id, 90))}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:server_status, server}, socket) do
    if server.id == socket.assigns.server.id do
      {:noreply, assign(socket, :server, Servers.get_server!(server.id))}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  ## ------------------------------------------------------------------ render

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header
      title={@server.name}
      subtitle={"#{@server.ssh_user}@#{@server.hostname}:#{@server.ssh_port}"}
    >
      <:breadcrumb>
        <ul>
          <li><.link navigate={~p"/servers"}>Серверы</.link></li>
          
          <li>{@server.name}</li>
        </ul>
      </:breadcrumb>
      
      <:actions>
        <.status_badge status={@server.status} class="badge-md" />
        <button class="btn btn-sm" phx-click="check">
          <.icon name="hero-signal" class="size-4" /> Проверить связь
        </button>
        
        <.link navigate={~p"/servers/#{@server}/discover"} class="btn btn-sm">
          <.icon name="hero-magnifying-glass" class="size-4" /> Найти проекты
        </.link>
        
        <.link navigate={~p"/servers/#{@server}/provision"} class="btn btn-sm btn-primary">
          <.icon name="hero-wrench-screwdriver" class="size-4" /> Установка ПО
        </.link>
      </:actions>
    </.page_header>

    <div :if={@server.status_message} class="alert alert-warning mb-4 text-sm">
      <.icon name="hero-exclamation-triangle" class="size-5" /> <span>{@server.status_message}</span>
    </div>

    <div class="grid grid-cols-2 gap-4 lg:grid-cols-4">
      <.stat_tile
        label="CPU"
        value={percent(@metrics && @metrics.cpu_percent)}
        hint={
          @metrics && "LA #{@metrics.load.load1} / #{@metrics.load.load5} / #{@metrics.load.load15}"
        }
        icon="hero-cpu-chip"
        progress={@metrics && @metrics.cpu_percent}
      />
      <.stat_tile
        label="Память"
        value={percent(@metrics && @metrics.memory.percent)}
        hint={@metrics && "#{bytes(@metrics.memory.used)} из #{bytes(@metrics.memory.total)}"}
        icon="hero-circle-stack"
        progress={@metrics && @metrics.memory.percent}
      />
      <.stat_tile
        label="Диск /"
        value={percent(@metrics && @metrics.disk.percent)}
        hint={@metrics && "#{bytes(@metrics.disk.used)} из #{bytes(@metrics.disk.total)}"}
        icon="hero-server"
        progress={@metrics && @metrics.disk.percent}
      />
      <.stat_tile
        label="Аптайм"
        value={uptime(@metrics && @metrics.uptime)}
        hint={@metrics && "процессов: #{@metrics.process_count || "—"}"}
        icon="hero-clock"
      />
    </div>

    <div class="mt-6 grid gap-6 lg:grid-cols-3">
      <div class="space-y-6 lg:col-span-2">
        <.card title="Нагрузка">
          <div class="grid gap-6 sm:grid-cols-2">
            <div>
              <div class="mb-1 flex items-baseline justify-between">
                <span class="text-xs uppercase text-base-content/60">CPU, %</span>
                <span class="text-sm font-semibold tabular-nums">
                  {percent(@metrics && @metrics.cpu_percent)}
                </span>
              </div>
              
              <.sparkline
                values={Enum.map(@series, & &1.cpu_percent)}
                class="h-16 w-full text-primary"
              />
            </div>
            
            <div>
              <div class="mb-1 flex items-baseline justify-between">
                <span class="text-xs uppercase text-base-content/60">Память, %</span>
                <span class="text-sm font-semibold tabular-nums">
                  {percent(@metrics && @metrics.memory.percent)}
                </span>
              </div>
              
              <.sparkline
                values={Enum.map(@series, & &1.memory.percent)}
                class="h-16 w-full text-secondary"
              />
            </div>
            
            <div>
              <div class="mb-1 flex items-baseline justify-between">
                <span class="text-xs uppercase text-base-content/60">Сеть ↓</span>
                <span class="text-sm font-semibold tabular-nums">
                  {rate(@metrics && @metrics.net.rx_rate)}
                </span>
              </div>
              
              <.sparkline values={Enum.map(@series, & &1.net.rx_rate)} class="h-16 w-full text-info" />
            </div>
            
            <div>
              <div class="mb-1 flex items-baseline justify-between">
                <span class="text-xs uppercase text-base-content/60">Сеть ↑</span>
                <span class="text-sm font-semibold tabular-nums">
                  {rate(@metrics && @metrics.net.tx_rate)}
                </span>
              </div>
              
              <.sparkline
                values={Enum.map(@series, & &1.net.tx_rate)}
                class="h-16 w-full text-accent"
              />
            </div>
          </div>
        </.card>
        
        <.card title="BEAM-процессы на сервере">
          <.empty_state
            :if={@metrics == nil or @metrics.beam_processes == []}
            title="Запущенных BEAM-нод не обнаружено"
            description="Если приложение запущено, но не видно здесь — проверьте, что процесс beam.smp работает от доступного пользователя."
            icon="hero-cube"
          />
          <div :if={@metrics && @metrics.beam_processes != []} class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>PID</th>
                  
                  <th>Нода</th>
                  
                  <th class="text-right">RSS</th>
                  
                  <th class="text-right">Аптайм</th>
                  
                  <th>Релиз</th>
                </tr>
              </thead>
              
              <tbody>
                <tr :for={process <- @metrics.beam_processes} class="hover">
                  <td class="font-mono text-xs">{process.pid}</td>
                  
                  <td class="font-mono text-xs">{process.node || "—"}</td>
                  
                  <td class="text-right tabular-nums">{bytes(process.rss)}</td>
                  
                  <td class="text-right tabular-nums">{uptime(process.uptime)}</td>
                  
                  <td class="truncate text-xs text-base-content/60">
                    {truncate(process.release, 40)}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </.card>
        
        <.card title="Проекты на сервере">
          <:actions>
            <.link navigate={~p"/servers/#{@server}/discover"} class="btn btn-xs btn-ghost">
              Найти
            </.link>
          </:actions>
          
          <.empty_state
            :if={@projects == []}
            title="Проектов нет"
            description="Запустите поиск, чтобы найти уже развёрнутые приложения, или добавьте проект вручную."
            icon="hero-cube"
          />
          <ul :if={@projects != []} class="divide-y divide-base-300">
            <li :for={project <- @projects} class="flex items-center justify-between gap-3 py-2">
              <div class="min-w-0">
                <.link navigate={~p"/projects/#{project}"} class="link link-hover font-medium">
                  {project.name}
                </.link>
                
                <div class="truncate text-xs text-base-content/50">
                  {project.service_name} · {project.deploy_path}
                </div>
              </div>
               <.status_badge status={project.status} />
            </li>
          </ul>
        </.card>
        
        <.card title="Топ процессов">
          <:actions>
            <button class="btn btn-xs" phx-click="load_processes">Обновить</button>
          </:actions>
          
          <.empty_state
            :if={@processes == []}
            title="Нажмите «Обновить», чтобы получить список"
            icon="hero-list-bullet"
          />
          <div :if={@processes != []} class="overflow-x-auto">
            <table class="table table-xs">
              <thead>
                <tr>
                  <th>PID</th>
                  
                  <th>Пользователь</th>
                  
                  <th>Команда</th>
                  
                  <th class="text-right">CPU %</th>
                  
                  <th class="text-right">MEM %</th>
                  
                  <th class="text-right">RSS</th>
                  
                  <th></th>
                </tr>
              </thead>
              
              <tbody>
                <tr :for={process <- @processes} class="hover">
                  <td class="font-mono">{process.pid}</td>
                  
                  <td>{process.user}</td>
                  
                  <td class="font-mono">{process.command}</td>
                  
                  <td class="text-right tabular-nums">{process.cpu}</td>
                  
                  <td class="text-right tabular-nums">{process.mem}</td>
                  
                  <td class="text-right tabular-nums">{bytes(process.rss)}</td>
                  
                  <td class="text-right">
                    <.danger_button
                      class="btn btn-ghost btn-xs text-error"
                      confirm={"Отправить SIGTERM процессу #{process.pid}?"}
                      phx-click="kill"
                      phx-value-pid={process.pid}
                    >
                      kill
                    </.danger_button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </.card>
      </div>
      
      <div class="space-y-6">
        <.card title="Окружение">
          <:actions>
            <button class="btn btn-xs" phx-click="refresh_facts">Обновить</button>
          </:actions>
          
          <dl>
            <.kv label="ОС">{@server.facts["os_pretty"] || "—"}</.kv>
            
            <.kv label="Ядро">{@server.facts["kernel"] || "—"}</.kv>
            
            <.kv label="Архитектура">{@server.facts["arch"] || "—"}</.kv>
            
            <.kv label="vCPU">{@server.facts["cpu_cores"] || "—"}</.kv>
            
            <.kv label="RAM">
              {(@server.facts["mem_total_mb"] && "#{@server.facts["mem_total_mb"]} MB") || "—"}
            </.kv>
            
            <.kv label="Виртуализация">{@server.facts["virt"] || "—"}</.kv>
          </dl>
          
          <div class="divider my-2"></div>
          
          <dl>
            <.kv label="Erlang/OTP">
              <span class={erlang_class(@server.facts["erlang"])}>
                {@server.facts["erlang"] || "не установлен"}
              </span>
            </.kv>
            
            <.kv label="Elixir">
              <span class={erlang_class(@server.facts["elixir"])}>
                {@server.facts["elixir"] || "не установлен"}
              </span>
            </.kv>
            
            <.kv label="rebar3">{@server.facts["rebar3"] || "—"}</.kv>
            
            <.kv label="Node.js">{@server.facts["node"] || "—"}</.kv>
            
            <.kv label="Git">{@server.facts["git"] || "—"}</.kv>
            
            <.kv label="Docker">{@server.facts["docker"] || "—"}</.kv>
            
            <.kv label="nginx">{@server.facts["nginx"] || "—"}</.kv>
            
            <.kv label="PostgreSQL">{@server.facts["postgres"] || "—"}</.kv>
            
            <.kv label="epmd">{@server.facts["epmd_names"] || "—"}</.kv>
          </dl>
        </.card>
        
        <.card title="Обслуживание">
          <div class="space-y-2">
            <button class="btn btn-sm btn-block" phx-click="check_updates">
              Проверить обновления системы
            </button>
            
            <p :if={@pending_updates} class="text-sm">
              Доступно обновлений: <span class="font-semibold">{@pending_updates}</span>
            </p>
            
            <.link navigate={~p"/servers/#{@server}/services"} class="btn btn-sm btn-block">
              Управление службами
            </.link>
            
            <.danger_button
              class="btn btn-sm btn-block btn-error btn-outline"
              confirm={"Перезагрузить сервер #{@server.name}?"}
              phx-click="reboot"
            >
              Перезагрузить сервер
            </.danger_button>
          </div>
        </.card>
        
        <.card title="Подключение">
          <dl>
            <.kv label="Тип">{(@server.connection == "local" && "локально") || "SSH"}</.kv>
            
            <.kv label="Аутентификация">{@server.auth_method}</.kv>
            
            <.kv label="Каталог деплоя">{@server.deploy_root}</.kv>
            
            <.kv label="Пользователь деплоя">{@server.deploy_user}</.kv>
            
            <.kv label="Интервал опроса">{@server.monitor_interval} с</.kv>
            
            <.kv label="Последний ответ">{relative(@server.last_seen_at)}</.kv>
          </dl>
        </.card>
      </div>
    </div>
    """
  end

  defp erlang_class(nil), do: "text-error"
  defp erlang_class(_), do: "text-success"
end
