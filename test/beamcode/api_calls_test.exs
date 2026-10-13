defmodule Beamcode.ApiCallsTest do
  # A Project's own API calls (`.peon/api/*.json`) next to shared connectors.
  use Beamcode.DataCase, async: false

  import BeamcodeWeb.ConnCase, only: [user_fixture: 0]
  import Beamcode.OpencodeStub

  alias Beamcode.{Connectors, Projects, Vault}

  @dir "/srv/ops"

  @stripe ~s({"baseUrl": "https://api.stripe.test",
    "auth": {"type": "bearer", "secret": "STRIPE_KEY"},
    "tools": {"get_charge": ["GET", "/v1/charges/{charge}", "allow", "One charge"],
              "delete_charge": ["DELETE", "/v1/charges/{charge}", "deny"]}})

  @front_shared ~s({"name": "front", "baseUrl": "https://front.test",
    "tools": {"me": ["GET", "/me", "allow"]}, "projects": ["ops", "other"]})

  @stripe_shared ~s({"name": "stripe", "baseUrl": "https://old.test",
    "tools": {"old": ["GET", "/old", "allow"]}, "projects": ["ops"]})

  setup do
    user = user_fixture()

    {:ok, _} =
      Projects.insert_project(
        %{name: "setup", kind: "system", directory: "/srv/setup", scope: "team"},
        nil
      )

    {:ok, project} =
      Projects.insert_project(
        %{name: "ops", kind: "routine", directory: @dir, scope: "team"},
        user
      )

    files =
      start_supervised!(
        {Agent,
         fn ->
           %{
             {@dir, ".peon/api/stripe.json"} => @stripe,
             {"/srv/setup", "connectors/front.json"} => @front_shared,
             {"/srv/setup", "connectors/stripe.json"} => @stripe_shared
           }
         end}
      )

    # Files by {directory, path}; Opencode sends the directory as `location[directory]`.
    setup_stub(fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      dir = conn.query_params["location"]["directory"]

      case {conn.method, String.split(conn.request_path, "/", trim: true)} do
        {"GET", ["api", "fs", "list"]} ->
          path = conn.query_params["path"]

          entries =
            for {{d, file}, _} <- Agent.get(files, & &1),
                d == dir,
                Path.dirname(file) == path,
                do: %{"path" => file, "type" => "file"}

          data(conn, entries)

        {"GET", ["api", "fs", "read" | rest]} ->
          case Agent.get(files, &Map.get(&1, {dir, Enum.join(rest, "/")})) do
            nil -> Plug.Conn.send_resp(conn, 404, "")
            body -> Plug.Conn.send_resp(conn, 200, body)
          end

        {"POST", ["api", "experimental", "fs", "write"]} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          Agent.update(files, &Map.put(&1, {dir, conn.query_params["path"]}, body))
          data(conn, %{})

        _ ->
          data(conn, %{})
      end
    end)

    before = Application.get_env(:beamcode, :connector_req_options)
    Application.put_env(:beamcode, :connector_req_options, plug: {Req.Test, :api})
    on_exit(fn -> Application.put_env(:beamcode, :connector_req_options, before || []) end)

    %{user: user, project: project, files: files}
  end

  test "a Project's own file comes first and replaces a shared one with its name", %{
    project: project
  } do
    services = Connectors.all_for(project)

    assert Enum.map(services, &{&1.name, &1.source}) == [
             {"stripe", "project"},
             {"front", "shared"}
           ]

    assert hd(services).path == ".peon/api/stripe.json"
    assert Enum.map(hd(services).tools, & &1.name) == ["delete_charge", "get_charge"]
  end

  test "only services with their secret set may be called", %{user: user, project: project} do
    assert Enum.map(Connectors.for_project(project), & &1.name) == ["front"]
    {:ok, _} = Vault.put("STRIPE_KEY", "sk_test", user)
    assert Enum.map(Connectors.for_project(project), & &1.name) == ["stripe", "front"]
  end

  test "a person can send any call by hand, even a denied one", %{user: user, project: project} do
    {:ok, _} = Vault.put("STRIPE_KEY", "sk_test", user)

    Req.Test.stub(:api, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer sk_test"]
      Req.Test.json(conn, %{"id" => "ch 1", "path" => conn.request_path})
    end)

    assert {:ok, %{status: 200, body: body, url: url}} =
             Connectors.try_call(project, "stripe", "delete_charge", %{
               "charge" => "ch 1",
               "query" => %{"expand" => "x"}
             })

    assert body =~ "/v1/charges/ch%201"
    assert url == "https://api.stripe.test/v1/charges/ch%201?expand=x"

    assert {:error, "stripe has no nope."} = Connectors.try_call(project, "stripe", "nope", %{})
  end

  test "save checks the file before writing it", %{project: project, files: files} do
    assert {:error, msg} =
             Connectors.save(project, "github", ~s({"tools": {"a": ["GET", "/", "maybe"]}}))

    assert msg =~ "permission"
    assert {:error, _} = Connectors.save(project, "Bad Name", "{}")

    good = ~s({"baseUrl": "https://api.github.com", "tools": {"me": ["GET", "/user", "allow"]}})
    assert :ok = Connectors.save(project, "github", good)
    assert Agent.get(files, &Map.get(&1, {@dir, ".peon/api/github.json"})) == good
    assert "github" in Enum.map(Connectors.all_for(project), & &1.name)
  end

  test "moving a shared one in writes it here and takes the Project off its list", %{
    project: project,
    files: files
  } do
    assert :ok = Connectors.move_here(project, "front")

    own = Agent.get(files, &Map.get(&1, {@dir, ".peon/api/front.json"})) |> Jason.decode!()
    refute Map.has_key?(own, "projects")
    assert own["tools"] == %{"me" => ["GET", "/me", "allow"]}

    shared =
      Agent.get(files, &Map.get(&1, {"/srv/setup", "connectors/front.json"})) |> Jason.decode!()

    assert shared["projects"] == ["other"]

    assert [%{name: "front", source: "project"}] =
             Enum.filter(Connectors.all_for(project), &(&1.name == "front"))
  end
end
