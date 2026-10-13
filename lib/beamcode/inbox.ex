defmodule Beamcode.Inbox do
  @moduledoc """
  Everything waiting on a person, filtered to what the user can see:
  pending permission requests and questions from a session that is still
  running, and procedure runs that wait for a person's answer. A finished
  run belongs in the Runs tab, not here.
  `mine` = started by me or a schedule I own; `team` = the rest.
  """
  alias Beamcode.{Projects, Schedules}
  alias Beamcode.Opencode.Events

  def items(user, projects) do
    running = MapSet.new(Events.running_ids())

    perms =
      Events.pending_permissions()
      |> Enum.flat_map(&waiting(:permission, :perm, &1, user, projects, running))

    questions =
      Events.pending_forms()
      |> Enum.flat_map(&waiting(:question, :form, &1, user, projects, running))

    runs =
      Schedules.inbox_runs(user, projects)
      |> Enum.map(&%{type: :run, run: &1, project: &1.project, mine?: &1.owner_id == user.id})

    perms ++ questions ++ runs
  end

  # A permission request or question, when its session is still running and one
  # the user can see. One left over from a session that stopped is stale: the
  # event stream missed its reply, so it is dropped here.
  defp waiting(type, key, item, user, projects, running) do
    sid = item["sessionID"]

    with true <- MapSet.member?(running, sid),
         %{} = session <- Events.session_info(sid),
         %{} = project <- Projects.project_for_session(session, projects),
         record = Projects.session_record(sid),
         true <- Projects.session_visible?(record, user) do
      [
        %{
          :type => type,
          key => item,
          :session => session,
          :project => project,
          :mine? => record != nil and record.user_id == user.id
        }
      ]
    else
      _ -> []
    end
  end

  def count(user, projects), do: length(items(user, projects))

  @doc "One line describing what a permission request wants."
  def permission_title(%{"action" => "shell"} = p), do: "Run #{first_resource(p)}"
  def permission_title(%{"action" => "edit"} = p), do: "Edit #{first_resource(p)}"

  def permission_title(%{"action" => "external_directory"} = p),
    do: "Use folder #{first_resource(p)}"

  def permission_title(%{"action" => "gateway_" <> tool}) do
    case String.split(tool, "_", parts: 2) do
      [connector, name] -> "Call #{connector} · #{name}"
      _ -> "Call #{tool}"
    end
  end

  def permission_title(%{"action" => action}), do: "Allow #{action}"

  @doc "What a question asks: its first question's text, or the form's title."
  def question_text(form) do
    case List.wrap(form["fields"]) do
      [%{"description" => d} | _] when is_binary(d) and d != "" -> d
      [%{"title" => t} | _] when is_binary(t) and t != "" -> t
      _ -> form["title"] || "A question"
    end
  end

  defp first_resource(p),
    do: p["resources"] |> List.wrap() |> List.first("") |> String.slice(0, 80)
end
