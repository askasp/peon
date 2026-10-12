defmodule BeamcodeWeb.FileController do
  @moduledoc """
  Serves a project's files under a signed prefix (see `BeamcodeWeb.FileToken`).

  Files come from agents, so HTML is served sandboxed: the page gets its own
  opaque origin and can't reach the app's cookies or pages.

  HTML pages also get `peon.query(sql, db = "data.sqlite")`, a read-only query on
  a SQLite file in the folder (`_query` under the same prefix), so an app an
  agent writes over a dataset can show its data.
  """
  use BeamcodeWeb, :controller
  alias Beamcode.ProjectFiles

  @sandbox "sandbox allow-scripts allow-forms allow-popups allow-modals allow-downloads"

  def show(conn, %{"token" => token, "path" => parts}) do
    with {:ok, project} <- BeamcodeWeb.FileToken.verify(token),
         {:ok, body} <- ProjectFiles.read(project, Enum.join(parts, "/")) do
      type = ProjectFiles.content_type(List.last(parts))
      body = if type == "text/html", do: with_peon(body, token), else: body

      conn
      |> put_resp_content_type(type, nil)
      |> put_resp_header("content-security-policy", @sandbox)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("referrer-policy", "no-referrer")
      |> put_resp_header("cache-control", "private, max-age=60")
      |> send_resp(200, body)
    else
      :error -> send_resp(conn, 401, "")
      {:error, :bad_path} -> send_resp(conn, 400, "")
      {:error, :enoent} -> send_resp(conn, 404, "")
      {:error, :too_big} -> send_resp(conn, 413, "")
      {:error, _} -> send_resp(conn, 502, "")
    end
  end

  def query(conn, %{"token" => token, "sql" => sql} = params) when is_binary(sql) do
    conn = put_resp_header(conn, "access-control-allow-origin", "*")

    with {:ok, project} <- BeamcodeWeb.FileToken.verify(token),
         {:ok, rows} <- ProjectFiles.query(project, params["db"] || "data.sqlite", sql) do
      json(conn, %{rows: rows})
    else
      :error -> conn |> put_status(401) |> json(%{error: "This link has expired"})
      {:error, :bad_path} -> conn |> put_status(400) |> json(%{error: "Bad path"})
      {:error, reason} -> conn |> put_status(422) |> json(%{error: to_string(reason)})
    end
  end

  def query(conn, _),
    do: conn |> put_resp_header("access-control-allow-origin", "*") |> send_resp(400, "")

  # The page's origin is opaque (sandbox), so the query is a cross-origin POST;
  # a form body keeps it a simple request (no preflight). Storage throws in a
  # sandbox, so pages get an in-memory localStorage/sessionStorage instead.
  defp with_peon(html, token) do
    script = """
    <script>["localStorage","sessionStorage"].forEach(function(k){try{window[k].length}catch(e){var m={};Object.defineProperty(window,k,{configurable:true,value:{getItem:function(i){return i in m?m[i]:null},setItem:function(i,v){m[i]=String(v)},removeItem:function(i){delete m[i]},clear:function(){m={}},key:function(n){return Object.keys(m)[n]||null},get length(){return Object.keys(m).length}}})}});window.peon={query:function(sql,db){return fetch("/files/#{token}/_query",{method:"POST",body:new URLSearchParams({sql:sql,db:db||"data.sqlite"})}).then(function(r){return r.json().then(function(j){if(!r.ok)throw new Error(j.error||r.statusText);return j.rows})})}};</script>
    """

    case Regex.run(~r/<head[^>]*>/i, html, return: :index) do
      [{at, len}] ->
        binary_part(html, 0, at + len) <>
          script <> binary_part(html, at + len, byte_size(html) - at - len)

      _ ->
        script <> html
    end
  end
end
