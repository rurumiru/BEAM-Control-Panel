defmodule BeamPanelWeb.ProjectLive.Show do
  @moduledoc "Project overview: service state, releases, deployments and quick actions."

  use BeamPanelWeb, :live_view

  alias BeamPanel.{Projects, Deploy, Accounts, Audit, Beam}
  alias BeamPanel.Projects.Project

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    project = Projects.get_project!(id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(BeamPanel.PubSub, Projects.topic(project))
      Phoenix.PubSub.subscribe(BeamPanel.PubSub, Projects.topic())
    end

    {:ok,
     socket
     |> assign(
       project: project,
       page_title: project.name,
       deployments: Deploy.list_deployments(project_id: project.id, limit: 10),
       details: nil,
       health: nil,
       releases: [],
       ping: nil,
       deploy_ref: ""
     )}
  end

  ## ------------------------------------------------------------------ events

  @impl true
  def handle_event("deploy", params, socket) do
    ref = String.trim(params["ref"] || socket.assigns.deploy_ref || "")

    if Accounts.can?(socket.assigns.current_user, :operator) do
      opts = if ref == "", do: [], else: [ref: ref]

      case Deploy.deploy(socket.assigns.project, socket.assigns.current_user, opts) do
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

  def handle_event("update_ref", %{"ref" => ref}, socket),
    do: {:noreply, assign(socket, :deploy_ref, ref)}

  def handle_event("control", %{"action" => action}, socket) do
    if Accounts.can?(socket.assigns.current_user, :operator) do
      case Projects.control(socket.assigns.project, action) do
        {:ok, _} ->
          Audit.log(socket.assigns.current_user, "project.#{action}",
            resource_type: "project",
            resource_id: socket.assigns.project.id
          )

          {:noreply,
           socket
           |> assign(:project, Projects.get_project!(socket.assigns.project.id))
           |> put_flash(:info, "Команда «#{action}» выполнена.")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, truncate(reason, 300))}
      end
    else
      {:noreply, put_flash(socket, :error, "Недостаточно прав.")}
    end
  end

  def handle_event("sync_service", _params, socket) do
    if Accounts.can?(socket.assigns.current_user, :operator) do
      case Projects.sync_service(socket.assigns.project) do
        {:ok, path} -> {:noreply, put_flash(socket, :info, "systemd unit обновлён: #{path}")}
        {:error, reason} -> {:noreply, put_flash(socket, :error, truncate(reason, 300))}
      end
    else
      {:noreply, put_flash(socket, :error, "Недостаточно прав.")}
    end
  end

  def handle_event("details", _params, socket) do
    case Projects.service_details(socket.assigns.project) do
      {:ok, details} -> {:noreply, assign(socket, :details, details)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, reason)}
    end
  end

  def handle_event("health", _params, socket) do
    case Projects.health_check(socket.assigns.project) do
      {:ok, health} ->
        {:noreply, assign(socket, :health, health)}

      {:error, :no_health_endpoint} ->
        {:noreply, put_flash(socket, :error, "Health-check не настроен.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, inspect(reason))}
    end
  end

  def handle_event("ping", _params, socket) do
    result =
      case Beam.ping(socket.assigns.project) do
        :ok -> "pong"
        {:error, reason} -> "нет ответа: #{truncate(to_string(inspect(reason)), 120)}"
      end

    {:noreply, assign(socket, :ping, result)}
  end

  def handle_event("load_releases", _params, socket) do
    {:noreply, assign(socket, :releases, Deploy.available_releases(socket.assigns.project))}
  end

  def handle_event("rollback", params, socket) do
    if Accounts.can?(socket.assigns.current_user, :operator) do
      case Deploy.rollback(socket.assigns.project, socket.assigns.current_user, params["release"]) do
        {:ok, deployment} ->
          {:noreply, push_navigate(socket, to: ~p"/deployments/#{deployment}")}

        {:error, :no_previous_release} ->
          {:noreply, put_flash(socket, :error, "Нет предыдущего релиза.")}
      end
    else
      {:noreply, put_flash(socket, :error, "Недостаточно прав.")}
    end
  end

  @impl true
  def handle_info(_message, socket) do
    project = Projects.get_project!(socket.assigns.project.id)

    {:noreply,
     assign(socket,
       project: project,
       deployments: Deploy.list_deployments(project_id: project.id, limit: 10)
     )}
  end

  ## ------------------------------------------------------------------ render

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header title={@project.name} subtitle={@project.description}>
      <:breadcrumb>
        <ul>
          <li><.link navigate={~p"/projects"}>Проекты</.link></li>
          
          <li>{@project.name}</li>
        </ul>
      </:breadcrumb>
      
      <:actions>
        <.status_badge status={@project.status} class="badge-md" />
        <.link navigate={~p"/projects/#{@project}/logs"} class="btn btn-sm">
          <.icon name="hero-document-text" class="size-4" /> Логи
        </.link>
        
        <.link navigate={~p"/projects/#{@project}/beam"} class="btn btn-sm">
          <.icon name="hero-cpu-chip" class="size-4" /> OTP
        </.link>
        
        <.link navigate={~p"/projects/#{@project}/env"} class="btn btn-sm">
          <.icon name="hero-key" class="size-4" /> ENV
        </.link>
      </:actions>
    </.page_header>

    <div class="grid gap-6 lg:grid-cols-3">
      <div class="space-y-6 lg:col-span-2">
        <.card title="Деплой">
          <form phx-submit="deploy" class="flex flex-wrap items-end gap-2">
            <label class="form-control flex-1 min-w-48">
              <span class="label-text text-xs">Git ref (пусто — origin/{@project.branch})</span>
              <input
                type="text"
                name="ref"
                value={@deploy_ref}
                placeholder={"origin/#{@project.branch}"}
                class="input input-sm input-bordered"
              />
            </label>
            
            <button
              type="submit"
              class="btn btn-sm btn-primary"
              phx-disable-with="Запускаем…"
            >
              <.icon name="hero-rocket-launch" class="size-4" /> Развернуть
            </button>
            
            <button type="button" class="btn btn-sm" phx-click="load_releases">
              Показать релизы
            </button>
            
            <button
              type="button"
              class="btn btn-sm btn-warning btn-outline"
              phx-click="rollback"
              data-confirm="Откатиться на предыдущий релиз?"
            >
              <.icon name="hero-arrow-uturn-left" class="size-4" /> Откат
            </button>
          </form>
          
          <div :if={@releases != []} class="mt-4">
            <p class="mb-2 text-xs uppercase text-base-content/60">Доступные релизы</p>
            
            <ul class="divide-y divide-base-300">
              <li :for={release <- @releases} class="flex items-center justify-between gap-2 py-1.5">
                <span class="font-mono text-xs">{release}</span>
                <button
                  class="btn btn-xs"
                  phx-click="rollback"
                  phx-value-release={release}
                  data-confirm={"Переключиться на #{release}?"}
                >
                  Активировать
                </button>
              </li>
            </ul>
          </div>
        </.card>
        
        <.card title="Управление службой">
          <div class="flex flex-wrap gap-2">
            <button class="btn btn-sm" phx-click="control" phx-value-action="start">Запустить</button>
            <button class="btn btn-sm" phx-click="control" phx-value-action="restart">
              Перезапустить
            </button>
            
            <button
              class="btn btn-sm btn-outline btn-error"
              phx-click="control"
              phx-value-action="stop"
              data-confirm={"Остановить #{@project.name}?"}
            >
              Остановить
            </button>
            
            <button class="btn btn-sm btn-ghost" phx-click="sync_service">
              Обновить unit и env
            </button>
             <button class="btn btn-sm btn-ghost" phx-click="details">Подробности</button>
            <button class="btn btn-sm btn-ghost" phx-click="health">Health-check</button>
            <button class="btn btn-sm btn-ghost" phx-click="ping">Ping ноды</button>
          </div>
          
          <div :if={@health} class="alert alert-info mt-4 text-sm">
            <.icon name="hero-heart" class="size-5" />
            <span>HTTP {@health.status} за {@health.time}s — {@health.url}</span>
          </div>
          
          <div :if={@ping} class="alert mt-4 text-sm">
            <.icon name="hero-signal" class="size-5" /> <span>{@ping}</span>
          </div>
          
          <div :if={@details} class="mt-4 overflow-x-auto">
            <table class="table table-xs">
              <tbody>
                <tr :for={{key, value} <- @details}>
                  <td class="font-mono text-xs text-base-content/60">{key}</td>
                  
                  <td class="font-mono text-xs">{value}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </.card>
        
        <.card title="История деплоев">
          <:actions>
            <.link navigate={~p"/deployments"} class="btn btn-xs btn-ghost">Все</.link>
          </:actions>
          
          <.empty_state
            :if={@deployments == []}
            title="Деплоев ещё не было"
            icon="hero-rocket-launch"
          />
          <div :if={@deployments != []} class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Когда</th>
                  
                  <th>Статус</th>
                  
                  <th>Версия</th>
                  
                  <th>Коммит</th>
                  
                  <th>Кто</th>
                  
                  <th></th>
                </tr>
              </thead>
              
              <tbody>
                <tr :for={deployment <- @deployments} class="hover">
                  <td class="text-xs">{relative(deployment.inserted_at)}</td>
                  
                  <td><.status_badge status={deployment.status} /></td>
                  
                  <td class="font-mono text-xs">{deployment.release_version || "—"}</td>
                  
                  <td class="font-mono text-xs">{deployment.commit_sha || "—"}</td>
                  
                  <td class="text-xs">{(deployment.user && deployment.user.email) || "—"}</td>
                  
                  <td class="text-right">
                    <.link navigate={~p"/deployments/#{deployment}"} class="btn btn-xs">Лог</.link>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </.card>
      </div>
      
      <div class="space-y-6">
        <.card title="Конфигурация">
          <dl>
            <.kv label="Сервер">
              <.link navigate={~p"/servers/#{@project.server}"} class="link link-hover">
                {@project.server.name}
              </.link>
            </.kv>
            
            <.kv label="Тип">{@project.kind}</.kv>
            
            <.kv label="MIX_ENV">{@project.mix_env}</.kv>
            
            <.kv label="Каталог">{@project.deploy_path}</.kv>
            
            <.kv label="Релиз">{@project.release_name}</.kv>
            
            <.kv label="Служба">{@project.service_name}</.kv>
            
            <.kv label="Порт">{@project.http_port || "—"}</.kv>
            
            <.kv label="Нода">{@project.node_name || "—"}</.kv>
            
            <.kv label="Репозиторий">{truncate(@project.repo_url, 32)}</.kv>
            
            <.kv label="Ветка">{@project.branch}</.kv>
            
            <.kv label="Миграции">{(@project.auto_migrate && "авто") || "вручную"}</.kv>
          </dl>
        </.card>
        
        <.card title="Версии">
          <dl>
            <.kv label="Текущая">{@project.current_version || "—"}</.kv>
            
            <.kv label="Предыдущая">{@project.previous_version || "—"}</.kv>
            
            <.kv label="Последний деплой">{relative(@project.last_deployed_at)}</.kv>
          </dl>
        </.card>
        
        <.card title="Пути">
          <dl class="font-mono text-xs">
            <.kv label="current">{Project.current_path(@project)}</.kv>
            
            <.kv label="releases">{Project.releases_path(@project)}</.kv>
            
            <.kv label="source">{Project.source_path(@project)}</.kv>
            
            <.kv label="bin">{Project.bin_path(@project)}</.kv>
          </dl>
        </.card>
      </div>
    </div>
    """
  end
end
