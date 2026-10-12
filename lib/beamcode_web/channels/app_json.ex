defmodule BeamcodeWeb.AppJSON do
  @moduledoc """
  What the phone app gets over the socket: plain maps with the fields it shows.
  OpenCode session and message maps pass through mostly as they are.
  """
  alias Beamcode.Inbox
  alias Beamcode.Opencode.Events

  def user(nil), do: nil
  def user(u), do: %{id: u.id, username: u.username, admin: u.admin}

  def project(nil), do: nil

  def project(p) do
    %{
      id: p.id,
      name: p.name,
      kind: p.kind,
      scope: p.scope,
      always_worktree: p.always_worktree,
      queue_auto: p.queue_auto,
      default_branch: p.default_branch,
      schedule: Beamcode.Schedules.summary(p.id)
    }
  end

  @doc "A session for lists. `status` is read live unless given."
  def session(s, project \\ nil) do
    record = s["record"]

    %{
      id: s["id"],
      title: s["title"] || "New session",
      updated: get_in(s, ["time", "updated"]),
      created: get_in(s, ["time", "created"]),
      directory: get_in(s, ["location", "directory"]),
      branch: get_in(s, ["location", "branch"]),
      agent: s["agent"],
      model: s["model"],
      status: Events.status(s["id"]),
      scope: record && record.scope,
      scheduled: !!(record && record.schedule_key),
      started_by: record && record.user && record.user.username,
      project: project(project)
    }
  end

  @doc "A session in `project`'s list: with its worktree folder name when it has its own."
  def listed_session(s, project), do: s |> session() |> Map.put(:worktree, worktree(s, project))

  @doc "The session's worktree folder name, or nil when it works in the project's folder."
  def worktree(s, project) do
    dir = get_in(s, ["location", "directory"])
    if dir && dir != project.directory, do: Path.basename(dir)
  end

  def running(%{id: id, title: title, project: project, status: status}),
    do: %{id: id, title: title, project: project(project), status: status}

  def perm(perm) do
    %{
      id: perm["id"],
      session_id: perm["sessionID"],
      action: perm["action"],
      resources: List.wrap(perm["resources"]),
      title: Inbox.permission_title(perm),
      # What the call carries (a tool's arguments), so a row it acts on can show "waiting".
      detail: perm["metadata"] |> Kernel.||(%{}) |> Jason.encode!() |> String.slice(0, 2000)
    }
  end

  def inbox_item(%{type: :permission} = item) do
    %{
      type: "permission",
      key: "perm-" <> item.perm["id"],
      perm: perm(item.perm),
      session: %{id: item.session["id"], title: item.session["title"] || "New session"},
      project: project(item.project),
      mine: item.mine?
    }
  end

  def inbox_item(%{type: :question} = item) do
    fields = List.wrap(item.form["fields"])

    %{
      type: "question",
      key: "form-" <> item.form["id"],
      form: %{
        id: item.form["id"],
        session_id: item.form["sessionID"],
        text: Inbox.question_text(item.form),
        count: length(fields)
      },
      session: %{id: item.session["id"], title: item.session["title"] || "New session"},
      project: project(item.project),
      mine: item.mine?
    }
  end

  def inbox_item(%{type: :run} = item) do
    %{
      type: "run",
      key: "run-#{item.run.id}",
      run: run(item.run),
      project: project(item.project),
      mine: item.mine?
    }
  end

  def run(r) do
    %{
      id: r.id,
      owner: if(Ecto.assoc_loaded?(r.owner) and r.owner, do: r.owner.username),
      owner_id: r.owner_id,
      inputs: r.inputs || %{},
      schedule_key: r.schedule_key,
      procedure: r.procedure,
      session_id: r.session_id,
      status: r.status,
      scope: r.scope,
      error: r.error,
      summary: r.summary,
      started: r.inserted_at,
      finished: r.finished_at,
      trigger: r.trigger,
      step: r.step,
      steps: Enum.map(r.steps || [], &run_step/1),
      waiting: r.waiting,
      parent_id: r.parent_id,
      ticket: r.ticket,
      # What each output holds, by count (the lists stay on the server).
      outputs: Map.new(r.outputs || %{}, fn {k, v} -> {k, if(is_list(v), do: length(v), else: 1)} end)
    }
  end

  # A step of a run, as the chat shows it; its reply is cut to what a card needs.
  defp run_step(s) do
    s
    |> Map.take(~w(name status session_id model effort session loops error started finished children results))
    |> Map.put("text", s["text"] && String.slice(s["text"], 0, 4000))
  end

  @doc """
  A procedure for the app: what it takes, its steps and how it starts.
  opts: `paused` (its schedule), `last` (its last run).
  """
  def procedure(p, opts \\ []) do
    %{
      name: p.name,
      description: p.description,
      inputs: Enum.map(p.inputs, &Map.take(&1, [:name, :type, :default, :options, :multi, :currency])),
      key: p.key,
      source: p.source,
      path: p.path,
      overrides: p.overrides,
      queue: p.queue,
      outputs: p.outputs,
      schedule:
        p.schedule &&
          %{
            at: p.schedule.at,
            tz: p.schedule.tz,
            when: p.schedule.cron && Beamcode.Schedules.Cron.describe(p.schedule.cron),
            next: next_time(p.schedule.cron),
            paused: Keyword.get(opts, :paused, false)
          },
      steps:
        Enum.map(p.steps, fn st ->
          Map.take(st, ~w(name kind prompt model effort session wait uses hand_over offers skill run
                          for_each returns on_fail queue title call params confirm)a)
          |> Map.put(:on_changes, st.on_changes)
          |> Map.put(:model_label, Beamcode.Procedures.model_label(st.model))
        end),
      last: opts[:last] && run(opts[:last])
    }
  end

  defp next_time(nil), do: nil

  defp next_time(cron) do
    case Beamcode.Schedules.Cron.parse(cron) do
      {:ok, c} ->
        case Beamcode.Schedules.Cron.next(c, Beamcode.Schedules.Cron.local_now()) do
          %NaiveDateTime{} = t -> NaiveDateTime.to_iso8601(t)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # Base64 images up to this size travel with the message; bigger ones are only named.
  @inline_image 400_000

  @doc """
  An OpenCode message for the app. Attached images come along when they are
  small (as `data`, base64); big ones only by name, so a transcript stays light.
  """
  def message(%{"type" => "user"} = m) do
    files =
      for f <- List.wrap(m["files"]) do
        small = is_binary(f["data"]) and byte_size(f["data"]) <= @inline_image
        %{"mime" => f["mime"], "name" => f["name"], "data" => if(small, do: f["data"])}
      end

    Map.put(m, "files", files)
  end

  def message(m), do: m

  def schedule(s) do
    %{
      key: s.key,
      project: project(s.project),
      cron: s.cron,
      when: s.when,
      scope: s.scope,
      owner: s.owner,
      prompt: s.prompt,
      procedure: s[:raw] && s.raw["procedure"],
      paused: s.paused,
      next: s.next && NaiveDateTime.to_iso8601(s.next),
      last: s.last && run(s.last)
    }
  end
end
