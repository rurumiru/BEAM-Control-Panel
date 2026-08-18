defmodule BeamPanelWeb.SettingsLive.Users do
  @moduledoc "User management — administrators only."

  use BeamPanelWeb, :live_view

  alias BeamPanel.{Accounts, Audit}
  alias BeamPanel.Accounts.User

  @impl true
  def mount(_params, _session, socket) do
    if Accounts.can?(socket.assigns.current_user, :admin) do
      {:ok,
       socket
       |> assign(
         page_title: "Пользователи",
         form: to_form(Accounts.change_user_registration(%User{role: "viewer"})),
         editing: nil
       )
       |> load()}
    else
      {:ok,
       socket |> put_flash(:error, "Доступ только для администраторов.") |> redirect(to: ~p"/")}
    end
  end

  defp load(socket), do: assign(socket, :users, Accounts.list_users())

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    changeset =
      %User{}
      |> Accounts.change_user_registration(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("create", %{"user" => params}, socket) do
    case Accounts.register_user(params) do
      {:ok, user} ->
        Audit.log(socket.assigns.current_user, "user.create",
          resource_type: "user",
          resource_id: user.id,
          metadata: %{email: user.email, role: user.role}
        )

        {:noreply,
         socket
         |> assign(:form, to_form(Accounts.change_user_registration(%User{role: "viewer"})))
         |> put_flash(:info, "Пользователь создан.")
         |> load()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("set_role", %{"user_id" => id, "role" => role}, socket) do
    user = Accounts.get_user!(id)

    if user.id == socket.assigns.current_user.id do
      {:noreply, put_flash(socket, :error, "Нельзя изменить собственную роль.")}
    else
      {:ok, user} = Accounts.update_user(user, %{"role" => role})

      Audit.log(socket.assigns.current_user, "user.role_changed",
        resource_type: "user",
        resource_id: user.id,
        metadata: %{role: role}
      )

      {:noreply, socket |> put_flash(:info, "Роль обновлена.") |> load()}
    end
  end

  def handle_event("toggle_active", %{"id" => id}, socket) do
    user = Accounts.get_user!(id)

    if user.id == socket.assigns.current_user.id do
      {:noreply, put_flash(socket, :error, "Нельзя отключить собственную учётную запись.")}
    else
      {:ok, user} = Accounts.update_user(user, %{"active" => !user.active})
      if not user.active, do: Accounts.delete_all_sessions(user)

      Audit.log(socket.assigns.current_user, "user.toggle_active",
        resource_type: "user",
        resource_id: user.id,
        metadata: %{active: user.active}
      )

      {:noreply, load(socket)}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    user = Accounts.get_user!(id)

    cond do
      user.id == socket.assigns.current_user.id ->
        {:noreply, put_flash(socket, :error, "Нельзя удалить самого себя.")}

      Enum.count(socket.assigns.users, &(&1.role == "admin")) <= 1 and user.role == "admin" ->
        {:noreply, put_flash(socket, :error, "Должен остаться хотя бы один администратор.")}

      true ->
        {:ok, _} = Accounts.delete_user(user)

        Audit.log(socket.assigns.current_user, "user.delete",
          resource_type: "user",
          resource_id: user.id,
          metadata: %{email: user.email}
        )

        {:noreply, socket |> put_flash(:info, "Пользователь удалён.") |> load()}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header title="Пользователи" subtitle="Доступ к панели и роли">
      <:actions>
        <.link navigate={~p"/settings"} class="btn btn-sm">Профиль</.link>
      </:actions>
    </.page_header>

    <div class="grid gap-6 lg:grid-cols-3">
      <div class="lg:col-span-2">
        <.card title={"Пользователи (#{length(@users)})"}>
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>E-mail</th>
                  
                  <th>Имя</th>
                  
                  <th>Роль</th>
                  
                  <th>2FA</th>
                  
                  <th>Последний вход</th>
                  
                  <th></th>
                </tr>
              </thead>
              
              <tbody>
                <tr :for={user <- @users} class={["hover", !user.active && "opacity-50"]}>
                  <td class="font-medium">
                    {user.email}
                    <span :if={user.id == @current_user.id} class="badge badge-xs badge-primary ml-1">
                      вы
                    </span>
                  </td>
                  
                  <td class="text-xs">{user.name || "—"}</td>
                  
                  <td>
                    <form phx-change="set_role">
                      <input type="hidden" name="user_id" value={user.id} />
                      <select
                        name="role"
                        class="select select-xs select-bordered"
                        disabled={user.id == @current_user.id}
                      >
                        <option :for={role <- User.roles()} value={role} selected={user.role == role}>
                          {role}
                        </option>
                      </select>
                    </form>
                  </td>
                  
                  <td>
                    <span class={[
                      "badge badge-xs",
                      (user.totp_enabled && "badge-success") || "badge-ghost"
                    ]}>
                      {(user.totp_enabled && "вкл") || "выкл"}
                    </span>
                  </td>
                  
                  <td class="text-xs">{relative(user.last_login_at)}</td>
                  
                  <td class="text-right">
                    <button
                      class="btn btn-ghost btn-xs"
                      phx-click="toggle_active"
                      phx-value-id={user.id}
                      disabled={user.id == @current_user.id}
                    >
                      {(user.active && "Отключить") || "Включить"}
                    </button>
                    
                    <.danger_button
                      class="btn btn-ghost btn-xs text-error"
                      confirm={"Удалить пользователя #{user.email}?"}
                      phx-click="delete"
                      phx-value-id={user.id}
                    >
                      Удалить
                    </.danger_button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </.card>
      </div>
      
      <div>
        <.card title="Новый пользователь">
          <.form for={@form} phx-change="validate" phx-submit="create" class="space-y-3">
            <.input field={@form[:email]} type="email" label="E-mail" required />
            <.input field={@form[:name]} label="Имя" />
            <.input
              field={@form[:role]}
              type="select"
              label="Роль"
              options={[
                {"viewer — только просмотр", "viewer"},
                {"operator — деплой и управление", "operator"},
                {"admin — полный доступ", "admin"}
              ]}
            />
            <.input
              field={@form[:password]}
              type="password"
              label="Пароль"
              required
              autocomplete="new-password"
            /> <button type="submit" class="btn btn-primary btn-sm btn-block">Создать</button>
          </.form>
        </.card>
      </div>
    </div>
    """
  end
end
