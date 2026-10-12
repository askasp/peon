defmodule Beamcode.DataSourcesTest do
  use Beamcode.DataCase, async: false

  import Beamcode.OpencodeStub
  import BeamcodeWeb.ChannelCase, only: [project_fixture: 2]
  alias Beamcode.{DataSources, ProjectFiles}

  @moduletag :tmp_dir

  # A tiny OpenCode whose shell really runs the command, and whose files are
  # the folder's, so sources run for real.
  setup %{tmp_dir: dir} do
    runs = start_supervised!({Agent, fn -> %{} end})

    setup_stub(fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/fs/read/" <> path} ->
          case File.read(Path.join(dir, URI.decode(path))) do
            {:ok, body} -> Plug.Conn.send_resp(conn, 200, body)
            _ -> Plug.Conn.send_resp(conn, 404, "")
          end

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

    File.mkdir_p!(Path.join(dir, "sources"))

    File.write!(Path.join(dir, "sources/weather.py"), """
    import os, sqlite3, datetime
    c = sqlite3.connect("data.sqlite")
    c.execute("create table if not exists weather(day text primary key, temp real, fetched_at text)")
    now = datetime.datetime.now(datetime.timezone.utc).isoformat()
    c.execute("insert into weather values ('mon', ?, ?) on conflict(day) do update set temp = excluded.temp, fetched_at = excluded.fetched_at", (float(os.environ["TEMP"]), now))
    c.commit()
    """)

    File.write!(Path.join(dir, "sources/broken.py"), "raise SystemExit('API said no')\n")
    File.write!(Path.join(dir, ".env"), "TEMP=12.5\n")

    File.write!(
      Path.join(dir, "sources.json"),
      Jason.encode!(%{
        "weather" => %{"script" => "sources/weather.py", "table" => "weather", "every_hours" => 6},
        "broken" => %{"script" => "sources/broken.py", "table" => "nothing"},
        "outside" => %{"script" => "../evil.py", "table" => "x"},
        "other" => %{"script" => "sources/o.py", "table" => "o", "db" => "other.sqlite"}
      })
    )

    %{project: project_fixture(%{name: "weather", kind: "dataset", directory: dir}, nil)}
  end

  test "a source runs with the folder's .env and shows how old its data is", %{project: project} do
    assert [%{name: "weather", fetched_at: nil, stale: true}] =
             DataSources.list(project) |> Enum.filter(&(&1.name == "weather"))

    assert :ok = DataSources.refresh(project, "weather")
    assert :ok = DataSources.refresh(project, "weather")

    assert {:ok, [%{"day" => "mon", "temp" => 12.5}]} =
             ProjectFiles.query(project, "data.sqlite", "select day, temp from weather")

    assert %{fetched_at: at, stale: false, every_hours: 6} =
             Enum.find(DataSources.list(project), &(&1.name == "weather"))

    assert is_binary(at)
  end

  test "only sources in sources/ for that file are listed", %{project: project} do
    assert project |> DataSources.list() |> Enum.map(& &1.name) |> Enum.sort() ==
             ["broken", "weather"]

    assert [%{name: "other"}] = DataSources.list(project, "other.sqlite")
    assert {:error, "No source outside in sources.json"} = DataSources.refresh(project, "outside")
  end

  test "a failing script's last line comes back", %{project: project} do
    assert {:error, "API said no"} = DataSources.refresh(project, "broken")
  end

  test "the keys in .env are never read out", %{project: project} do
    assert {:error, :enoent} = ProjectFiles.read(project, ".env")
    assert {:error, :enoent} = ProjectFiles.read(project, "sub/.env")
  end
end
