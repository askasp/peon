defmodule Beamcode.Composer.Catalog do
  @moduledoc """
  The models and agents a composer line can name ("… using opus", "with the
  plan agent"), from the OpenCode server.

  The preview parses on every keystroke, so the lists are kept for a minute,
  and a slow or missing server gives empty lists after two seconds instead of
  holding the preview up.
  """
  alias Beamcode.Opencode

  @wait 2_000

  @type model :: %{value: String.t(), name: String.t()}
  @type t :: %{models: [model], agents: [String.t()], default_provider: String.t() | nil}

  @empty %{models: [], agents: [], default_provider: nil}

  @doc "The cached catalog, fetched again when older than a minute."
  @spec get() :: t
  def get do
    now = System.monotonic_time(:millisecond)
    ttl = ttl()

    case :persistent_term.get(__MODULE__, nil) do
      {at, catalog} when now - at < ttl ->
        catalog

      stale ->
        catalog = fetch() || (stale && elem(stale, 1)) || @empty
        :persistent_term.put(__MODULE__, {now, catalog})
        catalog
    end
  end

  @doc "Forgets the cached catalog (tests, or after models change)."
  def clear, do: :persistent_term.erase(__MODULE__)

  # Kept a minute; tests set 0 so each one sees its own stub.
  defp ttl, do: Application.get_env(:beamcode, :composer_catalog_ttl, :timer.minutes(1))

  defp fetch do
    # Unlinked: a failing fetch gives empty lists, it never takes the caller down.
    task =
      Task.Supervisor.async_nolink(Beamcode.TaskSupervisor, fn ->
        models = Task.async(fn -> Opencode.models() end)
        # No retries: the preview would rather go without agents than wait.
        agents = Task.async(fn -> Opencode.agents(nil, 1) end)
        default = Task.async(fn -> Opencode.default_model() end)

        {Task.await(models, :infinity), Task.await(agents, :infinity),
         Task.await(default, :infinity)}
      end)

    case Task.yield(task, @wait) || Task.shutdown(task, :brutal_kill) do
      {:ok, {{:ok, models}, agents, default}} ->
        %{
          models:
            for(
              m <- models,
              m["enabled"] != false,
              m["status"] != "deprecated",
              do: %{value: "#{m["providerID"]}/#{m["id"]}", name: m["name"] || m["id"]}
            ),
          agents:
            case agents do
              {:ok, list} -> for a <- list, a["mode"] != "subagent", !a["hidden"], do: a["id"]
              _ -> []
            end,
          default_provider:
            case default do
              {:ok, %{"providerID" => p}} -> p
              _ -> nil
            end
        }

      _ ->
        nil
    end
  end
end
