defmodule BeamPanelWeb.ProjectLive.Beam do
  @moduledoc """
  OTP introspection for a running project: schedulers, memory, applications,
  supervision trees, processes, ETS tables, ports and the distribution view.
  """

  use BeamPanelWeb, :live_view

  alias BeamPanel.{Projects, Beam, Accounts, Audit}

  @tabs [
    {"overview", "Обзор"},
    {"applications", "Приложения"},
    {"supervision", "Супервизоры"},
    {"processes", "Процессы"},
    {"ets", "ETS"},
    {"ports", "Порты"},
    {"cluster", "Кластер"},
    {"console", "Консоль"}
  ]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    project = Projects.get_project!(id)

    socket =
      assign(socket,
        project: project,
        page_title: "OTP · #{project.name}",
        tab: "overview",
        loading: false,
        error: nil,
        system: nil,
        applications: [],
        tree: nil,
        tree_app: nil,
        processes: [],
        sort: "memory",
        ets: [],
        ports: [],
        cluster: nil,
        console_code: "",
        console_result: nil
      )

    {:ok, if(connected?(socket), do: fetch(socket, "overview"), else: socket)}
  end

  def tabs, do: @tabs

  ## ------------------------------------------------------------------ events

  @impl true
  def handle_event("tab", %{"tab" => tab}, socket), do: {:noreply, fetch(socket, tab)}

  def handle_event("refresh", _params, socket), do: {:noreply, fetch(socket, socket.assigns.tab)}

  def handle_event("sort", %{"sort" => sort}, socket) do
    {:noreply, socket |> assign(:sort, sort) |> fetch("processes")}
  end

  def handle_event("tree", %{"app" => app}, socket) do
    case Beam.supervision_tree(socket.assigns.project, app) do
      {:ok, tree} -> {:noreply, assign(socket, tree: tree, tree_app: app, error: nil)}
      {:error, reason} -> {:noreply, assign(socket, error: format(reason))}
    end
  end

  def handle_event("eval", %{"code" => code}, socket) do
    cond do
      not Accounts.can?(socket.assigns.current_user, :admin) ->
        {:noreply, put_flash(socket, :error, "Выполнять код на ноде может только администратор.")}

      String.trim(code) == "" ->
        {:noreply, socket}

      true ->
        Audit.log(socket.assigns.current_user, "beam.eval",
          resource_type: "project",
          resource_id: socket.assigns.project.id,
          metadata: %{code: String.slice(code, 0, 500)}
        )

        result =
          case Beam.eval(socket.assigns.project, code) do
            {:ok, output} -> output
            {:error, reason} -> "ОШИБКА: #{format(reason)}"
          end

        {:noreply, assign(socket, console_result: result, console_code: code)}
    end
  end

  ## ------------------------------------------------------------------- fetch

  defp fetch(socket, tab) do
    project = socket.assigns.project
    socket = assign(socket, tab: tab, error: nil)

    case tab do
      "overview" ->
        put(socket, :system, Beam.system_info(project))

      "applications" ->
        put(socket, :applications, Beam.applications(project))

      "supervision" ->
        put(socket, :applications, Beam.applications(project))

      "processes" ->
        put(socket, :processes, Beam.processes(project, String.to_atom(socket.assigns.sort), 40))

      "ets" ->
        put(socket, :ets, Beam.ets_tables(project))

      "ports" ->
        put(socket, :ports, Beam.ports(project))

      "cluster" ->
        put(socket, :cluster, Beam.cluster(project))

      _ ->
        socket
    end
  end

  defp put(socket, key, {:ok, value}), do: assign(socket, key, value)
  defp put(socket, _key, {:error, reason}), do: assign(socket, :error, format(reason))

  defp format(reason) when is_binary(reason), do: reason
  defp format(reason), do: inspect(reason, limit: 10, printable_limit: 800)

  ## ------------------------------------------------------------------ render

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header
      title="OTP-интроспекция"
      subtitle={"#{@project.name} · #{@project.node_name || "нода не задана"}"}
    >
      <:breadcrumb>
        <ul>
          <li><.link navigate={~p"/projects"}>Проекты</.link></li>
          <li><.link navigate={~p"/projects/#{@project}"}>{@project.name}</.link></li>
          <li>OTP</li>
        </ul>
      </:breadcrumb>
      <:actions>
        <button class="btn btn-sm" phx-click="refresh">
          <.icon name="hero-arrow-path" class="size-4" /> Обновить
        </button>
      </:actions>
    </.page_header>

    <div role="tablist" class="tabs tabs-box mb-4">
      <button
        :for={{key, label} <- tabs()}
        role="tab"
        class={["tab", @tab == key && "tab-active"]}
        phx-click="tab"
        phx-value-tab={key}
      >
        {label}
      </button>
    </div>

    <div :if={@error} class="alert alert-warning mb-4 text-sm">
      <.icon name="hero-exclamation-triangle" class="size-5" />
      <div>
        <p class="font-medium">Не удалось получить данные с ноды.</p>
        <p class="mt-1 font-mono text-xs opacity-80">{@error}</p>
        <p class="mt-1 text-xs opacity-70">
          Проверьте, что приложение запущено и релиз доступен по пути <code>{BeamPanel.Projects.Project.bin_path(@project)}</code>.
        </p>
      </div>
    </div>

    <%!-- Overview --%>
    <div :if={@tab == "overview" and @system}>
      <div class="grid grid-cols-2 gap-4 lg:grid-cols-4">
        <.stat_tile
          label="Процессы"
          value={number(@system.process_count)}
          hint={"лимит: #{number(@system.process_limit)}"}
          icon="hero-cpu-chip"
          progress={ratio(@system.process_count, @system.process_limit)}
        />
        <.stat_tile
          label="Память BEAM"
          value={bytes(@system.memory[:total])}
          hint={"процессы: #{bytes(@system.memory[:processes])}"}
          icon="hero-circle-stack"
        />
        <.stat_tile
          label="Планировщики"
          value={"#{@system.schedulers_online}/#{@system.schedulers}"}
          hint={"run queue: #{@system.run_queue}"}
          icon="hero-bolt"
        />
        <.stat_tile
          label="Аптайм ноды"
          value={uptime(div(@system.uptime_ms, 1000))}
          hint={"ETS: #{@system.ets_count} · порты: #{@system.port_count}"}
          icon="hero-clock"
        />
      </div>

      <div class="mt-6 grid gap-6 lg:grid-cols-2">
        <.card title="Нода">
          <dl>
            <.kv label="Имя">{@system.node}</.kv>
            <.kv label="OTP">{@system.otp_release}</.kv>
            <.kv label="ERTS">{@system.erts_version}</.kv>
            <.kv label="Elixir">{@system.elixir_version}</.kv>
            <.kv label="Атомы">{number(@system.atom_count)} / {number(@system.atom_limit)}</.kv>
            <.kv label="Порты">{number(@system.port_count)} / {number(@system.port_limit)}</.kv>
            <.kv label="Редукции">{number(@system.reductions)}</.kv>
            <.kv label="Соединённые ноды">
              {(@system.connected_nodes != [] && Enum.join(@system.connected_nodes, ", ")) || "нет"}
            </.kv>
          </dl>
        </.card>

        <.card title="Память по типам">
          <dl>
            <.kv
              :for={{key, value} <- Enum.sort_by(@system.memory, &elem(&1, 1), :desc)}
              label={to_string(key)}
            >
              {bytes(value)}
            </.kv>
          </dl>
        </.card>
      </div>
    </div>

    <%!-- Applications --%>
    <.card :if={@tab == "applications"} title={"Приложения (#{length(@applications)})"}>
      <div class="overflow-x-auto">
        <table class="table table-sm">
          <thead>
            <tr>
              <th>Приложение</th>
              <th>Версия</th>
              <th>Статус</th>
              <th>Описание</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={app <- @applications} class="hover">
              <td class="font-mono text-xs font-semibold">{app.name}</td>
              <td class="font-mono text-xs">{app.version}</td>
              <td>
                <span class={["badge badge-xs", (app.running && "badge-success") || "badge-ghost"]}>
                  {(app.running && "running") || "loaded"}
                </span>
              </td>
              <td class="text-xs text-base-content/60">{app.description}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </.card>

    <%!-- Supervision --%>
    <div :if={@tab == "supervision"} class="grid gap-6 lg:grid-cols-4">
      <.card title="Приложения" class="lg:col-span-1">
        <ul class="max-h-[70vh] space-y-1 overflow-y-auto">
          <li :for={app <- Enum.filter(@applications, & &1.running)}>
            <button
              class={["btn btn-xs btn-block justify-start", @tree_app == app.name && "btn-primary"]}
              phx-click="tree"
              phx-value-app={app.name}
            >
              {app.name}
            </button>
          </li>
        </ul>
      </.card>

      <.card
        title={"Дерево супервизоров#{(@tree_app && ": " <> @tree_app) || ""}"}
        class="lg:col-span-3"
      >
        <.empty_state
          :if={is_nil(@tree)}
          title="Выберите приложение слева"
          icon="hero-share"
        />

        <div :if={@tree && @tree[:error]} class="alert alert-warning text-sm">
          <span>{@tree[:error]}</span>
        </div>

        <div :if={@tree && !@tree[:error]} class="max-h-[70vh] overflow-auto font-mono text-xs">
          <.tree_node node={@tree} />
        </div>
      </.card>
    </div>

    <%!-- Processes --%>
    <.card :if={@tab == "processes"} title="Топ процессов">
      <:actions>
        <form phx-change="sort">
          <select name="sort" class="select select-xs select-bordered">
            <option value="memory" selected={@sort == "memory"}>по памяти</option>
            <option value="reductions" selected={@sort == "reductions"}>по редукциям</option>
            <option value="message_queue_len" selected={@sort == "message_queue_len"}>
              по очереди сообщений
            </option>
          </select>
        </form>
      </:actions>

      <div class="overflow-x-auto">
        <table class="table table-xs">
          <thead>
            <tr>
              <th>PID</th>
              <th>Имя</th>
              <th>Текущая функция</th>
              <th class="text-right">Память</th>
              <th class="text-right">Очередь</th>
              <th class="text-right">Редукции</th>
              <th>Статус</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={process <- @processes} class="hover">
              <td class="font-mono">{process.pid}</td>
              <td class="font-mono">{process.name || "—"}</td>
              <td class="font-mono text-[11px]">
                {process.current_function || process.initial_call}
              </td>
              <td class="text-right tabular-nums">{bytes(process.memory)}</td>
              <td class={["text-right tabular-nums", process.message_queue_len > 100 && "text-error"]}>
                {process.message_queue_len}
              </td>
              <td class="text-right tabular-nums">{number(process.reductions)}</td>
              <td>{process.status}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </.card>

    <%!-- ETS --%>
    <.card :if={@tab == "ets"} title={"ETS-таблицы (#{length(@ets)})"}>
      <div class="overflow-x-auto">
        <table class="table table-xs">
          <thead>
            <tr>
              <th>Таблица</th>
              <th>Тип</th>
              <th>Доступ</th>
              <th class="text-right">Записей</th>
              <th class="text-right">Память</th>
              <th>Владелец</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={table <- @ets} class="hover">
              <td class="font-mono">{table.name}</td>
              <td>{table.type}</td>
              <td>{table.protection}</td>
              <td class="text-right tabular-nums">{number(table.size)}</td>
              <td class="text-right tabular-nums">{bytes(table.memory)}</td>
              <td class="font-mono text-[11px]">{table.owner}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </.card>

    <%!-- Ports --%>
    <.card :if={@tab == "ports"} title={"Порты (#{length(@ports)})"}>
      <div class="overflow-x-auto">
        <table class="table table-xs">
          <thead>
            <tr>
              <th>Порт</th>
              <th>Имя</th>
              <th>Владелец</th>
              <th class="text-right">Вход</th>
              <th class="text-right">Выход</th>
              <th class="text-right">OS PID</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={port <- @ports} class="hover">
              <td class="font-mono">{port.port}</td>
              <td class="font-mono text-[11px]">{port.name}</td>
              <td class="font-mono text-[11px]">{port.connected}</td>
              <td class="text-right tabular-nums">{bytes(port.input)}</td>
              <td class="text-right tabular-nums">{bytes(port.output)}</td>
              <td class="text-right tabular-nums">{port.os_pid || "—"}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </.card>

    <%!-- Cluster --%>
    <.card :if={@tab == "cluster" and @cluster} title="Распределённый Erlang">
      <dl class="mb-4">
        <.kv label="Эта нода">{@cluster.self}</.kv>
        <.kv label="Distribution">{(@cluster.alive && "включён") || "выключен"}</.kv>
        <.kv label="Скрытые ноды">
          {(@cluster.hidden != [] && Enum.join(@cluster.hidden, ", ")) || "нет"}
        </.kv>
      </dl>

      <.empty_state
        :if={@cluster.peers == []}
        title="Соединённых нод нет"
        icon="hero-share"
      />

      <div :if={@cluster.peers != []} class="overflow-x-auto">
        <table class="table table-sm">
          <thead>
            <tr>
              <th>Нода</th>
              <th>Доступна</th>
              <th>OTP</th>
              <th class="text-right">Процессов</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={peer <- @cluster.peers} class="hover">
              <td class="font-mono text-xs">{peer.node}</td>
              <td>
                <span class={["badge badge-xs", (peer.reachable && "badge-success") || "badge-error"]}>
                  {(peer.reachable && "да") || "нет"}
                </span>
              </td>
              <td>{peer.otp_release || "—"}</td>
              <td class="text-right tabular-nums">{number(peer.process_count)}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </.card>

    <%!-- Console --%>
    <.card :if={@tab == "console"} title="Удалённая консоль (rpc)">
      <div class="alert alert-warning mb-4 text-sm">
        <.icon name="hero-exclamation-triangle" class="size-5" />
        <span>
          Код выполняется прямо в работающем приложении. Доступно только администраторам,
          каждое выполнение попадает в аудит.
        </span>
      </div>

      <form phx-submit="eval" class="space-y-3">
        <textarea
          name="code"
          rows="6"
          class="textarea textarea-bordered w-full font-mono text-xs"
          placeholder="MyApp.Repo.aggregate(MyApp.User, :count)"
        >{@console_code}</textarea>
        <button
          type="submit"
          class="btn btn-sm btn-primary"
          disabled={!Accounts.can?(@current_user, :admin)}
        >
          Выполнить
        </button>
      </form>

      <pre
        :if={@console_result}
        class="mt-4 max-h-96 overflow-auto rounded-box bg-neutral p-4 font-mono text-xs text-neutral-content"
      ><code>{@console_result}</code></pre>
    </.card>
    """
  end

  attr :node, :map, required: true

  defp tree_node(assigns) do
    ~H"""
    <div class="border-l border-base-300 pl-3">
      <div class="flex flex-wrap items-center gap-2 py-0.5">
        <span class="font-semibold">
          {@node[:id] || @node[:application] || "root"}
        </span>
        <span class="text-base-content/50">{@node[:pid]}</span>
        <span :if={@node[:type]} class="badge badge-xs badge-ghost">{@node[:type]}</span>
        <span :if={info(@node)[:registered_name]} class="badge badge-xs badge-outline">
          {info(@node)[:registered_name]}
        </span>
        <span :if={info(@node)[:memory]} class="text-base-content/50">
          {BeamPanelWeb.Format.bytes(info(@node)[:memory])}
        </span>
        <span
          :if={(info(@node)[:message_queue_len] || 0) > 0}
          class={["text-warning", (info(@node)[:message_queue_len] || 0) > 100 && "text-error"]}
        >
          queue {info(@node)[:message_queue_len]}
        </span>
      </div>

      <.tree_node :for={child <- @node[:children] || []} node={child} />
    </div>
    """
  end

  defp info(node), do: node[:info] || %{}

  defp ratio(_value, 0), do: 0.0
  defp ratio(value, limit) when is_number(value) and is_number(limit), do: value / limit * 100
  defp ratio(_value, _limit), do: nil
end
