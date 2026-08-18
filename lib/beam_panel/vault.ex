defmodule BeamPanel.Vault do
  @moduledoc """
  Cloak vault used to encrypt every secret the panel stores: SSH private keys,
  SSH passwords, Erlang distribution cookies and project environment variables.

  The key is read (in order of priority) from:

    1. the `BEAM_PANEL_CLOAK_KEY` environment variable (base64 encoded, 32 bytes)
    2. the `:key` value configured for `#{inspect(__MODULE__)}` in config files
    3. a deterministic development key — **never** used when `MIX_ENV=prod`

  Generate a production key with:

      mix beam_panel.gen.secrets
  """

  use Cloak.Vault, otp_app: :beam_panel

  # exactly 32 bytes — AES-256 requires it; production keys come from the env
  @dev_key "beam-panel-development-key-32byt"

  @impl GenServer
  def init(config) do
    key = resolve_key(config)

    config =
      Keyword.put(config, :ciphers,
        default: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: key, iv_length: 12}
      )

    {:ok, config}
  end

  defp resolve_key(config) do
    with nil <- env_key(),
         nil <- Keyword.get(config, :key) do
      if Application.get_env(:beam_panel, :env) == :prod do
        raise """
        BEAM_PANEL_CLOAK_KEY is not set.

        Generate one with:

            openssl rand -base64 32

        and expose it to the release as BEAM_PANEL_CLOAK_KEY.
        """
      else
        @dev_key
      end
    end
  end

  defp env_key do
    case System.get_env("BEAM_PANEL_CLOAK_KEY") do
      nil ->
        nil

      value ->
        case Base.decode64(value) do
          {:ok, <<key::binary-size(32)>>} ->
            key

          {:ok, other} ->
            raise "BEAM_PANEL_CLOAK_KEY must decode to 32 bytes, got #{byte_size(other)}"

          :error ->
            raise "BEAM_PANEL_CLOAK_KEY must be valid base64"
        end
    end
  end
end
