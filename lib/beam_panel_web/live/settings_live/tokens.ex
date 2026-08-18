defmodule BeamPanelWeb.SettingsLive.Tokens do
  @moduledoc "Personal API tokens for the REST API."

  use BeamPanelWeb, :live_view

  alias BeamPanel.{Accounts, Audit}
  alias BeamPanel.Accounts.ApiToken

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "API-токены",
       form: to_form(Accounts.change_api_token(%ApiToken{})),
       created: nil
     )
     |> load()}
  end

  defp load(socket),
    do: assign(socket, :tokens, Accounts.list_api_tokens(socket.assigns.current_user))

  @impl true
  def handle_event("create", %{"api_token" => params}, socket) do
    scopes = params |> Map.get("scopes", []) |> List.wrap() |> Enum.reject(&(&1 == ""))
    params = Map.put(params, "scopes", if(scopes == [], do: ["read"], else: scopes))

    case Accounts.create_api_token(socket.assigns.current_user, params) do
      {:ok, token} ->
        Audit.log(socket.assigns.current_user, "api_token.create",
          resource_type: "api_token",
          resource_id: token.id,
          metadata: %{name: token.name, scopes: token.scopes}
        )

        {:noreply,
         socket
         |> assign(
           created: token.plaintext,
           form: to_form(Accounts.change_api_token(%ApiToken{}))
         )
         |> load()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    token = Enum.find(socket.assigns.tokens, &(to_string(&1.id) == id))

    if token do
      {:ok, _} = Accounts.revoke_api_token(token)

      Audit.log(socket.assigns.current_user, "api_token.revoke",
        resource_type: "api_token",
        resource_id: token.id
      )

      {:noreply, socket |> put_flash(:info, "Токен отозван.") |> load()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("dismiss", _params, socket), do: {:noreply, assign(socket, :created, nil)}

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header title="API-токены" subtitle="Доступ к REST API панели">
      <:actions>
        <.link navigate={~p"/settings"} class="btn btn-sm">Профиль</.link>
      </:actions>
    </.page_header>

    <div :if={@created} class="alert alert-success mb-6">
      <.icon name="hero-key" class="size-5" />
      <div class="min-w-0">
        <p class="font-medium">Токен создан — скопируйте сейчас, позже он не будет показан.</p>
        
        <code class="mt-1 block break-all rounded bg-base-100/40 p-2 font-mono text-xs">{@created}</code>
      </div>
       <button class="btn btn-sm btn-ghost" phx-click="dismiss">Закрыть</button>
    </div>

    <div class="grid gap-6 lg:grid-cols-3">
      <div class="lg:col-span-2">
        <.card title={"Токены (#{length(@tokens)})"}>
          <.empty_state :if={@tokens == []} title="Токенов нет" icon="hero-key" />
          <div :if={@tokens != []} class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Название</th>
                  
                  <th>Права</th>
                  
                  <th>Создан</th>
                  
                  <th>Использован</th>
                  
                  <th>Статус</th>
                  
                  <th></th>
                </tr>
              </thead>
              
              <tbody>
                <tr :for={token <- @tokens} class="hover">
                  <td class="font-medium">{token.name}</td>
                  
                  <td>
                    <span :for={scope <- token.scopes} class="badge badge-xs badge-ghost mr-1">
                      {scope}
                    </span>
                  </td>
                  
                  <td class="text-xs">{datetime(token.inserted_at)}</td>
                  
                  <td class="text-xs">{relative(token.last_used_at)}</td>
                  
                  <td>
                    <span class={[
                      "badge badge-xs",
                      (ApiToken.valid?(token) && "badge-success") || "badge-error"
                    ]}>
                      {(ApiToken.valid?(token) && "активен") || "отозван"}
                    </span>
                  </td>
                  
                  <td class="text-right">
                    <.danger_button
                      :if={ApiToken.valid?(token)}
                      class="btn btn-ghost btn-xs text-error"
                      confirm={"Отозвать токен #{token.name}?"}
                      phx-click="revoke"
                      phx-value-id={token.id}
                    >
                      Отозвать
                    </.danger_button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </.card>
        
        <.card title="Использование" class="mt-6">
          <pre class="overflow-x-auto rounded-box bg-neutral p-4 font-mono text-xs text-neutral-content"><code>{usage_example()}</code></pre>
        </.card>
      </div>
      
      <div>
        <.card title="Новый токен">
          <.form for={@form} phx-submit="create" class="space-y-3">
            <.input field={@form[:name]} label="Название" placeholder="CI/CD" required />
            <fieldset class="fieldset">
              <legend class="fieldset-legend text-xs">Права</legend>
              
              <label
                :for={scope <- ApiToken.scopes()}
                class="label cursor-pointer justify-start gap-2"
              >
                <input
                  type="checkbox"
                  name="api_token[scopes][]"
                  value={scope}
                  checked={scope == "read"}
                  class="checkbox checkbox-sm"
                /> <span class="label-text">{scope_label(scope)}</span>
              </label>
            </fieldset>
             <button type="submit" class="btn btn-primary btn-sm btn-block">Создать токен</button>
          </.form>
        </.card>
      </div>
    </div>
    """
  end

  defp usage_example do
    """
    curl -H "Authorization: Bearer bcp_..." \
      https://panel.example.com/api/v1/servers

    curl -X POST -H "Authorization: Bearer bcp_..." \
      https://panel.example.com/api/v1/projects/1/deploy
    """
  end

  defp scope_label("read"), do: "read — чтение метрик и списков"
  defp scope_label("deploy"), do: "deploy — запуск деплоя и рестарт"
  defp scope_label("admin"), do: "admin — полный доступ"
  defp scope_label(other), do: other
end
