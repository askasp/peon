defmodule Beamcode.OpencodeStub do
  @moduledoc """
  Points the OpenCode client (and the GitHub check) at a `Req.Test` stub for one
  test. Shared mode, so LiveViews and their async tasks hit it too: use it only
  in `async: false` tests.
  """
  import ExUnit.Callbacks

  def setup_stub(handler) do
    opencode = Application.get_env(:beamcode, :opencode)
    github = Application.get_env(:beamcode, :github_req_options)

    Application.put_env(
      :beamcode,
      :opencode,
      Keyword.put(opencode, :req_options, plug: {Req.Test, Beamcode.Opencode})
    )

    Application.put_env(:beamcode, :github_req_options, plug: {Req.Test, Beamcode.GitTokens})

    on_exit(fn ->
      Application.put_env(:beamcode, :opencode, opencode)

      if github,
        do: Application.put_env(:beamcode, :github_req_options, github),
        else: Application.delete_env(:beamcode, :github_req_options)
    end)

    Req.Test.set_req_test_to_shared()
    Req.Test.stub(Beamcode.Opencode, handler)
    :ok
  end

  @doc "Replies like OpenCode: JSON wrapped in `data`."
  def data(conn, data), do: Req.Test.json(conn, %{"location" => %{}, "data" => data})

  def no_content(conn), do: Plug.Conn.send_resp(conn, 204, "")
end
