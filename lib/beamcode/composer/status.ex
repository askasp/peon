defmodule Beamcode.Composer.Status do
  @moduledoc """
  Answers the composer's status questions from live session data, without an
  agent: "what's the status of the latest session in amino-monorepo?",
  "status of all sessions", "anything waiting?".

  `answer/4` returns `%{text, spoken, items, open}`: a line for the screen, a
  shorter one to say, the sessions it is about (newest first) and the session
  to open on Enter (the latest one, for a `:latest` question).
  """
  alias Beamcode.{Opencode, Projects, Speech}
  alias Beamcode.Opencode.Events

  @per_project 20
  @shown 6

  def answer(kind, project, projects, user) do
    scope = if project, do: [project], else: Enum.filter(projects, &(&1.kind != "system"))
    sessions = recent(scope, user)
    where = if project, do: " in #{project.name}", else: ""

    case {kind, sessions} do
      {_, []} ->
        line = "No sessions#{where} yet."
        %{text: line, spoken: line, items: [], open: nil, reply: ""}

      {:latest, [s | _]} ->
        latest(s, where)

      {:overview, list} ->
        overview(list, where)
    end
  end

  defp latest(s, where) do
    reply = last_reply(s.id)
    head = "The latest session#{where}, “#{s.title}”, #{state(s.status)}, #{ago(s.updated)}."

    %{
      text: head,
      spoken:
        "The latest session#{spoken_where(where)} #{state(s.status)}. " <>
          if(reply == "", do: "", else: "Last reply: " <> reply),
      items: [s],
      open: s.id,
      reply: reply
    }
  end

  defp overview(list, where) do
    running = Enum.count(list, &(&1.status == :running))
    waiting = Enum.count(list, &(&1.status == :waiting))
    recent = Enum.count(list, &recent?/1)

    counts =
      [
        running > 0 && "#{running} running",
        waiting > 0 && "#{waiting} waiting for you",
        "#{recent} active in the last day"
      ]
      |> Enum.filter(& &1)
      |> Enum.join(", ")

    busy = Enum.filter(list, &(&1.status != :idle))

    named =
      case busy do
        [] ->
          ""

        _ ->
          " " <>
            Enum.map_join(Enum.take(busy, 3), ". ", &"#{&1.title} #{state(&1.status)}") <> "."
      end

    line = "Sessions#{where}: #{counts}."

    %{
      text: line,
      spoken: "#{line}#{named}" |> String.replace(~r/[-_]+/, " "),
      items: Enum.take(busy ++ (list -- busy), @shown),
      open: nil,
      reply: ""
    }
  end

  @doc "Visible top-level sessions of `scope` (projects), newest first."
  def recent(scope, user) do
    scope
    |> Task.async_stream(&project_sessions(&1, user), timeout: 15_000, on_timeout: :kill_task)
    |> Enum.flat_map(fn
      {:ok, list} -> list
      _ -> []
    end)
    |> Enum.sort_by(& &1.updated, :desc)
  end

  defp project_sessions(project, user) do
    params =
      if project.oc_project_id,
        do: [project: project.oc_project_id, limit: @per_project],
        else: [directory: project.directory, limit: @per_project]

    case Opencode.list_sessions(params) do
      {:ok, list} when is_list(list) ->
        list = Enum.reject(list, &(&1["parentID"] || get_in(&1, ["time", "archived"])))
        records = Projects.session_records(Enum.map(list, & &1["id"]))

        for s <- list, Projects.session_visible?(records[s["id"]], user) do
          %{
            id: s["id"],
            title: s["title"] || "New session",
            project: project,
            status: Events.status(s["id"]),
            updated: get_in(s, ["time", "updated"]) || 0
          }
        end

      _ ->
        []
    end
  end

  defp last_reply(id) do
    case Opencode.messages(id, 20) do
      {:ok, msgs} ->
        msgs
        |> Enum.reverse()
        |> Enum.find(&(&1["type"] == "assistant"))
        |> case do
          nil ->
            ""

          m ->
            for(%{"type" => "text", "text" => t} <- m["content"] || [], do: t)
            |> Enum.join("\n\n")
        end
        |> Speech.speakable(max_words: 30)

      _ ->
        ""
    end
  end

  def state(:running), do: "is working"
  def state(:waiting), do: "is waiting for your OK"
  def state(_), do: "is done"

  defp spoken_where(""), do: ""
  defp spoken_where(where), do: String.replace(where, ~r/[-_]+/, " ")

  defp recent?(s), do: now_ms() - s.updated < 86_400_000

  @doc "“updated 5 minutes ago”"
  def ago(0), do: "never updated"

  def ago(ms) do
    mins = div(max(now_ms() - ms, 0), 60_000)

    cond do
      mins < 1 -> "updated just now"
      mins < 60 -> "updated #{plural(mins, "minute")} ago"
      mins < 1440 -> "updated #{plural(div(mins, 60), "hour")} ago"
      true -> "updated #{plural(div(mins, 1440), "day")} ago"
    end
  end

  defp plural(1, unit), do: "1 #{unit}"
  defp plural(n, unit), do: "#{n} #{unit}s"

  defp now_ms, do: System.system_time(:millisecond)
end
