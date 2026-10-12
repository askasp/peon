defmodule Beamcode.ProcedureRunsTest do
  use Beamcode.DataCase, async: false

  import Beamcode.OpencodeStub
  import BeamcodeWeb.ChannelCase, only: [project_fixture: 2]
  import BeamcodeWeb.ConnCase, only: [user_fixture: 0]
  alias Beamcode.Procedures.Runs
  alias Beamcode.Schedules.Run

  @dir "/srv/routines/amino-maintenance"

  @email_refunds """
  ---
  name: email-refunds
  inputs:
    since: { type: date, default: last_run }
  outputs:
    approved: [{ charge: text, amount: money, name: text }]
  steps:
    - name: Read
      model: haiku
      session: fresh
    - name: Decide
      model: opus
      effort: high
      session: fresh
      hand_over: [Read, refund-policy.md]
      returns: approved
    - name: Post
      model: sonnet
      offers: refund
  ---

  ## Read
  Read support mail since {since}.

  ## Decide
  Apply the policy.

  ## Post
  Post the approved ones.
  """

  @ship """
  ---
  name: ship
  inputs:
    task: { type: text }
  steps:
    - name: Plan
      model: opus
      wait: me
    - name: Build
      model: sonnet
    - name: Review
      model: sonnet
      session: fresh
      on_changes: { back_to: Build, max: 1 }
    - name: Merge
      wait: me
  ---

  ## Plan
  Plan {task}.

  ## Build
  Build it.

  ## Review
  Review it.
  """

  @finder """
  ---
  name: finder
  outputs:
    approved: [{ charge: text, amount: money }]
  returns: approved
  ---
  Find refunds.
  """

  @refund """
  ---
  name: refund
  key: charge
  inputs:
    charge: { type: text }
    amount: { type: money }
  ---
  Refund {amount} on {charge}.
  """

  @chain """
  ---
  name: monday-ops
  steps:
    - name: Find
      run: finder
    - name: Refund
      run: refund
      for_each: finder.approved
      wait: me
      confirm: Send {count} refunds · {total}?
    - name: Report
  ---

  ## Report
  Post a summary.
  """

  @models [
    %{"id" => "claude-haiku-5-5", "providerID" => "anthropic"},
    %{"id" => "claude-opus-5-5", "providerID" => "anthropic", "variants" => [%{"id" => "high"}]},
    %{"id" => "claude-sonnet-5-5", "providerID" => "anthropic"}
  ]

  # A fake OpenCode: the Folder's chat "chat", sessions made on POST (s1, s2,
  # …), and what each session last said (`reply/2`).
  setup do
    user = user_fixture()
    folder = project_fixture(%{name: "amino-maintenance", kind: "routine", directory: @dir}, user)

    oc =
      start_supervised!(
        {Agent,
         fn ->
           %{n: 0, created: [], prompts: [], models: [], replies: %{}}
         end}
      )

    files = %{
      ".peon/procedures/email-refunds.md" => @email_refunds,
      ".peon/procedures/ship.md" => @ship,
      ".peon/procedures/finder.md" => @finder,
      ".peon/procedures/refund.md" => @refund,
      ".peon/procedures/monday-ops.md" => @chain,
      ".peon/refund-policy.md" => "Refund double charges."
    }

    setup_stub(fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case {conn.method, String.split(conn.request_path, "/", trim: true)} do
        {"GET", ["api", "session"]} ->
          data(conn, [%{"id" => "chat", "title" => "chat", "time" => %{"created" => 1, "updated" => 1}}])

        {"POST", ["api", "session"]} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)

          id =
            Agent.get_and_update(oc, fn s ->
              id = "s#{s.n + 1}"
              {id, %{s | n: s.n + 1, created: s.created ++ [{id, Jason.decode!(body)}]}}
            end)

          data(conn, %{"id" => id})

        {"POST", ["api", "session", sid, "prompt"]} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          Agent.update(oc, &%{&1 | prompts: &1.prompts ++ [{sid, Jason.decode!(body)["text"]}]})
          data(conn, %{})

        {"POST", ["api", "session", sid, "model"]} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          Agent.update(oc, &%{&1 | models: &1.models ++ [{sid, Jason.decode!(body)["model"]}]})
          data(conn, %{})

        {"GET", ["api", "session", sid, "message"]} ->
          text = Agent.get(oc, &Map.get(&1.replies, sid, ""))
          data(conn, [%{"type" => "assistant", "content" => [%{"type" => "text", "text" => text}]}])

        {"GET", ["api", "model"]} ->
          data(conn, @models)

        # A shared skill, so the Folder's own (none) are known at once.
        {"GET", ["api", "skill"]} ->
          data(conn, [%{"name" => "shared", "path" => "/srv/routines/.opencode/skill/shared/SKILL.md"}])

        {"GET", ["api", "fs", "list"]} ->
          path = conn.query_params["path"]

          entries =
            for {file, _} <- files, Path.dirname(file) == path, do: %{"path" => file, "type" => "file"}

          data(conn, entries)

        {"GET", ["api", "fs", "read" | rest]} ->
          case files[Enum.join(rest, "/")] do
            nil -> Plug.Conn.send_resp(conn, 404, "")
            body -> Plug.Conn.send_resp(conn, 200, body)
          end

        _ ->
          data(conn, [])
      end
    end)

    %{user: user, folder: folder, oc: oc}
  end

  defp reply(oc, sid, text), do: Agent.update(oc, &%{&1 | replies: Map.put(&1.replies, sid, text)})
  defp last_prompt(oc), do: Agent.get(oc, &List.last(&1.prompts))
  defp reload(run), do: Repo.get!(Run, run.id)

  test "steps switch models, fresh ones get a hand-over, outputs are kept", %{user: user, folder: folder, oc: oc} do
    {:ok, run} = Runs.start(folder, user, "email-refunds", %{}, trigger: "slash")
    assert run.session_id == "chat"

    # Read: a fresh child of the chat, on Haiku, with the default `since`.
    assert [{"s1", %{"parentID" => "chat", "model" => %{"id" => "claude-haiku-5-5"}}}] =
             Agent.get(oc, & &1.created)

    assert {"s1", text} = last_prompt(oc)
    assert text =~ "/email-refunds · Read (step 1 of 3)"
    assert text =~ "Read support mail since the last 7 days."

    reply(oc, "s1", "Ola asked for 299 back.")
    Runs.session_idle("s1", :ok)

    # Decide: fresh again, on Opus high, handed Read's answer and the policy.
    assert {"s2", %{"model" => %{"id" => "claude-opus-5-5", "variant" => "high"}}} =
             Agent.get(oc, &List.last(&1.created))

    assert {"s2", text} = last_prompt(oc)
    assert text =~ "### What Read said\n\nOla asked for 299 back."
    assert text =~ "### refund-policy.md\n\nRefund double charges."
    assert text =~ "```peon-output"

    reply(oc, "s2", ~s(Approved.\n```peon-output\n{"approved": [{"charge": "ch_1", "amount": 299, "name": "Ola"}]}\n```))
    Runs.session_idle("s2", :ok)

    # Post: in the chat itself, switched to Sonnet, offering /refund buttons.
    assert [{"chat", %{"id" => "claude-sonnet-5-5"}}] = Agent.get(oc, & &1.models)
    assert {"chat", text} = last_prompt(oc)
    assert text =~ "run:refund?charge=…&amount=…"

    reply(oc, "chat", "- **Ola** [Send refund](run:refund?charge=ch_1&amount=299&currency=NOK)")
    Runs.session_idle("chat", :ok)

    run = reload(run)
    assert run.status == "done"
    assert run.outputs["approved"] == [%{"charge" => "ch_1", "amount" => 299, "name" => "Ola"}]
    assert run.summary == "1 × Send refund · 299 NOK"
    assert Enum.map(run.steps, & &1["status"]) == ["done", "done", "done"]
  end

  test "waits for you, goes back with a note, and loops a review at most max times",
       %{user: user, folder: folder, oc: oc} do
    {:ok, run} = Runs.start(folder, user, "ship", %{"task" => "refund status"})
    assert {"chat", "/ship · Plan (step 1 of 4)\n\nInputs: task: refund status\n\nPlan refund status."} =
             last_prompt(oc)

    Runs.session_idle("chat", :ok)
    run = reload(run)
    assert %{status: "waiting", waiting: %{"kind" => "after", "next" => "Build", "back" => "Plan"}} = run

    # Typing at the wait: Plan again, with the note.
    {:ok, _} = Runs.back(run, "Smaller, please.")
    assert {"chat", text} = last_prompt(oc)
    assert text =~ "Plan refund status." and text =~ "Smaller, please."

    Runs.session_idle("chat", :ok)
    {:ok, _} = Runs.continue(reload(run))
    assert {"chat", "/ship · Build (step 2 of 4)\n\nBuild it."} = last_prompt(oc)

    Runs.session_idle("chat", :ok)
    assert {"s1", review} = last_prompt(oc)
    assert review =~ "peon-step"

    # Changes needed: back to Build once, then the second time it waits.
    reply(oc, "s1", ~s(Fix the rounding.\n```peon-step {"changes": true}```))
    Runs.session_idle("s1", :ok)
    assert {"chat", text} = last_prompt(oc)
    assert text =~ "Review asked for changes:\n\nFix the rounding."

    Runs.session_idle("chat", :ok)
    assert {"s2", _} = last_prompt(oc)
    reply(oc, "s2", ~s(Still wrong.\n```peon-step {"changes": true}```))
    Runs.session_idle("s2", :ok)
    assert %{status: "waiting", waiting: %{"kind" => "changes"}} = reload(run)

    # Go on anyway; Merge waits before it does anything.
    {:ok, _} = Runs.continue(reload(run))
    assert %{status: "waiting", waiting: %{"kind" => "before", "text" => "Merge?"}} = reload(run)
    {:ok, done} = Runs.continue(reload(run))
    assert done.status == "done"
  end

  test "a chain runs a procedure, asks once for the batch, then runs it per item",
       %{user: user, folder: folder, oc: oc} do
    {:ok, run} = Runs.start(folder, user, "monday-ops", %{}, trigger: "schedule")

    # Find runs finder as a child run, in its own session under the chat.
    assert [{"s1", %{"parentID" => "chat"}}] = Agent.get(oc, & &1.created)
    assert [%{procedure: "finder", parent_id: parent, trigger: "chain"}] = Repo.all(from r in Run, where: r.parent_id == ^run.id)
    assert parent == run.id

    items = ~s([{"charge": "ch_1", "amount": 299, "currency": "NOK"}, {"charge": "ch_2", "amount": 99, "currency": "NOK"}])
    reply(oc, "s1", "Two.\n```peon-output\n{\"approved\": #{items}}\n```")
    Runs.session_idle("s1", :ok)

    run = reload(run)
    assert %{status: "waiting", seen: false, waiting: %{"kind" => "before", "text" => "Send 2 refunds · 398 NOK?"}} = run
    assert length(run.waiting["items"]) == 2

    # Pick one: refund runs once, for ch_1, with no offer buttons inside a chain.
    {:ok, _} = Runs.continue(run, items: [%{"charge" => "ch_1", "amount" => 299}])
    assert {"s2", text} = last_prompt(oc)
    assert text =~ "Refund 299 on ch_1."
    refute text =~ "run:"

    Runs.session_idle("s2", :ok)
    assert {"chat", "/monday-ops · Report (step 3 of 3)\n\nPost a summary."} = last_prompt(oc)
    Runs.session_idle("chat", :ok)

    run = reload(run)
    assert run.status == "done"
    assert [%{"status" => "done"}, %{"status" => "done", "text" => "1 run"}, %{"status" => "done"}] = run.steps
  end

  test "a failed child stops the chain", %{user: user, folder: folder} do
    {:ok, run} = Runs.start(folder, user, "monday-ops", %{})
    Runs.session_idle("s1", :failed)

    assert %{status: "failed", error: "Find: finder failed: " <> _} = reload(run)
  end
end
