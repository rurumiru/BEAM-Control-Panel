defmodule BeamPanelWeb.SettingsLive.Profile do
  @moduledoc "Own profile: password change and TOTP two-factor authentication."

  use BeamPanelWeb, :live_view

  alias BeamPanel.{Accounts, Audit}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    {:ok,
     socket
     |> assign(
       page_title: "Профиль",
       user: user,
       password_form: to_form(Accounts.change_user_password(user), as: :password),
       totp_secret: nil,
       totp_uri: nil,
       totp_error: nil
     )}
  end

  ## ------------------------------------------------------------------ events

  @impl true
  def handle_event("change_password", %{"password" => params}, socket) do
    case Accounts.update_user_password(socket.assigns.user, params) do
      {:ok, user} ->
        Audit.log(user, "user.password_changed", resource_type: "user", resource_id: user.id)

        {:noreply,
         socket
         |> put_flash(:info, "Пароль изменён. Остальные сессии завершены — войдите заново.")
         |> redirect(to: ~p"/logout")}

      {:error, changeset} ->
        {:noreply, assign(socket, :password_form, to_form(changeset, as: :password))}
    end
  end

  def handle_event("start_totp", _params, socket) do
    secret = Accounts.generate_totp_secret()

    {:noreply,
     assign(socket,
       totp_secret: secret,
       totp_uri: Accounts.totp_uri(socket.assigns.user, secret),
       totp_error: nil
     )}
  end

  def handle_event("cancel_totp", _params, socket),
    do: {:noreply, assign(socket, totp_secret: nil, totp_uri: nil, totp_error: nil)}

  def handle_event("confirm_totp", %{"code" => code}, socket) do
    case Accounts.enable_totp(socket.assigns.user, socket.assigns.totp_secret, code) do
      {:ok, user} ->
        Audit.log(user, "user.totp_enabled", resource_type: "user", resource_id: user.id)

        {:noreply,
         socket
         |> assign(user: user, totp_secret: nil, totp_uri: nil, totp_error: nil)
         |> put_flash(:info, "Двухфакторная аутентификация включена.")}

      {:error, :invalid_code} ->
        {:noreply, assign(socket, :totp_error, "Неверный код. Проверьте время на устройстве.")}

      {:error, _changeset} ->
        {:noreply, assign(socket, :totp_error, "Не удалось сохранить настройки.")}
    end
  end

  def handle_event("disable_totp", _params, socket) do
    {:ok, user} = Accounts.disable_totp(socket.assigns.user)
    Audit.log(user, "user.totp_disabled", resource_type: "user", resource_id: user.id)

    {:noreply,
     socket |> assign(:user, user) |> put_flash(:info, "Двухфакторная аутентификация отключена.")}
  end

  def handle_event("logout_everywhere", _params, socket) do
    Accounts.delete_all_sessions(socket.assigns.user)
    {:noreply, redirect(socket, to: ~p"/logout")}
  end

  ## ------------------------------------------------------------------ render

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header title="Профиль" subtitle={@user.email}>
      <:actions>
        <.link navigate={~p"/settings/tokens"} class="btn btn-sm">API-токены</.link>
        <.link :if={@user.role == "admin"} navigate={~p"/settings/users"} class="btn btn-sm">
          Пользователи
        </.link>
        <.link :if={@user.role == "admin"} navigate={~p"/settings/notifications"} class="btn btn-sm">
          Уведомления
        </.link>
      </:actions>
    </.page_header>

    <div class="grid gap-6 lg:grid-cols-2">
      <.card title="Учётная запись">
        <dl>
          <.kv label="E-mail">{@user.email}</.kv>
          <.kv label="Имя">{@user.name || "—"}</.kv>
          <.kv label="Роль">{@user.role}</.kv>
          <.kv label="Последний вход">{datetime(@user.last_login_at)}</.kv>
          <.kv label="IP последнего входа">{@user.last_login_ip || "—"}</.kv>
          <.kv label="2FA">{(@user.totp_enabled && "включена") || "выключена"}</.kv>
        </dl>

        <button class="btn btn-sm btn-outline mt-4" phx-click="logout_everywhere">
          Завершить все сессии
        </button>
      </.card>

      <.card title="Смена пароля">
        <.form for={@password_form} phx-submit="change_password" class="space-y-3">
          <.input
            field={@password_form[:password]}
            type="password"
            label="Новый пароль"
            required
            autocomplete="new-password"
          />
          <.input
            field={@password_form[:password_confirmation]}
            type="password"
            label="Повторите пароль"
            required
            autocomplete="new-password"
          />
          <button type="submit" class="btn btn-primary btn-sm">Изменить пароль</button>
        </.form>
      </.card>

      <.card title="Двухфакторная аутентификация" class="lg:col-span-2">
        <div
          :if={@user.totp_enabled and is_nil(@totp_secret)}
          class="flex items-center justify-between gap-4"
        >
          <p class="text-sm">
            2FA включена. При входе потребуется код из приложения-аутентификатора.
          </p>
          <.danger_button
            confirm="Отключить двухфакторную аутентификацию?"
            phx-click="disable_totp"
          >
            Отключить
          </.danger_button>
        </div>

        <div :if={not @user.totp_enabled and is_nil(@totp_secret)}>
          <p class="mb-3 text-sm text-base-content/70">
            Защитите вход одноразовыми кодами (TOTP): Google Authenticator, Aegis, 1Password и др.
          </p>
          <button class="btn btn-primary btn-sm" phx-click="start_totp">Настроить 2FA</button>
        </div>

        <div :if={@totp_secret} class="space-y-3">
          <p class="text-sm">
            Добавьте в приложение-аутентификатор вручную либо по ссылке ниже, затем подтвердите кодом.
          </p>

          <div>
            <p class="text-xs uppercase text-base-content/60">Секрет (Base32)</p>
            <code class="block break-all rounded-box bg-base-200 p-2 font-mono text-sm">
              {Base.encode32(@totp_secret, padding: false)}
            </code>
          </div>

          <div>
            <p class="text-xs uppercase text-base-content/60">otpauth URI</p>
            <code class="block break-all rounded-box bg-base-200 p-2 font-mono text-xs">
              {@totp_uri}
            </code>
          </div>

          <p :if={@totp_error} class="text-sm text-error">{@totp_error}</p>

          <form phx-submit="confirm_totp" class="flex items-end gap-2">
            <label class="form-control">
              <span class="label-text text-xs">Код из приложения</span>
              <input
                type="text"
                name="code"
                inputmode="numeric"
                placeholder="123456"
                class="input input-sm input-bordered w-40 font-mono"
              />
            </label>
            <button type="submit" class="btn btn-primary btn-sm">Подтвердить</button>
            <button type="button" class="btn btn-ghost btn-sm" phx-click="cancel_totp">Отмена</button>
          </form>
        </div>
      </.card>
    </div>
    """
  end
end
