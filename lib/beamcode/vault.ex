defmodule Beamcode.Vault do
  @moduledoc """
  Secrets for connectors and GitHub tokens. Values are encrypted with
  AES-256-GCM using a key derived from `VAULT_KEY` (or the endpoint's
  secret_key_base). Connector secrets are only ever decrypted by the gateway
  when it calls an API; they never go to a session, a file or the browser.
  GitHub tokens are the exception: git on the OpenCode server needs them, so
  `Beamcode.GitTokens` writes them to the server's token file.
  """
  import Ecto.Query
  alias Beamcode.Repo
  alias Beamcode.Vault.Secret

  def list, do: Repo.all(from s in Secret, order_by: s.name, preload: :set_by)

  def names, do: Repo.all(from s in Secret, select: s.name) |> MapSet.new()

  def put(name, value, user) when is_binary(value) and value != "" do
    %Secret{}
    |> Secret.changeset(%{name: name})
    |> Ecto.Changeset.put_change(:ciphertext, encrypt(value))
    |> Ecto.Changeset.put_change(:set_by_id, user && user.id)
    |> Repo.insert(
      on_conflict: {:replace, [:ciphertext, :set_by_id, :updated_at]},
      conflict_target: :name
    )
  end

  def delete(name), do: Repo.delete_all(from s in Secret, where: s.name == ^name)

  def fetch(name) do
    case Repo.get_by(Secret, name: name) do
      nil -> :error
      secret -> decrypt(secret.ciphertext)
    end
  end

  @doc "Last four characters, for display."
  def hint(name) do
    case fetch(name) do
      {:ok, v} -> String.duplicate("•", 12) <> String.slice(v, -4, 4)
      _ -> nil
    end
  end

  defp key do
    base =
      Application.get_env(:beamcode, :vault_key) ||
        Application.fetch_env!(:beamcode, BeamcodeWeb.Endpoint)[:secret_key_base]

    :crypto.hash(:sha256, "beamcode-vault:" <> base)
  end

  defp encrypt(plain) do
    iv = :crypto.strong_rand_bytes(12)
    {ct, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, plain, "vault", true)
    iv <> tag <> ct
  end

  defp decrypt(<<iv::binary-12, tag::binary-16, ct::binary>>) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, ct, "vault", tag, false) do
      :error -> :error
      plain -> {:ok, plain}
    end
  end

  defp decrypt(_), do: :error
end
