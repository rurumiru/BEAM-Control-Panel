defmodule BeamPanelWeb.Api.StatusController do
  @moduledoc "Panel health and summary."

  use BeamPanelWeb, :controller

  alias BeamPanel.{Servers, Projects, Deploy}

  def show(conn, _params) do
    json(conn, %{
      status: "ok",
      version: to_string(Application.spec(:beam_panel, :vsn)),
      elixir: System.version(),
      otp: to_string(:erlang.system_info(:otp_release)),
      servers: Servers.count_by_status(),
      projects: Projects.count_by_status(),
      deployments_7d: Deploy.stats(7),
      user: conn.assigns.current_user.email,
      scopes: conn.assigns.api_token.scopes
    })
  end
end
