defmodule BeamPanelWeb.DeploymentLive.Show do
  @moduledoc "Live deployment log with per-step progress."

  use BeamPanelWeb, :live_view

  alias BeamPanel.{Deploy, Accounts}
  alias BeamPanel.Deploy.{Deployment, Pipeline}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    deployment = Deploy.get_deployment!(id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(BeamPanel.PubSub, Deploy.topic(deployment))
    end

    steps =
      deployment.project
      |> Pipeline.steps()
      |> Enum.map(fn {key, title, _fun} -> %{key: key, title: title, state: :pending} end)

    socket =
      socket
      |> assign(
        deployment: deployment,
        page_title: "Деплой ##{deployment.id}",
        steps: steps
      )
      |> stream_configure(:log, dom_id: fn _ -> "log-#{System.unique_integer([:positive])}" end)
      |> stream(:log, Deploy.log_lines(deployment))

    {:ok, socket}
  end

  ## ------------------------------------------------------------------ events

  @impl true
  def handle_event("cancel", _params, socket) do
    if Accounts.can?(socket.assigns.current_user, :operator) do
      case Deploy.cancel(socket.assigns.deployment) do
        {:ok, deployment} -> {:noreply, assign(socket, :deployment, deployment)}
        {:error, :not_running} -> {:noreply, put_flash(socket, :error, "Деплой уже завершён.")}
      end
    else
      {:noreply, put_flash(socket, :error, "Недостаточно прав.")}
    end
  end

  def handle_event("redeploy", _params, socket) do
    project = socket.assigns.deployment.project

    if Accounts.can?(socket.assigns.current_user, :operator) do
      case Deploy.deploy(project, socket.assigns.current_user, ref: socket.assigns.deployment.ref) do
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

  @impl true
  def handle_info({:deploy_log, line}, socket), do: {:noreply, stream_insert(socket, :log, line)}

  def handle_info({:deploy_step, key, state}, socket) do
    steps =
      Enum.map(socket.assigns.steps, fn step ->
        if step.key == key, do: %{step | state: state}, else: step
      end)

    {:noreply, assign(socket, :steps, steps)}
  end

  def handle_info({:deploy_status, _status}, socket) do
    {:noreply, assign(socket, :deployment, Deploy.get_deployment!(socket.assigns.deployment.id))}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  ## ------------------------------------------------------------------ render

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header
      title={"Деплой ##{@deployment.id}"}
      subtitle={
        @deployment.project && "#{@deployment.project.name} · #{@deployment.project.server.name}"
      }
    >
      <:breadcrumb>
        <ul>
          <li><.link navigate={~p"/deployments"}>Деплои</.link></li>
          
          <li>№{@deployment.id}</li>
        </ul>
      </:breadcrumb>
      
      <:actions>
        <.status_badge status={@deployment.status} class="badge-md" />
        <button
          :if={@deployment.status in ["pending", "running"]}
          class="btn btn-sm btn-error btn-outline"
          phx-click="cancel"
          data-confirm="Прервать деплой?"
        >
          Прервать
        </button>
        
        <button
          :if={Deployment.finished?(@deployment)}
          class="btn btn-sm btn-primary"
          phx-click="redeploy"
        >
          <.icon name="hero-arrow-path" class="size-4" /> Повторить
        </button>
        
        <.link
          :if={@deployment.project}
          navigate={~p"/projects/#{@deployment.project}"}
          class="btn btn-sm"
        >
          К проекту
        </.link>
      </:actions>
    </.page_header>

    <div :if={@deployment.error} class="alert alert-error mb-4 text-sm">
      <.icon name="hero-x-circle" class="size-5" /> <span class="break-all">{@deployment.error}</span>
    </div>

    <div class="grid gap-6 lg:grid-cols-4">
      <div class="lg:col-span-1 space-y-6">
        <.card title="Шаги">
          <ol class="space-y-1">
            <li :for={step <- @steps} class="flex items-center gap-2 text-sm">
              <span class={[
                "flex size-5 items-center justify-center rounded-full text-xs",
                step_class(step.state)
              ]}>
                {step_glyph(step.state)}
              </span>
               <span class={step.state == :running && "font-semibold"}>{step.title}</span>
            </li>
          </ol>
        </.card>
        
        <.card title="Сведения">
          <dl>
            <.kv label="Стратегия">{@deployment.strategy}</.kv>
            
            <.kv label="Ref">{@deployment.ref || "по умолчанию"}</.kv>
            
            <.kv label="Коммит">{@deployment.commit_sha || "—"}</.kv>
            
            <.kv label="Сообщение">{truncate(@deployment.commit_message, 60)}</.kv>
            
            <.kv label="Версия">{@deployment.release_version || "—"}</.kv>
            
            <.kv label="Предыдущая">{@deployment.previous_version || "—"}</.kv>
            
            <.kv label="Начало">{datetime(@deployment.started_at)}</.kv>
            
            <.kv label="Конец">{datetime(@deployment.finished_at)}</.kv>
            
            <.kv label="Длительность">
              {duration_ms(Deployment.duration(@deployment))}
            </.kv>
            
            <.kv label="Инициатор">
              {(@deployment.user && @deployment.user.email) || "система"}
            </.kv>
          </dl>
        </.card>
      </div>
      
      <div class="lg:col-span-3">
        <.card title="Журнал">
          <.log_console id="deploy-log" lines={@streams.log} class="h-[70vh]" />
        </.card>
      </div>
    </div>
    """
  end

  defp step_class(:done), do: "bg-success text-success-content"
  defp step_class(:running), do: "bg-info text-info-content animate-pulse"
  defp step_class(:failed), do: "bg-error text-error-content"
  defp step_class(_), do: "bg-base-300 text-base-content/60"

  defp step_glyph(:done), do: "✓"
  defp step_glyph(:running), do: "•"
  defp step_glyph(:failed), do: "✕"
  defp step_glyph(_), do: "·"
end
