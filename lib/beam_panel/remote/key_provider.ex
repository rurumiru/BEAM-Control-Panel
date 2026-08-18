defmodule BeamPanel.Remote.KeyProvider do
  @moduledoc """
  `:ssh_client_key_api` callback module that serves the private key straight from
  memory, so SSH keys stored (encrypted) in the database never touch the disk.

  Supported formats:

    * OpenSSH (`-----BEGIN OPENSSH PRIVATE KEY-----`), unencrypted
    * PEM RSA / EC / DSA, optionally passphrase protected

  Host keys are accepted without verification — the panel connects to servers the
  operator explicitly registered, and pinning is handled at the network level.
  """

  @behaviour :ssh_client_key_api

  @impl true
  def is_host_key(_key, _host, _port, _algorithm, _opts), do: true

  @impl true
  def add_host_key(_host, _port, _key, _opts), do: :ok

  @impl true
  def user_key(algorithm, opts) do
    private = Keyword.get(opts, :key_cb_private, [])
    pem = Keyword.get(private, :private_key)
    passphrase = Keyword.get(private, :passphrase)

    with {:ok, key} <- decode(pem, passphrase),
         true <- matches?(key, algorithm) do
      {:ok, key}
    else
      false -> {:error, :algorithm_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Decodes a private key blob into an Erlang key record."
  def decode(nil, _passphrase), do: {:error, :no_private_key}

  def decode(pem, passphrase) when is_binary(pem) do
    pem = normalize(pem)

    cond do
      String.contains?(pem, "OPENSSH PRIVATE KEY") -> decode_openssh(pem, passphrase)
      true -> decode_pem(pem, passphrase)
    end
  end

  defp normalize(pem) do
    pem = String.replace(pem, "\r\n", "\n")
    if String.ends_with?(pem, "\n"), do: pem, else: pem <> "\n"
  end

  defp decode_openssh(pem, passphrase) do
    args =
      if blank?(passphrase),
        do: [pem, :openssh_key],
        else: [pem, :openssh_key, [{:key_cb_private, [password: to_charlist(passphrase)]}]]

    try do
      case apply(:ssh_file, :decode, args) do
        [{key, _attrs} | _] -> {:ok, key}
        [key | _] when is_tuple(key) -> {:ok, key}
        {:error, reason} -> {:error, reason}
        other -> {:error, {:unexpected_key_format, other}}
      end
    rescue
      e -> {:error, {:openssh_decode_failed, Exception.message(e)}}
    catch
      _, reason -> {:error, {:openssh_decode_failed, reason}}
    end
  end

  defp decode_pem(pem, passphrase) do
    try do
      case :public_key.pem_decode(pem) do
        [] ->
          {:error, :invalid_pem}

        [entry | _] ->
          key =
            if blank?(passphrase) do
              :public_key.pem_entry_decode(entry)
            else
              :public_key.pem_entry_decode(entry, to_charlist(passphrase))
            end

          {:ok, key}
      end
    rescue
      e -> {:error, {:pem_decode_failed, Exception.message(e)}}
    catch
      _, reason -> {:error, {:pem_decode_failed, reason}}
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  # Ed25519 / Ed448
  defp matches?({:ed_pri, :ed25519, _, _}, alg), do: alg in [:"ssh-ed25519"]
  defp matches?({:ed_pri, :ed448, _, _}, alg), do: alg in [:"ssh-ed448"]

  # RSA
  defp matches?(key, alg) when elem(key, 0) == :RSAPrivateKey,
    do: alg in [:"ssh-rsa", :"rsa-sha2-256", :"rsa-sha2-512"]

  # ECDSA
  defp matches?(key, alg) when elem(key, 0) == :ECPrivateKey,
    do: alg in [:"ecdsa-sha2-nistp256", :"ecdsa-sha2-nistp384", :"ecdsa-sha2-nistp521"]

  # DSA
  defp matches?(key, alg) when elem(key, 0) == :DSAPrivateKey, do: alg == :"ssh-dss"

  defp matches?(_key, _alg), do: true
end
