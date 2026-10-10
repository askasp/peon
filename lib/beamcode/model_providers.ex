defmodule Beamcode.ModelProviders do
  @moduledoc """
  Model providers on the OpenCode server ("integrations"): which are signed in,
  and the forms for signing in to more with an API key or OAuth. Used by the
  app's admin channel.

  An integration has `methods`; each method may have a `form` of fields. A
  field can be hidden (sent with its default) or shown only `when` another
  answer has some value.
  """
  alias Beamcode.Opencode

  # Shown first when connecting. OpenCode Go is the team's subscription.
  @featured ~w(opencode-go opencode openai anthropic deepseek github-copilot)

  @doc "`{:ok, integrations, models_by_provider, default_model}` or an error."
  def load do
    with {:ok, integrations} <- Opencode.integrations() do
      models =
        case Opencode.models() do
          {:ok, list} when is_list(list) -> Enum.group_by(list, & &1["providerID"])
          _ -> %{}
        end

      default =
        case Opencode.default_model() do
          {:ok, %{"providerID" => p, "id" => id}} -> "#{p}/#{id}"
          {:ok, %{"providerID" => p, "modelID" => id}} -> "#{p}/#{id}"
          _ -> nil
        end

      {:ok, Enum.sort_by(integrations, &String.downcase(&1["name"] || &1["id"])), models, default}
    end
  end

  def signed_in?(i), do: (i["connections"] || []) != []

  @doc "Featured integrations not signed in yet, in featured order."
  def featured(integrations) do
    by_id = Map.new(integrations, &{&1["id"], &1})
    for id <- @featured, i = by_id[id], not signed_in?(i), do: i
  end

  def connection_label(%{"type" => "env"} = c), do: "from $#{c["name"]} on the server"
  def connection_label(%{"method" => "oauth"} = c), do: "signed in · #{c["label"]}"
  def connection_label(c), do: "API key · #{c["label"]}"

  @doc "The fields a method asks for (external ones are filled by the browser flow)."
  def fields(method), do: Enum.reject(method["form"] || [], &(&1["type"] == "external"))

  def shown?(field, answers) do
    not Map.get(field, "hidden", false) and
      Enum.all?(field["when"] || [], fn w ->
        value = Map.get(answers, w["key"])

        case w["op"] do
          "eq" -> to_string(value) == to_string(w["value"])
          "neq" -> to_string(value) != to_string(w["value"])
          _ -> true
        end
      end)
  end

  @doc "The answer map OpenCode expects for a method, from form answers (nil when it has no form)."
  def answer(nil, _answers), do: nil

  def answer(method, answers) do
    case fields(method) do
      [] ->
        nil

      fields ->
        for f <- fields,
            hidden = Map.get(f, "hidden", false),
            hidden or shown?(f, answers),
            value = if(hidden, do: f["default"], else: Map.get(answers, f["key"], f["default"])),
            value not in [nil, ""],
            into: %{},
            do: {f["key"], cast(f["type"], value)}
    end
  end

  defp cast("boolean", v), do: v in [true, "true"]

  defp cast(type, v) when type in ["number", "integer"] and is_binary(v) do
    case Float.parse(v) do
      {n, _} -> if type == "integer", do: trunc(n), else: n
      :error -> v
    end
  end

  defp cast(_type, v), do: v
end
