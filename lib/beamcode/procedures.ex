defmodule Beamcode.Procedures do
  @moduledoc """
  Procedures: named steps with inputs, in any Project. Each is one file,
  `.peon/procedures/<name>.md`: settings in the front matter, one `## Step`
  section per step for its prompt.

      ---
      name: email-refunds
      description: Read support mail and list who should get a refund
      inputs:
        since: { type: date, default: last_run, max: 4d }
      outputs:
        approved: [{ charge: text, amount: money, name: text }]
      schedule: { at: Mon 07:00, tz: Europe/Oslo }
      steps:
        - name: Read
          model: haiku
        - name: Decide
          model: opus
          effort: high
          session: fresh
          hand_over: [Read, refund-policy.md]
          returns: approved
        - name: Post
          offers: refund
      ---

      ## Read
      Read support mail since {since}. …

  Without `steps:` a procedure is one step: the body is its prompt, or the
  top-level `call:`/`params:`/`confirm:` make it one API call with no
  model. A step can instead `run:` another procedure (`for_each:` item of an
  earlier step's output), `queue:` tickets in a code Project, or just `wait: me`.

  Global procedures are `procedures/*.md` in the setup Project and show in every
  Project; a Project's own one with the same name replaces it. Projects made
  before this format (kind "routine") also list their own skills, with inputs
  from `procedures.json` or `routine.json`; those are read, never written.

  `Beamcode.Procedures.Runs` runs them; run-links, `peon-status`,
  `peon-output` and `peon-step` blocks are explained in `conventions/0`.
  """
  alias Beamcode.{Connectors, Opencode, Sessions, Vault, Workspace}
  alias Beamcode.Procedures.{Cache, Yaml}
  alias Beamcode.Projects.Project

  @dir ".peon/procedures"
  @global_dir "procedures"
  @legacy_json "procedures.json"
  @legacy_routine "routine.json"

  def dir, do: @dir

  ## Listing

  @doc """
  The procedures a Project can run, by name: its own files, its legacy skills,
  then the global ones it doesn't replace. Each is a map, see `from_front/4`.
  """
  def list(project), do: project |> load() |> elem(0)

  @doc "What's wrong with the Project's procedure files, or nil."
  def error(project) do
    case project |> load() |> elem(1) do
      [] -> nil
      errors -> Enum.join(errors, "; ")
    end
  end

  @doc "One procedure by name; a blank name means the Project's first one."
  def find(project, name) do
    list = list(project)

    case name do
      n when n in [nil, ""] -> List.first(list)
      n -> Enum.find(list, &(&1.name == n))
    end
  end

  @doc "`{procedures, errors}` for a Project (kept a few seconds, see `Procedures.Cache`)."
  def load(project) do
    Cache.fetch({project.directory, project.kind}, fn -> read(project) end)
  end

  @doc "Forgets a Project's cached procedures, after a file changed."
  def changed(project), do: Cache.drop({project.directory, project.kind})

  defp read(project) do
    {own, own_errors} = read_dir(project.directory, @dir, "folder")
    {legacy, legacy_error} = legacy(project)

    {global, global_errors} =
      case Workspace.setup_project() do
        %{directory: dir} when dir != project.directory -> read_dir(dir, @global_dir, "global")
        _ -> {[], []}
      end

    own_names = MapSet.new(own, & &1.name)
    global_names = MapSet.new(global, & &1.name)
    legacy = Enum.reject(legacy, &MapSet.member?(own_names, &1.name))
    taken = MapSet.union(own_names, MapSet.new(legacy, & &1.name))

    own = Enum.map(own, &%{&1 | overrides: MapSet.member?(global_names, &1.name)})
    global = Enum.reject(global, &MapSet.member?(taken, &1.name))

    list = Enum.sort_by(own ++ legacy ++ global, & &1.name)
    errors = own_errors ++ List.wrap(legacy_error) ++ Enum.map(global_errors, &"global #{&1}")
    {list, errors}
  end

  defp read_dir(dir, path, source) do
    case Opencode.list_dir(dir, path) do
      {:ok, entries} when is_list(entries) ->
        files =
          for e <- entries,
              e["type"] == "file",
              String.ends_with?(e["path"] || "", ".md"),
              do: Path.basename(e["path"])

        files
        |> Enum.sort()
        |> Task.async_stream(
          fn file ->
            rel = Path.join(path, file)

            with {:ok, body} <- Opencode.read_file(dir, rel),
                 {:ok, p} <- parse(body, Path.rootname(file)) do
              {:ok, %{p | source: source, path: rel}}
            else
              {:error, :enoent} -> {:error, "#{rel}: gone"}
              {:error, reason} when is_binary(reason) -> {:error, "#{rel}: #{reason}"}
              {:error, reason} -> {:error, "#{rel}: #{inspect(reason)}"}
            end
          end,
          timeout: 30_000,
          max_concurrency: 8
        )
        |> Enum.reduce({[], []}, fn
          {:ok, {:ok, p}}, {ok, errors} -> {[p | ok], errors}
          {:ok, {:error, e}}, {ok, errors} -> {ok, [e | errors]}
          {:exit, _}, acc -> acc
        end)
        |> then(fn {ok, errors} -> {Enum.reverse(ok), Enum.reverse(errors)} end)

      _ ->
        {[], []}
    end
  end

  @doc "The Project's notes a step can be handed: `.peon/*.md`."
  def notes(project) do
    case Opencode.list_dir(project.directory, ".peon") do
      {:ok, entries} when is_list(entries) ->
        for e <- entries,
            e["type"] == "file",
            String.ends_with?(e["path"] || "", ".md"),
            do: Path.basename(e["path"])

      _ ->
        []
    end
    |> Enum.sort()
  end

  @doc """
  What to warn about in a list: a procedure a scheduled chain runs that has
  its own schedule too (it would run twice). `%{name => [text]}`.
  """
  def warnings(list) do
    by_name = Map.new(list, &{&1.name, &1})

    for p <- list,
        p.schedule,
        s <- p.steps,
        s.run,
        child = by_name[s.run],
        child && child.schedule,
        reduce: %{} do
      acc ->
        text = "#{child.name} has its own schedule too, so it runs twice."
        Map.update(acc, p.name, [text], &Enum.uniq(&1 ++ [text]))
    end
  end

  ## The file format

  @doc """
  Parses a procedure file. `fallback_name` is its file name, used when the
  front matter has no `name`. Returns `{:ok, procedure}` or `{:error, message}`.
  """
  def parse(body, fallback_name \\ "procedure") do
    body = String.replace(body, "\r\n", "\n")
    {front, text} = split_front(body)

    with {:ok, map} <- Yaml.parse(front) do
      {:ok, from_front(map, text, fallback_name)}
    end
  end

  defp split_front("---\n" <> rest) do
    case String.split(rest, ~r/^---[ \t]*$/m, parts: 2) do
      [front, body] -> {front, String.trim_leading(body, "\n")}
      _ -> {"", rest}
    end
  end

  defp split_front(body), do: {"", body}

  @doc false
  def from_front(map, text, fallback_name) do
    name = str(map["name"]) || fallback_name
    sections = sections(text)
    inputs = inputs(map["inputs"])

    steps =
      case map["steps"] do
        list when is_list(list) and list != [] ->
          list
          |> Enum.filter(&is_map/1)
          |> Enum.with_index(1)
          |> Enum.map(fn {s, i} ->
            step_name = str(s["name"]) || "Step #{i}"
            step(s, Map.get(sections, String.downcase(step_name)))
          end)

        _ ->
          # One step: the body is its prompt (a lone "## name" heading aside).
          prompt =
            case Map.to_list(sections) do
              [{_, only}] when map_size(sections) == 1 -> only
              _ -> String.trim(text)
            end

          [step(Map.put(map, "name", name), blank(prompt))]
      end

    %{
      name: name,
      description: str(map["description"]) || "",
      inputs: inputs,
      key: str(map["key"]),
      outputs: outputs(map["outputs"]),
      schedule: schedule(map["schedule"]),
      queue: str(map["queue"]),
      steps: steps,
      run: nil,
      source: "folder",
      path: nil,
      overrides: false,
      front: map,
      body: text
    }
  end

  # "## Read" sections, by lower-cased heading.
  defp sections(text) do
    text
    |> String.split(~r/^## +/m)
    |> Enum.drop(1)
    |> Map.new(fn section ->
      [heading | rest] = String.split(section, "\n", parts: 2)
      {heading |> String.trim() |> String.downcase(), blank(Enum.join(rest))}
    end)
  end

  defp step(s, prompt) do
    on_changes =
      case s["on_changes"] do
        %{} = m -> %{back_to: str(m["back_to"]), max: int(m["max"]) || 2}
        _ -> nil
      end

    step = %{
      name: str(s["name"]),
      prompt: prompt,
      model: str(s["model"]),
      effort: str(s["effort"]),
      session: if(s["session"] == "fresh", do: "fresh", else: "same"),
      wait: s["wait"] in ["me", true, "you"],
      uses: Enum.map(List.wrap(s["uses"]), &use_name/1),
      hand_over: Enum.map(List.wrap(s["hand_over"]), &to_string/1),
      on_changes: on_changes,
      back_to: str(s["back_to"]),
      offers: str(s["offers"]),
      skill: str(s["skill"]),
      run: str(s["run"]),
      with: if(is_map(s["with"]), do: clean(s["with"]), else: %{}),
      for_each: str(s["for_each"]),
      returns: str(s["returns"]),
      on_fail: if(s["on_fail"] == "continue", do: "continue", else: "stop"),
      queue: str(s["queue"]),
      title: str(s["title"]),
      call: str(s["call"]),
      params: if(is_map(s["params"]), do: clean(s["params"]), else: %{}),
      confirm: str(s["confirm"])
    }

    Map.put(step, :kind, kind(step))
  end

  # What a step does: run a prompt, run other procedures, add tickets, call
  # a connector, or only wait for you.
  defp kind(%{call: c}) when is_binary(c), do: "call"
  defp kind(%{run: r}) when is_binary(r), do: "run"
  defp kind(%{queue: q}) when is_binary(q), do: "queue"
  defp kind(%{prompt: p, skill: s}) when is_binary(p) or is_binary(s), do: "prompt"
  defp kind(_), do: "wait"

  # `uses: [front, stripe: read]`: the connector names.
  defp use_name(%{} = m), do: m |> Map.keys() |> Enum.find(&is_binary/1) |> to_string()
  defp use_name(v), do: to_string(v)

  defp inputs(map) when is_map(map) do
    for name <- keys(map) do
      spec = if is_map(map[name]), do: map[name], else: %{"type" => map[name]}
      multi = spec["multi"] == true

      %{
        name: name,
        type: str(spec["type"]) || "text",
        default: default(spec["default"], multi),
        options: Enum.map(List.wrap(spec["options"]), &to_string/1),
        multi: multi,
        currency: str(spec["currency"]),
        max: str(spec["max"])
      }
    end
  end

  defp inputs(_), do: []

  defp default(nil, true), do: []
  defp default(nil, false), do: ""
  defp default(list, _) when is_list(list), do: Enum.map(list, &to_string/1)
  defp default(v, _), do: to_string(v)

  # `approved: [{ charge: text, amount: money }]` → %{"approved" => ["charge", "amount"]}.
  defp outputs(map) when is_map(map) do
    Map.new(keys(map), fn name ->
      fields =
        case map[name] do
          [%{} = shape | _] -> keys(shape)
          %{} = shape -> keys(shape)
          _ -> []
        end

      {name, fields}
    end)
  end

  defp outputs(_), do: %{}

  @doc """
  A schedule from the file: `Mon 07:00`, `daily 02:00`, `weekdays 08:00`, a
  five-field cron line, or `{ at: …, tz: Europe/Oslo }`. Returns
  `%{at, tz, cron}` (cron nil when `at` can't be read) or nil.
  """
  def schedule(nil), do: nil
  def schedule(%{} = m), do: schedule_at(str(m["at"]) || str(m["cron"]), str(m["tz"]))
  def schedule(at) when is_binary(at), do: schedule_at(at, nil)
  def schedule(_), do: nil

  defp schedule_at(nil, _), do: nil
  defp schedule_at(at, tz), do: %{at: at, tz: tz, cron: cron(at)}

  @days %{
    "sun" => "0",
    "mon" => "1",
    "tue" => "2",
    "wed" => "3",
    "thu" => "4",
    "fri" => "5",
    "sat" => "6",
    "daily" => "*",
    "day" => "*",
    "every day" => "*",
    "weekdays" => "1-5",
    "weekends" => "0,6"
  }

  defp cron(at) do
    text = at |> String.trim() |> String.downcase()

    cond do
      Beamcode.Schedules.Cron.valid?(text) ->
        text

      m = Regex.run(~r/^(.*?)\s*(\d{1,2}):(\d{2})$/, text) ->
        [_, day, h, min] = m
        day = day |> String.trim() |> String.trim_trailing("s")

        dow =
          case day do
            "" -> "*"
            d -> @days[d] || @days[String.slice(d, 0, 3)] || @days[d <> "s"]
          end

        if dow && String.to_integer(h) < 24 && String.to_integer(min) < 60,
          do: "#{String.to_integer(min)} #{String.to_integer(h)} * * #{dow}"

      true ->
        nil
    end
  end

  @doc """
  Seconds in a span: `4d`, `12h`, `2w`, `30m`, `4 days`, or a bare number of
  days. nil when it isn't one.
  """
  def duration(text) when is_binary(text) do
    case Regex.run(~r/^\s*(\d+)\s*([a-z]*)\s*$/i, text) do
      [_, n, unit] ->
        case unit |> String.downcase() |> String.first() do
          nil -> 86_400
          "d" -> 86_400
          "w" -> 604_800
          "h" -> 3_600
          "m" -> 60
          _ -> nil
        end
        |> then(&(&1 && String.to_integer(n) * &1))

      _ ->
        nil
    end
  end

  def duration(_), do: nil

  defp keys(map), do: Map.get(map, :order) || map |> Map.keys() |> Enum.filter(&is_binary/1)

  defp clean(map), do: for({k, v} <- map, is_binary(k), into: %{}, do: {k, v})

  defp str(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: String.trim(s))
  defp str(n) when is_number(n), do: to_string(n)
  defp str(_), do: nil

  defp int(n) when is_integer(n), do: n
  defp int(s) when is_binary(s), do: s |> Integer.parse() |> then(&(&1 && elem(&1, 0)))
  defp int(_), do: nil

  defp blank(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: String.trim(s))
  defp blank(_), do: nil

  @doc "The file text for a procedure's front matter map and body."
  def render(front, body) do
    "---\n" <> Yaml.dump(front) <> "\n---\n" <> if(body in [nil, ""], do: "", else: "\n" <> body)
  end

  ## Editing (the app's procedure editor writes the file)

  # Keys a step has, in the order a file lists them.
  @step_keys ~w(name run with for_each queue title call params confirm model effort session wait
                uses hand_over on_changes back_to returns offers on_fail skill)

  @doc """
  Changes a Project's own procedure file. `edit` is one of
  `%{"op" => "step", "index" => i, "attrs" => %{...}}` (a step's prompt,
  model, effort, session or wait; "" removes one), `%{"op" => "add_step"}`,
  `%{"op" => "remove_step", "index" => i}` or `%{"op" => "use_prompt", "index" => i}`
  (a connector call becomes a prompt step). One step keeps its settings at
  the top of the file; adding a second moves them under `steps:`.
  """
  def edit(project, name, edit) do
    with %{source: "folder", path: path} <-
           find(project, name) || {:error, "No procedure called #{name}."},
         {:ok, text} <- Opencode.read_file(project.directory, path),
         {:ok, parsed} <- parse(text, name),
         {:ok, steps} <- apply_edit(file_steps(parsed), edit),
         {:ok, _} <-
           Opencode.write_file(project.directory, path, render_steps(parsed.front, steps)) do
      changed(project)
      :ok
    else
      %{source: "global"} ->
        {:error, "This one is global: change it in the setup Project's procedures."}

      %{source: "legacy"} ->
        {:error,
         "This one is a skill from before procedure files. Ask the chat to move it to #{@dir}."}

      {:error, :enoent} ->
        {:error, "Its file is gone."}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  # [{step settings, prompt}], the one step of a file without `steps:` too.
  defp file_steps(%{front: front, steps: steps}) do
    case front["steps"] do
      list when is_list(list) and list != [] ->
        list |> Enum.filter(&is_map/1) |> Enum.zip(Enum.map(steps, & &1.prompt))

      _ ->
        [{Map.take(front, @step_keys -- ["name"]), hd(steps).prompt}]
    end
  end

  defp apply_edit(steps, %{"op" => "step", "index" => i, "attrs" => attrs}) when is_map(attrs) do
    if i in 0..(length(steps) - 1)//1 do
      {:ok,
       List.update_at(steps, i, fn {settings, prompt} ->
         prompt = if Map.has_key?(attrs, "prompt"), do: blank(attrs["prompt"]), else: prompt

         settings =
           for {k, v} <- Map.delete(attrs, "prompt"), k in @step_keys, reduce: settings do
             acc when v in [nil, "", false] -> Map.delete(acc, k)
             acc when k == "wait" -> Map.put(acc, k, "me")
             acc -> Map.put(acc, k, v)
           end

         {settings, prompt}
       end)}
    else
      {:error, "No such step."}
    end
  end

  defp apply_edit(steps, %{"op" => "add_step"}) do
    # The first step gets a name once there are two.
    steps =
      Enum.with_index(steps, 1)
      |> Enum.map(fn {{settings, prompt}, n} ->
        {Map.put_new(settings, "name", "Step #{n}"), prompt}
      end)

    {:ok, steps ++ [{%{"name" => "Step #{length(steps) + 1}"}, "Say what this step does."}]}
  end

  defp apply_edit(steps, %{"op" => "remove_step", "index" => i}) do
    cond do
      length(steps) < 2 -> {:error, "A procedure needs a step."}
      i in 0..(length(steps) - 1)//1 -> {:ok, List.delete_at(steps, i)}
      true -> {:error, "No such step."}
    end
  end

  defp apply_edit(steps, %{"op" => "use_prompt", "index" => i}) do
    apply_edit(
      List.update_at(steps, i, fn {settings, prompt} ->
        {Map.drop(settings, ~w(call params confirm)), prompt || "Do it with the inputs above."}
      end),
      %{"op" => "step", "index" => i, "attrs" => %{}}
    )
  end

  defp apply_edit(_steps, _edit), do: {:error, "Unknown change."}

  # The file again: one step at the top (no `steps:`), more under `steps:`
  # with a "## Name" section each.
  defp render_steps(front, [{settings, prompt}]) when not is_map_key(settings, "name") do
    front =
      front |> Map.drop(["steps" | @step_keys -- ["name"]]) |> Map.merge(settings) |> order(front)

    render(front, prompt)
  end

  defp render_steps(front, steps) do
    list =
      for {settings, _} <- steps, do: Map.put(Map.drop(settings, [:order]), :order, @step_keys)

    body =
      for {settings, prompt} <- steps, prompt not in [nil, ""] do
        "## #{settings["name"]}\n#{prompt}"
      end
      |> Enum.join("\n\n")

    front = front |> Map.drop(@step_keys -- ["name"]) |> Map.put("steps", list) |> order(front)
    render(front, body)
  end

  # Keeps the file's key order, with `steps` last.
  defp order(front, old) do
    keys = (Map.get(old, :order, []) -- ["steps"]) ++ ["steps"]
    Map.put(front, :order, keys)
  end

  ## Projects made before the file format (kind "routine")

  defp legacy(%Project{kind: "routine"} = project) do
    skills = own_skills(project.directory)
    {specs, error} = legacy_specs(project, skills)

    list =
      (Enum.map(skills, & &1.name) ++ Map.keys(specs))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(fn name ->
        skill = Enum.find(skills, &(&1.name == name))
        legacy_procedure(name, specs[name] || %{}, skill && skill.description)
      end)

    {list, error}
  end

  defp legacy(_project), do: {[], nil}

  defp legacy_procedure(name, spec, skill_description) do
    run = str(spec["run"])

    %{
      name: name,
      description: str(spec["description"]) || skill_description || "",
      # The key first: it's what the procedure acts on.
      inputs: spec["inputs"] |> legacy_inputs() |> Enum.sort_by(&(&1.name != spec["key"])),
      key: str(spec["key"]),
      outputs: %{},
      schedule: nil,
      queue: nil,
      steps: [step(%{"name" => name, "skill" => name}, nil)],
      run: run,
      source: "legacy",
      path: nil,
      overrides: false,
      front: %{},
      body: nil
    }
  end

  # procedures.json, or else routine.json as one entry for the Project's skill.
  defp legacy_specs(project, skills) do
    case read_json(project, @legacy_json) do
      {:ok, map} ->
        {map, nil}

      {:error, :enoent} ->
        case read_json(project, @legacy_routine) do
          {:ok, %{"run" => run} = json} when is_binary(run) ->
            {%{legacy_name(project, skills, run) => json}, nil}

          {:ok, _} ->
            {%{}, "#{@legacy_routine} needs a \"run\" prompt"}

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
        {:ok, map} when is_map(map) and file == @legacy_routine -> {:ok, map}
        {:ok, map} when is_map(map) -> {:ok, for({k, v} <- map, is_map(v), into: %{}, do: {k, v})}
        {:ok, _} -> {:error, "#{file} must be a JSON object"}
        {:error, e} -> {:error, "#{file}: " <> Exception.message(e)}
      end
    else
      {:error, :enoent} -> {:error, :enoent}
      {:error, e} -> {:error, inspect(e)}
    end
  end

  # The skill a routine.json runs: the one its prompt names, else the Project's.
  defp legacy_name(project, skills, run) do
    own = Enum.map(skills, & &1.name)
    preferred = skill_name(project.name)

    case Regex.run(~r{^/([\w.-]+)}, run) do
      [_, name] -> name
      _ -> if(preferred in own or own == [], do: preferred, else: hd(Enum.sort(own)))
    end
  end

  # The skills in the Project itself. OpenCode loads a folder's skills lazily,
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
  defp legacy_inputs(inputs) when is_map(inputs) do
    inputs
    |> Enum.filter(fn {_, v} -> is_map(v) end)
    |> Enum.map(fn {name, spec} ->
      multi = spec["multi"] == true

      %{
        name: name,
        type: "text",
        default: spec["default"] || if(multi, do: [], else: ""),
        options: Enum.map(List.wrap(spec["options"]), &to_string/1),
        multi: multi,
        currency: nil,
        max: nil
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp legacy_inputs(_), do: []

  ## Messages

  @doc "Default values for the inputs."
  def defaults(procedure), do: Map.new(procedure.inputs, &{&1.name, &1.default})

  @doc """
  The message that runs a one-step procedure with `values` (defaults for
  missing ones). A Project from before the file format runs its skill: its
  `run` prompt with `{input}` placeholders filled in, or else `/name` and the
  values as `name: value` pairs. A file procedure's step prompt comes after a
  `/name values` line, so the chat says what ran.
  """
  def prompt(procedure, values) do
    values = Map.merge(defaults(procedure), values || %{})

    case procedure do
      %{source: "legacy", run: nil} ->
        String.trim("/#{procedure.name} " <> pairs(procedure, values))

      %{source: "legacy", run: run} ->
        fill(run, values)

      _ ->
        step_text(procedure, hd(procedure.steps), values)
    end
  end

  @doc "A prompt step's message: the `/name values` line, then the filled prompt."
  def step_text(procedure, step, values, extra \\ "") do
    head = String.trim("/#{procedure.name} " <> pairs(procedure, values))
    prompt = fill(step.prompt || "", values)

    [head, prompt, extra]
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  @doc """
  Fills `{input}` placeholders. A dotted one reaches into a value an earlier
  step returned (`{customer.email}`, `{matches.0.id}`). The last part can be
  `minor` (a money input × 100: 299 NOK → 29900 øre), or for a time `unix`
  (seconds), `date` (2026-10-12) or `iso`. Unknown placeholders stay as they are.
  """
  def fill(text, values) do
    Regex.replace(~r/\{([\w-]+(?:\.[\w-]+)*)\}/, text, fn whole, path ->
      case lookup(values, String.split(path, ".")) do
        {:ok, value} -> text(value)
        :error -> whole
      end
    end)
  end

  @modifiers ~w(minor unix date iso)

  defp lookup(values, parts) do
    with :error <- dig(values, parts),
         [modifier | rest] when modifier in @modifiers and rest != [] <- Enum.reverse(parts),
         {:ok, value} <- dig(values, Enum.reverse(rest)) do
      modify(value, modifier)
    else
      {:ok, value} -> {:ok, value}
      _ -> :error
    end
  end

  # A map key can hold dots itself ("email-refunds.approved"): the longest
  # one that matches wins.
  defp dig(value, []), do: if(is_nil(value), do: :error, else: {:ok, value})

  defp dig(%{} = map, parts) do
    Enum.find_value(length(parts)..1//-1, :error, fn n ->
      {key, rest} = Enum.split(parts, n)
      key = Enum.join(key, ".")
      if Map.has_key?(map, key), do: dig(map[key], rest)
    end)
  end

  defp dig(list, [i | rest]) when is_list(list) do
    case Integer.parse(i) do
      {n, ""} when n < length(list) -> dig(Enum.at(list, n), rest)
      _ -> :error
    end
  end

  defp dig(_, _), do: :error

  defp modify(value, "minor"), do: {:ok, minor(value)}

  defp modify(value, modifier) do
    case to_time(value) do
      nil -> :error
      t when modifier == "unix" -> {:ok, Integer.to_string(DateTime.to_unix(t))}
      t when modifier == "date" -> {:ok, Date.to_iso8601(DateTime.to_date(t))}
      t -> {:ok, DateTime.to_iso8601(t)}
    end
  end

  @doc "A time from an input value: an ISO time or date (as UTC). nil otherwise."
  def to_time(value) when is_binary(value) do
    value = String.trim(value)

    with {:error, _} <- DateTime.from_iso8601(value),
         {:error, _} <- NaiveDateTime.from_iso8601(value),
         {:error, _} <- Date.from_iso8601(value) do
      nil
    else
      {:ok, %DateTime{} = t, _} -> t
      {:ok, %NaiveDateTime{} = t} -> DateTime.from_naive!(t, "Etc/UTC")
      {:ok, %Date{} = d} -> DateTime.new!(d, ~T[00:00:00], "Etc/UTC")
    end
  end

  def to_time(_), do: nil

  defp minor(value) do
    case Float.parse(value |> to_string() |> String.replace(",", ".")) do
      {n, _} -> n |> Kernel.*(100) |> round() |> Integer.to_string()
      :error -> to_string(value)
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
  @doc false
  def pairs(procedure, values) do
    names =
      [procedure.key | Enum.map(procedure.inputs, & &1.name)] ++
        (values |> Map.keys() |> Enum.filter(&is_binary/1) |> Enum.sort())

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
  defp text(%{} = map), do: Jason.encode!(map)

  defp text(list) when is_list(list) do
    if Enum.any?(list, &(is_map(&1) or is_list(&1))),
      do: Jason.encode!(list),
      else: Enum.map_join(list, ", ", &to_string/1)
  end

  defp text(v), do: v |> to_string() |> String.replace(~r/\s+/, " ") |> String.trim()

  @doc "Whether a procedure is more than one prompt sent as a message."
  def multi_step?(%{source: "legacy"}), do: false

  def multi_step?(%{steps: [%{kind: "prompt"} = s]}),
    do: s.session == "fresh" or s.wait or s.model != nil

  def multi_step?(_), do: true

  @doc "`/` completion: the Project's procedures, with their inputs."
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
  How procedures work, for a Project's AGENTS.md and the agent that drafts
  one: the file, run-links to start the next one, and the hidden blocks a
  step's reply ends with.
  """
  def conventions do
    """
    ## Procedures

    A procedure is one file, `.peon/procedures/<name>.md`, run as `/<name>`
    (and by a schedule, a button in a result, or a Queue ticket). Settings go
    in the front matter; each step's prompt is a `## <Step>` section:

    ```markdown
    ---
    name: refund
    description: Refund one Stripe charge. Asks before it sends.
    key: charge
    inputs:
      charge: { type: text }
      amount: { type: money, currency: NOK }
      name: { type: text }
    ---
    Refund {amount} NOK on charge {charge} for {name}. Refuse a charge that is
    already refunded.
    ```

    Without `steps:` the body is the one step's prompt. More steps:

    ```yaml
    schedule: Mon 07:00            # or "daily 02:00", "weekdays 08:00", cron
    outputs:
      approved: [{ charge: text, amount: money, name: text }]
    steps:
      - name: Read                 # its prompt is the "## Read" section
        model: haiku               # opus, sonnet, haiku, or provider/model
        effort: low
      - name: Decide
        session: fresh             # a clean model; gets hand_over instead
        hand_over: [Read, refund-policy.md]   # earlier steps, .peon/ notes, ticket, diff
        returns: approved
        wait: me                   # stop for a person after this step
      - name: Post
        offers: refund             # rows get a button that runs /refund
    ```

    Other step kinds: `run: refund` (with `for_each: approved`, `with:`,
    `on_fail: continue`) runs another procedure; `queue: ship` with
    `for_each:` and `title:` adds tickets in a code Project; `call:
    stripe.create_refund` with `params:` and `confirm:` sends one of the
    Project's API calls (`.peon/api/stripe.json`) with no model. `key` is the input that identifies the thing acted on
    (a charge id, not a name): never act twice on the same key. Notes a step
    can be handed live in `.peon/*.md`.

    ### Since the last run

    A procedure that reads what came in (mail, orders) takes a time input
    that starts where its last run started, so nothing is read twice or
    missed:

    ```yaml
    inputs:
      since: { type: date, default: last_run, max: 4d }
    ```

    `{since}` is an ISO time: when the last finished run started, but never
    more than `max` back (also on the first run). A failed run doesn't count,
    so the next one covers it again. A person can type `1d`, `12h` or a date
    instead. Don't give a schedule a number of days: a daily schedule gets
    about one day by itself and catches up after a missed day. For an API's
    query use `{since.unix}` (seconds) or `{since.date}` (2026-10-12).

    ### Passing data on

    A `call:` step with `returns: customer` keeps the JSON answer as the
    output `customer`. Later steps use it as `{customer.email}` or
    `{customer.matches.0.id}`, in `params:`, `with:`, `confirm:` and prompts.
    So does a `run:` step, from the outputs of the procedure it ran.

    Make each part its own procedure, so a person can run it alone (find
    mail, look up a customer, act on one), then a chain that runs them:

    ```yaml
    # refund-one.md: one email in, one comment out
    key: message
    inputs:
      message: { type: text }
      email: { type: text }
    steps:
      - name: Look up
        call: shop.find_customer
        params: { q: "{email}" }
        returns: customer
      - name: Comment
        call: mail.add_comment
        params: { id: "{message}", body: "Refund: https://shop.test/refund/{customer.id}" }
    ```

    ```yaml
    # refunds.md: the chain
    inputs:
      since: { type: date, default: last_run, max: 4d }
    steps:
      - name: Find
        run: find-refunds          # returns refunds: [{ message, email, name }]
      - name: Each
        run: refund-one
        for_each: refunds
        on_fail: continue
    ```

    When a lookup can find nothing or several, put a prompt step between
    (`returns:` the one it picked) instead of trusting the first match.

    ### Starting the next procedure

    A result can offer the next step as run-links, one row per item:

    ```markdown
    - **Ola Nordmann** · 299 NOK · charged twice [Send refund](run:refund?charge=ch_1&name=Ola%20Nordmann&amount=299&currency=NOK)
    ```

    The app shows each as a button, and "Send all" when there are several.
    URL-encode values. Use only procedures this Project has.

    ### Blocks a reply ends with (hidden in the app)

    Per row of a batch, its outcome:

    ```peon-status
    {"key": "ch_1", "status": "done", "note": "Refunded 299 NOK · re_9"}
    {"key": "ch_2", "status": "failed", "note": "Card expired"}
    ```

    A step with `returns: approved` ends with its output as JSON:

    ```peon-output
    {"approved": [{"charge": "ch_1", "amount": 299, "name": "Ola Nordmann"}]}
    ```

    A review step with `on_changes` ends with ```peon-step {"changes": true}```
    (or false).
    """
  end

  @doc """
  Starts drafting a new procedure in the Project's chat from `description`
  (the user's words). Returns `{:ok, session_id, not_ready}` where
  `not_ready` are its API services still missing their secret.
  """
  def draft(project, user, description) do
    services = Enum.filter(Connectors.all_for(project), &(&1.error == nil))
    secrets = Vault.names()

    calls =
      for c <- services,
          t <- c.tools,
          t.permission != "deny",
          do: "#{c.name}.#{t.name}"

    not_ready = for c <- services, not Connectors.ready?(c, secrets), do: c.name

    connector_hint =
      cond do
        calls == [] ->
          "It has no API calls yet (.peon/api/)."

        true ->
          "Its API calls (a `call:` step, or the gateway tool `<service>_<call>`): #{Enum.join(calls, ", ")}."
      end

    prompt = """
    Add a procedure to this Project (#{project.name}). Its job, in the user's words:

    #{description}

    1. Write it as #{@dir}/<name>.md, with a short name it runs as (/<name>). One step unless the job needs more. If a person should look before acting (find, then act), make two procedures and have the first offer the second.
    2. Put the values it acts on, and choices worth asking for on each run, under inputs.
    3. Add a line about it to AGENTS.md.

    #{connector_hint} Keep it short. Don't run it now; end by telling me to try /<name>.

    #{conventions()}
    """

    with {:ok, session} <- Sessions.open(project, user, title: project.name),
         {:ok, _} <- Sessions.send_text(session["id"], prompt, project.directory) do
      {:ok, session["id"], not_ready}
    end
  end

  ## Models for steps

  @doc """
  The OpenCode model a step names: `provider/id`, an id, or a short name like
  `opus` (its newest match, from `prefer`'s provider first: the one the
  Project's default model comes from). Effort becomes the model's variant when
  it has one. Returns `%{"id", "providerID", ["variant"]}` or nil.
  """
  def resolve_model(name, effort, models, prefer \\ nil)
  def resolve_model(nil, _effort, _models, _prefer), do: nil

  def resolve_model(name, effort, models, prefer) do
    name = String.downcase(name)

    found =
      case String.split(name, "/", parts: 2) do
        [provider, id] ->
          Enum.find(
            models,
            &(String.downcase(&1["providerID"] || "") == provider and
                String.downcase(&1["id"] || "") == id)
          )

        [short] ->
          Enum.find(models, &(String.downcase(&1["id"] || "") == short)) ||
            models
            |> Enum.filter(fn m ->
              m["enabled"] != false and m["status"] != "deprecated" and
                String.contains?(String.downcase("#{m["id"]} #{m["name"]}"), short)
            end)
            |> Enum.sort_by(&{&1["providerID"] == prefer, &1["id"] || ""}, :desc)
            |> List.first()
      end

    case found do
      nil ->
        nil

      m ->
        variants = for %{"id" => v} <- m["variants"] || [], do: v
        base = %{"id" => m["id"], "providerID" => m["providerID"]}
        if effort && effort in variants, do: Map.put(base, "variant", effort), else: base
    end
  end

  @doc "A step's model as a short label: \"Opus\", or the name as written."
  def model_label(nil), do: nil

  def model_label(name) do
    case name |> String.split("/") |> List.last() |> String.split("-") do
      ["gpt", v | rest] -> Enum.join(["GPT-" <> v | Enum.map(rest, &String.capitalize/1)], " ")
      parts -> Enum.map_join(parts, " ", &String.capitalize/1)
    end
  end
end
