defmodule Beamcode.ProjectTools do
  @moduledoc """
  The project screen's tools, for the app (`BeamcodeWeb.ProjectChannel`):

    * skills and instruction files (AGENTS.md, `.opencode/skill/*/SKILL.md`)
    * schedule forms: presets ↔ cron, saving to schedules.json
    * project settings, with branch protection kept in sync
    * the agents and models a schedule can pick from
  """
  alias Beamcode.{BranchGuard, Opencode, Projects, Schedules}
  alias Beamcode.Projects.Project
  alias Beamcode.Schedules.Cron

  ## Permissions

  @doc "Owners and admins change a project's settings."
  def can_edit?(%Project{} = project, user), do: user.admin or project.owner_id == user.id

  ## Skills and files

  @skill_template """
  ---
  name: NAME
  description: What /NAME does, in one line. OpenCode uses this to decide when to use it.
  ---

  Steps to follow when someone runs /NAME.
  """

  @doc "The project's own skills as `{name, relative path}`, sorted."
  def skill_files(%Project{} = project) do
    case Opencode.skills(project.directory) do
      {:ok, list} ->
        for s <- list, String.starts_with?(s["path"], project.directory <> "/") do
          {s["name"] || s["id"], Path.relative_to(s["path"], project.directory)}
        end
        |> Enum.sort()

      _ ->
        []
    end
  end

  @doc "A file in the project, or \"\" when it doesn't exist yet."
  def read_file(%Project{} = project, path) do
    case Opencode.read_file(project.directory, path) do
      {:ok, body} -> body
      _ -> ""
    end
  end

  @doc "Writes a file in the project and has OpenCode reload the folder (skills, AGENTS.md)."
  def write_file(%Project{} = project, path, content) do
    with {:ok, _} <- Opencode.write_file(project.directory, path, content) do
      _ = Opencode.reload_location(project.directory)
      :ok
    end
  end

  @doc "Creates `.opencode/skill/<name>/SKILL.md` from the template: `{:ok, path}` or `{:error, message}`."
  def create_skill(%Project{} = project, name) do
    name = name |> String.trim() |> String.downcase()
    path = ".opencode/skill/#{name}/SKILL.md"

    cond do
      not Regex.match?(~r/^[a-z0-9][a-z0-9-]*$/, name) ->
        {:error, "Skill names are lowercase letters, digits and dashes."}

      Enum.any?(skill_files(project), fn {n, _} -> n == name end) ->
        {:error, "/#{name} already exists."}

      true ->
        case write_file(project, path, String.replace(@skill_template, "NAME", name)) do
          :ok -> {:ok, path}
          {:error, e} -> {:error, "Could not create: #{format(e)}"}
        end
    end
  end

  ## Schedules

  @doc "The visible schedules of a project, decorated (`when`, `next`, `last`)."
  def schedules(%Project{} = project, user) do
    case Schedules.read(project) do
      {:ok, map} ->
        {:ok,
         for(
           {k, s} <- Enum.sort(map),
           Schedules.visible?(s, user),
           do: Schedules.decorate(project, k, s)
         )}

      {:error, e} ->
        {:error, format(e)}
    end
  end

  @doc "Form values for a new schedule."
  def new_schedule_params(user) do
    %{
      "key" => "",
      "preset" => "weekdays",
      "at" => "08:00",
      "every" => "30",
      "cron" => "",
      "prompt" => "",
      "scope" => "team",
      "agent" => "",
      "model" => "",
      "owner" => user.username
    }
  end

  @doc "Form values for an existing schedule; a cron line that fits a preset shows as that preset."
  def params_from_schedule(%{key: key, raw: raw}) do
    cron = raw["cron"] || ""

    base = %{
      "key" => key,
      "prompt" => raw["prompt"] || "",
      "scope" => raw["scope"] || "team",
      "agent" => raw["agent"] || "",
      "model" => raw["model"] || "",
      "owner" => raw["owner"] || "",
      "every" => "30",
      "at" => "08:00",
      "cron" => cron
    }

    case String.split(cron) do
      ["*/" <> n, "*", "*", "*", "*"] ->
        Map.merge(base, %{"preset" => "every", "every" => n})

      [m, h, "*", "*", dow] when dow in ["*", "1-5", "1", "5"] ->
        preset = %{"*" => "daily", "1-5" => "weekdays", "1" => "mondays", "5" => "fridays"}[dow]
        at = String.pad_leading(h, 2, "0") <> ":" <> String.pad_leading(m, 2, "0")
        Map.merge(base, %{"preset" => preset, "at" => at})

      _ ->
        Map.put(base, "preset", "custom")
    end
  end

  @doc "The cron line for schedule form values (preset, `at`, `every`, or `cron` for custom)."
  def build_cron(%{"preset" => preset} = p) do
    {h, m} =
      case String.split(p["at"] || "", ":") do
        [h, m] -> {String.to_integer(h), String.to_integer(m)}
        _ -> {8, 0}
      end

    case preset do
      "every" -> "*/#{p["every"] || "30"} * * * *"
      "hourly" -> "#{m} * * * *"
      "daily" -> "#{m} #{h} * * *"
      "weekdays" -> "#{m} #{h} * * 1-5"
      "mondays" -> "#{m} #{h} * * 1"
      "fridays" -> "#{m} #{h} * * 5"
      _ -> p["cron"] || ""
    end
  rescue
    _ -> ""
  end

  def build_cron(p), do: p["cron"] || ""

  @doc "What form values mean: `{cron, description, next run}`; next is nil for an invalid line."
  def describe_schedule(params) do
    cron = build_cron(params)

    next =
      case Cron.parse(cron) do
        {:ok, c} -> Cron.next(c, Cron.local_now())
        _ -> nil
      end

    {cron, Cron.describe(cron), next}
  end

  @doc "Saves schedule form values (owner defaults to `user`)."
  def save_schedule(%Project{} = project, params, user) do
    existing = existing_schedule(project, params["key"])

    # A schedule runs as its owner: only an admin picks someone else. Anyone
    # else keeps the owner it has, or owns the new one.
    owner =
      cond do
        user.admin and params["owner"] not in [nil, ""] -> params["owner"]
        existing -> existing["owner"] || user.username
        true -> user.username
      end

    attrs = params |> Map.put("cron", build_cron(params)) |> Map.put("owner", owner)

    with :ok <- may_change(existing, user),
         :ok <- Schedules.save(project, params["key"], attrs) do
      :ok
    else
      {:error, msg} -> {:error, format(msg)}
    end
  end

  @doc "Deletes a schedule, unless it is someone else's private one."
  def pause_schedule(%Project{} = project, key, paused, user) do
    with :ok <- may_change(existing_schedule(project, key), user),
         :ok <- Schedules.set_paused(project, key, paused) do
      :ok
    else
      {:error, msg} -> {:error, format(msg)}
    end
  end

  def delete_schedule(%Project{} = project, key, user) do
    with :ok <- may_change(existing_schedule(project, key), user),
         :ok <- Schedules.delete(project, key) do
      :ok
    else
      {:error, msg} -> {:error, format(msg)}
    end
  end

  defp existing_schedule(project, key) do
    case Schedules.read(project) do
      {:ok, scheds} when is_binary(key) -> scheds[key]
      _ -> nil
    end
  end

  # Someone else's "only me" schedule can't be seen, so it can't be changed either.
  defp may_change(nil, _user), do: :ok

  defp may_change(sched, user),
    do: if(Schedules.visible?(sched, user), do: :ok, else: {:error, "No schedule by that name."})

  def agents(%Project{} = project) do
    case Opencode.agents(project.directory) do
      {:ok, agents} -> for a <- agents, a["mode"] != "subagent", !a["hidden"], do: a["id"]
      _ -> ["build", "plan"]
    end
  end

  @doc "Enabled models as `{\"provider/id\", name}`."
  def models do
    case Opencode.models() do
      {:ok, models} ->
        for m <- models,
            m["enabled"] != false,
            m["status"] != "deprecated",
            do: {"#{m["providerID"]}/#{m["id"]}", m["name"]}

      _ ->
        []
    end
  end

  ## Settings

  @doc """
  Saves scope, always-worktree and branch protection. Turning protection on or
  off installs or removes the git hook; if that fails the toggle reverts.
  `{:ok, project, message}`, `{:reverted, project, message}` when the hook
  couldn't be changed, or `{:error, message}`.
  """
  def update_settings(%Project{} = project, params, user) do
    if can_edit?(project, user) do
      case Projects.update_settings(project, params) do
        {:ok, updated} -> sync_branch_guard(project, updated)
        {:error, _} -> {:error, "Could not save."}
      end
    else
      {:error, "Only the owner or an admin can change this."}
    end
  end

  defp sync_branch_guard(before, updated)
       when before.protect_default_branch == updated.protect_default_branch,
       do: {:ok, updated, "Saved."}

  defp sync_branch_guard(_before, updated) do
    case BranchGuard.sync(updated) do
      {:ok, project} ->
        msg =
          if project.protect_default_branch,
            do: "Pushes to #{Enum.join(BranchGuard.branches(project), ", ")} are now blocked.",
            else: "Default branch protection is off."

        {:ok, project, msg}

      {:error, reason} ->
        {:ok, project} =
          Projects.update_settings(updated, %{
            protect_default_branch: !updated.protect_default_branch
          })

        {:reverted, project, "Could not change branch protection: #{reason}"}
    end
  end

  defp format({_status, msg}) when is_binary(msg), do: msg
  defp format({:transport, msg}), do: "OpenCode server unreachable (#{msg})"
  defp format(msg) when is_binary(msg), do: msg
  defp format(other), do: inspect(other)
end
