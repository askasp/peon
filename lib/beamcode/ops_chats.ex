defmodule Beamcode.OpsChats do
  @moduledoc """
  An Operations Project's chats. It has no one chat: work there is always about
  one procedure or one run, so each gets its own (`session_records.chat`).

    * A procedure chat writes and edits `.peon/procedures/<name>.md`. New
      procedure opens an empty one (`procedure` nil); the procedure it writes
      becomes its own (`info/2`), with its schedule paused until someone starts
      it. Before each message the file is kept as `base`, so the file view can
      show what the chat changed and undo it.
    * A run chat starts with the run (`Beamcode.Procedures.Runs` gives each top
      level run a new session). Messages there carry the run's details, and the
      agent is told not to edit procedures: it offers `[Edit name](edit:name)`,
      which opens that procedure's chat.

  What the app sends along with a message goes in a ```peon-context block
  (`with_context/3`), which the app doesn't show.
  """
  import Ecto.Query
  alias Beamcode.{Opencode, Procedures, Projects, Repo, Sessions}
  alias Beamcode.Projects.{Project, SessionRecord}
  alias Beamcode.Schedules.Run

  @dir ".peon/procedures"
  @file_re ~r{(?:^|/)\.peon/procedures/([\w.-]+)\.md$}

  @doc "Procedure `name`'s chat, made the first time: `{:ok, session_id}`."
  def procedure_chat(%Project{} = project, user, name) when is_binary(name) do
    lock = {{__MODULE__, project.id, name}, self()}

    :global.trans(
      lock,
      fn ->
        # A new procedure's chat may have written it while nobody looked.
        if latest(project, name) == nil, do: claim_new(project)

        case latest(project, name) do
          nil ->
            with {:ok, s} <-
                   Sessions.start(project, user, title: name, chat: "procedure", procedure: name),
                 do: {:ok, s["id"]}

          sid ->
            {:ok, sid}
        end
      end,
      [node()]
    )
  end

  # The newest procedure chat for `name` that OpenCode still has.
  defp latest(project, name) do
    from(r in SessionRecord,
      where: r.project_id == ^project.id and r.chat == "procedure" and r.procedure == ^name,
      order_by: [desc: r.inserted_at, desc: r.id],
      select: r.session_id
    )
    |> Repo.all()
    |> Enum.find(&match?({:ok, %{"id" => _}}, Opencode.get_session(&1)))
  end

  defp claim_new(project) do
    from(r in SessionRecord,
      where: r.project_id == ^project.id and r.chat == "procedure" and is_nil(r.procedure),
      order_by: [desc: r.inserted_at],
      limit: 10
    )
    |> Repo.all()
    |> Enum.each(&claim(project, &1))
  end

  @doc "An empty chat for a new procedure: `{:ok, session_id}`."
  def new_procedure_chat(%Project{} = project, user) do
    with {:ok, s} <-
           Sessions.start(project, user, title: "New procedure", chat: "procedure", base: ""),
         do: {:ok, s["id"]}
  end

  @doc """
  What a procedure chat's file view shows: `%{procedure, path, base, new}`.
  `base` is the file before the last message (nil: nothing to compare), `new`
  whether the chat made the file. A new procedure's chat takes the procedure
  it wrote (pausing its schedule) the first time it's asked after.
  """
  def info(%Project{} = project, %SessionRecord{chat: "procedure"} = record) do
    record = claim(project, record)

    %{
      procedure: record.procedure,
      path: record.procedure && Path.join(@dir, record.procedure <> ".md"),
      base: record.base,
      new: record.base == ""
    }
  end

  defp claim(project, %SessionRecord{procedure: nil} = record) do
    with {:ok, messages} when is_list(messages) <- Opencode.messages(record.session_id),
         name when is_binary(name) <- written(messages),
         false <- taken?(project, name) do
      record = record |> Ecto.Changeset.change(procedure: name) |> Repo.update!()
      Opencode.update_session(record.session_id, %{title: name})
      Procedures.changed(project)

      case Procedures.find(project, name) do
        %{schedule: %{}} -> Projects.pause_schedule(project, name, true)
        _ -> :ok
      end

      record
    else
      _ -> record
    end
  end

  defp claim(_project, record), do: record

  # The procedure a chat wrote (else one it edited), from its file tools: an
  # Operations Project has no git, so no session diff to read.
  defp written(messages) do
    found =
      for %{"content" => parts} <- messages,
          is_list(parts),
          %{"type" => "tool", "name" => tool, "state" => %{"status" => "completed"} = state} <-
            parts,
          tool in ["write", "edit"],
          path = get_in(state, ["input", "filePath"]) || get_in(state, ["input", "path"]),
          is_binary(path),
          [_, name] <- [Regex.run(@file_re, path)],
          do: {name, tool == "write"}

    case Enum.find(found, &elem(&1, 1)) || List.first(found) do
      {name, _} -> name
      nil -> nil
    end
  end

  defp taken?(project, name) do
    Repo.exists?(
      from r in SessionRecord,
        where: r.project_id == ^project.id and r.chat == "procedure" and r.procedure == ^name
    )
  end

  @doc """
  Puts the run's or procedure's context on a message sent in one of these
  chats, and for a procedure chat keeps the file as it is now as `base`.
  Other chats' text goes as it is.
  """
  def with_context(%Project{} = project, %SessionRecord{chat: "procedure"} = record, text) do
    record = claim(project, record)

    case record.procedure do
      nil ->
        context(text, new_procedure(project))

      name ->
        base =
          case Opencode.read_file(project.directory, Path.join(@dir, name <> ".md")) do
            {:ok, body} -> body
            _ -> ""
          end

        record |> Ecto.Changeset.change(base: base) |> Repo.update!()

        context(text, """
        This chat is about the procedure #{name} (#{@dir}/#{name}.md). Change that file when asked, and its line in AGENTS.md if what it does changes. Don't run it.
        """)
    end
  end

  def with_context(_project, %SessionRecord{chat: "run", session_id: sid}, text) do
    case run_for(sid) do
      nil -> text
      run -> context(text, run_context(run))
    end
  end

  def with_context(_project, _record, text), do: text

  defp context(text, block), do: "#{text}\n\n```peon-context\n#{String.trim(block)}\n```"

  defp new_procedure(project) do
    """
    This chat makes a new procedure in this Project (#{project.name}). Write it as #{@dir}/<name>.md with a short name it runs as (/<name>), then add a line about it to AGENTS.md. Reuse the Project's procedures: a step can run one (run:) instead of doing its work again. Ask before choices that change the file (one question at a time). Don't run it. A schedule stays paused until the user starts it.
    """
  end

  @doc "The first run in run chat `sid`, the one the chat is about."
  def run_for(sid) do
    from(r in Run,
      where: r.session_id == ^sid,
      order_by: [asc: r.inserted_at, asc: r.id],
      limit: 1
    )
    |> Repo.one()
  end

  @doc "What the agent is told about the run a chat is about, and what it may do there."
  def run_context(%Run{} = run) do
    children =
      from(r in Run, where: r.parent_id == ^run.id, order_by: [asc: r.inserted_at])
      |> Repo.all()

    """
    This chat is about run #{run.id} of the procedure #{run.procedure} (#{run.status}#{if run.error, do: ": " <> run.error}). Answer questions about it, and take follow-up actions through the Project's API calls when asked. Don't change anything in #{@dir}/ from here: when a fix belongs in the procedure, say what to change and end your reply with the line [Edit #{run.procedure}](edit:#{run.procedure}).

    Inputs: #{json(run.inputs)}
    Summary: #{run.summary || "none"}
    Steps:
    #{Enum.map_join(run.steps || [], "\n", &step_line/1)}
    Outputs: #{json(run.outputs, 3000)}
    #{if children != [], do: "Runs it started:\n" <> Enum.map_join(children, "\n", &child_line/1)}
    """
  end

  defp step_line(s) do
    text = s["text"] && String.slice(s["text"], 0, 1200)

    "- #{s["name"]}: #{s["status"]}#{if s["error"], do: " (#{s["error"]})"}#{if text, do: "\n  " <> text}"
  end

  defp child_line(r),
    do:
      "- run #{r.id} #{r.procedure} #{json(r.inputs)}: #{r.status}" <>
        "#{if r.summary, do: " · " <> r.summary}#{if r.error, do: " · " <> r.error}"

  defp json(value, max \\ 600) do
    text = Jason.encode!(value || %{})
    if String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text
  end

  @doc """
  The chat for `run`: the one it ran in, else (a run with only API calls) a new
  one, kept on the run. `{:ok, session_id}`.
  """
  def run_chat(%Project{} = project, user, %Run{session_id: nil} = run) do
    with {:ok, s} <-
           Sessions.start(project, user,
             title: run.procedure || "Run",
             scope: run.scope || "team",
             chat: "run",
             procedure: run.procedure
           ) do
      run |> Ecto.Changeset.change(session_id: s["id"]) |> Repo.update!()
      {:ok, s["id"]}
    end
  end

  def run_chat(_project, _user, %Run{session_id: sid}), do: {:ok, sid}

  @doc """
  Puts the procedure file back as it was before the chat's last message (a new
  one is removed). `{:ok, record}`.
  """
  def undo(%Project{} = project, %SessionRecord{chat: "procedure", procedure: name} = record)
      when is_binary(name) do
    path = Path.join(@dir, name <> ".md")

    result =
      case record.base do
        "" -> Opencode.run_shell(project.directory, "rm -f '#{path}'")
        base when is_binary(base) -> Opencode.write_file(project.directory, path, base)
        nil -> {:error, "Nothing to undo."}
      end

    with {:ok, _} <- ok(result) do
      Procedures.changed(project)
      {:ok, record |> Ecto.Changeset.change(base: nil) |> Repo.update!()}
    end
  end

  def undo(_project, _record), do: {:error, "Nothing to undo."}

  defp ok({:ok, _, _} = r), do: {:ok, r}
  defp ok(other), do: other
end
