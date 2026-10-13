defmodule Beamcode.Vault do
  @moduledoc """
  Secrets for API calls, synced services and GitHub, one set per Project:
  a secret set in one Project is never seen by another. Values are encrypted
  with AES-256-GCM using a key derived from `VAULT_KEY` (or the endpoint's
  secret_key_base). Secrets are only ever decrypted by the gateway when it
  calls an API; they never go to a session, a file or the browser. A code
  Project's `GIT_TOKEN` is the exception: git on the OpenCode server needs it,
  so `Beamcode.GitTokens` writes it to the server's token file.
  """
  require Logger
  import Ecto.Query
  alias Beamcode.{Connectors, DataSources, Opencode, Projects, Repo}
  alias Beamcode.Projects.Project
  alias Beamcode.Vault.Secret

  def list(project),
    do: Repo.all(from s in scoped(project), order_by: s.name, preload: :set_by)

  def names(project), do: Repo.all(from s in scoped(project), select: s.name) |> MapSet.new()

  def put(project, name, value, user) when is_binary(value) and value != "" do
    %Secret{project_id: id(project)}
    |> Secret.changeset(%{name: name})
    |> Ecto.Changeset.put_change(:ciphertext, encrypt(value))
    |> Ecto.Changeset.put_change(:set_by_id, user && user.id)
    |> Repo.insert(
      on_conflict: {:replace, [:ciphertext, :set_by_id, :updated_at]},
      conflict_target: [:project_id, :name]
    )
  end

  def delete(project, name),
    do: Repo.delete_all(from s in scoped(project), where: s.name == ^name)

  def fetch(project, name) do
    case Repo.one(from s in scoped(project), where: s.name == ^name) do
      nil -> :error
      secret -> decrypt(secret.ciphertext)
    end
  end

  @doc "Last four characters, for display."
  def hint(project, name) do
    case fetch(project, name) do
      {:ok, v} -> String.duplicate("•", 12) <> String.slice(v, -4, 4)
      _ -> nil
    end
  end

  defp scoped(project), do: from(s in Secret, where: s.project_id == ^id(project))

  defp id(%Project{id: id}), do: id
  defp id(id) when is_integer(id), do: id

  @doc """
  Copies the old shared secrets (from before secrets belonged to a Project)
  into each Project whose API calls or synced sources name them, then deletes
  them. Waits for the OpenCode server, since that's where those files are.
  """
  def adopt_legacy do
    legacy = Repo.all(from s in Secret, where: is_nil(s.project_id))

    cond do
      legacy == [] ->
        :ok

      not match?({:ok, _}, Opencode.location()) ->
        {:error, "the OpenCode server isn't reachable"}

      true ->
        by_name = Map.new(legacy, &{&1.name, &1})

        for project <- Projects.list_projects(),
            name <- needed(project),
            %Secret{} = s <- [by_name[name]] do
          Repo.insert!(
            %Secret{
              project_id: project.id,
              name: s.name,
              ciphertext: s.ciphertext,
              set_by_id: s.set_by_id
            },
            on_conflict: :nothing,
            conflict_target: [:project_id, :name]
          )

          Logger.info("vault: copied #{s.name} into #{project.name}")
        end

        Repo.delete_all(from s in Secret, where: is_nil(s.project_id))
        :ok
    end
  end

  defp needed(project) do
    api = for c <- Connectors.all_for(project), is_binary(c[:secret]), do: c.secret
    synced = for {_, s} <- DataSources.connector_sources(project), do: s.connector.info().secret
    Enum.uniq(api ++ synced)
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
