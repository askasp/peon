defmodule Beamcode.Inbox do
  @moduledoc """
  Everything waiting on a person, filtered to what the user can see:
  pending permission requests and finished schedule runs.
  `mine` = started by me or a schedule I own; `team` = the rest.
  """
  alias Beamcode.{Projects, Schedules}
  alias Beamcode.Opencode.Events

  def items(user, projects) do
    perms =
      Events.pending_permissions()
      |> Enum.flat_map(fn perm ->
        with %{} = session <- Events.session_info(perm["sessionID"]),
             %{} = project <- Projects.project_for_session(session, projects),
             record = Projects.session_record(perm["sessionID"]),
             true <- Projects.session_visible?(record, user) do
          [
            %{
              type: :permission,
              perm: perm,
              session: session,
              project: project,
              mine?: record != nil and record.user_id == user.id
            }
          ]
        else
          _ -> []
        end
      end)

    runs =
      Schedules.inbox_runs(user, projects)
      |> Enum.map(&%{type: :run, run: &1, project: &1.project, mine?: &1.owner_id == user.id})

    perms ++ runs
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

  defp first_resource(p),
    do: p["resources"] |> List.wrap() |> List.first("") |> String.slice(0, 80)
end
