defmodule BeamPanel.Encrypted.Binary do
  @moduledoc "Ecto type for encrypted binary/text columns."
  use Cloak.Ecto.Binary, vault: BeamPanel.Vault
end

defmodule BeamPanel.Encrypted.Map do
  @moduledoc "Ecto type for encrypted map columns (serialised as JSON before encryption)."
  use Cloak.Ecto.Map, vault: BeamPanel.Vault
end
