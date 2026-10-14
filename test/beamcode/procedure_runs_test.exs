defmodule Beamcode.ProcedureRunsTest do
  use Beamcode.DataCase, async: false

  import Beamcode.OpencodeStub
  import Ecto.Query, only: [from: 2]
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

  @second_look """
  ---
  name: second-look
  steps:
    - name: Draft
    - name: Check
      session: fresh
      agent: review
  ---

  ## Draft
  Draft it.

  ## Check
  Check it.
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

  @pay """
  ---
  name: pay
  key: charge
  inputs:
    charge: { type: text }
    amount: { type: money, currency: NOK }
  call: stripe.refunds.create
  params:
    charge: "{charge}"
    amount: "{amount.minor}"
    idempotency_key: "refund-{charge}"
  ---
  """

  @nuke """
  ---
  name: nuke
  call: stripe.charges.delete
  params:
    charge: ch_1
  ---
  """

  @refund_one """
  ---
  name: refund-one
  key: message
  inputs:
    message: { type: text }
    email: { type: text }
  steps:
    - name: Look up
      call: stripe.customers_search
      params: { q: "{email}" }
      returns: customer
    - name: Comment
      call: stripe.comments_create
      params: { message: "{message}", body: "https://shop.test/refund/{customer.id}" }
  ---
  """

  @comment_m1 """
  ---
  name: comment-m1
  run: refund-one
  with: { message: m1, email: "ola@x.no" }
  ---
  """

  @pay_ch9 """
  ---
  name: pay-ch9
  run: pay
  with: { charge: ch_9, amount: "10" }
  ---
  """

  @stripe ~s({"name": "stripe", "baseUrl": "https://api.stripe.test",
    "auth": {"type": "bearer", "secret": "STRIPE_KEY"},
    "tools": {"refunds_create": ["POST", "/v1/refunds", "ask", "Refund a charge"],
              "charges_delete": ["DELETE", "/v1/charges/{charge}", "deny"],
              "customers_search": ["GET", "/v1/customers/search", "allow"],
              "comments_create": ["POST", "/v1/comments", "allow"]},
    "projects": ["amino-maintenance"]})

  @models [
    %{"id" => "claude-haiku-5-5", "providerID" => "anthropic"},
    %{"id" => "claude-opus-5-5", "providerID" => "anthropic", "variants" => [%{"id" => "high"}]},
    %{"id" => "claude-sonnet-5-5", "providerID" => "anthropic"}
  ]

  # A fake OpenCode: the Project's chat "chat", sessions made on POST (s1, s2,
  # …), and what each session last said (`reply/2`).
  setup do
    user = user_fixture()
    # The engine in a Project with one chat; Operations runs get their own (OpsChatsTest).
    folder = project_fixture(%{name: "amino-maintenance", kind: "dataset", directory: @dir}, user)

    oc =
      start_supervised!(
        {Agent,
         fn ->
           %{n: 0, created: [], prompts: [], models: [], agents: [], replies: %{}}
         end}
      )

    files = %{
      ".peon/procedures/email-refunds.md" => @email_refunds,
      ".peon/procedures/ship.md" => @ship,
      ".peon/procedures/second-look.md" => @second_look,
      ".peon/procedures/finder.md" => @finder,
      ".peon/procedures/refund.md" => @refund,
      ".peon/procedures/monday-ops.md" => @chain,
      ".peon/refund-policy.md" => "Refund double charges.",
      ".peon/procedures/pay.md" => @pay,
      ".peon/procedures/nuke.md" => @nuke,
      ".peon/procedures/refund-one.md" => @refund_one,
      ".peon/procedures/comment-m1.md" => @comment_m1,
      ".peon/procedures/pay-ch9.md" => @pay_ch9,
      "connectors/stripe.json" => @stripe
    }

    setup_stub(fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case {conn.method, String.split(conn.request_path, "/", trim: true)} do
        {"GET", ["api", "session"]} ->
          data(conn, [
            %{"id" => "chat", "title" => "chat", "time" => %{"created" => 1, "updated" => 1}}
          ])

        {"POST", ["api", "session"]} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)

          id =
            Agent.get_and_update(oc, fn s ->
              id = "s#{s.n + 1}"
              {id, %{s | n: s.n + 1, created: s.created ++ [{id, Jason.decode!(body)}]}}
            end)

          data(conn, %{"id" => id})

        {"GET", ["api", "session", "chat"]} ->
          data(conn, %{"id" => "chat", "model" => %{"id" => "qwen", "providerID" => "local"}})

        {"POST", ["api", "session", sid, "prompt"]} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          Agent.update(oc, &%{&1 | prompts: &1.prompts ++ [{sid, Jason.decode!(body)["text"]}]})
          data(conn, %{})

        {"POST", ["api", "session", sid, "model"]} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          Agent.update(oc, &%{&1 | models: &1.models ++ [{sid, Jason.decode!(body)["model"]}]})
          data(conn, %{})

        {"POST", ["api", "session", sid, "agent"]} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          Agent.update(oc, &%{&1 | agents: &1.agents ++ [{sid, Jason.decode!(body)["agent"]}]})
          data(conn, %{})

        {"GET", ["api", "session", sid, "message"]} ->
          text = Agent.get(oc, &Map.get(&1.replies, sid, ""))

          data(conn, [
            %{"type" => "assistant", "content" => [%{"type" => "text", "text" => text}]}
          ])

        {"GET", ["api", "model"]} ->
          data(conn, @models)

        # A shared skill, so the Project's own (none) are known at once.
        {"GET", ["api", "skill"]} ->
          data(conn, [
            %{"name" => "shared", "path" => "/srv/routines/.opencode/skill/shared/SKILL.md"}
          ])

        {"GET", ["api", "fs", "list"]} ->
          path = conn.query_params["path"]

          entries =
            for {file, _} <- files,
                Path.dirname(file) == path,
                do: %{"path" => file, "type" => "file"}

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

  defp reply(oc, sid, text),
    do: Agent.update(oc, &%{&1 | replies: Map.put(&1.replies, sid, text)})

  defp last_prompt(oc), do: Agent.get(oc, &List.last(&1.prompts))
  defp reload(run), do: Repo.get!(Run, run.id)

  test "steps switch models, fresh ones get a hand-over, outputs are kept", %{
    user: user,
    folder: folder,
    oc: oc
  } do
    {:ok, run} = Runs.start(folder, user, "email-refunds", %{}, trigger: "slash")
    assert run.session_id == "chat"

    # Read: a fresh child of the chat, on Haiku, with the default `since`.
    assert [{"s1", %{"parentID" => "chat", "model" => %{"id" => "claude-haiku-5-5"}}}] =
             Agent.get(oc, & &1.created)

    assert {"s1", text} = last_prompt(oc)
    assert text =~ "/email-refunds · Read (step 1 of 3)"
    assert text =~ ~r"Read support mail since \d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\."

    reply(oc, "s1", "Ola asked for 299 back.")
    Runs.session_idle("s1", :ok)

    # Decide: fresh again, on Opus high, handed Read's answer and the policy.
    assert {"s2", %{"model" => %{"id" => "claude-opus-5-5", "variant" => "high"}}} =
             Agent.get(oc, &List.last(&1.created))

    assert {"s2", text} = last_prompt(oc)
    assert text =~ "### What Read said\n\nOla asked for 299 back."
    assert text =~ "### refund-policy.md\n\nRefund double charges."
    assert text =~ "```peon-output"

    reply(
      oc,
      "s2",
      ~s(Approved.\n```peon-output\n{"approved": [{"charge": "ch_1", "amount": 299, "name": "Ola"}]}\n```)
    )

    Runs.session_idle("s2", :ok)

    # Post: in the chat itself, switched to Sonnet, offering /refund buttons.
    assert [{"chat", %{"id" => "claude-sonnet-5-5"}}] = Agent.get(oc, & &1.models)
    assert {"chat", text} = last_prompt(oc)
    assert text =~ "run:refund?charge=…&amount=…"

    reply(oc, "chat", "- **Ola** [Send refund](run:refund?charge=ch_1&amount=299&currency=NOK)")
    Runs.session_idle("chat", :ok)

    run = reload(run)
    assert run.status == "done"

    # The chat gets its own model back.
    assert [
             {"chat", %{"id" => "claude-sonnet-5-5"}},
             {"chat", %{"id" => "qwen", "providerID" => "local"}}
           ] =
             Agent.get(oc, & &1.models)

    assert run.outputs["approved"] == [%{"charge" => "ch_1", "amount" => 299, "name" => "Ola"}]
    assert run.summary == "1 × Send refund · 299 NOK"
    assert Enum.map(run.steps, & &1["status"]) == ["done", "done", "done"]
  end

  test "a step can start fresh on another agent", %{user: user, folder: folder, oc: oc} do
    {:ok, run} = Runs.start(folder, user, "second-look", %{}, trigger: "slash")
    assert {"chat", _} = last_prompt(oc)
    assert Agent.get(oc, & &1.agents) == []

    reply(oc, "chat", "Drafted.")
    Runs.session_idle("chat", :ok)

    assert [{"s1", %{"parentID" => "chat"}}] = Agent.get(oc, & &1.created)
    assert Agent.get(oc, & &1.agents) == [{"s1", "review"}]
    assert {"s1", text} = last_prompt(oc)
    assert text =~ "Check it."
    assert Enum.at(reload(run).steps, 1)["status"] == "running"
  end

  test "a step whose end was never heard is found once its session is idle", %{
    user: user,
    folder: folder
  } do
    {:ok, run} = Runs.start(folder, user, "email-refunds", %{}, trigger: "slash")
    idle = fn _sid -> false end

    assert Runs.stalled_steps(idle) == []
    assert Runs.stalled_steps(idle, 0) == [{run.id, 0, "s1"}]
    assert Runs.stalled_steps(fn _sid -> true end, 0) == []
  end

  test "waits for you, goes back with a note, and loops a review at most max times",
       %{user: user, folder: folder, oc: oc} do
    {:ok, run} = Runs.start(folder, user, "ship", %{"task" => "refund status"})

    assert {"chat",
            "/ship · Plan (step 1 of 4)\n\nInputs: task: refund status\n\nPlan refund status."} =
             last_prompt(oc)

    Runs.session_idle("chat", :ok)
    run = reload(run)

    assert %{
             status: "waiting",
             waiting: %{"kind" => "after", "next" => "Build", "back" => "Plan"}
           } = run

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

    assert [%{procedure: "finder", parent_id: parent, trigger: "chain"}] =
             Repo.all(from r in Run, where: r.parent_id == ^run.id)

    assert parent == run.id

    items =
      ~s([{"charge": "ch_1", "amount": 299, "currency": "NOK"}, {"charge": "ch_2", "amount": 99, "currency": "NOK"}])

    reply(oc, "s1", "Two.\n```peon-output\n{\"approved\": #{items}}\n```")
    Runs.session_idle("s1", :ok)

    run = reload(run)

    assert %{
             status: "waiting",
             seen: false,
             waiting: %{"kind" => "before", "text" => "Send 2 refunds · 398 NOK?"}
           } = run

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

    assert [
             %{"status" => "done"},
             %{"status" => "done", "text" => "1 run"},
             %{"status" => "done"}
           ] = run.steps
  end

  test "a failed child stops the chain", %{user: user, folder: folder} do
    {:ok, run} = Runs.start(folder, user, "monday-ops", %{})
    Runs.session_idle("s1", :failed)

    assert %{status: "failed", error: "Find: finder failed: " <> _} = reload(run)
  end

  describe "a connector call step" do
    setup %{user: user, folder: folder} do
      {:ok, _} =
        Beamcode.Projects.insert_project(
          %{name: "setup", kind: "system", directory: "/srv/setup", scope: "team"},
          nil
        )

      {:ok, _} = Beamcode.Vault.put(folder, "STRIPE_KEY", "sk_test", user)
      calls = start_supervised!({Agent, fn -> [] end}, id: :calls)
      before = Application.get_env(:beamcode, :connector_req_options)
      Application.put_env(:beamcode, :connector_req_options, plug: {Req.Test, :stripe})
      on_exit(fn -> Application.put_env(:beamcode, :connector_req_options, before || []) end)

      Req.Test.stub(:stripe, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        conn = Plug.Conn.fetch_query_params(conn)
        key = Plug.Conn.get_req_header(conn, "idempotency-key")
        sent = if body == "", do: conn.query_params, else: Jason.decode!(body)
        Agent.update(calls, &(&1 ++ [{conn.method, conn.request_path, sent, key}]))

        case conn.request_path do
          "/v1/customers/search" when sent == %{"q" => "nobody@x.no"} -> Req.Test.json(conn, %{})
          "/v1/customers/search" -> Req.Test.json(conn, %{"id" => "cus_7", "name" => "Ola"})
          _ -> Req.Test.json(conn, %{"id" => "re_1", "status" => "succeeded"})
        end
      end)

      %{calls: calls}
    end

    test "asks first (the tool is ask), then calls with no model", %{
      user: user,
      folder: folder,
      oc: oc,
      calls: calls
    } do
      {:ok, run} = Runs.start(folder, user, "pay", %{"charge" => "ch_1", "amount" => "299"})
      assert %{status: "waiting", waiting: %{"kind" => "before"}} = run
      assert Agent.get(calls, & &1) == []

      {:ok, done} = Runs.continue(run)

      assert [
               {"POST", "/v1/refunds", %{"charge" => "ch_1", "amount" => "29900"},
                ["refund-ch_1"]}
             ] = Agent.get(calls, & &1)

      assert %{status: "done", summary: "200 · succeeded · re_1"} = done
      # No model, no message.
      assert Agent.get(oc, & &1.prompts) == []
    end

    test "returns keeps the answer for the next step", %{
      user: user,
      folder: folder,
      calls: calls
    } do
      {:ok, run} =
        Runs.start(folder, user, "refund-one", %{"message" => "m1", "email" => "ola@x.no"})

      assert %{status: "done", outputs: %{"customer" => %{"id" => "cus_7"}}} = run

      assert [
               {"GET", "/v1/customers/search", %{"q" => "ola@x.no"}, _},
               {"POST", "/v1/comments",
                %{"message" => "m1", "body" => "https://shop.test/refund/cus_7"}, _}
             ] = Agent.get(calls, & &1)

      assert hd(run.steps)["text"] =~ "200 · cus_7\n\n```json"
    end

    test "a child that finishes at once moves the chain on; a chain never acts twice on a key",
         %{user: user, folder: folder, calls: calls} do
      {:ok, run} = Runs.start(folder, user, "comment-m1", %{})
      assert %{status: "done", outputs: %{"customer" => %{"id" => "cus_7"}}} = reload(run)
      assert length(Agent.get(calls, & &1)) == 2

      {:ok, again} = Runs.start(folder, user, "comment-m1", %{})
      assert %{status: "done"} = again = reload(again)
      assert length(Agent.get(calls, & &1)) == 2

      [child] = Repo.all(from r in Run, where: r.parent_id == ^again.id)
      assert child.summary =~ "Already done for message m1"

      # By hand it runs again.
      {:ok, _} = Runs.start(folder, user, "refund-one", %{"message" => "m1", "email" => "a@b.no"})
      assert length(Agent.get(calls, & &1)) == 4
    end

    test "a skipped child doesn't count as done", %{user: user, folder: folder, calls: calls} do
      {:ok, run} = Runs.start(folder, user, "pay-ch9", %{})
      [child] = Repo.all(from r in Run, where: r.parent_id == ^run.id)
      assert child.status == "waiting"
      {:ok, _} = Runs.skip(child)

      assert %{status: "done", steps: [%{"status" => "skipped"}]} = reload(run)

      {:ok, again} = Runs.start(folder, user, "pay-ch9", %{})
      [child] = Repo.all(from r in Run, where: r.parent_id == ^again.id)
      assert child.status == "waiting"
      assert Agent.get(calls, & &1) == []
    end

    test "a placeholder with no value stops the call", %{
      user: user,
      folder: folder,
      calls: calls
    } do
      {:ok, run} =
        Runs.start(folder, user, "refund-one", %{"message" => "m1", "email" => "nobody@x.no"})

      assert %{status: "failed", error: "Comment: No value for {customer.id}."} = run
      assert [{"GET", "/v1/customers/search", _, _}] = Agent.get(calls, & &1)
    end

    test "a denied tool is never called", %{user: user, folder: folder, calls: calls} do
      {:ok, run} = Runs.start(folder, user, "nuke", %{})
      assert %{status: "failed", error: "nuke: stripe · charges.delete is denied."} = run
      assert Agent.get(calls, & &1) == []
    end
  end

  describe "since the last run" do
    @input %{name: "since", type: "date", default: "last_run", max: "4d"}

    defp finished(folder, status, at) do
      Repo.insert!(%Run{
        project_id: folder.id,
        schedule_key: "manual",
        procedure: "email-refunds",
        status: status,
        inserted_at: at,
        updated_at: at
      })
    end

    test "starts where the last finished run started, at most max back", %{folder: folder} do
      now = ~U[2026-10-13 07:00:00Z]
      proc = %{name: "email-refunds"}

      assert %{value: "2026-10-09T07:00:00Z", last: nil, capped: false} =
               Runs.since(folder, proc, @input, now)

      finished(folder, "done", ~U[2026-10-02 07:00:00Z])

      assert %{value: "2026-10-09T07:00:00Z", capped: true} =
               Runs.since(folder, proc, @input, now)

      finished(folder, "done", ~U[2026-10-12 07:00:00Z])
      # A failed run doesn't move it on.
      finished(folder, "failed", ~U[2026-10-13 06:00:00Z])

      assert %{value: "2026-10-12T07:00:00Z", last: "2026-10-12T07:00:00Z", capped: false} =
               Runs.since(folder, proc, @input, now)
    end

    test "a run fills since with a time; a span counts back from now", %{
      user: user,
      folder: folder
    } do
      {:ok, run} = Runs.start(folder, user, "email-refunds", %{})
      assert {:ok, _, _} = DateTime.from_iso8601(run.inputs["since"])

      {:ok, run} = Runs.start(folder, user, "email-refunds", %{"since" => "1d"})
      {:ok, t, _} = DateTime.from_iso8601(run.inputs["since"])
      assert_in_delta DateTime.diff(DateTime.utc_now(), t), 86_400, 5

      {:ok, run} = Runs.start(folder, user, "email-refunds", %{"since" => "2026-10-01"})
      assert run.inputs["since"] == "2026-10-01"
    end
  end
end
