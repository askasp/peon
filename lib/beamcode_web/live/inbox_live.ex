defmodule BeamcodeWeb.InboxLive do
  @moduledoc "Everything waiting on a person: permission asks and finished schedule runs."
  use BeamcodeWeb, :live_view
  alias Beamcode.{Inbox, Opencode, Schedules}
  alias BeamcodeWeb.Shell

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Inbox", filter: "all") |> load()}
  end

  defp load(socket) do
    user = socket.assigns.current_scope.user
    items = Inbox.items(user, socket.assigns.shell_projects)
    mine = Enum.count(items, & &1.mine?)

    shown =
      case socket.assigns.filter do
        "mine" -> Enum.filter(items, & &1.mine?)
        "team" -> Enum.reject(items, & &1.mine?)
        _ -> items
      end

    socket
    |> assign(counts: %{mine: mine, team: length(items) - mine, all: length(items)})
    |> stream(:items, Enum.map(shown, &Map.put(&1, :id, item_id(&1))), reset: true)
  end

  defp item_id(%{type: :permission, perm: p}), do: "perm-" <> p["id"]
  defp item_id(%{type: :run, run: r}), do: "run-#{r.id}"

  @impl true
  def handle_event("filter", %{"f" => f}, socket),
    do: {:noreply, socket |> assign(filter: f) |> load()}

  def handle_event("permission", %{"session" => sid, "id" => id, "decision" => decision}, socket) do
    case Opencode.reply_permission(sid, id, decision) do
      {:ok, _} -> {:noreply, socket}
      {:error, e} -> {:noreply, put_flash(socket, :error, Shell.format_error(e))}
    end
  end

  def handle_event("dismiss", %{"run" => id}, socket) do
    Schedules.mark_seen(String.to_integer(id))
    {:noreply, socket}
  end

  @impl true
  def handle_info({:oc_activity, _, _}, socket), do: {:noreply, load(socket)}
  def handle_info({:runs_changed, _}, socket), do: {:noreply, load(socket)}
  def handle_info(_, socket), do: {:noreply, socket}

  defp local_time(%DateTime{} = dt) do
    dt
    |> DateTime.to_naive()
    |> NaiveDateTime.to_erl()
    |> :calendar.universal_time_to_local_time()
    |> NaiveDateTime.from_erl!()
    |> Calendar.strftime("%a %-d %b %H:%M")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} shell={assigns} active={:inbox}>
      <Layouts.page_header title="Inbox" subtitle="Waiting on you, and on the team" />
      <div class="flex-1 min-h-0 overflow-y-auto">
        <div class="max-w-[860px] px-10 py-6 flex flex-col gap-4">
          <div id="inbox-filters" class="flex gap-1.5">
            <button
              :for={
                {f, label} <- [
                  {"all", "All · #{@counts.all}"},
                  {"mine", "Mine · #{@counts.mine}"},
                  {"team", "Team · #{@counts.team}"}
                ]
              }
              id={"inbox-filter-#{f}"}
              phx-click="filter"
              phx-value-f={f}
              class={[
                "h-8 px-3 rounded-lg text-[13px] transition",
                if(@filter == f, do: "bg-fg text-canvas", else: "bg-raised text-muted hover:text-fg")
              ]}
            >
              {label}
            </button>
          </div>

          <div id="inbox-items" phx-update="stream" class="flex flex-col gap-3">
            <div id="inbox-empty" class="hidden only:block py-16 text-center text-[13.5px] text-faint">
              Nothing waiting. Permission asks and finished scheduled runs show up here.
            </div>
            <div
              :for={{dom_id, item} <- @streams.items}
              id={dom_id}
              class={[
                "rounded-[14px] p-4 flex flex-col gap-3",
                if(item.type == :permission,
                  do: "bg-waitbg/60 shadow-[inset_0_0_0_1px_var(--color-waitline)]",
                  else: "bg-panel shadow-[inset_0_0_0_1px_var(--color-line)]"
                )
              ]}
            >
              <%= if item.type == :permission do %>
                <div class="flex items-center gap-3">
                  <Layouts.avatar name={item.project.name} status={:waiting} />
                  <div class="flex flex-col min-w-0">
                    <span class="text-[14px] font-medium truncate">
                      {Inbox.permission_title(item.perm)}
                    </span>
                    <span class="text-[12.5px] text-muted truncate">
                      {item.project.name} · {item.session["title"] || "session"} · {if item.mine?,
                        do: "your session",
                        else: "team"}
                    </span>
                  </div>
                </div>
                <pre
                  :if={item.perm["resources"] not in [nil, [], ["*"]]}
                  class="px-3.5 py-2.5 rounded-[10px] bg-code font-mono text-[12.5px] text-soft whitespace-pre-wrap break-all"
                  phx-no-format
                >{Enum.join(item.perm["resources"], "\n")}</pre>
                <div class="flex gap-2">
                  <button
                    class="btn btn-primary"
                    phx-click="permission"
                    phx-value-session={item.perm["sessionID"]}
                    phx-value-id={item.perm["id"]}
                    phx-value-decision="once"
                    id={"inbox-once-#{item.perm["id"]}"}
                  >Allow once</button>
                  <button
                    class="btn"
                    phx-click="permission"
                    phx-value-session={item.perm["sessionID"]}
                    phx-value-id={item.perm["id"]}
                    phx-value-decision="always"
                    id={"inbox-always-#{item.perm["id"]}"}
                  >Always for this project</button>
                  <button
                    class="btn"
                    phx-click="permission"
                    phx-value-session={item.perm["sessionID"]}
                    phx-value-id={item.perm["id"]}
                    phx-value-decision="reject"
                    id={"inbox-deny-#{item.perm["id"]}"}
                  >Deny</button>
                  <.link navigate={~p"/s/#{item.perm["sessionID"]}"} class="btn ml-auto">Open session</.link>
                </div>
              <% else %>
                <div class="flex items-center gap-3">
                  <Layouts.avatar name={item.project.name} />
                  <div class="flex flex-col min-w-0">
                    <span class="text-[14px] font-medium truncate">
                      {item.run.schedule_key} {if item.run.status == "done",
                        do: "is ready",
                        else: "failed"}
                    </span>
                    <span class="text-[12.5px] text-muted truncate">
                      {item.project.name} · {if item.run.scope == "private",
                        do: "only you",
                        else: "team schedule"} · {local_time(item.run.inserted_at)}
                    </span>
                    <span :if={item.run.error} class="text-[12.5px] text-del truncate">{item.run.error}</span>
                  </div>
                  <div class="ml-auto flex gap-2">
                    <.link
                      :if={item.run.session_id}
                      navigate={~p"/s/#{item.run.session_id}"}
                      class="btn btn-primary"
                      id={"inbox-open-#{item.run.id}"}
                    >Open session</.link>
                    <button
                      class="btn"
                      phx-click="dismiss"
                      phx-value-run={item.run.id}
                      id={"inbox-dismiss-#{item.run.id}"}
                    >Done</button>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
