defmodule BeamPanelWeb.ServerLive.ProvisionRun do
  @moduledoc "Live output of a provisioning run."

  use BeamPanelWeb, :live_view

  alias BeamPanel.Provision

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    run = Provision.get_run!(id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(BeamPanel.PubSub, Provision.topic(run))
    end

    socket =
      socket
      |> assign(run: run, page_title: "Провижининг #{run.server.name}", counter: 0)
      |> stream_configure(:log, dom_id: fn _ -> "log-#{System.unique_integer([:positive])}" end)
      |> stream(:log, Provision.log_lines(run))

    {:ok, socket}
  end

  @impl true
  def handle_info({:provision_log, line}, socket) do
    {:noreply, stream_insert(socket, :log, line)}
  end

  def handle_info({:provision_status, status}, socket) do
    run = Provision.get_run!(socket.assigns.run.id)

    {:noreply,
     socket |> assign(:run, run) |> put_flash(:info, "Провижининг: #{status_label(status)}")}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header
      title={"Провижининг: #{@run.server.name}"}
      subtitle={Enum.join(@run.components, ", ")}
    >
      <:breadcrumb>
        <ul>
          <li><.link navigate={~p"/servers"}>Серверы</.link></li>
          <li><.link navigate={~p"/servers/#{@run.server}"}>{@run.server.name}</.link></li>
          <li>Провижининг</li>
        </ul>
      </:breadcrumb>
      <:actions>
        <.status_badge status={@run.status} class="badge-md" />
        <.link navigate={~p"/servers/#{@run.server}/provision"} class="btn btn-sm">Назад</.link>
      </:actions>
    </.page_header>

    <div :if={@run.error} class="alert alert-error mb-4 text-sm">
      <.icon name="hero-x-circle" class="size-5" />
      <span>{@run.error}</span>
    </div>

    <.card title="Журнал выполнения">
      <.log_console id="provision-log" lines={@streams.log} class="h-[65vh]" />
    </.card>

    <div class="mt-4 grid gap-4 sm:grid-cols-3">
      <.stat_tile label="Начало" value={datetime(@run.started_at)} icon="hero-play" />
      <.stat_tile label="Окончание" value={datetime(@run.finished_at)} icon="hero-flag" />
      <.stat_tile
        label="Инициатор"
        value={(@run.user && @run.user.email) || "система"}
        icon="hero-user"
      />
    </div>
    """
  end
end
