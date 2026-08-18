defmodule BeamPanelWeb.ServerLive.Provision do
  @moduledoc "Installs the BEAM toolchain and supporting software on a server."

  use BeamPanelWeb, :live_view

  alias BeamPanel.{Servers, Provision, Accounts}
  alias BeamPanel.Provision.Playbook

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    server = Servers.get_server!(id)

    {:ok,
     socket
     |> assign(
       server: server,
       page_title: "Установка ПО · #{server.name}",
       components: Playbook.default_components(),
       options: default_options(server),
       runs: Provision.list_runs(server.id),
       preview: nil
     )}
  end

  defp default_options(server) do
    %{
      "otp_version" => "27",
      "elixir_version" => "1.18.4",
      "node_version" => "22",
      "postgres_version" => "16",
      "deploy_user" => server.deploy_user || "deploy",
      "deploy_root" => server.deploy_root || "/opt/beam",
      "db_name" => "beam_app",
      "db_user" => "beam_app",
      "db_password" => "",
      "swap_size" => "2G",
      "ssh_port" => to_string(server.ssh_port || 22)
    }
  end

  ## ------------------------------------------------------------------ events

  @impl true
  def handle_event("toggle", %{"key" => key}, socket) do
    components =
      if key in socket.assigns.components do
        List.delete(socket.assigns.components, key)
      else
        socket.assigns.components ++ [key]
      end

    {:noreply, assign(socket, components: components, preview: nil)}
  end

  def handle_event("update_options", %{"options" => options}, socket) do
    {:noreply, assign(socket, options: Map.merge(socket.assigns.options, options), preview: nil)}
  end

  def handle_event("preview", _params, socket) do
    script = Provision.preview(socket.assigns.components, socket.assigns.options)
    {:noreply, assign(socket, :preview, script)}
  end

  def handle_event("close_preview", _params, socket),
    do: {:noreply, assign(socket, :preview, nil)}

  def handle_event("run", _params, socket) do
    cond do
      not Accounts.can?(socket.assigns.current_user, :operator) ->
        {:noreply, put_flash(socket, :error, "Недостаточно прав.")}

      socket.assigns.components == [] ->
        {:noreply, put_flash(socket, :error, "Выберите хотя бы один компонент.")}

      true ->
        case Provision.provision(
               socket.assigns.server,
               socket.assigns.components,
               socket.assigns.options,
               socket.assigns.current_user
             ) do
          {:ok, run} ->
            {:noreply, push_navigate(socket, to: ~p"/provisioning/#{run.id}")}

          {:error, :already_running} ->
            {:noreply, put_flash(socket, :error, "Провижининг этого сервера уже выполняется.")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Не удалось запустить: #{inspect(reason)}")}
        end
    end
  end

  ## ------------------------------------------------------------------ render

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header
      title="Установка ПО"
      subtitle={"#{@server.name} · #{@server.facts["os_pretty"] || "ОС не определена"}"}
    >
      <:breadcrumb>
        <ul>
          <li><.link navigate={~p"/servers"}>Серверы</.link></li>
          <li><.link navigate={~p"/servers/#{@server}"}>{@server.name}</.link></li>
          <li>Установка</li>
        </ul>
      </:breadcrumb>
      <:actions>
        <button class="btn btn-sm" phx-click="preview">
          <.icon name="hero-code-bracket" class="size-4" /> Показать скрипт
        </button>
        <button
          class="btn btn-sm btn-primary"
          phx-click="run"
          phx-disable-with="Запускаем…"
        >
          <.icon name="hero-play" class="size-4" /> Запустить установку
        </button>
      </:actions>
    </.page_header>

    <div class="alert alert-info mb-4 text-sm">
      <.icon name="hero-information-circle" class="size-5" />
      <span>
        Скрипт рассчитан на чистый <strong>Ubuntu 24.04 / 26.04</strong>, идемпотентен
        и безопасен при повторном запуске. Все действия выполняются через sudo.
      </span>
    </div>

    <div class="grid gap-6 lg:grid-cols-3">
      <div class="lg:col-span-2">
        <.card title="Компоненты">
          <div class="grid gap-2 sm:grid-cols-2">
            <label
              :for={component <- Playbook.components()}
              class={[
                "flex cursor-pointer items-start gap-3 rounded-box border p-3 transition",
                (component.key in @components && "border-primary bg-primary/5") || "border-base-300"
              ]}
            >
              <input
                type="checkbox"
                class="checkbox checkbox-sm mt-0.5"
                checked={component.key in @components}
                phx-click="toggle"
                phx-value-key={component.key}
              />
              <span class="min-w-0">
                <span class="block text-sm font-medium">{component.name}</span>
                <span class="block text-xs text-base-content/60">{component.description}</span>
              </span>
            </label>
          </div>
        </.card>

        <.card title="История запусков" class="mt-6">
          <.empty_state
            :if={@runs == []}
            title="Установок ещё не было"
            icon="hero-clock"
          />

          <ul :if={@runs != []} class="divide-y divide-base-300">
            <li :for={run <- @runs} class="flex items-center justify-between gap-3 py-2">
              <div class="min-w-0">
                <.link
                  navigate={~p"/provisioning/#{run.id}"}
                  class="link link-hover text-sm font-medium"
                >
                  {Enum.join(run.components, ", ")}
                </.link>
                <div class="text-xs text-base-content/50">
                  {relative(run.inserted_at)} · {(run.user && run.user.email) || "система"}
                </div>
              </div>
              <.status_badge status={run.status} />
            </li>
          </ul>
        </.card>
      </div>

      <div>
        <.card title="Параметры">
          <form phx-change="update_options" class="space-y-3">
            <label class="form-control">
              <span class="label-text text-xs">Версия Erlang/OTP</span>
              <input
                type="text"
                name="options[otp_version]"
                value={@options["otp_version"]}
                class="input input-sm input-bordered"
              />
            </label>
            <label class="form-control">
              <span class="label-text text-xs">Версия Elixir</span>
              <input
                type="text"
                name="options[elixir_version]"
                value={@options["elixir_version"]}
                class="input input-sm input-bordered"
              />
            </label>
            <label class="form-control">
              <span class="label-text text-xs">Версия Node.js</span>
              <input
                type="text"
                name="options[node_version]"
                value={@options["node_version"]}
                class="input input-sm input-bordered"
              />
            </label>
            <label class="form-control">
              <span class="label-text text-xs">Пользователь деплоя</span>
              <input
                type="text"
                name="options[deploy_user]"
                value={@options["deploy_user"]}
                class="input input-sm input-bordered"
              />
            </label>
            <label class="form-control">
              <span class="label-text text-xs">Каталог деплоя</span>
              <input
                type="text"
                name="options[deploy_root]"
                value={@options["deploy_root"]}
                class="input input-sm input-bordered"
              />
            </label>

            <div class="divider my-1 text-xs">PostgreSQL</div>

            <label class="form-control">
              <span class="label-text text-xs">База данных</span>
              <input
                type="text"
                name="options[db_name]"
                value={@options["db_name"]}
                class="input input-sm input-bordered"
              />
            </label>
            <label class="form-control">
              <span class="label-text text-xs">Пользователь БД</span>
              <input
                type="text"
                name="options[db_user]"
                value={@options["db_user"]}
                class="input input-sm input-bordered"
              />
            </label>
            <label class="form-control">
              <span class="label-text text-xs">Пароль БД (пусто — сгенерировать)</span>
              <input
                type="text"
                name="options[db_password]"
                value={@options["db_password"]}
                class="input input-sm input-bordered"
              />
            </label>

            <div class="divider my-1 text-xs">Прочее</div>

            <label class="form-control">
              <span class="label-text text-xs">Размер swap</span>
              <input
                type="text"
                name="options[swap_size]"
                value={@options["swap_size"]}
                class="input input-sm input-bordered"
              />
            </label>
            <label class="form-control">
              <span class="label-text text-xs">Порт SSH для firewall</span>
              <input
                type="text"
                name="options[ssh_port]"
                value={@options["ssh_port"]}
                class="input input-sm input-bordered"
              />
            </label>
          </form>
        </.card>
      </div>
    </div>

    <.modal
      :if={@preview}
      id="preview-modal"
      show
      title="Сгенерированный скрипт"
      on_cancel={JS.push("close_preview")}
    >
      <pre class="max-h-[60vh] overflow-auto rounded-box bg-neutral p-4 font-mono text-xs text-neutral-content"><code>{@preview}</code></pre>
    </.modal>
    """
  end
end
