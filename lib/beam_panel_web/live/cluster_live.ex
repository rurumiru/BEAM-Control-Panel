defmodule BeamPanelWeb.ClusterLive do
  @moduledoc "Server groups viewed as BEAM clusters."

  use BeamPanelWeb, :live_view

  alias BeamPanel.{Servers, Projects, Monitor, Accounts}
  alias BeamPanel.Servers.ServerGroup

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(10_000, self(), :tick)

    {:ok,
     socket
     |> assign(
       page_title: "Кластер",
       form: to_form(Servers.change_group(%ServerGroup{})),
       editing: nil
     )
     |> load()}
  end

  defp load(socket) do
    groups = Servers.list_groups()
    servers = Servers.list_servers()

    assign(socket,
      groups: groups,
      servers: servers,
      ungrouped: Enum.filter(servers, &is_nil(&1.group_id)),
      projects: Projects.list_projects(),
      metrics: Monitor.latest_all(Enum.map(servers, & &1.id))
    )
  end

  @impl true
  def handle_event("save_group", %{"server_group" => params}, socket) do
    if Accounts.can?(socket.assigns.current_user, :operator) do
      result =
        case socket.assigns.editing do
          nil -> Servers.create_group(params)
          group -> Servers.update_group(group, params)
        end

      case result do
        {:ok, _group} ->
          {:noreply,
           socket
           |> assign(form: to_form(Servers.change_group(%ServerGroup{})), editing: nil)
           |> put_flash(:info, "Группа сохранена.")
           |> load()}

        {:error, changeset} ->
          {:noreply, assign(socket, :form, to_form(changeset))}
      end
    else
      {:noreply, put_flash(socket, :error, "Недостаточно прав.")}
    end
  end

  def handle_event("edit_group", %{"id" => id}, socket) do
    group = Servers.get_group!(id)
    {:noreply, assign(socket, editing: group, form: to_form(Servers.change_group(group)))}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, editing: nil, form: to_form(Servers.change_group(%ServerGroup{})))}
  end

  def handle_event("delete_group", %{"id" => id}, socket) do
    if Accounts.can?(socket.assigns.current_user, :admin) do
      {:ok, _} = id |> Servers.get_group!() |> Servers.delete_group()
      {:noreply, socket |> put_flash(:info, "Группа удалена.") |> load()}
    else
      {:noreply, put_flash(socket, :error, "Недостаточно прав.")}
    end
  end

  @impl true
  def handle_info(:tick, socket), do: {:noreply, load(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header
      title="Кластер"
      subtitle="Группы серверов и распределение проектов"
    />

    <div class="grid gap-6 lg:grid-cols-3">
      <div class="space-y-6 lg:col-span-2">
        <.empty_state
          :if={@groups == []}
          title="Групп пока нет"
          description="Объедините серверы в группу, чтобы видеть их как единый кластер."
          icon="hero-share"
        />

        <.card :for={group <- @groups} title={group.name}>
          <:actions>
            <button class="btn btn-xs" phx-click="edit_group" phx-value-id={group.id}>Изменить</button>
            <.danger_button
              class="btn btn-ghost btn-xs text-error"
              confirm={"Удалить группу #{group.name}? Серверы останутся."}
              phx-click="delete_group"
              phx-value-id={group.id}
            >
              Удалить
            </.danger_button>
          </:actions>

          <p :if={group.description} class="mb-3 text-sm text-base-content/60">{group.description}</p>

          <.empty_state
            :if={group.servers == []}
            title="В группе нет серверов"
            icon="hero-server-stack"
          />

          <div :if={group.servers != []} class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Сервер</th>
                  <th>Статус</th>
                  <th class="text-right">CPU</th>
                  <th class="text-right">RAM</th>
                  <th class="text-right">Проекты</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={server <- group.servers} class="hover">
                  <td>
                    <.link navigate={~p"/servers/#{server}"} class="link link-hover">{server.name}</.link>
                  </td>
                  <td><.status_badge status={server.status} /></td>
                  <td class="text-right tabular-nums">{gauge(@metrics, server.id, :cpu)}</td>
                  <td class="text-right tabular-nums">{gauge(@metrics, server.id, :mem)}</td>
                  <td class="text-right tabular-nums">{count_projects(@projects, server.id)}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </.card>

        <.card :if={@ungrouped != []} title="Без группы">
          <ul class="divide-y divide-base-300">
            <li :for={server <- @ungrouped} class="flex items-center justify-between py-2">
              <.link navigate={~p"/servers/#{server}"} class="link link-hover text-sm">
                {server.name}
              </.link>
              <.status_badge status={server.status} />
            </li>
          </ul>
        </.card>
      </div>

      <div>
        <.card title={(@editing && "Изменить группу") || "Новая группа"}>
          <.form for={@form} phx-submit="save_group" class="space-y-3">
            <.input field={@form[:name]} label="Название" required />
            <.input field={@form[:description]} label="Описание" />
            <.input
              field={@form[:cluster_cookie]}
              type="password"
              label="Общий Erlang cookie"
              value=""
            />
            <div class="flex gap-2">
              <button type="submit" class="btn btn-primary btn-sm flex-1">Сохранить</button>
              <button
                :if={@editing}
                type="button"
                class="btn btn-ghost btn-sm"
                phx-click="cancel_edit"
              >
                Отмена
              </button>
            </div>
          </.form>
        </.card>

        <.card title="Как это работает" class="mt-6">
          <p class="text-sm text-base-content/70">
            Группа объединяет серверы в логический кластер. Общий cookie позволяет
            нодам приложений видеть друг друга через distributed Erlang — задайте его
            здесь и укажите в переменной <code>RELEASE_COOKIE</code> проектов.
          </p>
          <p class="mt-2 text-sm text-base-content/70">
            Живое состояние distribution конкретного приложения смотрите на вкладке
            <strong>OTP → Кластер</strong>
            внутри проекта.
          </p>
        </.card>
      </div>
    </div>
    """
  end

  defp gauge(metrics, server_id, key) do
    case Map.get(metrics, server_id) do
      nil -> "—"
      m -> percent(if key == :cpu, do: m.cpu_percent, else: m.memory.percent)
    end
  end

  defp count_projects(projects, server_id),
    do: Enum.count(projects, &(&1.server_id == server_id))
end
