defmodule Beamcode.BranchGuard do
  @moduledoc """
  "Protect default branch" for code projects whose git host has no branch
  protection (e.g. private repos on GitHub's free tier). Agents must not push to
  `main`, `master` or origin's default branch. Two layers:

    * OpenCode permission rules on every session of the project deny
      `git push … main` style commands and `gh pr merge`, so the agent is told
      no before it runs anything.
    * A git pre-push hook in the repo (worktrees share it) refuses any push that
      updates a protected branch, however the command was written.

  Both stop an agent that follows the rules, not one that sets out to get
  around them: the GitHub token is still readable on the server.
  """
  require Logger
  alias Beamcode.{Opencode, Projects}
  alias Beamcode.Projects.Project

  @marker "peon: protect-default-branch"

  @doc "Branches that are protected for `project` (whether or not protection is on)."
  def branches(%Project{default_branch: default}),
    do: Enum.uniq(["main", "master"] ++ List.wrap(default))

  @doc "OpenCode permission rules for a new session in `project`."
  def session_rules(%Project{protect_default_branch: true} = project),
    do: rules(branches(project))

  def session_rules(_project), do: []

  @doc "Deny rules for pushes to `branches` and for merging pull requests."
  def rules(branches) do
    pushes =
      for b <- branches,
          target <- [" #{b}", ":#{b}", " refs/heads/#{b}", ":refs/heads/#{b}"],
          tail <- ["", " *"],
          do: "git push *" <> target <> tail

    for resource <- pushes ++ ["gh pr merge*"],
        do: %{"action" => "bash", "resource" => resource, "effect" => "deny"}
  end

  @doc """
  Brings the repo and the project's sessions in line with
  `project.protect_default_branch`: installs or removes the hook and replaces
  the sessions' permission rules.
  """
  def sync(%Project{protect_default_branch: true} = project) do
    with {:ok, project} <- detect_default_branch(project),
         :ok <- shell(project, install_script(branches(project))) do
      update_sessions(project, rules(branches(project)))
      {:ok, project}
    end
  end

  def sync(%Project{} = project) do
    with :ok <- shell(project, remove_script()) do
      update_sessions(project, [])
      {:ok, project}
    end
  end

  defp detect_default_branch(project) do
    case Opencode.run_shell(
           project.directory,
           "git symbolic-ref --quiet --short refs/remotes/origin/HEAD"
         ) do
      {:ok, 0, out} ->
        branch = out |> String.trim() |> String.replace_prefix("origin/", "")

        case Projects.set_default_branch(project, branch) do
          {:ok, project} -> {:ok, project}
          {:error, _} -> {:ok, project}
        end

      # No origin/HEAD (no remote, or never fetched): main and master still apply.
      _ ->
        {:ok, project}
    end
  end

  defp shell(project, script) do
    case Opencode.run_shell(project.directory, script) do
      {:ok, 0, _} -> :ok
      {:ok, _, out} -> {:error, "git hook: " <> String.trim(out)}
      {:error, e} -> {:error, "git hook: " <> inspect(e)}
    end
  end

  defp update_sessions(project, rules) do
    params =
      if project.oc_project_id,
        do: [project: project.oc_project_id, limit: 500],
        else: [directory: project.directory, limit: 500]

    case Opencode.list_sessions(params) do
      {:ok, sessions} ->
        sessions
        |> Task.async_stream(&Opencode.update_session(&1["id"], %{permissions: rules}),
          max_concurrency: 8,
          timeout: :infinity
        )
        |> Stream.run()

      error ->
        Logger.warning(
          "branch guard: could not list sessions of #{project.name}: #{inspect(error)}"
        )
    end
  end

  @doc "The pre-push hook. Branch names are checked against Project's format first."
  def hook(branches) do
    """
    #!/bin/sh
    # #{@marker}
    # Managed by Peon. Refuses pushes that update a protected branch. Turn it off
    # in the project's Settings in Peon instead of editing this file.
    protected="#{Enum.join(branches, " ")}"
    input=$(cat)
    for ref in $(printf '%s\\n' "$input" | awk '{print $3}'); do
      branch=${ref#refs/heads/}
      for p in $protected; do
        if [ "$branch" = "$p" ]; then
          echo "Peon: pushing to '$p' is blocked for this project (Protect default branch is on)." >&2
          echo "Push a feature branch and open a pull request instead." >&2
          exit 1
        fi
      done
    done
    orig="$(dirname "$0")/pre-push.peon-orig"
    if [ -x "$orig" ]; then
      printf '%s' "${input:+$input
    }" | "$orig" "$@"
      exit $?
    fi
    exit 0
    """
  end

  # A pre-push hook that isn't ours is kept and called after the check.
  @doc false
  def install_script(branches) do
    """
    set -e
    hooks="$(git rev-parse --git-path hooks)"
    mkdir -p "$hooks"
    if [ -f "$hooks/pre-push" ] && ! grep -q '#{@marker}' "$hooks/pre-push"; then
      mv "$hooks/pre-push" "$hooks/pre-push.peon-orig"
    fi
    cat > "$hooks/pre-push" <<'PEON_HOOK'
    #{hook(branches)}PEON_HOOK
    chmod +x "$hooks/pre-push"
    """
  end

  @doc false
  def remove_script do
    """
    set -e
    hooks="$(git rev-parse --git-path hooks)"
    if [ -f "$hooks/pre-push" ] && grep -q '#{@marker}' "$hooks/pre-push"; then
      rm "$hooks/pre-push"
      if [ -f "$hooks/pre-push.peon-orig" ]; then mv "$hooks/pre-push.peon-orig" "$hooks/pre-push"; fi
    fi
    """
  end
end
