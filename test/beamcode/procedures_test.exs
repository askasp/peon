defmodule Beamcode.ProceduresTest do
  use Beamcode.DataCase, async: false

  import Beamcode.OpencodeStub
  alias Beamcode.Procedures
  alias Beamcode.Procedures.Yaml
  alias Beamcode.Projects.Project

  @refund """
  ---
  name: refund
  description: Refund one Stripe charge. Asks before it sends.
  key: charge
  inputs:
    charge: { type: text }
    amount: { type: money, currency: NOK }
    name: { type: text }
  call: stripe.refunds.create
  params:
    charge: "{charge}"
    amount: "{amount.minor}"
    idempotency_key: "refund-{charge}"
  confirm: Refund {amount} NOK on {charge} to {name}?
  ---
  """

  @email_refunds """
  ---
  name: email-refunds
  description: Read support mail and list who should get a refund
  inputs:
    since: { type: date, default: last_run }
  outputs:
    approved: [{ charge: text, amount: money, name: text }]
  schedule: Mon 07:00
  steps:
    - name: Read
      model: haiku
      effort: low
      session: fresh
      uses: [front]
    - name: Decide
      model: opus
      effort: high
      session: fresh
      uses: [stripe: read]
      hand_over: [Read, refund-policy.md]
      returns: approved
    - name: Post
      model: sonnet
      session: same
      offers: refund
  ---

  ## Read
  Read support mail since {since}. List every refund
  request with the customer and the charge ID.

  ## Decide
  Check each request against refund-policy.md and Stripe.

  ## Post
  Post the approved requests to the Project chat.
  """

  @ship """
  ---
  name: ship
  description: Plan, build, review with a second model, preview
  inputs:
    task: { type: text }
  queue: default
  steps:
    - name: Plan
      model: opus
      wait: me
    - name: Build
      model: sonnet
    - name: Review
      model: gpt-5-codex
      session: fresh
      hand_over: [ticket, diff, review.md]
      on_changes: { back_to: Build, max: 2 }
    - name: Merge
      wait: me
  ---

  ## Plan
  Read the ticket and the code. Write a short plan.

  ## Build
  Follow the plan.

  ## Review
  Review the diff.
  """

  @monday_ops """
  ---
  name: monday-ops
  schedule: { at: Mon 07:00, tz: Europe/Oslo }
  steps:
    - name: Reconcile
      run: stripe-reconcile
      on_fail: continue
    - name: Find refunds
      run: email-refunds
    - name: Refund
      run: refund
      for_each: email-refunds.approved
      wait: me
      confirm: Send {count} refunds · {total} NOK?
    - name: Report
      model: sonnet
      uses: [slack]
  ---

  ## Report
  Post a short summary of the steps above to #ops.
  """

  describe "parse/2" do
    test "one connector call, no prompt" do
      assert {:ok, p} = Procedures.parse(@refund)
      assert p.name == "refund" and p.key == "charge"
      assert Enum.map(p.inputs, & &1.name) == ["charge", "amount", "name"]
      assert %{type: "money", currency: "NOK"} = Enum.at(p.inputs, 1)

      assert [
               %{kind: "call", call: "stripe.refunds.create", confirm: "Refund {amount} NOK" <> _} =
                 s
             ] =
               p.steps

      assert s.params == %{
               "charge" => "{charge}",
               "amount" => "{amount.minor}",
               "idempotency_key" => "refund-{charge}"
             }
    end

    test "steps with models, sessions, hand-overs and their prompts" do
      assert {:ok, p} = Procedures.parse(@email_refunds)
      assert p.schedule == %{at: "Mon 07:00", tz: nil, cron: "0 7 * * 1"}
      assert p.outputs == %{"approved" => ["charge", "amount", "name"]}
      assert [read, decide, post] = p.steps
      assert %{kind: "prompt", model: "haiku", effort: "low", uses: ["front"]} = read
      assert read.prompt =~ "Read support mail since {since}."

      assert %{session: "fresh", hand_over: ["Read", "refund-policy.md"], returns: "approved"} =
               decide

      assert decide.uses == ["stripe"]
      assert %{session: "same", offers: "refund"} = post
    end

    test "waits, loops back, and the Queue default" do
      assert {:ok, p} = Procedures.parse(@ship)
      assert p.queue == "default"
      assert [plan, _build, review, merge] = p.steps
      assert plan.wait and plan.kind == "prompt"
      assert review.on_changes == %{back_to: "Build", max: 2}
      assert %{kind: "wait", wait: true} = merge
    end

    test "a chain runs other procedures" do
      assert {:ok, p} = Procedures.parse(@monday_ops)
      assert p.schedule.tz == "Europe/Oslo"
      assert [rec, find, refund, report] = p.steps
      assert %{kind: "run", run: "stripe-reconcile", on_fail: "continue"} = rec
      assert %{kind: "run", run: "email-refunds", on_fail: "stop"} = find

      assert %{for_each: "email-refunds.approved", wait: true, confirm: "Send {count}" <> _} =
               refund

      assert %{kind: "prompt", prompt: "Post a short summary" <> _} = report
    end

    test "a plain body is the one step's prompt; bad YAML is an error" do
      assert {:ok, %{name: "hello", steps: [%{kind: "prompt", prompt: "Say hi to {name}."}]}} =
               Procedures.parse("Say hi to {name}.\n", "hello")

      assert {:error, msg} = Procedures.parse("---\nname: [oops\n---\n")
      assert msg =~ "line 1"
    end
  end

  test "the YAML subset reads back what it writes" do
    {:ok, p} = Procedures.parse(@email_refunds)
    text = Yaml.dump(p.front)
    assert {:ok, again} = Yaml.parse(text)
    assert again == p.front
    assert text =~ "  since: { type: date, default: last_run }"
    assert text =~ "    uses: [stripe: read]"
  end

  test "schedules in words" do
    assert Procedures.schedule("daily 02:00").cron == "0 2 * * *"
    assert Procedures.schedule("weekdays 08:30").cron == "30 8 * * 1-5"
    assert Procedures.schedule("Fri 16:00").cron == "0 16 * * 5"
    assert Procedures.schedule("*/5 * * * *").cron == "*/5 * * * *"
    assert Procedures.schedule("whenever").cron == nil
  end

  test "fill/2 and money in minor units" do
    values = %{"charge" => "ch_1", "amount" => "299", "name" => "Ola  Nordmann"}

    assert Procedures.fill("{charge} {amount.minor} {name} {nope}", values) ==
             "ch_1 29900 Ola Nordmann {nope}"

    assert Procedures.fill("{amount.minor}", %{"amount" => "12,5"}) == "1250"
  end

  test "fill/2 reaches into returned values and formats times" do
    values = %{
      "since" => "2026-10-12T07:00:00Z",
      "customer" => %{"id" => "cus_1", "matches" => [%{"email" => "a@b.no"}]},
      "finder.approved" => [%{"charge" => "ch_1"}]
    }

    assert Procedures.fill("{customer.id} {customer.matches.0.email}", values) ==
             "cus_1 a@b.no"

    assert Procedures.fill("{finder.approved.0.charge} {customer.nope}", values) ==
             "ch_1 {customer.nope}"

    assert Procedures.fill("{since.unix} {since.date} {since}", values) ==
             "1791788400 2026-10-12 2026-10-12T07:00:00Z"

    assert Procedures.fill("{customer}", values) =~ ~s("id":"cus_1")
  end

  test "duration/1 reads spans" do
    assert Procedures.duration("4d") == 4 * 86_400
    assert Procedures.duration("4 days") == 4 * 86_400
    assert Procedures.duration("12h") == 12 * 3_600
    assert Procedures.duration("2w") == 14 * 86_400
    assert Procedures.duration("3") == 3 * 86_400
    assert Procedures.duration("soon") == nil
    assert Procedures.duration(nil) == nil
  end

  test "model names resolve to the newest match, effort to its variant" do
    models = [
      %{"id" => "claude-opus-4-1", "providerID" => "anthropic"},
      %{
        "id" => "claude-opus-5-5",
        "providerID" => "anthropic",
        "variants" => [%{"id" => "high"}]
      },
      %{"id" => "gpt-5-codex", "providerID" => "openai"}
    ]

    assert Procedures.resolve_model("opus", "high", models) ==
             %{"id" => "claude-opus-5-5", "providerID" => "anthropic", "variant" => "high"}

    assert %{"id" => "gpt-5-codex"} = Procedures.resolve_model("gpt-5-codex", "high", models)
    assert Procedures.resolve_model("nope", nil, models) == nil

    # A short name prefers the default model's provider.
    local = models ++ [%{"id" => "claude-opus-4-9", "providerID" => "local"}]
    assert %{"providerID" => "local"} = Procedures.resolve_model("opus", nil, local, "local")
    assert Procedures.model_label("gpt-5-codex") == "GPT-5 Codex"
    assert Procedures.model_label("opus") == "Opus"
  end

  describe "legacy prompts (Projects from before the file format)" do
    @digest %{
      name: "digest",
      source: "legacy",
      run: "/digest since {since} in {inboxes}",
      key: nil,
      inputs: [
        %{name: "inboxes", default: ["Support", "Billing"], options: [], multi: true},
        %{name: "since", default: "last run", options: [], multi: false}
      ]
    }

    @legacy_refund %{
      name: "refund",
      source: "legacy",
      run: nil,
      key: "charge",
      inputs: [
        %{name: "amount", default: "", options: [], multi: false},
        %{name: "charge", default: "", options: [], multi: false},
        %{name: "name", default: "", options: [], multi: false}
      ]
    }

    test "fills the run template with defaults and given values" do
      assert Procedures.prompt(@digest, %{}) == "/digest since last run in Support, Billing"

      assert Procedures.prompt(@digest, %{"since" => "today", "inboxes" => ["Sales"]}) ==
               "/digest since today in Sales"
    end

    test "without a run prompt: /name and the values, key first, extras last" do
      values = %{
        "name" => "Ola  Nordmann",
        "amount" => "299",
        "charge" => "ch_1",
        "currency" => "NOK"
      }

      assert Procedures.prompt(@legacy_refund, values) ==
               "/refund charge: ch_1, amount: 299, name: Ola Nordmann, currency: NOK"
    end

    test "batch_prompt/2 sends every row in one message" do
      rows = [%{"charge" => "ch_1", "amount" => "299"}, %{"charge" => "ch_2", "amount" => "99"}]

      assert Procedures.batch_prompt(@legacy_refund, rows) ==
               "/refund Run this once for each row, in order:\n" <>
                 "- charge: ch_1, amount: 299\n- charge: ch_2, amount: 99"
    end
  end

  describe "list/1" do
    @dir "/srv/routines/amino-maintenance"
    @setup "/srv/setup"

    setup do
      {:ok, _} =
        Beamcode.Projects.insert_project(
          %{name: "setup", kind: "system", directory: @setup, scope: "team"},
          nil
        )

      :ok
    end

    # An OpenCode with these skills, and files by folder.
    defp stub(files) do
      setup_stub(fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        dir = get_in(conn.query_params, ["location", "directory"])

        case conn.request_path do
          "/api/skill" ->
            data(conn, [
              %{
                "name" => "refund",
                "description" => "Refund one charge",
                "path" => @dir <> "/.opencode/skill/refund/SKILL.md"
              },
              %{"name" => "shared", "path" => "/srv/routines/.opencode/skill/shared/SKILL.md"}
            ])

          "/api/fs/list" ->
            path = conn.query_params["path"]
            prefix = Path.join(dir, path) <> "/"

            entries =
              for {file, _} <- files,
                  String.starts_with?(file, prefix),
                  do: %{"path" => String.replace_prefix(file, dir <> "/", ""), "type" => "file"}

            data(conn, entries)

          "/api/fs/read/" <> file ->
            case files[Path.join(dir, file)] do
              nil -> Plug.Conn.send_resp(conn, 404, "")
              body -> Plug.Conn.send_resp(conn, 200, body)
            end
        end
      end)
    end

    defp folder(kind \\ "routine"),
      do: %Project{name: "amino-maintenance", kind: kind, directory: @dir}

    test "the Project's files, its legacy skills, and global ones it doesn't replace" do
      stub(%{
        (@dir <> "/.peon/procedures/email-refunds.md") => @email_refunds,
        (@dir <> "/procedures.json") =>
          ~s({"refund": {"key": "charge", "inputs": {"charge": {}}}}),
        (@setup <> "/procedures/email-refunds.md") => "---\nname: email-refunds\n---\nOld.",
        (@setup <> "/procedures/explain.md") => "Explain the code."
      })

      assert [own, explain, refund] = Procedures.list(folder())

      assert %{
               name: "email-refunds",
               source: "folder",
               overrides: true,
               path: ".peon/procedures/email-refunds.md"
             } = own

      assert %{name: "explain", source: "global"} = explain

      assert %{name: "refund", source: "legacy", key: "charge", steps: [%{skill: "refund"}]} =
               refund

      assert Procedures.error(folder()) == nil
    end

    test "a code Project lists its files and the global ones, not its skills" do
      stub(%{(@setup <> "/procedures/explain.md") => "Explain the code."})
      assert [%{name: "explain"}] = Procedures.list(folder("code"))
    end

    test "a broken file is reported, the rest still listed" do
      stub(%{
        (@dir <> "/.peon/procedures/bad.md") => "---\nname: [oops\n---\n",
        (@dir <> "/.peon/procedures/ok.md") => "Do it."
      })

      assert ["ok", "refund"] = Enum.map(Procedures.list(folder()), & &1.name)
      assert Procedures.error(folder()) =~ ".peon/procedures/bad.md"
    end
  end

  describe "edit/3" do
    setup do
      files = start_supervised!({Agent, fn -> %{".peon/procedures/refund.md" => @refund} end})

      setup_stub(fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        case {conn.method, conn.request_path} do
          {"GET", "/api/fs/list"} ->
            path = conn.query_params["path"]

            data(
              conn,
              for(
                f <- Agent.get(files, &Map.keys/1),
                Path.dirname(f) == path,
                do: %{"path" => f, "type" => "file"}
              )
            )

          {"GET", "/api/fs/read/" <> file} ->
            case Agent.get(files, & &1[file]) do
              nil -> Plug.Conn.send_resp(conn, 404, "")
              body -> Plug.Conn.send_resp(conn, 200, body)
            end

          {"POST", "/api/experimental/fs/write"} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            Agent.update(files, &Map.put(&1, conn.query_params["path"], body))
            data(conn, %{})

          _ ->
            data(conn, [])
        end
      end)

      %{files: files, project: %Project{name: "ops", kind: "chat", directory: "/srv/ops"}}
    end

    defp file(files), do: Agent.get(files, & &1[".peon/procedures/refund.md"])

    test "a second step moves the settings under steps:, and back", %{
      files: files,
      project: project
    } do
      assert :ok = Procedures.edit(project, "refund", %{"op" => "add_step"})
      {:ok, p} = Procedures.parse(file(files))

      assert [
               %{name: "Step 1", kind: "call", call: "stripe.refunds.create"},
               %{name: "Step 2", kind: "prompt"}
             ] = p.steps

      assert file(files) =~ "## Step 2\nSay what this step does."
      assert file(files) =~ "name: refund\ndescription:"

      assert :ok =
               Procedures.edit(project, "refund", %{
                 "op" => "step",
                 "index" => 1,
                 "attrs" => %{
                   "prompt" => "Tell {name}.",
                   "model" => "haiku",
                   "session" => "fresh",
                   "wait" => true
                 }
               })

      {:ok, p} = Procedures.parse(file(files))

      assert %{prompt: "Tell {name}.", model: "haiku", session: "fresh", wait: true} =
               Enum.at(p.steps, 1)

      assert :ok = Procedures.edit(project, "refund", %{"op" => "remove_step", "index" => 0})
      {:ok, p} = Procedures.parse(file(files))
      assert [%{name: "Step 2", kind: "prompt", prompt: "Tell {name}."}] = p.steps

      assert {:error, "A procedure needs a step."} =
               Procedures.edit(project, "refund", %{"op" => "remove_step", "index" => 0})
    end

    test "a call becomes a prompt", %{files: files, project: project} do
      assert :ok = Procedures.edit(project, "refund", %{"op" => "use_prompt", "index" => 0})
      {:ok, p} = Procedures.parse(file(files))
      assert [%{kind: "prompt", call: nil, prompt: "Do it with the inputs above."}] = p.steps
      refute file(files) =~ "params"
    end
  end
end
