defmodule BeamcodeWeb.AdminChannel do
  @moduledoc """
  The admin screens for the app ("admin", admins only): users, the old shared
  API calls, and model providers. Secrets belong to each Project.

  Requests:
    * `users` → `{users}`; `create_user` `{username, password, admin}`;
      `toggle_admin` `{id}`; `delete_user` `{id}`
    * `connectors` → `{connectors}`; `apply`; `new_connector` → `{session_id}`
    * `models` → `{integrations, featured, models, default}`;
      `connect_key` `{id, key, answers}`; `start_oauth` `{id, method, answers}` → `{attempt}`;
      `complete_oauth` `{code}`; `paste_callback` `{url}`; `cancel_oauth`; `disconnect` `{id}`

  Pushes `oauth` `{status, message}` while an OAuth sign-in is pending
  (complete | failed | expired).
  """
  use BeamcodeWeb, :channel

  alias Beamcode.{Accounts, Connectors, ModelProviders, Opencode, Sessions, Workspace}
  alias BeamcodeWeb.{ChannelTasks}

  @poll_ms 2_000

  @impl true
  def join("admin", _params, %{assigns: %{user: %{admin: true}}} = socket),
    do: {:ok, assign(socket, attempt: nil, tasks: %{})}

  def join("admin", _params, _socket), do: {:error, %{reason: "unauthorized"}}

  ## Users

  @impl true
  def handle_in("users", _params, socket),
    do: {:reply, {:ok, %{users: Enum.map(Accounts.list_users(), &user/1)}}, socket}

  def handle_in("create_user", params, socket) do
    attrs = Map.take(params, ["username", "password"])

    case Accounts.create_user(attrs, admin: params["admin"] == true) do
      {:ok, user} -> {:reply, {:ok, %{user: user(user)}}, socket}
      {:error, cs} -> {:reply, {:error, %{message: changeset_error(cs)}}, socket}
    end
  end

  def handle_in("toggle_admin", %{"id" => id}, socket) do
    with_other_user(socket, id, "You can't change your own admin role.", fn user ->
      {:ok, user} = Accounts.set_admin(user, !user.admin)
      # Their open sockets reconnect, so the new role applies right away.
      BeamcodeWeb.AppToken.disconnect(user.id)
      {:ok, %{user: user(user)}}
    end)
  end

  def handle_in("delete_user", %{"id" => id}, socket) do
    with_other_user(socket, id, "You can't delete yourself.", fn user ->
      {:ok, _} = Accounts.delete_user(user)
      BeamcodeWeb.AppToken.disconnect(user.id)
      {:ok, %{}}
    end)
  end

  ## Shared API calls

  def handle_in("connectors", _params, socket) do
    ChannelTasks.reply_async(socket, fn -> {:ok, connectors()} end)
  end

  def handle_in("apply", _params, socket) do
    ChannelTasks.reply_async(socket, fn ->
      Connectors.sync_all()
      {:ok, connectors()}
    end)
  end

  def handle_in("new_connector", _params, socket) do
    user = socket.assigns.user

    case Workspace.setup_project() do
      nil ->
        {:reply,
         {:error, %{message: "The setup project isn't ready. Is the OpenCode server reachable?"}},
         socket}

      setup ->
        ChannelTasks.reply_async(socket, fn ->
          case Sessions.start(setup, user, worktree: false) do
            {:ok, session} -> {:ok, %{session_id: session["id"]}}
            {:error, reason} -> {:error, %{message: ChannelTasks.error_message(reason)}}
          end
        end)
    end
  end

  ## Model providers

  def handle_in("models", _params, socket) do
    ChannelTasks.reply_async(socket, fn ->
      case ModelProviders.load() do
        {:ok, integrations, models, default} ->
          {:ok,
           %{
             integrations: Enum.map(integrations, &integration/1),
             featured: Enum.map(ModelProviders.featured(integrations), & &1["id"]),
             models:
               Map.new(models, fn {p, list} -> {p, Enum.map(list, &(&1["name"] || &1["id"]))} end),
             default: default
           }}

        error ->
          {:error, %{message: ChannelTasks.error_message(error)}}
      end
    end)
  end

  def handle_in("connect_key", %{"id" => id, "key" => key} = params, socket)
      when is_binary(key) do
    key = String.trim(key)

    if key == "" do
      {:reply, {:error, %{message: "Paste the API key."}}, socket}
    else
      ChannelTasks.reply_async(socket, fn ->
        method = method(id, &(&1["type"] == "key"))

        case Opencode.connect_key(
               id,
               key,
               ModelProviders.answer(method, params["answers"] || %{})
             ) do
          {:ok, _} -> {:ok, %{}}
          error -> {:error, %{message: ChannelTasks.error_message(error)}}
        end
      end)
    end
  end

  def handle_in("start_oauth", %{"id" => id, "method" => method_id} = params, socket) do
    socket = cancel_attempt(socket)

    ChannelTasks.reply_async(
      socket,
      fn ->
        method = method(id, &(&1["id"] == method_id))

        case Opencode.start_oauth(
               id,
               method_id,
               ModelProviders.answer(method, params["answers"] || %{})
             ) do
          {:ok, %{"attemptID" => _} = attempt} -> {:attempt, Map.put(attempt, "integration", id)}
          {:ok, _} -> {:ok, %{done: true}}
          error -> {:error, %{message: ChannelTasks.error_message(error)}}
        end
      end,
      fn
        {:attempt, attempt}, socket ->
          Process.send_after(self(), :poll, @poll_ms)
          reply = Map.take(attempt, ["url", "instructions", "mode"])
          {{:ok, %{attempt: reply}}, assign(socket, attempt: attempt)}

        reply, socket ->
          {reply, socket}
      end
    )
  end

  def handle_in("complete_oauth", %{"code" => code}, %{assigns: %{attempt: %{} = a}} = socket) do
    case Opencode.complete_oauth(a["integration"], a["attemptID"], String.trim(code)) do
      {:ok, _} -> {:reply, {:ok, %{}}, assign(socket, attempt: nil)}
      error -> {:reply, {:error, %{message: ChannelTasks.error_message(error)}}, socket}
    end
  end

  def handle_in("paste_callback", %{"url" => url}, socket) when is_binary(url) do
    ChannelTasks.reply_async(socket, fn ->
      case Opencode.forward_oauth_callback(url) do
        :ok -> {:ok, %{}}
        error -> {:error, %{message: ChannelTasks.error_message(error)}}
      end
    end)
  end

  def handle_in("cancel_oauth", _params, socket),
    do: {:reply, {:ok, %{}}, cancel_attempt(socket)}

  def handle_in("disconnect", %{"id" => credential_id}, socket) do
    ChannelTasks.reply_async(socket, fn ->
      case Opencode.remove_credential(credential_id) do
        {:ok, _} ->
          {:ok, %{}}

        error ->
          {:error, %{message: "Could not disconnect: #{ChannelTasks.error_message(error)}"}}
      end
    end)
  end

  def handle_in(_event, _params, socket),
    do: {:reply, {:error, %{message: "Unknown request."}}, socket}

  ## OAuth status

  @impl true
  def handle_info(:poll, %{assigns: %{attempt: %{} = a}} = socket) do
    case Opencode.oauth_status(a["integration"], a["attemptID"]) do
      {:ok, %{"status" => "complete"}} ->
        push(socket, "oauth", %{status: "complete"})
        {:noreply, assign(socket, attempt: nil)}

      {:ok, %{"status" => "failed"} = s} ->
        push(socket, "oauth", %{status: "failed", message: s["message"] || "Sign-in failed."})
        {:noreply, assign(socket, attempt: nil)}

      {:ok, %{"status" => "expired"}} ->
        push(socket, "oauth", %{status: "expired", message: "The sign-in expired. Start again."})
        {:noreply, assign(socket, attempt: nil)}

      _ ->
        Process.send_after(self(), :poll, @poll_ms)
        {:noreply, socket}
    end
  end

  def handle_info({ref, _} = msg, socket) when is_reference(ref),
    do: ChannelTasks.handle_info(msg, socket)

  def handle_info({:DOWN, _, :process, _, _} = msg, socket),
    do: ChannelTasks.handle_info(msg, socket)

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    cancel_attempt(socket)
    :ok
  end

  ## Helpers

  defp user(u),
    do: %{id: u.id, username: u.username, admin: u.admin, inserted_at: u.inserted_at}

  defp with_other_user(socket, id, own_message, fun) do
    case Accounts.get_user(id) do
      nil ->
        {:reply, {:error, %{message: "No such user."}}, socket}

      %{id: same} when same == socket.assigns.user.id ->
        {:reply, {:error, %{message: own_message}}, socket}

      user ->
        {:reply, fun.(user), socket}
    end
  end

  defp changeset_error(cs),
    do: Enum.map_join(cs.errors, ", ", fn {f, {m, _}} -> "#{f} #{m}" end)

  # Secrets live in each Project now; this lists only the old shared API calls.
  defp connectors do
    %{
      connectors:
        for c <- Connectors.list() do
          %{
            name: c.name,
            file: c.file,
            error: c.error,
            base_url: c[:base_url],
            secret: c[:secret],
            projects: c.projects,
            tools:
              for(
                t <- c.tools,
                do: Map.take(t, [:name, :method, :path, :permission, :description])
              )
          }
        end
    }
  end

  defp integration(i) do
    %{
      id: i["id"],
      name: i["name"] || i["id"],
      connections:
        for c <- i["connections"] || [] do
          %{
            id: c["id"],
            type: c["type"],
            label: ModelProviders.connection_label(c),
            # Set when OpenCode can't use it any more (e.g. an expired sign-in).
            problem: c["status"] && (c["status"]["message"] || "needs sign-in again")
          }
        end,
      methods:
        for m <- i["methods"] || [] do
          %{
            id: m["id"],
            type: m["type"],
            label: m["label"],
            fields: ModelProviders.fields(m)
          }
        end
    }
  end

  defp method(integration_id, pred) do
    with {:ok, integrations} <- Opencode.integrations(),
         %{} = i <- Enum.find(integrations, &(&1["id"] == integration_id)) do
      Enum.find(i["methods"] || [], pred)
    else
      _ -> nil
    end
  end

  defp cancel_attempt(%{assigns: %{attempt: %{} = a}} = socket) do
    Opencode.cancel_oauth(a["integration"], a["attemptID"])
    assign(socket, attempt: nil)
  end

  defp cancel_attempt(socket), do: socket
end
