defmodule Mix.Tasks.BeamPanel.Gen.Bootstrap do
  @shortdoc "Renders the node bootstrap script for a clean Ubuntu server"

  @moduledoc """
  Writes `scripts/bootstrap-node.sh` — the same playbook the panel executes over
  SSH, exported so it can be run by hand on a fresh Ubuntu 24.04 / 26.04 host.

      mix beam_panel.gen.bootstrap
      mix beam_panel.gen.bootstrap --output /tmp/bootstrap.sh --components base,erlang,elixir
      mix beam_panel.gen.bootstrap --all
  """

  use Mix.Task

  alias BeamPanel.Provision.Playbook

  @impl Mix.Task
  def run(args) do
    {opts, _argv, _} =
      OptionParser.parse(args,
        strict: [
          output: :string,
          components: :string,
          all: :boolean,
          otp: :string,
          elixir: :string
        ]
      )

    components =
      cond do
        opts[:all] -> Enum.map(Playbook.components(), & &1.key)
        opts[:components] -> String.split(opts[:components], ",", trim: true)
        true -> Playbook.default_components() ++ ["postgres", "nginx", "firewall", "fail2ban"]
      end

    playbook_opts = %{
      "otp_version" => opts[:otp] || "27",
      "elixir_version" => opts[:elixir] || "1.18.4",
      # generated at run time on the target host rather than baked into the file
      "db_password" => ~S{$(openssl rand -base64 24 | tr -d '\n=+/')}
    }

    output = opts[:output] || "scripts/bootstrap-node.sh"
    script = Playbook.render(components, playbook_opts)

    File.mkdir_p!(Path.dirname(output))
    File.write!(output, script)
    File.chmod(output, 0o755)

    Mix.shell().info("""
    Скрипт записан: #{output}
    Компоненты: #{Enum.join(components, ", ")}

    Использование на целевом сервере:

        scp #{output} root@host:/tmp/bootstrap.sh
        ssh root@host 'bash /tmp/bootstrap.sh'
    """)
  end
end
