defmodule BeamcodeWeb.FileToken do
  @moduledoc """
  Signed `/files/<token>/` prefixes, so a WebView or `<img>` can load a
  project's files without the app's login. A token is for one user and one
  project tree (its own folder, or a chat's worktree: see `Beamcode.Worktrees`),
  and stops working after an hour or when the user can no longer see the
  project. Relative links inside an HTML file stay under the same prefix.
  """
  alias Beamcode.{Accounts, Projects}

  @salt "project files"
  @max_age 60 * 60

  @doc "A token for `project`'s files, from the folder in its `directory` (a tree from `Beamcode.Worktrees.at/3`)."
  def sign(user, project),
    do: Phoenix.Token.sign(BeamcodeWeb.Endpoint, @salt, {user.id, project.id, project.directory})

  @doc "The URL path files are served under, ending in `/`."
  def base(user, project), do: "/files/#{sign(user, project)}/"

  @doc """
  `{:ok, project}` for a valid token whose user still sees the project, with
  `directory` set to the signed tree; else `:error`.
  """
  def verify(token) do
    with {:ok, _user, project} <- verify_user(token), do: {:ok, project}
  end

  @doc "Like `verify/1`, with the user the token was made for: `{:ok, user, project}`."
  def verify_user(token) when is_binary(token) do
    with {:ok, {user_id, project_id, dir}} <-
           Phoenix.Token.verify(BeamcodeWeb.Endpoint, @salt, token, max_age: @max_age),
         %{} = user <- Accounts.get_user(user_id),
         %{} = project <- Enum.find(Projects.list_visible(user), &(&1.id == project_id)) do
      {:ok, user, %{project | directory: dir}}
    else
      _ -> :error
    end
  end

  def verify_user(_), do: :error
end
