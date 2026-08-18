defmodule BeamPanelWeb.ServerLive.Services do
  @moduledoc "systemd unit browser and control."

  use BeamPanelWeb, :live_view

  alias BeamPanel.{Servers, Accounts, Audit}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    server = Servers.get_server!(id)

    {:ok,
     socket
     |> assign(
       server: server,
       page_title: "Службы · #{server.name}",
       filter: "",
       services: [],
       loading: true,
       detail: nil
     )
     |> load()}
  end

  defp load(socket) do
    case Servers.list_services(socket.assigns.server, nilify(socket.assigns.filter)) do
      {:ok, services} ->
        assign(socket, services: services, loading: false)

      {:error, reason} ->
        socket |> assign(services: [], loading: false) |> put_flash(:error, reason)
    end
  end

  defp nilify(""), do: nil
  defp nilify(value), do: value

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket) do
    {:noreply, socket |> assign(filter: filter, loading: true) |> load()}
  end

  def handle_event("action", %{"unit" => unit, "action" => action}, socket) do
    if Accounts.can?(socket.assigns.current_user, :operator) do
      case Servers.service_action(socket.assigns.server, unit, action) do
        {:ok, _output} ->
          Audit.log(socket.assigns.current_user, "service.#{action}",
            resource_type: "server",
            resource_id: socket.assigns.server.id,
            metadata: %{unit: unit}
          )

          {:noreply, socket |> put_flash(:info, "#{unit}: #{action} выполнено.") |> load()}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, truncate(reason, 300))}
      end
    else
      {:noreply, put_flash(socket, :error, "Недостаточно прав.")}
    end
  end

  def handle_event("detail", %{"unit" => unit}, socket) do
    {:ok, output} = Servers.service_status(socket.assigns.server, unit)
    {:noreply, assign(socket, :detail, %{unit: unit, output: output})}
  end

  def handle_event("close_detail", _params, socket), do: {:noreply, assign(socket, :detail, nil)}

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header title="Службы systemd" subtitle={@server.name}>
      <:breadcrumb>
        <ul>
          <li><.link navigate={~p"/servers"}>Серверы</.link></li>
          
          <li><.link navigate={~p"/servers/#{@server}"}>{@server.name}</.link></li>
          
          <li>Службы</li>
        </ul>
      </:breadcrumb>
      
      <:actions>
        <form phx-change="filter" phx-submit="filter">
          <input
            type="text"
            name="filter"
            value={@filter}
            placeholder="Фильтр по имени…"
            class="input input-sm input-bordered w-56"
            phx-debounce="400"
          />
        </form>
      </:actions>
    </.page_header>

    <.card title={"Найдено: #{length(@services)}"}>
      <.empty_state
        :if={@services == [] and not @loading}
        title="Службы не найдены"
        icon="hero-cog-6-tooth"
      />
      <div :if={@services != []} class="overflow-x-auto">
        <table class="table table-sm">
          <thead>
            <tr>
              <th>Юнит</th>
              
              <th>Состояние</th>
              
              <th>Описание</th>
              
              <th class="text-right">Действия</th>
            </tr>
          </thead>
          
          <tbody>
            <tr :for={service <- @services} class="hover">
              <td class="font-mono text-xs">{service.unit}</td>
              
              <td>
                <span class={["badge badge-xs", active_class(service.active)]}>
                  {service.active}/{service.sub}
                </span>
              </td>
              
              <td class="max-w-xs truncate text-xs text-base-content/60">{service.description}</td>
              
              <td class="text-right">
                <div class="join">
                  <button
                    class="btn btn-xs join-item"
                    phx-click="detail"
                    phx-value-unit={service.unit}
                  >
                    status
                  </button>
                  
                  <button
                    class="btn btn-xs join-item"
                    phx-click="action"
                    phx-value-unit={service.unit}
                    phx-value-action="start"
                  >
                    start
                  </button>
                  
                  <button
                    class="btn btn-xs join-item"
                    phx-click="action"
                    phx-value-unit={service.unit}
                    phx-value-action="restart"
                  >
                    restart
                  </button>
                  
                  <button
                    class="btn btn-xs join-item btn-error btn-outline"
                    phx-click="action"
                    phx-value-unit={service.unit}
                    phx-value-action="stop"
                    data-confirm={"Остановить #{service.unit}?"}
                  >
                    stop
                  </button>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </.card>

    <.modal
      :if={@detail}
      id="service-detail"
      show
      title={detail_title(@detail)}
      on_cancel={JS.push("close_detail")}
    >
      <pre class="max-h-[60vh] overflow-auto rounded-box bg-neutral p-4 font-mono text-xs text-neutral-content"><code>{detail_output(@detail)}</code></pre>
    </.modal>
    """
  end

  defp detail_title(detail), do: (detail && detail.unit) || ""
  defp detail_output(detail), do: (detail && detail.output) || ""

  defp active_class("active"), do: "badge-success"
  defp active_class("failed"), do: "badge-error"
  defp active_class("activating"), do: "badge-info"
  defp active_class(_), do: "badge-ghost"
end
