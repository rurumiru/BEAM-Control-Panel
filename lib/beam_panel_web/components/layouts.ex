defmodule BeamPanelWeb.Layouts do
  @moduledoc """
  Application shell: a persistent sidebar with the main sections, a top bar with
  the current user, and the flash group.
  """
  use BeamPanelWeb, :html

  embed_templates "layouts/*"

  @nav [
    %{path: "/", label: "Обзор", icon: "hero-squares-2x2", match: :exact},
    %{path: "/servers", label: "Серверы", icon: "hero-server-stack", match: :prefix},
    %{path: "/projects", label: "Проекты", icon: "hero-cube", match: :prefix},
    %{path: "/deployments", label: "Деплои", icon: "hero-rocket-launch", match: :prefix},
    %{path: "/cluster", label: "Кластер", icon: "hero-share", match: :prefix},
    %{path: "/audit", label: "Аудит", icon: "hero-clipboard-document-list", match: :prefix},
    %{path: "/settings", label: "Настройки", icon: "hero-cog-6-tooth", match: :prefix}
  ]

  attr :flash, :map, required: true
  attr :current_user, :map, default: nil
  attr :current_scope, :map, default: nil
  attr :current_path, :string, default: "/"
  attr :inner_content, :any, default: nil

  def app(assigns) do
    assigns = assign_new(assigns, :nav, fn -> @nav end)

    ~H"""
    <div class="drawer lg:drawer-open min-h-screen bg-base-200">
      <input id="panel-drawer" type="checkbox" class="drawer-toggle" />
      <div class="drawer-content flex min-h-screen flex-col">
        <header class="navbar sticky top-0 z-30 border-b border-base-300 bg-base-100/95 backdrop-blur px-4">
          <div class="flex-none lg:hidden">
            <label for="panel-drawer" class="btn btn-square btn-ghost btn-sm" aria-label="Меню">
              <.icon name="hero-bars-3" class="size-5" />
            </label>
          </div>
          
          <div class="flex-1 min-w-0">
            <span class="text-sm font-semibold tracking-tight lg:hidden">BEAM Control Panel</span>
          </div>
          
          <div class="flex-none flex items-center gap-2">
            <.theme_toggle />
            <div :if={@current_user} class="dropdown dropdown-end">
              <button tabindex="0" class="btn btn-ghost btn-sm gap-2">
                <.icon name="hero-user-circle" class="size-5" />
                <span class="hidden sm:inline max-w-40 truncate">{@current_user.email}</span>
              </button>
              
              <ul
                tabindex="0"
                class="dropdown-content menu z-40 mt-2 w-56 rounded-box border border-base-300 bg-base-100 p-2 shadow"
              >
                <li class="menu-title text-xs">
                  {@current_user.name || @current_user.email} · {role_label(@current_user.role)}
                </li>
                
                <li><.link navigate={~p"/settings"}>Профиль и 2FA</.link></li>
                
                <li><.link navigate={~p"/settings/tokens"}>API-токены</.link></li>
                
                <li>
                  <.link href={~p"/logout"} method="delete" class="text-error">Выйти</.link>
                </li>
              </ul>
            </div>
          </div>
        </header>
        
        <main class="flex-1 px-4 py-6 sm:px-6 lg:px-8">
          <div class="mx-auto w-full max-w-7xl">
            {@inner_content}
          </div>
        </main>
        
        <footer class="border-t border-base-300 px-6 py-3 text-xs text-base-content/50">
          BEAM Control Panel · Elixir {System.version()} · OTP {:erlang.system_info(:otp_release)}
        </footer>
      </div>
      
      <div class="drawer-side z-40">
        <label for="panel-drawer" class="drawer-overlay" aria-label="Закрыть меню"></label>
        <aside class="flex min-h-full w-64 flex-col border-r border-base-300 bg-base-100">
          <div class="flex items-center gap-2 border-b border-base-300 px-4 py-4">
            <span class="flex size-9 items-center justify-center rounded-box bg-primary/10 text-primary">
              <.icon name="hero-bolt" class="size-5" />
            </span>
            
            <div class="min-w-0">
              <p class="text-sm font-semibold leading-tight">BEAM Control</p>
              
              <p class="text-xs text-base-content/50 leading-tight">Panel</p>
            </div>
          </div>
          
          <ul class="menu menu-sm flex-1 gap-0.5 p-3">
            <li :for={item <- @nav}>
              <.link
                navigate={item.path}
                class={["gap-3", nav_active?(@current_path, item) && "menu-active font-semibold"]}
              >
                <.icon name={item.icon} class="size-4" /> {item.label}
              </.link>
            </li>
          </ul>
          
          <div class="border-t border-base-300 p-3 text-xs text-base-content/50">
            <.link
              href="https://github.com/rurumiru/BEAM-Control-Panel"
              target="_blank"
              class="link link-hover"
            >
              Документация
            </.link>
          </div>
        </aside>
      </div>
    </div>
     <.flash_group flash={@flash} />
    """
  end

  @doc "Minimal centred layout for login and setup screens."
  attr :flash, :map, required: true
  attr :title, :string, default: "BEAM Control Panel"
  attr :subtitle, :string, default: nil
  slot :inner_block, required: true

  def auth(assigns) do
    ~H"""
    <div class="flex min-h-screen items-center justify-center bg-base-200 px-4 py-10">
      <div class="w-full max-w-md">
        <div class="mb-6 flex flex-col items-center gap-2 text-center">
          <span class="flex size-12 items-center justify-center rounded-box bg-primary/10 text-primary">
            <.icon name="hero-bolt" class="size-6" />
          </span>
          
          <h1 class="text-xl font-semibold">{@title}</h1>
          
          <p :if={@subtitle} class="text-sm text-base-content/60">{@subtitle}</p>
        </div>
        
        <div class="rounded-box border border-base-300 bg-base-100 p-6 shadow-sm">
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
     <.flash_group flash={@flash} />
    """
  end

  defp nav_active?(current_path, %{path: "/", match: :exact}), do: current_path in ["/", ""]

  defp nav_active?(current_path, %{path: path}),
    do: current_path == path or String.starts_with?(current_path || "", path <> "/")

  defp role_label("admin"), do: "администратор"
  defp role_label("operator"), do: "оператор"
  defp role_label("viewer"), do: "наблюдатель"
  defp role_label(other), do: to_string(other)

  attr :flash, :map, required: true
  attr :id, :string, default: "flash-group"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} /> <.flash kind={:error} flash={@flash} />
      <.flash
        id="client-error"
        kind={:error}
        title="Нет соединения"
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Переподключение… <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
      
      <.flash
        id="server-error"
        kind={:error}
        title="Что-то пошло не так"
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Переподключение… <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc "Light / dark / system theme switch."
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative hidden flex-row items-center rounded-full border-2 border-base-300 bg-base-300 sm:flex">
      <div class="absolute left-0 h-full w-1/3 rounded-full border-1 border-base-200 bg-base-100 brightness-200 transition-[left] [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0" />
      <button
        class="flex w-1/3 cursor-pointer p-2"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        aria-label="Системная тема"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
      
      <button
        class="flex w-1/3 cursor-pointer p-2"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        aria-label="Светлая тема"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
      
      <button
        class="flex w-1/3 cursor-pointer p-2"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        aria-label="Тёмная тема"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
