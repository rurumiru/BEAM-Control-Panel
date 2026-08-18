defmodule BeamPanelWeb.ServerLive.Index do
  @moduledoc "Server inventory with inline create/edit."

  use BeamPanelWeb, :live_view

  alias BeamPanel.{Servers, Monitor, Audit, Accounts}
  alias BeamPanel.Servers.Server

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(BeamPanel.PubSub, Servers.topic())
      :timer.send_interval(5_000, self(), :tick)
    end

    {:ok, socket |> assign(page_title: "Серверы", checking: nil) |> load()}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    server = %Server{connection: "ssh", auth_method: "key", ssh_port: 22, ssh_user: "root"}

    socket
    |> assign(:server, server)
    |> assign(:form, to_form(Servers.change_server(server)))
    |> assign(:modal_title, "Новый сервер")
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    server = Servers.get_server!(id)

    socket
    |> assign(:server, server)
    |> assign(:form, to_form(Servers.change_server(server)))
    |> assign(:modal_title, "Редактирование: #{server.name}")
  end

  defp apply_action(socket, _action, _params), do: assign(socket, server: nil, form: nil)

  defp load(socket) do
    servers = Servers.list_servers_with_counts()

    assign(socket,
      servers: servers,
      groups: Servers.list_groups(),
      metrics: Monitor.latest_all(Enum.map(servers, & &1.id))
    )
  end

  ## ------------------------------------------------------------------- events

  @impl true
  def handle_event("validate", %{"server" => params}, socket) do
    changeset =
      socket.assigns.server
      |> Servers.change_server(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"server" => params}, socket) do
    if Accounts.can?(socket.assigns.current_user, :operator) do
      save_server(socket, socket.assigns.live_action, params)
    else
      {:noreply, put_flash(socket, :error, "Недостаточно прав.")}
    end
  end

  def handle_event("check", %{"id" => id}, socket) do
    server = Servers.get_server!(id)
    socket = assign(socket, :checking, server.id)

    Task.Supervisor.start_child(BeamPanel.TaskSupervisor, fn ->
      Servers.check_connection(server)
    end)

    {:noreply, put_flash(socket, :info, "Проверяем связь с #{server.name}…")}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    server = Servers.get_server!(id)

    cond do
      not Accounts.can?(socket.assigns.current_user, :admin) ->
        {:noreply, put_flash(socket, :error, "Удалять серверы может только администратор.")}

      server.connection == "local" ->
        {:noreply, put_flash(socket, :error, "Основной сервер удалить нельзя.")}

      true ->
        {:ok, _} = Servers.delete_server(server)

        Audit.log(socket.assigns.current_user, "server.delete",
          resource_type: "server",
          resource_id: server.id,
          metadata: %{name: server.name}
        )

        {:noreply, socket |> put_flash(:info, "Сервер удалён.") |> load()}
    end
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/servers")}
  end

  @impl true
  def handle_info(:tick, socket), do: {:noreply, load(socket)}

  def handle_info({:server_status, _server}, socket),
    do: {:noreply, socket |> assign(:checking, nil) |> load()}

  def handle_info({:metrics, server_id, metrics}, socket),
    do: {:noreply, assign(socket, :metrics, Map.put(socket.assigns.metrics, server_id, metrics))}

  def handle_info(_message, socket), do: {:noreply, load(socket)}

  defp save_server(socket, :new, params) do
    case Servers.create_server(params) do
      {:ok, server} ->
        Audit.log(socket.assigns.current_user, "server.create",
          resource_type: "server",
          resource_id: server.id,
          metadata: %{name: server.name, hostname: server.hostname}
        )

        Task.Supervisor.start_child(BeamPanel.TaskSupervisor, fn ->
          Servers.check_connection(server)
        end)

        {:noreply,
         socket
         |> put_flash(:info, "Сервер добавлен. Проверяем подключение…")
         |> load()
         |> push_patch(to: ~p"/servers")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp save_server(socket, :edit, params) do
    case Servers.update_server(socket.assigns.server, params) do
      {:ok, server} ->
        Audit.log(socket.assigns.current_user, "server.update",
          resource_type: "server",
          resource_id: server.id
        )

        {:noreply,
         socket
         |> put_flash(:info, "Изменения сохранены.")
         |> load()
         |> push_patch(to: ~p"/servers")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  ## ------------------------------------------------------------------ render

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header
      title="Серверы"
      subtitle="Основной сервер и дополнительные узлы"
    >
      <:actions>
        <.link patch={~p"/servers/new"} class="btn btn-sm btn-primary">
          <.icon name="hero-plus" class="size-4" /> Добавить сервер
        </.link>
      </:actions>
    </.page_header>

    <.empty_state
      :if={@servers == []}
      title="Серверов пока нет"
      description="Добавьте первый сервер — панель подключится по SSH и начнёт собирать метрики."
      icon="hero-server-stack"
    >
      <:actions>
        <.link patch={~p"/servers/new"} class="btn btn-sm btn-primary">Добавить сервер</.link>
      </:actions>
    </.empty_state>

    <div class="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
      <div
        :for={server <- @servers}
        class="rounded-box border border-base-300 bg-base-100 p-4 transition hover:border-primary/40"
      >
        <div class="flex items-start justify-between gap-2">
          <div class="min-w-0">
            <.link navigate={~p"/servers/#{server}"} class="link link-hover font-semibold">
              {server.name}
            </.link>
            <div class="truncate text-xs text-base-content/50">
              {server.ssh_user}@{server.hostname}:{server.ssh_port}
            </div>
          </div>
          <.status_badge status={server.status} />
        </div>

        <div class="mt-2 flex flex-wrap gap-1">
          <span :if={server.connection == "local"} class="badge badge-xs badge-primary badge-outline">
            основной
          </span>
          <span class="badge badge-xs badge-ghost">{server.role}</span>
          <span :for={tag <- server.tags} class="badge badge-xs badge-ghost">{tag}</span>
          <span :if={server.group} class="badge badge-xs badge-outline">{server.group.name}</span>
        </div>

        <div class="mt-3 grid grid-cols-3 gap-2 text-center">
          <div>
            <div class={["text-lg font-semibold tabular-nums", gauge_tone(@metrics, server.id, :cpu)]}>
              {gauge(@metrics, server.id, :cpu)}
            </div>
            <div class="text-[10px] uppercase text-base-content/50">CPU</div>
          </div>
          <div>
            <div class={["text-lg font-semibold tabular-nums", gauge_tone(@metrics, server.id, :mem)]}>
              {gauge(@metrics, server.id, :mem)}
            </div>
            <div class="text-[10px] uppercase text-base-content/50">RAM</div>
          </div>
          <div>
            <div class={["text-lg font-semibold tabular-nums", gauge_tone(@metrics, server.id, :disk)]}>
              {gauge(@metrics, server.id, :disk)}
            </div>
            <div class="text-[10px] uppercase text-base-content/50">Диск</div>
          </div>
        </div>

        <div class="mt-3 text-xs text-base-content/50">
          {facts_line(server)}
        </div>

        <div class="mt-3 flex flex-wrap gap-1">
          <.link navigate={~p"/servers/#{server}"} class="btn btn-xs">Обзор</.link>
          <.link navigate={~p"/servers/#{server}/provision"} class="btn btn-xs btn-ghost">
            Установка
          </.link>
          <.link navigate={~p"/servers/#{server}/discover"} class="btn btn-xs btn-ghost">Поиск</.link>
          <button class="btn btn-xs btn-ghost" phx-click="check" phx-value-id={server.id}>
            <.icon
              name="hero-arrow-path"
              class={["size-3", @checking == server.id && "animate-spin"]}
            /> Связь
          </button>
          <.link patch={~p"/servers/#{server}/edit"} class="btn btn-xs btn-ghost">Изменить</.link>
          <.danger_button
            :if={server.connection != "local"}
            class="btn btn-xs btn-ghost text-error"
            confirm={"Удалить сервер #{server.name}? Все проекты на нём тоже будут удалены из панели."}
            phx-click="delete"
            phx-value-id={server.id}
          >
            Удалить
          </.danger_button>
        </div>
      </div>
    </div>

    <.modal
      :if={@live_action in [:new, :edit]}
      id="server-modal"
      show
      title={@modal_title}
      on_cancel={JS.push("close_modal")}
    >
      <.form for={@form} phx-change="validate" phx-submit="save" class="space-y-4">
        <div class="grid gap-4 sm:grid-cols-2">
          <.input field={@form[:name]} label="Название" required />
          <.input field={@form[:hostname]} label="Хост или IP" required />
        </div>

        <div class="grid gap-4 sm:grid-cols-3">
          <.input
            field={@form[:connection]}
            type="select"
            label="Подключение"
            options={[{"SSH", "ssh"}, {"Локально (основной)", "local"}]}
          />
          <.input field={@form[:ssh_user]} label="Пользователь" />
          <.input field={@form[:ssh_port]} type="number" label="Порт SSH" />
        </div>

        <div class="grid gap-4 sm:grid-cols-2">
          <.input
            field={@form[:auth_method]}
            type="select"
            label="Аутентификация"
            options={[{"Приватный ключ", "key"}, {"Пароль", "password"}, {"SSH-агент", "agent"}]}
          />
          <.input
            field={@form[:role]}
            type="select"
            label="Роль"
            options={[
              {"Основной", "primary"},
              {"Дополнительный", "secondary"},
              {"Сборочный", "build"},
              {"База данных", "database"}
            ]}
          />
        </div>

        <.input
          :if={@form[:auth_method].value in ["key", nil]}
          field={@form[:ssh_private_key]}
          type="textarea"
          label="Приватный SSH-ключ"
          rows="6"
          placeholder="-----BEGIN OPENSSH PRIVATE KEY-----"
        />
        <.input
          :if={@form[:auth_method].value in ["key", nil]}
          field={@form[:ssh_passphrase]}
          type="password"
          label="Пароль ключа (если есть)"
          value=""
        />
        <.input
          :if={@form[:auth_method].value == "password"}
          field={@form[:ssh_password]}
          type="password"
          label="Пароль SSH"
          value=""
        />
        <.input
          field={@form[:sudo_password]}
          type="password"
          label="Пароль sudo (если пользователь не root)"
          value=""
        />

        <div class="grid gap-4 sm:grid-cols-2">
          <.input field={@form[:deploy_user]} label="Пользователь деплоя" />
          <.input field={@form[:deploy_root]} label="Каталог деплоя" />
        </div>

        <div class="grid gap-4 sm:grid-cols-3">
          <.input
            field={@form[:group_id]}
            type="select"
            label="Группа / кластер"
            prompt="— без группы —"
            options={Enum.map(@groups, &{&1.name, &1.id})}
          />
          <.input
            field={@form[:monitor_interval]}
            type="number"
            label="Интервал опроса, с"
          />
          <.input
            field={@form[:monitor_enabled]}
            type="checkbox"
            label="Мониторинг включён"
          />
        </div>

        <.input field={@form[:tags_input]} label="Теги" placeholder="prod, eu-central, web" />
        <.input field={@form[:description]} label="Описание" />

        <div class="flex justify-end gap-2 pt-2">
          <button type="button" class="btn btn-ghost btn-sm" phx-click="close_modal">Отмена</button>
          <button
            type="submit"
            class="btn btn-primary btn-sm"
            phx-disable-with="Сохраняем…"
          >
            Сохранить
          </button>
        </div>
      </.form>
    </.modal>
    """
  end

  defp gauge(metrics, server_id, key) do
    case Map.get(metrics, server_id) do
      nil -> "—"
      m -> percent(value_for(m, key))
    end
  end

  defp gauge_tone(metrics, server_id, key) do
    case Map.get(metrics, server_id) do
      nil -> "text-base-content/40"
      m -> gauge_class(value_for(m, key))
    end
  end

  defp value_for(m, :cpu), do: m.cpu_percent
  defp value_for(m, :mem), do: m.memory.percent
  defp value_for(m, :disk), do: m.disk.percent

  defp facts_line(server) do
    case server.facts do
      facts when map_size(facts) > 0 ->
        [
          facts["os_pretty"],
          facts["erlang"] && "OTP #{facts["erlang"]}",
          facts["elixir"] && "Elixir #{facts["elixir"]}"
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" · ")

      _ ->
        "нет данных об окружении"
    end
  end
end
