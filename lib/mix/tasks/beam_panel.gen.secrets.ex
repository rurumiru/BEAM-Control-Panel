defmodule Mix.Tasks.BeamPanel.Gen.Secrets do
  @shortdoc "Generates the secrets required to run the panel in production"

  @moduledoc """
  Prints (or writes) `SECRET_KEY_BASE` and `BEAM_PANEL_CLOAK_KEY`.

      mix beam_panel.gen.secrets
      mix beam_panel.gen.secrets --output .env
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _argv, _} = OptionParser.parse(args, strict: [output: :string])

    secret_key_base = :crypto.strong_rand_bytes(64) |> Base.encode64()
    cloak_key = :crypto.strong_rand_bytes(32) |> Base.encode64()

    content = """
    SECRET_KEY_BASE=#{secret_key_base}
    BEAM_PANEL_CLOAK_KEY=#{cloak_key}
    """

    case opts[:output] do
      nil ->
        Mix.shell().info("\n" <> content)

      path ->
        File.write!(path, content, [:append])
        File.chmod(path, 0o600)
        Mix.shell().info("Секреты дописаны в #{path} (права 0600)")
    end

    Mix.shell().info("""
    BEAM_PANEL_CLOAK_KEY шифрует SSH-ключи, cookie и переменные окружения проектов.
    Потеря ключа делает эти данные нечитаемыми — храните его вместе с бэкапами.
    """)
  end
end
