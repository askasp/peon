defmodule Beamcode.Sessions do
  @moduledoc "Starting OpenCode sessions for a project and sending prompts to them."
  alias Beamcode.{BranchGuard, Opencode, Projects}
  alias Beamcode.Projects.Project

  @doc """
  Creates a session in the project's folder, or in a fresh git worktree when
  `worktree: true`. Records who started it.

  opts: :worktree, :scope, :schedule_key, :title, :agent, :model (%{"id", "providerID"})
  """
  def start(%Project{} = project, user, opts \\ []) do
    with {:ok, dir} <- directory(project, Keyword.get(opts, :worktree, false)) do
      body =
        %{location: %{directory: dir}}
        |> put_opt(:title, opts[:title])
        |> put_opt(:agent, opts[:agent])
        |> put_opt(:model, opts[:model])
        |> put_rules(BranchGuard.session_rules(project))

      with {:ok, session} <- Opencode.create_session(body) do
        Projects.record_session(session["id"], project, user,
          scope: Keyword.get(opts, :scope, "team"),
          schedule_key: opts[:schedule_key]
        )

        {:ok, session}
      end
    end
  end

  defp put_rules(map, []), do: map
  defp put_rules(map, rules), do: Map.put(map, :permissions, rules)

  defp put_opt(map, _key, nil), do: map
  defp put_opt(map, _key, ""), do: map
  defp put_opt(map, key, value), do: Map.put(map, key, value)

  defp directory(project, false), do: {:ok, project.directory}

  defp directory(%Project{oc_project_id: nil} = project, true),
    do: {:error, "#{project.name} has no OpenCode project id yet"}

  defp directory(project, true) do
    case Opencode.create_worktree(project.oc_project_id) do
      {:ok, %{"directory" => dir}} -> {:ok, dir}
      error -> error
    end
  end

  @doc """
  Sends text to a session. `/name rest` runs a skill or command called `name`
  when one exists in the session's folder; anything else is a plain prompt.
  `files` are `%{uri: "data:image/png;base64,…", name: "…"}` attachments.
  """
  def send_text(session_id, text, dir, files \\ [], delivery \\ nil) do
    text = String.trim(text)

    attach = fn body ->
      body = if files == [], do: body, else: Map.put(body, :files, files)
      if delivery, do: Map.put(body, :delivery, delivery), else: body
    end

    case Regex.run(~r{^/([\w.-]+)\s*(.*)$}s, text) do
      [_, name, rest] ->
        cond do
          skill?(dir, name) ->
            Opencode.prompt(
              session_id,
              attach.(%{
                text: if(rest == "", do: "Run the #{name} skill.", else: rest),
                skills: [%{id: name}]
              })
            )

          command?(dir, name) ->
            Opencode.command(session_id, attach.(%{name: name, text: rest}))

          true ->
            Opencode.prompt(session_id, attach.(%{text: text}))
        end

      _ ->
        Opencode.prompt(session_id, attach.(%{text: text}))
    end
  end

  defp skill?(dir, name) do
    case Opencode.skills(dir) do
      {:ok, skills} -> Enum.any?(skills, &(&1["id"] == name or &1["name"] == name))
      _ -> false
    end
  end

  defp command?(dir, name) do
    case Opencode.commands(dir) do
      {:ok, cmds} -> Enum.any?(cmds, &(&1["name"] == name))
      _ -> false
    end
  end

  @doc """
  Skills and commands available in a folder, for `/` completion.

  OpenCode loads a folder's skills and commands lazily: the first request for a
  folder answers with empty lists while it loads. So an empty answer is retried.
  """
  def slash_items(dir, tries \\ 5) do
    case {list(Opencode.skills(dir)), list(Opencode.commands(dir))} do
      {[], []} when tries > 1 ->
        Process.sleep(300)
        slash_items(dir, tries - 1)

      {skills, commands} ->
        skills =
          Enum.map(skills, &%{name: &1["id"], description: &1["description"], kind: "skill"})

        commands =
          Enum.map(
            commands,
            &%{name: &1["name"], description: &1["description"], kind: "command"}
          )

        Enum.reject(skills ++ commands, &(&1.name in ["opencode", "report"]))
    end
  end

  defp list({:ok, list}) when is_list(list), do: list
  defp list(_), do: []
end
