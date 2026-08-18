defmodule BeamPanelWeb.SettingsLive.Notifications do
  @moduledoc "Notification channels: webhook, Telegram, Slack, Discord and email."

  use BeamPanelWeb, :live_view

  alias BeamPanel.{Notifications, Accounts, Audit}
  alias BeamPanel.Notifications.Channel

  @impl true
  def mount(_params, _session, socket) do
    if Accounts.can?(socket.assigns.current_user, :admin) do
      {:ok,
       socket
       |> assign(
         page_title: "Уведомления",
         form: to_form(Notifications.change_channel(%Channel{kind: "webhook", events: []})),
         editing: nil,
         kind: "webhook"
       )
       |> load()}
    else
      {:ok,
       socket |> put_flash(:error, "Доступ только для администраторов.") |> redirect(to: ~p"/")}
    end
  end

  defp load(socket), do: assign(socket, :channels, Notifications.list_channels())

  @impl true
  def handle_event("validate", %{"channel" => params}, socket) do
    changeset =
      (socket.assigns.editing || %Channel{})
      |> Notifications.change_channel(normalize(params))
      |> Map.put(:action, :validate)

    {:noreply,
     assign(socket, form: to_form(changeset), kind: params["kind"] || socket.assigns.kind)}
  end

  def handle_event("save", %{"channel" => params}, socket) do
    params = normalize(params)

    result =
      case socket.assigns.editing do
        nil -> Notifications.create_channel(params)
        channel -> Notifications.update_channel(channel, params)
      end

    case result do
      {:ok, channel} ->
        Audit.log(socket.assigns.current_user, "notification.save",
          resource_type: "notification_channel",
          resource_id: channel.id,
          metadata: %{name: channel.name, kind: channel.kind}
        )

        {:noreply,
         socket
         |> assign(
           form: to_form(Notifications.change_channel(%Channel{kind: "webhook", events: []})),
           editing: nil,
           kind: "webhook"
         )
         |> put_flash(:info, "Канал сохранён.")
         |> load()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    channel = Notifications.get_channel!(id)

    {:noreply,
     assign(socket,
       editing: channel,
       kind: channel.kind,
       form: to_form(Notifications.change_channel(channel))
     )}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply,
     assign(socket,
       editing: nil,
       kind: "webhook",
       form: to_form(Notifications.change_channel(%Channel{kind: "webhook", events: []}))
     )}
  end

  def handle_event("test", %{"id" => id}, socket) do
    channel = Notifications.get_channel!(id)

    case Notifications.test(channel) do
      :ok -> {:noreply, socket |> put_flash(:info, "Тестовое сообщение отправлено.") |> load()}
      {:error, reason} -> {:noreply, socket |> put_flash(:error, truncate(reason, 200)) |> load()}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    {:ok, _} = id |> Notifications.get_channel!() |> Notifications.delete_channel()
    {:noreply, socket |> put_flash(:info, "Канал удалён.") |> load()}
  end

  defp normalize(params) do
    config =
      params
      |> Map.get("config", %{})
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> Map.new()

    events = params |> Map.get("events", []) |> List.wrap() |> Enum.reject(&(&1 == ""))

    params
    |> Map.put("config", config)
    |> Map.put("events", events)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header
      title="Уведомления"
      subtitle="Куда сообщать о деплоях и авариях"
    >
      <:actions>
        <.link navigate={~p"/settings"} class="btn btn-sm">Профиль</.link>
      </:actions>
    </.page_header>

    <div class="grid gap-6 lg:grid-cols-3">
      <div class="lg:col-span-2">
        <.card title={"Каналы (#{length(@channels)})"}>
          <.empty_state
            :if={@channels == []}
            title="Каналов нет"
            description="Добавьте webhook или Telegram, чтобы получать оповещения о деплоях и недоступных серверах."
            icon="hero-bell"
          />

          <ul :if={@channels != []} class="divide-y divide-base-300">
            <li :for={channel <- @channels} class="py-3">
              <div class="flex items-start justify-between gap-3">
                <div class="min-w-0">
                  <p class="font-medium">
                    {channel.name}
                    <span class="badge badge-xs badge-outline ml-1">{channel.kind}</span>
                    <span :if={!channel.enabled} class="badge badge-xs badge-ghost ml-1">выключен</span>
                  </p>
                  <p class="mt-1 text-xs text-base-content/50">
                    {(channel.events == [] && "все события") || Enum.join(channel.events, ", ")}
                  </p>
                  <p :if={channel.last_error} class="mt-1 text-xs text-error">{channel.last_error}</p>
                  <p :if={channel.last_sent_at} class="mt-1 text-xs text-base-content/50">
                    последняя отправка: {relative(channel.last_sent_at)}
                  </p>
                </div>
                <div class="flex shrink-0 gap-1">
                  <button class="btn btn-xs" phx-click="test" phx-value-id={channel.id}>Тест</button>
                  <button class="btn btn-xs btn-ghost" phx-click="edit" phx-value-id={channel.id}>
                    Изменить
                  </button>
                  <.danger_button
                    class="btn btn-ghost btn-xs text-error"
                    confirm={"Удалить канал #{channel.name}?"}
                    phx-click="delete"
                    phx-value-id={channel.id}
                  >
                    Удалить
                  </.danger_button>
                </div>
              </div>
            </li>
          </ul>
        </.card>
      </div>

      <div>
        <.card title={(@editing && "Изменить канал") || "Новый канал"}>
          <.form for={@form} phx-change="validate" phx-submit="save" class="space-y-3">
            <.input field={@form[:name]} label="Название" required />
            <.input
              field={@form[:kind]}
              type="select"
              label="Тип"
              options={[
                {"Webhook", "webhook"},
                {"Telegram", "telegram"},
                {"Slack", "slack"},
                {"Discord", "discord"},
                {"E-mail", "email"}
              ]}
            />

            <div :if={@kind in ["webhook", "slack", "discord"]}>
              <label class="form-control">
                <span class="label-text text-xs">URL</span>
                <input
                  type="text"
                  name="channel[config][url]"
                  value={config(@editing, "url")}
                  class="input input-sm input-bordered"
                  placeholder="https://hooks.example.com/..."
                />
              </label>
            </div>

            <div :if={@kind == "webhook"}>
              <label class="form-control">
                <span class="label-text text-xs">Секрет (заголовок x-beam-panel-secret)</span>
                <input
                  type="text"
                  name="channel[config][secret]"
                  value={config(@editing, "secret")}
                  class="input input-sm input-bordered"
                />
              </label>
            </div>

            <div :if={@kind == "telegram"} class="space-y-3">
              <label class="form-control">
                <span class="label-text text-xs">Bot token</span>
                <input
                  type="text"
                  name="channel[config][bot_token]"
                  value={config(@editing, "bot_token")}
                  class="input input-sm input-bordered"
                />
              </label>
              <label class="form-control">
                <span class="label-text text-xs">Chat ID</span>
                <input
                  type="text"
                  name="channel[config][chat_id]"
                  value={config(@editing, "chat_id")}
                  class="input input-sm input-bordered"
                />
              </label>
            </div>

            <div :if={@kind == "email"} class="space-y-3">
              <label class="form-control">
                <span class="label-text text-xs">Кому</span>
                <input
                  type="email"
                  name="channel[config][to]"
                  value={config(@editing, "to")}
                  class="input input-sm input-bordered"
                />
              </label>
              <label class="form-control">
                <span class="label-text text-xs">От кого</span>
                <input
                  type="email"
                  name="channel[config][from]"
                  value={config(@editing, "from")}
                  class="input input-sm input-bordered"
                />
              </label>
            </div>

            <fieldset class="fieldset">
              <legend class="fieldset-legend text-xs">События (пусто — все)</legend>
              <label :for={event <- Channel.events()} class="label cursor-pointer justify-start gap-2">
                <input
                  type="checkbox"
                  name="channel[events][]"
                  value={event}
                  checked={@editing && event in @editing.events}
                  class="checkbox checkbox-xs"
                />
                <span class="label-text text-xs">{event_label(event)}</span>
              </label>
            </fieldset>

            <.input field={@form[:enabled]} type="checkbox" label="Включён" />

            <div class="flex gap-2">
              <button type="submit" class="btn btn-primary btn-sm flex-1">Сохранить</button>
              <button :if={@editing} type="button" class="btn btn-ghost btn-sm" phx-click="cancel">
                Отмена
              </button>
            </div>
          </.form>
        </.card>
      </div>
    </div>
    """
  end

  defp config(nil, _key), do: ""
  defp config(%Channel{config: nil}, _key), do: ""
  defp config(%Channel{config: config}, key), do: Map.get(config, key, "")

  defp event_label("deploy_success"), do: "успешный деплой"
  defp event_label("deploy_failed"), do: "неудачный деплой"
  defp event_label("server_unreachable"), do: "сервер недоступен"
  defp event_label("server_online"), do: "сервер снова онлайн"
  defp event_label("project_down"), do: "проект упал"
  defp event_label("provision_finished"), do: "провижининг завершён"
  defp event_label(other), do: other
end
