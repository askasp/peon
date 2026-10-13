defmodule Beamcode.GitTokens do
  @moduledoc """
  GitHub tokens for code projects, so sessions can clone, push and open PRs.

  Each token is a fine-grained PAT for one repo, kept in the project's vault
  as `GIT_TOKEN`. Git on the OpenCode server needs it in plain text,
  so the gateway also writes it to `~/.config/opencode-git/tokens.local` there,
  one `owner/name token` line per repo. The server's git credential helper and
  `gh` wrapper read that file (see the ansible opencode_web role). The gateway
  only rewrites its own block in it; lines added by anyone else stay.

  Sessions can read the file, so scope each token to its one repo.
  """
  alias Beamcode.{Opencode, Projects, Vault}
  alias Beamcode.Projects.Project

  @dir ".config/opencode-git"
  @tokens_file "tokens.local"
  @block_start "# beamcode: managed block, rewritten on every change"
  @block_end "# beamcode: end"

  @doc "Parses a github.com remote into \"owner/name\"."
  def parse_github(url) do
    url = String.trim(url || "")

    [
      ~r{^https?://(?:[^@/]+@)?github\.com/([^/]+)/([^/]+?)(?:\.git)?/?$},
      ~r{^(?:ssh://)?git@github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?/?$},
      ~r{^github\.com/([^/]+)/([^/]+?)(?:\.git)?/?$}
    ]
    |> Enum.find_value(:error, fn re ->
      case Regex.run(re, url) do
        [_, owner, name] -> {:ok, owner <> "/" <> name}
        _ -> nil
      end
    end)
  end

  def https_url(repo), do: "https://github.com/#{repo}.git"

  @secret "GIT_TOKEN"
  def secret_name, do: @secret

  def hint(project), do: Vault.hint(project, @secret)

  @doc "Asks GitHub whether the token can see the repo."
  def check(repo, token) do
    case Req.get(github_req(), url: "/repos/#{repo}", auth: {:bearer, token}) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: 401}} -> {:error, "GitHub rejected the token"}
      {:ok, %{status: s}} when s in [403, 404] -> {:error, "the token can't see #{repo}"}
      {:ok, %{status: s}} -> {:error, "GitHub answered #{s}"}
      {:error, e} -> {:error, "could not reach GitHub: #{Exception.message(e)}"}
    end
  end

  defp github_req do
    Req.new(
      base_url: "https://api.github.com",
      headers: [{"accept", "application/vnd.github+json"}],
      retry: false,
      receive_timeout: 10_000
    )
    |> Req.merge(Application.get_env(:beamcode, :github_req_options, []))
  end

  @doc """
  Sets or replaces a code project's token. A project without a known repo
  takes it from its origin remote, which is switched to HTTPS so git uses the
  token instead of SSH keys.
  """
  def save(%Project{} = project, token, user) do
    token = String.trim(token || "")

    with :ok <- if(token == "", do: {:error, "paste a token"}, else: :ok),
         {:ok, repo} <- repo_for(project),
         :ok <- check(repo, token),
         {:ok, project} <- Projects.set_github_repo(project, repo),
         {:ok, _} <- Vault.put(project, @secret, token, user),
         :ok <- sync() do
      {:ok, project}
    else
      {:error, %Ecto.Changeset{}} -> {:error, "could not store the token"}
      error -> error
    end
  end

  def delete(%Project{} = project) do
    Vault.delete(project, @secret)
    sync()
  end

  defp repo_for(%Project{github_repo: repo}) when is_binary(repo), do: {:ok, repo}

  defp repo_for(project) do
    with {:ok, 0, out} <- Opencode.run_shell(project.directory, "git remote get-url origin"),
         url = String.trim(out),
         {:ok, repo} <- parse_github(url) do
      if String.starts_with?(url, "https://"),
        do: {:ok, repo},
        else: set_https_origin(project.directory, repo)
    else
      :error -> {:error, "origin is not on github.com"}
      _ -> {:error, "this repo has no origin remote"}
    end
  end

  defp set_https_origin(dir, repo) do
    case Opencode.run_shell(dir, "git remote set-url origin #{https_url(repo)}") do
      {:ok, 0, _} -> {:ok, repo}
      _ -> {:error, "could not switch origin to HTTPS"}
    end
  end

  @doc "Rewrites the server's token file from the vault, if any project has a token."
  def restore do
    if stored() == [], do: :ok, else: sync()
  end

  @doc """
  Rewrites the gateway's block in the server's token file from the vault.
  `extra` adds `{repo, token}` pairs that aren't stored yet, for a clone that
  runs before its project exists.
  """
  def sync(extra \\ []) do
    entries = stored() ++ extra

    with {:ok, dir} <- token_dir(),
         {:ok, current} <- read(dir) do
      content = merge(current, entries)

      if content == current do
        :ok
      else
        with {:ok, _} <- Opencode.write_file(dir, @tokens_file, content),
             {:ok, 0, _} <- Opencode.run_shell(dir, "chmod 600 #{@tokens_file}") do
          :ok
        else
          {:ok, code, out} -> {:error, "chmod failed (#{code}): #{out}"}
          error -> error
        end
      end
    end
  end

  defp stored do
    for %Project{github_repo: repo} = p when is_binary(repo) <- Projects.list_projects(),
        {:ok, token} <- [Vault.fetch(p, @secret)],
        do: {repo, token}
  end

  # The file lives in the server user's home, so ask the server where that is.
  defp token_dir do
    with {:ok, %{"directory" => server_dir}} <- Opencode.location(),
         {:ok, 0, out} <-
           Opencode.run_shell(
             server_dir,
             ~s(mkdir -p "$HOME/#{@dir}" && printf %s "$HOME/#{@dir}")
           ) do
      {:ok, String.trim(out)}
    else
      {:ok, code, out} -> {:error, "could not find the server's home (#{code}): #{out}"}
      error -> error
    end
  end

  defp read(dir) do
    case Opencode.read_file(dir, @tokens_file) do
      {:ok, body} -> {:ok, body}
      {:error, :enoent} -> {:ok, ""}
      error -> error
    end
  end

  @doc "Replaces the gateway's block in a token file with `entries`."
  def merge(current, entries) do
    {kept, _} =
      current
      |> String.split("\n")
      |> Enum.reduce({[], false}, fn
        @block_start, {acc, _} -> {acc, true}
        @block_end, {acc, true} -> {acc, false}
        _line, {acc, true} -> {acc, true}
        line, {acc, false} -> {[line | acc], false}
      end)

    kept = kept |> Enum.drop_while(&(&1 == "")) |> Enum.reverse()

    block =
      if entries == [],
        do: [],
        else:
          [@block_start | Enum.map(entries, fn {repo, token} -> "#{repo} #{token}" end)] ++
            [@block_end]

    case kept ++ block do
      [] -> ""
      lines -> Enum.join(lines, "\n") <> "\n"
    end
  end
end
