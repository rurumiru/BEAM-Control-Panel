defmodule BeamPanelWeb.ProjectLive.Logs do
  @moduledoc "Live journal viewer for a project's systemd unit."

  use BeamPanelWeb, :live_view

  alias BeamPanel.Projects

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    project = Projects.get_project!(id)

    socket =
      socket
      |> assign(
        project: project,
        page_title: "Логи · #{project.name}",
        following: false,
        filter: "",
        task: nil,
        lines: []
      )
      |> stream_configure(:log, dom_id: fn _ -> "log-#{System.unique_integer([:positive])}" end)
      |> stream(:log, [])

    {:ok, if(connected?(socket), do: load_tail(socket), else: socket)}
  end

  defp load_tail(socket) do
    {:ok, text} = Projects.logs(socket.assigns.project, 300)

    lines =
      text
      |> String.split(~r/\r?\n/)
      |> Enum.reject(&(String.trim(&1) == ""))

    socket
    |> assign(:lines, lines)
    |> stream(:log, lines, reset: true)
  end

  ## ------------------------------------------------------------------ events

  @impl true
  def handle_event("reload", _params, socket), do: {:noreply, load_tail(socket)}

  def handle_event("toggle_follow", _params, socket) do
    if socket.assigns.following do
      stop_follow(socket.assigns.task)
      {:noreply, assign(socket, following: false, task: nil)}
    else
      {:noreply, assign(socket, following: true, task: start_follow(socket))}
    end
  end

  def handle_event("filter", %{"filter" => filter}, socket) do
    filtered =
      if filter == "" do
        socket.assigns.lines
      else
        Enum.filter(
          socket.assigns.lines,
          &String.contains?(String.downcase(&1), String.downcase(filter))
        )
      end

    {:noreply, socket |> assign(:filter, filter) |> stream(:log, filtered, reset: true)}
  end

  def handle_event("clear", _params, socket) do
    {:noreply, socket |> assign(:lines, []) |> stream(:log, [], reset: true)}
  end

  @impl true
  def handle_info({:log_line, line}, socket) do
    line = String.trim_trailing(line)

    if line == "" or (socket.assigns.filter != "" and not matches?(line, socket.assigns.filter)) do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:lines, Enum.take([line | socket.assigns.lines], 2000))
       |> stream_insert(:log, line)}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket), do: stop_follow(socket.assigns[:task])

  defp matches?(line, filter),
    do: String.contains?(String.downcase(line), String.downcase(filter))

  defp start_follow(socket) do
    parent = self()
    project = socket.assigns.project

    {:ok, pid} =
      Task.Supervisor.start_child(BeamPanel.TaskSupervisor, fn ->
        Projects.follow_logs(project, fn line -> send(parent, {:log_line, line}) end)
      end)

    pid
  end

  defp stop_follow(nil), do: :ok

  defp stop_follow(pid) when is_pid(pid) do
    Process.exit(pid, :kill)
    :ok
  end

  ## ------------------------------------------------------------------ render

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header title="Журнал" subtitle={"#{@project.name} · #{@project.service_name}"}>
      <:breadcrumb>
        <ul>
          <li><.link navigate={~p"/projects"}>Проекты</.link></li>
          <li><.link navigate={~p"/projects/#{@project}"}>{@project.name}</.link></li>
          <li>Логи</li>
        </ul>
      </:breadcrumb>
      <:actions>
        <form phx-change="filter">
          <input
            type="text"
            name="filter"
            value={@filter}
            placeholder="Поиск в логе…"
            class="input input-sm input-bordered w-56"
            phx-debounce="300"
          />
        </form>
        <button class="btn btn-sm" phx-click="reload">
          <.icon name="hero-arrow-path" class="size-4" /> Обновить
        </button>
        <button class={["btn btn-sm", @following && "btn-primary"]} phx-click="toggle_follow">
          <.icon name={(@following && "hero-pause") || "hero-play"} class="size-4" />
          {(@following && "Остановить") || "Следить"}
        </button>
        <button class="btn btn-sm btn-ghost" phx-click="clear">Очистить</button>
      </:actions>
    </.page_header>

    <.log_console id="project-log" lines={@streams.log} class="h-[70vh]" />
    """
  end
end
