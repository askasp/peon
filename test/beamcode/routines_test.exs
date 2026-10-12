defmodule Beamcode.RoutinesTest do
  use ExUnit.Case, async: false

  import Beamcode.OpencodeStub
  alias Beamcode.Routines

  @digest %{
    name: "digest",
    run: "/digest since {since} in {inboxes}",
    key: nil,
    inputs: [
      %{
        name: "inboxes",
        default: ["Support", "Billing"],
        options: ["Support", "Billing", "Sales"],
        multi: true
      },
      %{name: "since", default: "last run", options: ["last run", "today"], multi: false}
    ]
  }

  @refund %{
    name: "refund",
    run: nil,
    key: "charge",
    inputs: [
      %{name: "amount", default: "", options: [], multi: false},
      %{name: "charge", default: "", options: [], multi: false},
      %{name: "name", default: "", options: [], multi: false}
    ]
  }

  describe "prompt/2" do
    test "fills placeholders with defaults" do
      assert Routines.prompt(@digest, %{}) == "/digest since last run in Support, Billing"
    end

    test "given values win, lists are joined" do
      assert Routines.prompt(@digest, %{"since" => "today", "inboxes" => ["Sales"]}) ==
               "/digest since today in Sales"
    end

    test "unknown placeholders are left alone" do
      assert Routines.prompt(%{@digest | run: "/x {nope}"}, %{}) == "/x {nope}"
    end

    test "without a run prompt: /name and the values, key first, extras last" do
      values = %{
        "name" => "Ola  Nordmann",
        "amount" => "299",
        "charge" => "ch_1",
        "currency" => "NOK"
      }

      assert Routines.prompt(@refund, values) ==
               "/refund charge: ch_1, amount: 299, name: Ola Nordmann, currency: NOK"

      assert Routines.prompt(%{@refund | inputs: [], key: nil}, %{}) == "/refund"
    end
  end

  test "batch_prompt/2 sends every row in one message" do
    rows = [%{"charge" => "ch_1", "amount" => "299"}, %{"charge" => "ch_2", "amount" => "99"}]

    assert Routines.batch_prompt(@refund, rows) ==
             "/refund Run this once for each row, in order:\n" <>
               "- charge: ch_1, amount: 299\n- charge: ch_2, amount: 99"

    assert Routines.batch_prompt(@refund, [hd(rows)]) == "/refund charge: ch_1, amount: 299"
  end

  describe "list/1" do
    @dir "/srv/routines/amino-maintenance"
    @project %{name: "amino-maintenance", directory: @dir}

    # An OpenCode with these skills and files in the Folder.
    defp stub(files) do
      setup_stub(fn conn ->
        case conn.request_path do
          "/api/skill" ->
            data(conn, [
              %{
                "name" => "refund",
                "description" => "Refund one charge",
                "path" => @dir <> "/.opencode/skill/refund/SKILL.md"
              },
              %{
                "name" => "email-refunds",
                "description" => "Find refunds",
                "path" => @dir <> "/.opencode/skill/email-refunds/SKILL.md"
              },
              %{
                "name" => "shared",
                "description" => "Not this Folder's",
                "path" => "/srv/routines/.opencode/skill/shared/SKILL.md"
              }
            ])

          "/api/fs/read/" <> file ->
            case files[file] do
              nil -> Plug.Conn.send_resp(conn, 404, "")
              body -> Plug.Conn.send_resp(conn, 200, body)
            end
        end
      end)
    end

    test "the Folder's own skills, with inputs and key from procedures.json" do
      stub(%{
        "procedures.json" =>
          ~s({"refund": {"key": "charge", "inputs": {"charge": {}, "amount": {"default": "0"}}}})
      })

      assert [refunds, refund] = Routines.list(@project)
      assert %{name: "email-refunds", description: "Find refunds", inputs: [], key: nil} = refunds
      assert %{name: "refund", key: "charge", run: nil} = refund
      assert Enum.map(refund.inputs, &{&1.name, &1.default}) == [{"charge", ""}, {"amount", "0"}]
      assert Routines.error(@project) == nil
    end

    test "an old Folder's routine.json is one procedure, for the skill it runs" do
      stub(%{"routine.json" => ~s({"run": "/refund {charge}", "inputs": {"charge": {}}})})

      assert [%{name: "email-refunds", inputs: []}, %{name: "refund", run: "/refund {charge}"}] =
               Routines.list(@project)

      assert %{name: "refund"} = Routines.find(@project, "refund")
      assert %{name: "email-refunds"} = Routines.find(@project, nil)
    end

    test "a broken procedures.json is reported, and the skills still listed" do
      stub(%{"procedures.json" => "{nope"})

      assert ["email-refunds", "refund"] = Enum.map(Routines.list(@project), & &1.name)
      assert Routines.error(@project) =~ "procedures.json"
    end
  end
end
