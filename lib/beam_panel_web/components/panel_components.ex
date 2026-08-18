defmodule BeamPanelWeb.PanelComponents do
  @moduledoc "Reusable building blocks for the control panel UI."

  use Phoenix.Component
  use BeamPanelWeb, :verified_routes

  import BeamPanelWeb.Format

  alias Phoenix.LiveView.JS

  @doc "Heroicon rendered through the Tailwind plugin (kept local to avoid an import cycle)."
  attr :name, :string, required: true
  attr :class, :string, default: "size-4"
  attr :rest, :global

  def panel_icon(assigns) do
    ~H"""
    <span class={[@name, @class]} {@rest} />
    """
  end

  @doc "Page header with title, subtitle and optional actions."
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  slot :actions
  slot :breadcrumb

  def page_header(assigns) do
    ~H"""
    <div class="flex flex-col gap-3 border-b border-base-300 pb-4 mb-6 sm:flex-row sm:items-end sm:justify-between">
      <div class="min-w-0">
        <div :if={@breadcrumb != []} class="text-xs breadcrumbs py-0 text-base-content/60">
          {render_slot(@breadcrumb)}
        </div>
        
        <h1 class="text-2xl font-semibold truncate">{@title}</h1>
        
        <p :if={@subtitle} class="text-sm text-base-content/60 mt-1">{@subtitle}</p>
      </div>
      
      <div :if={@actions != []} class="flex flex-wrap items-center gap-2">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  @doc "Compact metric tile."
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :hint, :string, default: nil
  attr :icon, :string, default: nil
  attr :tone, :string, default: "text-base-content"
  attr :progress, :any, default: nil

  def stat_tile(assigns) do
    ~H"""
    <div class="rounded-box border border-base-300 bg-base-100 p-4">
      <div class="flex items-center justify-between gap-2">
        <span class="text-xs uppercase tracking-wide text-base-content/60">{@label}</span>
        <.panel_icon :if={@icon} name={@icon} class="size-4 opacity-50" />
      </div>
      
      <div class={["mt-2 text-2xl font-semibold tabular-nums", @tone]}>{@value}</div>
      
      <div :if={@hint} class="mt-1 text-xs text-base-content/50">{@hint}</div>
      
      <progress
        :if={is_number(@progress)}
        class={["progress mt-3 h-1.5 w-full", progress_class(@progress)]}
        value={@progress}
        max="100"
      ></progress>
    </div>
    """
  end

  @doc "Status badge."
  attr :status, :string, required: true
  attr :class, :string, default: nil

  def status_badge(assigns) do
    ~H"""
    <span class={["badge badge-sm whitespace-nowrap", status_class(@status), @class]}>
      {status_label(@status)}
    </span>
    """
  end

  @doc "Card with a title bar."
  attr :title, :string, default: nil
  attr :class, :string, default: nil
  slot :actions
  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <section class={["rounded-box border border-base-300 bg-base-100", @class]}>
      <header
        :if={@title || @actions != []}
        class="flex items-center justify-between gap-2 border-b border-base-300 px-4 py-3"
      >
        <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/70">{@title}</h2>
        
        <div class="flex items-center gap-2">{render_slot(@actions)}</div>
      </header>
      
      <div class="p-4">{render_slot(@inner_block)}</div>
    </section>
    """
  end

  @doc "Empty-state placeholder."
  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :icon, :string, default: "hero-inbox"
  slot :actions

  def empty_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center gap-2 py-12 text-center">
      <.panel_icon name={@icon} class="size-10 opacity-30" />
      <p class="font-medium">{@title}</p>
      
      <p :if={@description} class="max-w-md text-sm text-base-content/60">{@description}</p>
      
      <div :if={@actions != []} class="mt-3 flex gap-2">{render_slot(@actions)}</div>
    </div>
    """
  end

  @doc "Terminal-style log viewer with autoscroll."
  attr :id, :string, required: true
  attr :lines, :list, required: true
  attr :class, :string, default: "h-96"
  attr :follow, :boolean, default: true

  def log_console(assigns) do
    ~H"""
    <div
      id={@id}
      phx-update="stream"
      phx-hook={@follow && "LogScroll"}
      class={[
        "overflow-y-auto rounded-box bg-neutral p-3 font-mono text-xs leading-relaxed text-neutral-content",
        @class
      ]}
    >
      <div :for={{dom_id, line} <- @lines} id={dom_id} class={log_line_class(line)}>
        {line}
      </div>
    </div>
    """
  end

  defp log_line_class(line) do
    cond do
      String.starts_with?(line, "✗") -> "text-error"
      String.starts_with?(line, "✓") -> "text-success"
      String.starts_with?(line, "▸") -> "text-info font-semibold"
      String.starts_with?(line, "↩") -> "text-warning"
      String.starts_with?(line, "──") -> "text-primary font-semibold"
      String.contains?(line, "==>") -> "text-info"
      true -> ""
    end
  end

  @doc "Sparkline rendered as inline SVG from a list of numbers."
  attr :values, :list, required: true
  attr :class, :string, default: "h-10 w-full"
  attr :color, :string, default: "currentColor"

  def sparkline(assigns) do
    values = Enum.map(assigns.values, &to_number/1)
    max = Enum.max([1.0 | values])
    count = max(length(values), 2)

    points =
      values
      |> Enum.with_index()
      |> Enum.map_join(" ", fn {value, index} ->
        x = index / (count - 1) * 100
        y = 100 - value / max * 100
        "#{Float.round(x, 2)},#{Float.round(y, 2)}"
      end)

    assigns = assign(assigns, points: points, has_data: values != [])

    ~H"""
    <svg viewBox="0 0 100 100" preserveAspectRatio="none" class={@class}>
      <polyline
        :if={@has_data}
        points={@points}
        fill="none"
        stroke={@color}
        stroke-width="2"
        vector-effect="non-scaling-stroke"
      />
    </svg>
    """
  end

  defp to_number(value) when is_number(value), do: value * 1.0
  defp to_number(_), do: 0.0

  @doc "Key/value definition row."
  attr :label, :string, required: true
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def kv(assigns) do
    ~H"""
    <div class={["flex items-start justify-between gap-4 py-1.5 text-sm", @class]}>
      <dt class="shrink-0 text-base-content/60">{@label}</dt>
      
      <dd class="min-w-0 text-right font-medium break-all">{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  @doc "Confirmation-guarded danger button."
  attr :confirm, :string, required: true
  attr :rest, :global, include: ~w(phx-click phx-value-id phx-target disabled)
  attr :class, :string, default: "btn btn-sm btn-error btn-outline"
  slot :inner_block, required: true

  def danger_button(assigns) do
    ~H"""
    <button class={@class} data-confirm={@confirm} {@rest}>{render_slot(@inner_block)}</button>
    """
  end

  @doc "Modal dialog driven by a `show` boolean."
  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :on_cancel, JS, default: %JS{}
  attr :title, :string, default: nil
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div
      :if={@show}
      id={@id}
      class="modal modal-open"
      phx-window-keydown={@on_cancel}
      phx-key="escape"
    >
      <div class="modal-box max-w-3xl">
        <div class="flex items-start justify-between gap-4">
          <h3 :if={@title} class="text-lg font-semibold">{@title}</h3>
          
          <button
            class="btn btn-sm btn-circle btn-ghost"
            phx-click={@on_cancel}
            aria-label="Закрыть"
          >
            ✕
          </button>
        </div>
        
        <div class="mt-4">{render_slot(@inner_block)}</div>
      </div>
      
      <div class="modal-backdrop" phx-click={@on_cancel}></div>
    </div>
    """
  end
end
