defmodule BeamPanelWeb.ProjectLive.Env do
  @moduledoc "Environment variables for a project, stored encrypted and rendered into the systemd env file."

  use BeamPanelWeb, :live_view

  alias BeamPanel.{Projects, Accounts, Audit}
  alias BeamPanel.Projects.{EnvVar, Systemd}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    project = Projects.get_project!(id)

    {:ok,
     socket
     |> assign(
       project: project,
       page_title: "ENV · #{project.name}",
       form: to_form(Projects.change_env_var(%EnvVar{})),
       import_text: "",
       reveal: MapSet.new(),
       show_import: false
     )
     |> load()}
  end

  defp load(socket) do
    assign(socket, :env_vars, Projects.list_env_vars(socket.assigns.project.id))
  end

  ## ------------------------------------------------------------------ events

  @impl true
  def handle_event("validate", %{"env_var" => params}, socket) do
    changeset =
      %EnvVar{}
      |> Projects.change_env_var(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("add", %{"env_var" => params}, socket) do
    with true <- Accounts.can?(socket.assigns.current_user, :operator),
         {:ok, env_var} <- Projects.create_env_var(socket.assigns.project, params) do
      Audit.log(socket.assigns.current_user, "project.env.set",
        resource_type: "project",
        resource_id: socket.assigns.project.id,
        metadata: %{key: env_var.key}
      )

      {:noreply,
       socket
       |> assign(:form, to_form(Projects.change_env_var(%EnvVar{})))
       |> put_flash(:info, "Переменная #{env_var.key} сохранена.")
       |> load()}
    else
      false -> {:noreply, put_flash(socket, :error, "Недостаточно прав.")}
      {:error, changeset} -> {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    env_var = Enum.find(socket.assigns.env_vars, &(to_string(&1.id) == id))

    if env_var && Accounts.can?(socket.assigns.current_user, :operator) do
      {:ok, _} = Projects.delete_env_var(env_var)

      Audit.log(socket.assigns.current_user, "project.env.delete",
        resource_type: "project",
        resource_id: socket.assigns.project.id,
        metadata: %{key: env_var.key}
      )

      {:noreply, socket |> put_flash(:info, "Переменная удалена.") |> load()}
    else
      {:noreply, put_flash(socket, :error, "Недостаточно прав.")}
    end
  end

  def handle_event("toggle_reveal", %{"id" => id}, socket) do
    reveal = socket.assigns.reveal

    reveal =
      if MapSet.member?(reveal, id), do: MapSet.delete(reveal, id), else: MapSet.put(reveal, id)

    {:noreply, assign(socket, :reveal, reveal)}
  end

  def handle_event("show_import", _params, socket),
    do: {:noreply, assign(socket, :show_import, true)}

  def handle_event("close_import", _params, socket),
    do: {:noreply, assign(socket, :show_import, false)}

  def handle_event("import", %{"text" => text}, socket) do
    if Accounts.can?(socket.assigns.current_user, :operator) do
      {ok, failed} = Projects.import_env(socket.assigns.project, text)

      {:noreply,
       socket
       |> assign(show_import: false, import_text: "")
       |> put_flash(:info, "Импортировано: #{ok}, пропущено: #{failed}")
       |> load()}
    else
      {:noreply, put_flash(socket, :error, "Недостаточно прав.")}
    end
  end

  def handle_event("sync", _params, socket) do
    case Projects.sync_service(socket.assigns.project) do
      {:ok, _path} ->
        {:noreply,
         put_flash(socket, :info, "Файл окружения записан на сервер. Перезапустите службу.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, truncate(reason, 300))}
    end
  end

  ## ------------------------------------------------------------------ render

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header title="Переменные окружения" subtitle={@project.name}>
      <:breadcrumb>
        <ul>
          <li><.link navigate={~p"/projects"}>Проекты</.link></li>
          <li><.link navigate={~p"/projects/#{@project}"}>{@project.name}</.link></li>
          <li>ENV</li>
        </ul>
      </:breadcrumb>
      <:actions>
        <button class="btn btn-sm" phx-click="show_import">Импорт .env</button>
        <button class="btn btn-sm btn-primary" phx-click="sync">Записать на сервер</button>
      </:actions>
    </.page_header>

    <div class="alert alert-info mb-4 text-sm">
      <.icon name="hero-lock-closed" class="size-5" />
      <span>
        Значения хранятся зашифрованными (AES-256-GCM) и записываются в
        <code>{Systemd.env_path(@project)}</code>
        с правами 0600.
      </span>
    </div>

    <div class="grid gap-6 lg:grid-cols-3">
      <div class="lg:col-span-2">
        <.card title={"Переменные (#{length(@env_vars)})"}>
          <.empty_state
            :if={@env_vars == []}
            title="Переменных пока нет"
            icon="hero-key"
          />

          <div :if={@env_vars != []} class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Ключ</th>
                  <th>Значение</th>
                  <th class="text-right"></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={env_var <- @env_vars} class="hover">
                  <td class="font-mono text-xs font-semibold">{env_var.key}</td>
                  <td class="font-mono text-xs break-all">
                    {display(env_var, MapSet.member?(@reveal, to_string(env_var.id)))}
                  </td>
                  <td class="text-right">
                    <button
                      :if={env_var.secret}
                      class="btn btn-ghost btn-xs"
                      phx-click="toggle_reveal"
                      phx-value-id={env_var.id}
                    >
                      <.icon name="hero-eye" class="size-3" />
                    </button>
                    <.danger_button
                      class="btn btn-ghost btn-xs text-error"
                      confirm={"Удалить #{env_var.key}?"}
                      phx-click="delete"
                      phx-value-id={env_var.id}
                    >
                      <.icon name="hero-trash" class="size-3" />
                    </.danger_button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </.card>
      </div>

      <div>
        <.card title="Добавить переменную">
          <.form for={@form} phx-change="validate" phx-submit="add" class="space-y-3">
            <.input field={@form[:key]} label="Ключ" placeholder="DATABASE_URL" required />
            <.input field={@form[:value]} label="Значение" type="textarea" rows="3" />
            <.input
              field={@form[:secret]}
              type="checkbox"
              label="Секрет (скрывать значение)"
            />
            <button type="submit" class="btn btn-primary btn-sm btn-block">Сохранить</button>
          </.form>
        </.card>
      </div>
    </div>

    <.modal
      :if={@show_import}
      id="import-modal"
      show
      title="Импорт переменных"
      on_cancel={JS.push("close_import")}
    >
      <form phx-submit="import" class="space-y-3">
        <textarea
          name="text"
          rows="12"
          class="textarea textarea-bordered w-full font-mono text-xs"
          placeholder="DATABASE_URL=ecto://user:pass@localhost/app&#10;SECRET_KEY_BASE=..."
        ></textarea>
        <div class="flex justify-end gap-2">
          <button type="button" class="btn btn-ghost btn-sm" phx-click="close_import">Отмена</button>
          <button type="submit" class="btn btn-primary btn-sm">Импортировать</button>
        </div>
      </form>
    </.modal>
    """
  end

  defp display(%EnvVar{secret: true} = env_var, true), do: env_var.value
  defp display(%EnvVar{secret: true}, false), do: "••••••••"
  defp display(env_var, _), do: env_var.value
end
