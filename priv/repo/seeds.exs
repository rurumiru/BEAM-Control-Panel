# Seeds for BEAM Control Panel.
#
#     mix run priv/repo/seeds.exs
#
# Creates the initial administrator when the panel has no users yet. Credentials
# are taken from the environment so the same script works for local development
# and for automated installs:
#
#     BEAM_PANEL_ADMIN_EMAIL=admin@example.com \
#     BEAM_PANEL_ADMIN_PASSWORD='a-long-password' \
#     mix run priv/repo/seeds.exs
#
# The local ("main") server row is created automatically at boot, but we also
# ensure it here so a freshly seeded database is immediately usable.

alias BeamPanel.{Accounts, Servers}

email = System.get_env("BEAM_PANEL_ADMIN_EMAIL", "admin@localhost")

password =
  System.get_env("BEAM_PANEL_ADMIN_PASSWORD") ||
    :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)

if Accounts.count_users() == 0 do
  case Accounts.create_root_user(%{
         "email" => email,
         "name" => "Administrator",
         "password" => password
       }) do
    {:ok, user} ->
      IO.puts("""

      ╭──────────────────────────────────────────────────────────────╮
      │  Администратор создан                                        │
      ╰──────────────────────────────────────────────────────────────╯
        e-mail:  #{user.email}
        пароль:  #{password}

        Смените пароль после первого входа: /settings
      """)

    {:error, changeset} ->
      IO.puts("Не удалось создать администратора:")
      IO.inspect(changeset.errors)
  end
else
  IO.puts("Пользователи уже существуют — создание администратора пропущено.")
end

server = Servers.ensure_main_server!()
IO.puts("Основной сервер: #{server.name} (#{server.hostname})")
