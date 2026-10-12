defmodule Beamcode.ProjectFilesTest do
  use Beamcode.DataCase, async: false

  import Beamcode.OpencodeStub
  import BeamcodeWeb.ChannelCase, only: [project_fixture: 2]
  alias Beamcode.ProjectFiles

  @moduletag :tmp_dir

  # A tiny OpenCode whose shell really runs the command in the folder.
  setup %{tmp_dir: dir} do
    {_, 0} =
      System.cmd(
        "python3",
        [
          "-c",
          "import sqlite3; c=sqlite3.connect('data.sqlite'); " <>
            "c.execute(\"create table \\\"Loans\\\"(tool text, borrower text)\"); " <>
            "c.execute(\"insert into Loans values ('Ladder', 'Kari''s')\"); c.execute('create table Tools(name text)'); c.commit()"
        ],
        cd: dir
      )

    runs = start_supervised!({Agent, fn -> %{} end})

    setup_stub(fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/api/shell"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)

          {out, code} =
            System.cmd("sh", ["-c", Jason.decode!(body)["command"]],
              cd: dir,
              stderr_to_stdout: true
            )

          id = "sh#{System.unique_integer([:positive])}"
          Agent.update(runs, &Map.put(&1, id, {code, out}))
          data(conn, %{"id" => id})

        {"GET", "/api/shell/" <> rest} ->
          case String.split(rest, "/") do
            [id] ->
              data(conn, %{"status" => "done", "exit" => elem(Agent.get(runs, & &1[id]), 0)})

            [id, "output"] ->
              data(conn, %{"output" => elem(Agent.get(runs, & &1[id]), 1)})
          end
      end
    end)

    %{project: project_fixture(%{name: "loans", kind: "dataset", directory: dir}, nil)}
  end

  test "a SQLite file's tables and rows", %{project: project} do
    assert {:ok, %{tables: tables, table: "Loans", columns: ["tool", "borrower"], rows: rows}} =
             ProjectFiles.table(project, "data.sqlite")

    assert tables == [%{name: "Loans", rows: 1}, %{name: "Tools", rows: 0}]
    assert rows == [%{"tool" => "Ladder", "borrower" => "Kari's"}]

    assert {:ok, %{table: "Tools", rows: []}} =
             ProjectFiles.table(project, "data.sqlite", "Tools")

    assert {:error, :bad_path} = ProjectFiles.table(project, "../data.sqlite")
  end

  test "read-only queries for apps", %{project: project, tmp_dir: dir} do
    assert {:ok, [%{"n" => 1}]} =
             ProjectFiles.query(project, "data.sqlite", "select count(*) as n from Loans")

    assert {:error, _} = ProjectFiles.query(project, "data.sqlite", "delete from Loans")
    assert {:error, _} = ProjectFiles.query(project, "data.sqlite", ".shell touch x")

    assert {:error, _} =
             ProjectFiles.query(project, "data.sqlite", "attach '#{dir}/data.sqlite' as other")

    assert {:ok, [%{"n" => 1}]} =
             ProjectFiles.query(project, "data.sqlite", "select count(*) as n from Loans")
  end
end
