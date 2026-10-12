defmodule Beamcode.Composer.Router do
  @moduledoc """
  Reads a composer line with a model when the rules in `Beamcode.Composer`
  aren't sure. People talk freely: mixed Norwegian and English, speech-to-text
  slips, details in the same breath ("create a routine that reads Front mail for
  the last 5 days…"). The model picks one Peon action and fills in its fields;
  `Beamcode.Composer.Plan` checks the answer against real projects and sessions.

  It runs through the OpenCode server, so it uses the providers connected
  there: a throwaway session in `<root>/.composer`, on a fast model, deleted
  after. The folder's AGENTS.md holds the instructions; each prompt carries the
  context (projects, routines and their inputs, recent sessions, pending
  permissions, the current page) and the line.
  """
  require Logger
  alias Beamcode.{Opencode, Workspace}

  # Dot folder: project names start with a letter or digit, so no clash.
  @folder ".composer"
  @timeout 45_000
  @poll 350
  @fast ~r/haiku|flash|mini|nano|small|lite|fast|instant/i

  @instructions """
  # Composer

  You read one line a person typed or said to Peon, an app that runs OpenCode
  coding agents ("sessions") in projects, and routines (one-job agents that run
  on demand or on a schedule; the app calls them "procedures", so read
  "procedure" as "routine"). Turn the line into exactly one action.

  Reply with one JSON object and nothing else: no prose, no code fence. Never
  use tools; everything you need is in the message.

  The line may mix Norwegian and English and may contain speech-to-text mistakes
  ("Createa", "emailsfor", "amino mono repo"). Match names loosely against the
  context. Keep domain words as said (e.g. "tilleggsrekvisisjon").

  Never swap in another project, routine or session for a name that isn't in
  the context: put the name in as they said it, and Peon will tell them it
  doesn't exist. Never add requirements they didn't say.

  Actions, with their fields:

  - {"action": "start_session", "project": NAME, "task": TEXT, "skill": NAME or null, "model": NAME or null, "agent": NAME or null}
    New work in a code or chat project. `task` is what to do, cleaned of
    filler like "start a new session in X" and of the model and agent. Use a
    skill only if one is named. `model`: the model they asked for ("using
    opus", "med gpt-5"), matched to a listed model's name, else as said.
    `agent`: one of the listed agents, only if they asked for it.
  - {"action": "send_to_session", "session": ID, "text": TEXT}
    Continue one of the recent sessions ("tell the checkout session to…",
    "in that session, also…", or a follow-up to the current session).
  - {"action": "run_routine", "routine": NAME, "inputs": {INPUT: VALUE}}
    Run a routine now. Fill inputs only from its listed inputs and options;
    leave the rest out.
  - {"action": "status", "project": NAME or null, "scope": "latest" or "overview"}
    Questions about sessions or runs: what is running, waiting, done, how a
    session or routine is doing. "latest" for one session, else "overview".
    `project` is the project or routine they named, as said, or null if they
    named none.
  - {"action": "create_routine", "name": "kebab-case-name", "brief": TEXT, "connectors": [NAME], "missing": [NAME]}
    Make a new routine. `brief` is the job in the person's words, complete
    and cleaned up, with nothing added. `connectors`: listed connectors it
    needs. `missing`: services it needs that aren't listed (e.g. "Front").
  - {"action": "permission", "id": ID, "decision": "once" or "always" or "reject"}
    Answer a pending permission request ("approve", "allow it", "deny").
  - {"action": "chat", "text": TEXT, "model": NAME or null, "agent": NAME or null}
    A general question or request that belongs to no project. `model` and
    `agent` as for start_session.
  - {"action": "unclear", "question": TEXT}
    You can't tell what they want. Ask one short question back.

  Always add "summary": one short sentence, in the person's language, saying
  what will happen, like "Start a session in amino-monorepo to find why
  checkout fails on CI." No file paths.

  Questions about a project's code or contents ("what changed in X this
  week?") are start_session in that project with the question as the task.
  """

  @doc "Instructions written to the composer folder's AGENTS.md."
  def instructions, do: @instructions

  @doc """
  Asks the model. `context` is a JSON-able map. Returns
  `{:ok, map, model_label}` with the decoded JSON, or `{:error, reason}`.
  """
  def route(line, context) do
    with {:ok, dir} <- ensure_folder(),
         model = pick_model(),
         {:ok, session} <- Opencode.create_session(session_body(dir, model)) do
      id = session["id"]

      try do
        with {:ok, _} <- Opencode.prompt(id, %{text: prompt(line, context)}),
             {:ok, text} <- await_reply(id, System.monotonic_time(:millisecond) + @timeout),
             {:ok, json} <- decode(text) do
          {:ok, json, model_label(model)}
        end
      after
        Task.Supervisor.start_child(Beamcode.TaskSupervisor, fn -> Opencode.delete_session(id) end)
      end
    end
  end

  defp session_body(dir, nil), do: %{location: %{directory: dir}, title: "Composer"}

  defp session_body(dir, model),
    do: %{location: %{directory: dir}, title: "Composer", model: model}

  defp prompt(line, context) do
    """
    Context:
    #{Jason.encode!(context, pretty: true)}

    Line:
    #{line}
    """
  end

  # Waits for the assistant's finished reply.
  defp await_reply(id, deadline) do
    reply =
      case Opencode.messages(id, 10) do
        {:ok, msgs} ->
          msgs
          |> Enum.filter(&(&1["type"] == "assistant"))
          |> List.last()

        _ ->
          nil
      end

    done = reply && get_in(reply, ["time", "completed"])
    text = reply && for(%{"type" => "text", "text" => t} <- reply["content"] || [], do: t)

    cond do
      done && text != [] ->
        {:ok, Enum.join(text, "\n")}

      done && reply["error"] ->
        {:error, "the model failed: #{inspect(reply["error"])}"}

      System.monotonic_time(:millisecond) > deadline ->
        {:error, "the model took too long"}

      true ->
        Process.sleep(@poll)
        await_reply(id, deadline)
    end
  end

  @doc "The JSON object in a model reply, tolerating a code fence or stray prose."
  def decode(text) do
    candidate =
      case Regex.run(~r/\{.*\}/s, text || "") do
        [json] -> json
        nil -> ""
      end

    case Jason.decode(candidate) do
      {:ok, %{"action" => _} = map} -> {:ok, map}
      _ -> {:error, "the model's answer wasn't readable"}
    end
  end

  ## Folder and model

  defp ensure_folder do
    root = Workspace.root()

    cond do
      root == nil ->
        {:error, "OpenCode server is not reachable"}

      :persistent_term.get({__MODULE__, :folder}, nil) == @instructions ->
        {:ok, Path.join(root, @folder)}

      true ->
        path = Path.join(@folder, "AGENTS.md")

        result =
          case Opencode.read_file(root, path) do
            {:ok, @instructions} -> :ok
            {:ok, _} -> write(root, path)
            {:error, :enoent} -> write(root, path)
            error -> error
          end

        with :ok <- result do
          :persistent_term.put({__MODULE__, :folder}, @instructions)
          {:ok, Path.join(root, @folder)}
        end
    end
  end

  defp write(root, path) do
    case Opencode.write_file(root, path, @instructions) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc """
  The model to read with: COMPOSER_MODEL ("provider/id"), else a fast one from
  the server's list (preferring the default model's provider), else the
  server default (nil).
  """
  def pick_model do
    case String.split(Application.get_env(:beamcode, :composer_model) || "", "/", parts: 2) do
      [provider, id] when provider != "" and id != "" ->
        %{id: id, providerID: provider}

      _ ->
        with {:ok, models} when is_list(models) <- Opencode.models() do
          default =
            case Opencode.default_model() do
              {:ok, %{"providerID" => p}} -> p
              _ -> nil
            end

          models
          |> Enum.filter(&(&1["enabled"] != false and &1["status"] != "deprecated"))
          |> Enum.filter(&Regex.match?(@fast, "#{&1["id"]} #{&1["name"]}"))
          |> Enum.sort_by(&{&1["providerID"] != default, &1["id"]})
          |> List.first()
          |> case do
            nil -> nil
            m -> %{id: m["id"], providerID: m["providerID"]}
          end
        else
          _ -> nil
        end
    end
  end

  defp model_label(nil), do: "default model"
  defp model_label(%{id: id}), do: id
end
