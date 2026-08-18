defmodule BeamPanelWeb.Nav do
  @moduledoc "LiveView hook that keeps `@current_path` in sync for sidebar highlighting."

  import Phoenix.LiveView
  import Phoenix.Component

  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> assign(:current_path, "/")
      |> attach_hook(:beam_panel_nav, :handle_params, &set_current_path/3)

    {:cont, socket}
  end

  defp set_current_path(_params, url, socket) do
    {:cont, assign(socket, :current_path, URI.parse(url).path || "/")}
  end
end
