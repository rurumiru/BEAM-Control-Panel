defmodule BeamPanelWeb.ServerLive.Discover do
  @moduledoc "Finds BEAM applications already deployed on a server and imports them."

  use BeamPanelWeb, :live_view

  alias BeamPanel.{Servers, Projects, Accounts, Audit}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    server = Servers.get_server!(id)

    socket =
      assign(socket,
        server: server,
        page_title: "Поиск проектов · #{server.name}",
        candidates: [],
        scanning: false,
        scanned: false,
        error: nil
      )

    {:ok, if(connected?(socket), do: start_scan(socket), else: socket)}
  end

  defp start_scan(socket) do
    server = socket.assigns.server
    parent = self()

    Task.Supervisor.start_child(BeamPanel.TaskSupervisor, fn ->
      send(parent, {:scan_result, Projects.discover(server)})
    end)

    assign(socket, scanning: true, error: nil)
  end

  @impl true
  def handle_event("rescan", _params, socket), do: {:noreply, start_scan(socket)}

  def handle_event("import", %{"slug" => slug}, socket) do
    if Accounts.can?(socket.assigns.current_user, :operator) do
      candidate = Enum.find(socket.assigns.candidates, &(&1.slug == slug))

      case candidate && Projects.import_candidate(socket.assigns.server, candidate) do
        {:ok, project} ->
          Audit.log(socket.assigns.current_user, "project.import",
            resource_type: "project",
            resource_id: project.id,
            metadata: %{server: socket.assigns.server.name, slug: slug}
          )

          candidates =
            Enum.map(socket.assigns.candidates, fn c ->
              if c.slug == slug, do: Map.put(c, :registered, true), else: c
            end)

          {:noreply,
           socket
           |> assign(:candidates, candidates)
           |> put_flash(:info, "Проект «#{project.name}» добавлен.")}

        {:error, changeset} ->
          {:noreply, put_flash(socket, :error, "Не удалось добавить: #{errors(changeset)}")}

        nil ->
          {:noreply, put_flash(socket, :error, "Кандидат не найден.")}
      end
    else
      {:noreply, put_flash(socket, :error, "Недостаточно прав.")}
    end
  end

  def handle_event("import_all", _params, socket) do
    if Accounts.can?(socket.assigns.current_user, :operator) do
      imported =
        socket.assigns.candidates
        |> Enum.reject(& &1.registered)
        |> Enum.count(fn candidate ->
          match?({:ok, _}, Projects.import_candidate(socket.assigns.server, candidate))
        end)

      candidates = Enum.map(socket.assigns.candidates, &Map.put(&1, :registered, true))

      {:noreply,
       socket
       |> assign(:candidates, candidates)
       |> put_flash(:info, "Добавлено проектов: #{imported}")}
    else
      {:noreply, put_flash(socket, :error, "Недостаточно прав.")}
    end
  end

  @impl true
  def handle_info({:scan_result, {:ok, candidates}}, socket) do
    {:noreply, assign(socket, candidates: candidates, scanning: false, scanned: true)}
  end

  def handle_info({:scan_result, {:error, reason}}, socket) do
    {:noreply, assign(socket, scanning: false, scanned: true, error: reason)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header title="Поиск BEAM-проектов" subtitle={@server.name}>
      <:breadcrumb>
        <ul>
          <li><.link navigate={~p"/servers"}>Серверы</.link></li>
          <li><.link navigate={~p"/servers/#{@server}"}>{@server.name}</.link></li>
          <li>Поиск</li>
        </ul>
      </:breadcrumb>
      <:actions>
        <button class="btn btn-sm" phx-click="rescan" disabled={@scanning}>
          <.icon name="hero-arrow-path" class={["size-4", @scanning && "animate-spin"]} /> Сканировать
        </button>
        <button
          :if={Enum.any?(@candidates, &(!&1.registered))}
          class="btn btn-sm btn-primary"
          phx-click="import_all"
        >
          Добавить все
        </button>
      </:actions>
    </.page_header>

    <div class="alert alert-info mb-4 text-sm">
      <.icon name="hero-information-circle" class="size-5" />
      <span>
        Панель ищет systemd-юниты с релизами, каталоги с <code>mix.exs</code>
        или <code>rebar.config</code>, а также запущенные процессы <code>beam.smp</code>.
      </span>
    </div>

    <div :if={@error} class="alert alert-error mb-4 text-sm">
      <.icon name="hero-x-circle" class="size-5" />
      <span>{@error}</span>
    </div>

    <div
      :if={@scanning}
      class="flex items-center gap-3 rounded-box border border-base-300 bg-base-100 p-6"
    >
      <span class="loading loading-spinner loading-md"></span>
      <span class="text-sm">Сканируем сервер — это может занять до минуты…</span>
    </div>

    <.empty_state
      :if={not @scanning and @scanned and @candidates == []}
      title="BEAM-приложения не найдены"
      description="Похоже, на сервере пока нет развёрнутых Elixir/Erlang приложений. Создайте проект вручную и выполните деплой."
      icon="hero-magnifying-glass"
    >
      <:actions>
        <.link navigate={~p"/projects/new"} class="btn btn-sm btn-primary">Создать проект</.link>
      </:actions>
    </.empty_state>

    <div :if={@candidates != []} class="grid gap-4 md:grid-cols-2">
      <div
        :for={candidate <- @candidates}
        class="rounded-box border border-base-300 bg-base-100 p-4"
      >
        <div class="flex items-start justify-between gap-2">
          <div class="min-w-0">
            <p class="font-semibold">{candidate.name}</p>
            <p class="truncate text-xs text-base-content/50">{candidate.deploy_path}</p>
          </div>
          <span :if={candidate.registered} class="badge badge-sm badge-success">добавлен</span>
        </div>

        <div class="mt-2 flex flex-wrap gap-1">
          <span class="badge badge-xs badge-outline">{candidate.kind}</span>
          <span :for={source <- candidate.sources} class="badge badge-xs badge-ghost">
            {source_label(source)}
          </span>
          <.status_badge :if={candidate.status != "unknown"} status={candidate.status} />
        </div>

        <dl class="mt-3">
          <.kv label="Служба">{candidate.service_name}</.kv>
          <.kv label="Релиз">{candidate.release_name}</.kv>
          <.kv :if={candidate.node_name} label="Нода">{candidate.node_name}</.kv>
          <.kv :if={candidate.repo_url} label="Репозиторий">
            {truncate(candidate.repo_url, 40)}
          </.kv>
          <.kv :if={candidate.pid} label="PID">{candidate.pid}</.kv>
        </dl>

        <button
          :if={!candidate.registered}
          class="btn btn-sm btn-primary btn-block mt-3"
          phx-click="import"
          phx-value-slug={candidate.slug}
        >
          Добавить в панель
        </button>
      </div>
    </div>
    """
  end

  defp source_label(:systemd), do: "systemd"
  defp source_label(:source_tree), do: "исходники"
  defp source_label(:process), do: "процесс"
  defp source_label(other), do: to_string(other)
end
