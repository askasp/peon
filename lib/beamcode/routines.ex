defmodule Beamcode.Routines do
  @moduledoc """
  How a routine runs, from its `routine.json`:

      {
        "run": "/digest since {since} in {inboxes}",
        "inputs": {
          "since":   {"default": "last run", "options": ["last run", "today", "this week"]},
          "inboxes": {"default": ["Support", "Billing"], "multi": true,
                      "options": ["Support", "Billing", "Sales", "Partners"]}
        }
      }

  The Run button, schedules and "Run again" all go through here, so they
  behave the same. Without a routine.json the routine runs its skill.
  """
  alias Beamcode.{Connectors, Opencode, Schedules, Sessions, Vault}

  @file_name "routine.json"

  def file_name, do: @file_name

  @doc "Parsed routine.json, or a default that runs the routine's skill."
  def config(project) do
    with {:ok, body} <- Opencode.read_file(project.directory, @file_name),
         {:ok, %{"run" => run} = json} when is_binary(run) <- Jason.decode(body) do
      %{run: run, inputs: parse_inputs(json["inputs"]), error: nil}
    else
      {:error, :enoent} -> default(project, nil)
      {:ok, _} -> default(project, "routine.json needs a \"run\" prompt")
      {:error, %Jason.DecodeError{} = e} -> default(project, Exception.message(e))
      {:error, e} -> default(project, inspect(e))
    end
  end

  defp default(project, error) do
    %{run: default_run(project), inputs: [], error: error}
  end

  defp default_run(project) do
    own =
      case Opencode.skills(project.directory) do
        {:ok, list} ->
          for s <- list,
              String.starts_with?(s["path"], project.directory <> "/"),
              do: s["name"] || s["id"]

        _ ->
          []
      end

    preferred = project.name |> String.split("-") |> List.last()

    cond do
      preferred in own -> "/" <> preferred
      own != [] -> "/" <> hd(Enum.sort(own))
      true -> "Do your job as described in AGENTS.md."
    end
  end

  # [%{name, default, options, multi}] in file order is lost by JSON maps, so sort by name.
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
  def defaults(config), do: Map.new(config.inputs, &{&1.name, &1.default})

  @doc "The run prompt with `{input}` placeholders filled in (defaults for missing values)."
  def prompt(config, values) do
    values = Map.merge(defaults(config), values || %{})

    Regex.replace(~r/\{(\w+)\}/, config.run, fn whole, name ->
      case values[name] do
        nil -> whole
        list when is_list(list) -> Enum.join(list, ", ")
        value -> to_string(value)
      end
    end)
  end

  @doc "Starts a run from the Run button. Manual runs don't go to the Inbox."
  def run(project, user, values \\ %{}) do
    config = config(project)
    values = Map.merge(defaults(config), values || %{})

    Schedules.start_run(project, user, prompt(config, values),
      key: "manual",
      scope: if(project.scope == "private", do: "private", else: "team"),
      inputs: values,
      seen: true
    )
  end

  @doc "The skill a routine runs: the last part of its name (`front-digest` → `digest`)."
  def skill_name(name), do: name |> String.split("-") |> List.last()

  @doc """
  Starts the session in a new routine that drafts its AGENTS.md, skill and
  routine.json from `description` (the user's words). `granted` are connector
  names it may use. Returns `{:ok, session_id, not_ready}` where `not_ready`
  are granted connectors still missing their secret.
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
    This is a new routine called #{project.name}. Its one job, in the user's words:

    #{description}

    Draft it:
    1. Rewrite AGENTS.md as short, concrete instructions for this job: what to read, what to output, limits.
    2. Create one skill at .opencode/skill/#{skill}/SKILL.md (frontmatter with name and description) that does the job end to end, so it can be run as /#{skill}. Its last message must be the result itself, in markdown.
    3. If the job has choices worth asking for on each run (a time range, which inboxes…), add them as inputs in routine.json and use them in "run", like "/#{skill} since {since}". Otherwise leave routine.json as it is.

    #{connector_hint} Keep both files short. Don't run the job now; end by telling me to try /#{skill}.
    """

    with {:ok, session} <- Sessions.start(project, user, title: "Set up #{project.name}"),
         {:ok, _} <- Sessions.send_text(session["id"], prompt, project.directory) do
      {:ok, session["id"], not_ready}
    end
  end
end
