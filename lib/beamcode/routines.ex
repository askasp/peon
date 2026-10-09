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
  alias Beamcode.{Opencode, Schedules}

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
end
