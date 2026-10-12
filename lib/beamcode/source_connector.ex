defmodule Beamcode.SourceConnector do
  @moduledoc """
  A service a Dataset can sync from (`"connector"` in sources.json): what it
  pulls into which table, and the actions that post changes back. Everything
  else (the local copy, the Outbox, views, agent tools) is the same for every
  service; see `Beamcode.SourceSync` and `Beamcode.Outbox`.

  The token comes from the Vault secret named in `info().secret`.
  """

  @typedoc "One action: what the Folder settings show, and its level when nothing is set."
  @type action :: %{label: String.t(), default: String.t(), needs_row: boolean()}

  @typedoc """
  A pull: the synced table's `columns` (`{name, sqlite type}`), its `rows`
  (maps with `"_remote_id"`), the `fields` views and actions need (column,
  label, type, options, remote id), what to call it, and whether rows missing
  from the pull were deleted remotely (a full pull) or are just older (a window).
  """
  @type pull :: %{
          title: String.t(),
          url: String.t() | nil,
          remote_id: String.t() | nil,
          columns: [{String.t(), String.t()}],
          rows: [map()],
          fields: [map()],
          full: boolean()
        }

  @callback info() :: %{
              id: String.t(),
              name: String.t(),
              short: String.t(),
              secret: String.t(),
              table: String.t(),
              config_key: String.t(),
              actions: %{String.t() => action()}
            }

  @doc "Who the token belongs to, for \"connected as …\"."
  @callback account(token :: String.t()) :: {:ok, String.t()} | {:error, String.t()}

  @doc "What can be synced (projects, inboxes): `[%{id, label, detail}]`."
  @callback choices(token :: String.t()) :: {:ok, [map()]} | {:error, String.t()}

  @callback pull(token :: String.t(), config :: map()) :: {:ok, pull()} | {:error, String.t()}

  @doc """
  Checks an action against the local row before it's queued: `{:ok, patch,
  label}` where `patch` is the change to apply locally at once (`%{column =>
  value}`, may be empty) and `label` says what will happen ("Status → Todo").
  """
  @callback prepare(action :: String.t(), args :: map(), row :: map() | nil, fields :: [map()]) ::
              {:ok, map(), String.t()} | {:error, String.t()}

  @doc "Posts an action. `source` is the `_sources` row (the remote id), `fields` its fields."
  @callback post(
              token :: String.t(),
              action :: String.t(),
              args :: map(),
              row :: map() | nil,
              source :: map(),
              fields :: [map()]
            ) :: :ok | {:error, String.t()}

  @doc "The action that undoes a posted one, from the values before it: `{action, args}` or nil."
  @callback undo(action :: String.t(), args :: map(), before :: map()) ::
              {String.t(), map()} | nil

  @doc "Req options for a connector's API calls (tests plug in a stub)."
  def req(opts) do
    Req.new([retry: false, receive_timeout: 30_000] ++ opts)
    |> Req.merge(Application.get_env(:beamcode, :source_req_options, []))
  end

  @doc "A column name from a field name: lowercase, `a-z0-9_`."
  def column(name) do
    case name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_") |> String.trim("_") do
      "" -> "field"
      "_" <> _ = c -> "f" <> c
      c -> if c =~ ~r/^\d/, do: "f_" <> c, else: c
    end
  end

  @doc "An ISO UTC time from Unix seconds (Front's timestamps)."
  def iso(nil), do: nil

  def iso(seconds) when is_number(seconds),
    do: DateTime.from_unix!(trunc(seconds * 1000), :millisecond) |> DateTime.to_iso8601()

  def iso(other), do: to_string(other)
end
