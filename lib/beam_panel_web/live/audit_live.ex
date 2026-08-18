defmodule BeamPanelWeb.AuditLive do
  @moduledoc "Audit trail of every mutating action performed through the panel."

  use BeamPanelWeb, :live_view

  alias BeamPanel.Audit

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(BeamPanel.PubSub, Audit.topic())

    {:ok, socket |> assign(page_title: "Аудит", filter: "") |> load()}
  end

  defp load(socket) do
    opts = [limit: 200]

    opts =
      if socket.assigns.filter == "",
        do: opts,
        else: Keyword.put(opts, :action, socket.assigns.filter)

    assign(socket, :logs, Audit.list(opts))
  end

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket),
    do: {:noreply, socket |> assign(:filter, filter) |> load()}

  @impl true
  def handle_info({:audit_log, _log}, socket), do: {:noreply, load(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header title="Аудит" subtitle="Кто, что и когда изменил">
      <:actions>
        <form phx-change="filter">
          <input
            type="text"
            name="filter"
            value={@filter}
            placeholder="Фильтр по действию, напр. deploy.start"
            class="input input-sm input-bordered w-72"
            phx-debounce="400"
          />
        </form>
      </:actions>
    </.page_header>

    <.card title={"Записей: #{length(@logs)}"}>
      <.empty_state
        :if={@logs == []}
        title="Записей нет"
        icon="hero-clipboard-document-list"
      />

      <div :if={@logs != []} class="overflow-x-auto">
        <table class="table table-sm">
          <thead>
            <tr>
              <th>Время</th>
              <th>Пользователь</th>
              <th>Действие</th>
              <th>Объект</th>
              <th>Результат</th>
              <th>IP</th>
              <th>Детали</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={log <- @logs} class="hover">
              <td class="whitespace-nowrap text-xs">{datetime(log.inserted_at)}</td>
              <td class="text-xs">{log.actor || "система"}</td>
              <td class="font-mono text-xs font-semibold">{log.action}</td>
              <td class="text-xs">
                {(log.resource_type && "#{log.resource_type}##{log.resource_id}") || "—"}
              </td>
              <td>
                <span class={[
                  "badge badge-xs",
                  (log.result == "ok" && "badge-success") || "badge-error"
                ]}>
                  {log.result}
                </span>
              </td>
              <td class="font-mono text-xs">{log.ip || "—"}</td>
              <td class="max-w-md truncate font-mono text-[11px] text-base-content/60">
                {metadata(log.metadata)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </.card>
    """
  end

  defp metadata(metadata) when map_size(metadata) == 0, do: "—"

  defp metadata(metadata),
    do: Enum.map_join(metadata, " · ", fn {k, v} -> "#{k}=#{inspect(v, limit: 3)}" end)
end
