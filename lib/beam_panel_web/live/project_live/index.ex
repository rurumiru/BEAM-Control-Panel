defmodule BeamPanelWeb.ProjectLive.Index do
  @moduledoc "All BEAM projects across every server."

  use BeamPanelWeb, :live_view

  alias BeamPanel.{Projects, Servers, Deploy, Accounts, Audit}
  alias BeamPanel.Projects.Project

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(BeamPanel.PubSub, Projects.topic())
      :timer.send_interval(10_000, self(), :tick)
    end

    {:ok, socket |> assign(page_title: "Проекты", filter: "all") |> load()}
  end

  defp load(socket) do
    assign(socket, projects: Projects.list_projects(), servers: Servers.list_servers())
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, params) do
    project = %Project{
      kind: "phoenix",
      branch: "main",
      mix_env: "prod",
      auto_migrate: true,
      autostart: true,
      server_id: parse_int(params["server_id"])
    }

    socket
    |> assign(:project, project)
    |> assign(:form, to_form(Projects.change_project(project)))
    |> assign(:modal_title, "Новый проект")
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    project = Projects.get_project!(id)

    socket
    |> assign(:project, project)
    |> assign(:form, to_form(Projects.change_project(project)))
    |> assign(:modal_title, "Редактирование: #{project.name}")
  end

  defp apply_action(socket, _action, _params), do: assign(socket, project: nil, form: nil)

  defp parse_int(nil), do: nil

  defp parse_int(value) do
    case Integer.parse(to_string(value)) do
      {int, _} -> int
      :error -> nil
    end
  end

  ## ------------------------------------------------------------------ events

  @impl true
  def handle_event("validate", %{"project" => params}, socket) do
    changeset =
      socket.assigns.project
      |> Projects.change_project(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"project" => params}, socket) do
    if Accounts.can?(socket.assigns.current_user, :operator) do
      save(socket, socket.assigns.live_action, params)
    else
      {:noreply, put_flash(socket, :error, "Недостаточно прав.")}
    end
  end

  def handle_event("deploy", %{"id" => id}, socket) do
    project = Projects.get_project!(id)

    if Accounts.can?(socket.assigns.current_user, :operator) do
      case Deploy.deploy(project, socket.assigns.current_user) do
        {:ok, deployment} ->
          {:noreply, push_navigate(socket, to: ~p"/deployments/#{deployment}")}

        {:error, :already_running} ->
          {:noreply, put_flash(socket, :error, "Деплой уже выполняется.")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, inspect(reason))}
      end
    else
      {:noreply, put_flash(socket, :error, "Недостаточно прав.")}
    end
  end

  def handle_event("control", %{"id" => id, "action" => action}, socket) do
    project = Projects.get_project!(id)

    if Accounts.can?(socket.assigns.current_user, :operator) do
      case Projects.control(project, action) do
        {:ok, _} ->
          Audit.log(socket.assigns.current_user, "project.#{action}",
            resource_type: "project",
            resource_id: project.id
          )

          {:noreply,
           socket |> put_flash(:info, "#{project.name}: #{action} выполнено.") |> load()}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, truncate(reason, 300))}
      end
    else
      {:noreply, put_flash(socket, :error, "Недостаточно прав.")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    project = Projects.get_project!(id)

    if Accounts.can?(socket.assigns.current_user, :admin) do
      {:ok, _} = Projects.delete_project(project)

      Audit.log(socket.assigns.current_user, "project.delete",
        resource_type: "project",
        resource_id: project.id,
        metadata: %{name: project.name}
      )

      {:noreply, socket |> put_flash(:info, "Проект удалён из панели.") |> load()}
    else
      {:noreply, put_flash(socket, :error, "Удалять проекты может только администратор.")}
    end
  end

  def handle_event("filter", %{"filter" => filter}, socket),
    do: {:noreply, assign(socket, :filter, filter)}

  def handle_event("close_modal", _params, socket),
    do: {:noreply, push_patch(socket, to: ~p"/projects")}

  @impl true
  def handle_info(:tick, socket), do: {:noreply, load(socket)}
  def handle_info(_message, socket), do: {:noreply, load(socket)}

  defp save(socket, :new, params) do
    case Projects.create_project(params) do
      {:ok, project} ->
        Audit.log(socket.assigns.current_user, "project.create",
          resource_type: "project",
          resource_id: project.id,
          metadata: %{name: project.name}
        )

        {:noreply,
         socket
         |> put_flash(:info, "Проект создан.")
         |> load()
         |> push_patch(to: ~p"/projects")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp save(socket, :edit, params) do
    case Projects.update_project(socket.assigns.project, params) do
      {:ok, _project} ->
        {:noreply,
         socket
         |> put_flash(:info, "Изменения сохранены.")
         |> load()
         |> push_patch(to: ~p"/projects")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  ## ------------------------------------------------------------------ render

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header
      title="Проекты"
      subtitle="Elixir, Phoenix и Erlang приложения под управлением панели"
    >
      <:actions>
        <form phx-change="filter">
          <select name="filter" class="select select-sm select-bordered">
            <option value="all" selected={@filter == "all"}>Все статусы</option>
            <option value="running" selected={@filter == "running"}>Работают</option>
            <option value="stopped" selected={@filter == "stopped"}>Остановлены</option>
            <option value="failed" selected={@filter == "failed"}>С ошибкой</option>
          </select>
        </form>
        <.link patch={~p"/projects/new"} class="btn btn-sm btn-primary">
          <.icon name="hero-plus" class="size-4" /> Новый проект
        </.link>
      </:actions>
    </.page_header>

    <.empty_state
      :if={@projects == []}
      title="Проектов пока нет"
      description="Создайте проект вручную или запустите поиск уже развёрнутых приложений на сервере."
      icon="hero-cube"
    >
      <:actions>
        <.link patch={~p"/projects/new"} class="btn btn-sm btn-primary">Новый проект</.link>
        <.link navigate={~p"/servers"} class="btn btn-sm">К серверам</.link>
      </:actions>
    </.empty_state>

    <div class="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
      <div
        :for={project <- filtered(@projects, @filter)}
        class="flex flex-col rounded-box border border-base-300 bg-base-100 p-4"
      >
        <div class="flex items-start justify-between gap-2">
          <div class="min-w-0">
            <.link navigate={~p"/projects/#{project}"} class="link link-hover font-semibold">
              {project.name}
            </.link>
            <div class="truncate text-xs text-base-content/50">
              {project.server && project.server.name} · {project.deploy_path}
            </div>
          </div>
          <.status_badge status={project.status} />
        </div>

        <div class="mt-2 flex flex-wrap gap-1">
          <span class="badge badge-xs badge-outline">{project.kind}</span>
          <span :if={project.http_port} class="badge badge-xs badge-ghost">:{project.http_port}</span>
          <span :if={project.discovered} class="badge badge-xs badge-ghost">найден</span>
        </div>

        <dl class="mt-3 flex-1">
          <.kv label="Служба">{project.service_name}</.kv>
          <.kv label="Версия">{project.current_version || "—"}</.kv>
          <.kv label="Ветка">{project.branch}</.kv>
          <.kv label="Деплой">{relative(project.last_deployed_at)}</.kv>
        </dl>

        <div class="mt-3 flex flex-wrap gap-1">
          <button class="btn btn-xs btn-primary" phx-click="deploy" phx-value-id={project.id}>
            <.icon name="hero-rocket-launch" class="size-3" /> Деплой
          </button>
          <button
            class="btn btn-xs"
            phx-click="control"
            phx-value-id={project.id}
            phx-value-action="restart"
          >
            Рестарт
          </button>
          <button
            class="btn btn-xs btn-ghost"
            phx-click="control"
            phx-value-id={project.id}
            phx-value-action="start"
          >
            Старт
          </button>
          <button
            class="btn btn-xs btn-ghost"
            phx-click="control"
            phx-value-id={project.id}
            phx-value-action="stop"
            data-confirm={"Остановить #{project.name}?"}
          >
            Стоп
          </button>
          <.link navigate={~p"/projects/#{project}/logs"} class="btn btn-xs btn-ghost">Логи</.link>
          <.link patch={~p"/projects/#{project}/edit"} class="btn btn-xs btn-ghost">Изменить</.link>
          <.danger_button
            class="btn btn-xs btn-ghost text-error"
            confirm={"Удалить проект #{project.name} из панели? Файлы на сервере останутся."}
            phx-click="delete"
            phx-value-id={project.id}
          >
            Удалить
          </.danger_button>
        </div>
      </div>
    </div>

    <.modal
      :if={@live_action in [:new, :edit]}
      id="project-modal"
      show
      title={@modal_title}
      on_cancel={JS.push("close_modal")}
    >
      <.form for={@form} phx-change="validate" phx-submit="save" class="space-y-4">
        <div class="grid gap-4 sm:grid-cols-2">
          <.input field={@form[:name]} label="Название" required />
          <.input
            field={@form[:server_id]}
            type="select"
            label="Сервер"
            required
            prompt="— выберите сервер —"
            options={Enum.map(@servers, &{"#{&1.name} (#{&1.hostname})", &1.id})}
          />
        </div>

        <div class="grid gap-4 sm:grid-cols-3">
          <.input
            field={@form[:kind]}
            type="select"
            label="Тип"
            options={[
              {"Phoenix", "phoenix"},
              {"Elixir release", "elixir_release"},
              {"Mix-приложение", "mix_app"},
              {"Erlang release", "erlang_release"}
            ]}
          />
          <.input field={@form[:mix_env]} label="MIX_ENV" />
          <.input field={@form[:http_port]} type="number" label="HTTP-порт" />
        </div>

        <div class="grid gap-4 sm:grid-cols-2">
          <.input
            field={@form[:repo_url]}
            label="Git-репозиторий"
            placeholder="git@github.com:org/app.git"
          />
          <.input field={@form[:branch]} label="Ветка" />
        </div>

        <div class="grid gap-4 sm:grid-cols-3">
          <.input
            field={@form[:deploy_path]}
            label="Каталог деплоя"
            placeholder="/opt/beam/app"
          />
          <.input field={@form[:release_name]} label="Имя релиза" />
          <.input field={@form[:service_name]} label="systemd unit" />
        </div>

        <div class="grid gap-4 sm:grid-cols-2">
          <.input field={@form[:node_name]} label="Имя ноды" placeholder="app@127.0.0.1" />
          <.input field={@form[:node_cookie]} type="password" label="Erlang cookie" value="" />
        </div>

        <.input
          field={@form[:health_url]}
          label="URL health-check"
          placeholder="http://127.0.0.1:4000/health"
        />
        <.input
          field={@form[:migrate_command]}
          label="Команда миграций (пусто — автоматически)"
          placeholder="/opt/beam/app/current/bin/app eval &quot;App.Release.migrate&quot;"
        />

        <div class="grid gap-4 sm:grid-cols-2">
          <.input
            field={@form[:auto_migrate]}
            type="checkbox"
            label="Выполнять миграции при деплое"
          />
          <.input
            field={@form[:autostart]}
            type="checkbox"
            label="Автозапуск (systemctl enable)"
          />
        </div>

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

  defp filtered(projects, "all"), do: projects
  defp filtered(projects, status), do: Enum.filter(projects, &(&1.status == status))
end
