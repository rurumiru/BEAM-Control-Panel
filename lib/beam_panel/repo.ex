defmodule BeamPanel.Repo do
  use Ecto.Repo,
    otp_app: :beam_panel,
    adapter: Ecto.Adapters.Postgres
end
