defmodule Beamcode.Routines do
  @moduledoc """
  The procedures in a Procedure Folder (kind "routine"). Each procedure is one
  of the Folder's own skills, run as `/name` in the Folder's chat. Its inputs,
  and the input that makes a repeat safe (`key`), are in `procedures.json`:

      {
        "email-refunds": {"inputs": {"since": {"default": "last Friday"}}},
        "refund": {
          "key": "charge",
          "inputs": {"charge": {}, "name": {}, "amount": {}}
        },
        "digest": {
          "run": "/digest since {since} in {inboxes}",
          "inputs": {
            "since":   {"default": "last run", "options": ["last run", "today", "this week"]},
            "inboxes": {"default": ["Support", "Billing"], "multi": true,
                        "options": ["Support", "Billing", "Sales", "Partners"]}
          }
        }
      }

  `run` is optional: without it a run is `/name` and its inputs as
  `name: value` pairs. A Folder from before it held many procedures has a
  `routine.json` (one entry like the above, for its skill) instead.

  A procedure's result can start the next one with run-links, and report what
  happened per row in a `peon-status` block (see `conventions/0`).

  The Run buttons, schedules and run-links all go through here, so they behave
  the same.
  """
  alias Beamcode.{Connectors, Opencode, Sessions, Vault}

  @file_name "procedures.json"
  @legacy "routine.json"

  def file_name, do: @file_name

  @doc """
  The Folder's procedures, by name: its own skills (not the shared ones in the
  parent folder) and any `procedures.json` entries, as
  `%{name, description, run, inputs, key}`.
  """
  def list(project) do
    skills = own_skills(project.directory)
    {specs, _error} = specs(project, skills)

    (Enum.map(skills, & &1.name) ++ Map.keys(specs))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn name ->
      skill = Enum.find(skills, &(&1.name == name))
      procedure(name, specs[name] || %{}, skill && skill.description)
    end)
  end

  @doc "What's wrong with procedures.json (or routine.json), or nil."
  def error(project) do
    {_, error} = specs(project, own_skills(project.directory))
    error
  end

  @doc "One procedure by name; a blank name means the Folder's first one."
  def find(project, name) do
    list = list(project)

    case name do
      n when n in [nil, ""] -> List.first(list)
      n -> Enum.find(list, &(&1.name == n))
    end
  end

  defp procedure(name, spec, skill_description) do
    %{
      name: name,
      description: str(spec["description"]) || skill_description || "",
      run: str(spec["run"]),
      # The key first: it's what the procedure acts on.
      inputs: spec["inputs"] |> parse_inputs() |> Enum.sort_by(&(&1.name != spec["key"])),
      key: str(spec["key"])
    }
  end

  defp str(s) when is_binary(s) and s != "", do: s
  defp str(_), do: nil

  # procedures.json, or else routine.json as one entry for the Folder's skill.
  defp specs(project, skills) do
    case read_json(project, @file_name) do
      {:ok, map} ->
        {map, nil}

      {:error, :enoent} ->
        case read_json(project, @legacy) do
          {:ok, %{"run" => run} = json} when is_binary(run) ->
            {%{legacy_name(project, skills, run) => json}, nil}

          {:ok, _} ->
            {%{}, "#{@legacy} needs a \"run\" prompt"}

          {:error, :enoent} ->
            {%{}, nil}

          {:error, reason} ->
            {%{}, reason}
        end

      {:error, reason} ->
        {%{}, reason}
    end
  end

  defp read_json(project, file) do
    with {:ok, body} <- Opencode.read_file(project.directory, file) do
      case Jason.decode(body) do
        {:ok, map} when is_map(map) and file == @legacy -> {:ok, map}
        {:ok, map} when is_map(map) -> {:ok, for({k, v} <- map, is_map(v), into: %{}, do: {k, v})}
        {:ok, _} -> {:error, "#{file} must be a JSON object"}
        {:error, e} -> {:error, "#{file}: " <> Exception.message(e)}
      end
    else
      {:error, :enoent} -> {:error, :enoent}
      {:error, e} -> {:error, inspect(e)}
    end
  end

  # The skill a routine.json runs: the one its prompt names, else the Folder's.
  defp legacy_name(project, skills, run) do
    own = Enum.map(skills, & &1.name)
    preferred = skill_name(project.name)

    case Regex.run(~r{^/([\w.-]+)}, run) do
      [_, name] -> name
      _ -> if(preferred in own or own == [], do: preferred, else: hd(Enum.sort(own)))
    end
  end

  # The skills in the Folder itself. OpenCode loads a folder's skills lazily,
  # answering [] the first time, so an empty answer is asked once more.
  defp own_skills(dir, tries \\ 2) do
    case Opencode.skills(dir) do
      {:ok, list} when is_list(list) ->
        own =
          for s <- list,
              String.starts_with?(s["path"] || "", dir <> "/"),
              do: %{name: s["name"] || s["id"], description: s["description"]}

        if own == [] and list == [] and tries > 1 do
          Process.sleep(300)
          own_skills(dir, tries - 1)
        else
          own
        end

      _ ->
        []
    end
  end

  # [%{name, default, options, multi}]; JSON maps lose their order, so by name.
  defp parse_inputs(inputs) when is_map(inputs) do
    inputs
    |> Enum.filter(fn {_, v} -> is_map(v) end)
    |> Enum.map(fn {name, spec} ->
      multi = spec["multi"] == true

      %{
        name: name,
        default: spec["default"] || if(multi, do: [], else: ""),
        options: Enum.map(List.wrap(spec["options"]), &to_string/1),
        multi: multi
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp parse_inputs(_), do: []

  @doc "Default values for the inputs."
  def defaults(procedure), do: Map.new(procedure.inputs, &{&1.name, &1.default})

  @doc """
  The message that runs `procedure` with `values` (defaults for missing ones):
  its `run` prompt with `{input}` placeholders filled in, or else `/name` and
  the values as `name: value` pairs.
  """
  def prompt(procedure, values) do
    values = Map.merge(defaults(procedure), values || %{})

    case procedure.run do
      nil ->
        String.trim("/#{procedure.name} " <> pairs(procedure, values))

      run ->
        Regex.replace(~r/\{(\w+)\}/, run, fn whole, name ->
          case values[name] do
            nil -> whole
            value -> text(value)
          end
        end)
    end
  end

  @doc """
  One message that runs `procedure` once per row of values, in order, e.g.
  "/refund Run this once for each row, in order:\\n- charge: ch_1, amount: 299".
  """
  def batch_prompt(procedure, [values]), do: prompt(procedure, values)

  def batch_prompt(procedure, rows) do
    lines =
      Enum.map_join(rows, "\n", fn values ->
        "- " <> pairs(procedure, Map.merge(defaults(procedure), values || %{}))
      end)

    "/#{procedure.name} Run this once for each row, in order:\n" <> lines
  end

  # "charge: ch_1, name: Ola Nordmann, amount: 299": the key first, then the
  # declared inputs, then anything else the values carry.
  defp pairs(procedure, values) do
    names =
      [procedure.key | Enum.map(procedure.inputs, & &1.name)] ++
        (values |> Map.keys() |> Enum.sort())

    names
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.flat_map(fn name ->
      case text(values[name]) do
        "" -> []
        v -> ["#{name}: #{v}"]
      end
    end)
    |> Enum.join(", ")
  end

  defp text(nil), do: ""
  defp text(list) when is_list(list), do: Enum.map_join(list, ", ", &to_string/1)
  defp text(v), do: v |> to_string() |> String.replace(~r/\s+/, " ") |> String.trim()

  @doc """
  Runs a procedure in the Folder's chat, once (`values` is a map) or once per
  row (a list of maps, sent as one message). Returns `{:ok, session_id}`.
  """
  def run(project, user, values \\ %{}, name \\ nil) do
    case find(project, name) do
      nil ->
        {:error,
         if(name in [nil, ""],
           do: "This Folder has no procedures yet.",
           else: "No procedure called #{name}."
         )}

      procedure ->
        text =
          if is_list(values),
            do: batch_prompt(procedure, values),
            else: prompt(procedure, values)

        with {:ok, chat} <- Sessions.open(project, user),
             {:ok, _} <- Sessions.send_text(chat["id"], text, project.directory) do
          {:ok, chat["id"]}
        end
    end
  end

  @doc "`/` completion in a Procedure Folder: only its own procedures, with their inputs."
  def slash_items(project) do
    for p <- list(project) do
      %{
        name: p.name,
        description: p.description,
        kind: "procedure",
        inputs: Enum.map(p.inputs, & &1.name)
      }
    end
  end

  @doc "The skill a new routine starts with: the last part of its name (`front-digest` → `digest`)."
  def skill_name(name), do: name |> String.split("-") |> List.last()

  @doc """
  How procedures work, for the Folder's AGENTS.md and the agent that drafts
  one: where they live, run-links to start the next one, and `peon-status`.
  """
  def conventions do
    """
    ## Procedures

    This Folder holds procedures. Each one is a skill at
    `.opencode/skill/<name>/SKILL.md`, run in this chat as `/<name>`. Its last
    message is the result itself, in markdown, not commentary.

    Inputs go in `procedures.json`, one entry per procedure:

    ```json
    { "refund": { "key": "charge",
                  "inputs": { "charge": {}, "name": {}, "amount": {} } },
      "email-refunds": { "inputs": { "since": { "default": "last Friday",
                                                "options": ["last Friday", "this week"] } } } }
    ```

    A run arrives as `/<name> charge: ch_1, name: Ola Nordmann, amount: 299`;
    ask for anything missing. `key` is the input that identifies the thing
    acted on (a charge id, not a person's name): the skill must refuse to act
    twice on the same key.

    ### Starting the next procedure

    A result can offer the next step as run-links, one row per item:

    ```markdown
    - **Ola Nordmann** · 299 NOK · charged twice [Send refund](run:refund?charge=ch_1&name=Ola%20Nordmann&amount=299&currency=NOK)
    ```

    The app shows each as a button that runs `/refund` with those inputs, and
    "Send all" when there are several. URL-encode values. Use only procedures
    this Folder has.

    ### Reporting per row

    When a run handles keyed rows, end its result with one line per row in a
    `peon-status` block (the app hides it and shows each row's outcome):

    ```peon-status
    {"key": "ch_1", "status": "done", "note": "Refunded 299 NOK · re_9"}
    {"key": "ch_2", "status": "skipped", "note": "Already refunded"}
    {"key": "ch_3", "status": "failed", "note": "Card expired"}
    ```
    """
  end

  @doc """
  Starts drafting a new procedure in the Folder's chat from `description`
  (the user's words). `granted` are connector names it may use. Returns
  `{:ok, session_id, not_ready}` where `not_ready` are granted connectors
  still missing their secret.
  """
  def draft(project, user, description, granted) do
    skill = skill_name(project.name)
    connectors = Enum.filter(Connectors.list(), &(&1.error == nil and &1.name in granted))
    secrets = Vault.names()

    tools =
      for c <- connectors,
          t <- c.tools,
          t.permission != "deny",
          do: Connectors.tool_name(c, t)

    not_ready = for c <- connectors, not Connectors.ready?(c, secrets), do: c.name

    connector_hint =
      cond do
        tools == [] -> "It has no connectors yet."
        true -> "It may use these MCP tools from the gateway server: #{Enum.join(tools, ", ")}."
      end

    prompt = """
    Add a procedure to this Folder (#{project.name}). Its job, in the user's words:

    #{description}

    1. Create the skill at .opencode/skill/#{skill}/SKILL.md (frontmatter with name and description) that does the job end to end, so it runs as /#{skill}. If the job is really two steps, where a person should look before the second (find, then act), make two procedures and link them with run-links.
    2. Add its inputs (choices worth asking for on each run, values it acts on) to procedures.json.
    3. Add a line about it to AGENTS.md.

    #{connector_hint} Keep the files short. Don't run it now; end by telling me to try /#{skill}.

    #{conventions()}
    """

    with {:ok, session} <- Sessions.open(project, user, title: project.name),
         {:ok, _} <- Sessions.send_text(session["id"], prompt, project.directory) do
      {:ok, session["id"], not_ready}
    end
  end
end
