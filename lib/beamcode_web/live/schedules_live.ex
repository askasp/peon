defmodule BeamcodeWeb.SchedulesLive do
  @moduledoc "All schedules the user can see, across projects."
  use BeamcodeWeb, :live_view
  alias Beamcode.Schedules

  @impl true
  def mount(_params, _session, socket) do
    socket = assign(socket, page_title: "Schedules", filter: "all", loading: true)
    user = socket.assigns.current_scope.user
    {:ok, socket |> stream(:rows, []) |> start_async(:load, fn -> Schedules.list_all(user) end)}
  end

  @impl true
  def handle_async(:load, {:ok, all}, socket) do
    {:noreply, socket |> assign(all: all, loading: false) |> show_rows()}
  end

  def handle_async(:load, _, socket), do: {:noreply, assign(socket, all: [], loading: false)}

  defp show_rows(socket) do
    rows =
      case socket.assigns.filter do
        "me" -> Enum.filter(socket.assigns.all, &(&1.scope == "me"))
        "team" -> Enum.filter(socket.assigns.all, &(&1.scope != "me"))
        _ -> socket.assigns.all
      end

    stream(socket, :rows, Enum.map(rows, &Map.put(&1, :id, "#{&1.project.id}-#{&1.key}")),
      reset: true
    )
  end

  @impl true
  def handle_event("filter", %{"f" => f}, socket),
    do: {:noreply, socket |> assign(filter: f) |> show_rows()}

  @impl true
  def handle_info(msg, socket) when elem(msg, 0) in [:schedules_changed, :runs_changed] do
    user = socket.assigns.current_scope.user
    {:noreply, start_async(socket, :load, fn -> Schedules.list_all(user) end)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} shell={assigns} active={:schedules}>
      <Layouts.page_header title="Schedules" subtitle="All schedules you can see, across projects" />
      <div class="flex-1 min-h-0 overflow-y-auto">
        <div class="max-w-[1100px] px-10 py-6 flex flex-col gap-4">
          <div id="schedule-filters" class="flex gap-1.5">
            <button
              :for={{f, label} <- [{"all", "All"}, {"me", "Only me"}, {"team", "Team"}]}
              id={"schedule-filter-#{f}"}
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

          <div class="rounded-[14px] bg-panel shadow-[inset_0_0_0_1px_var(--color-line)] overflow-hidden">
            <div class="grid grid-cols-[1.4fr_1fr_1fr_.7fr_.7fr_1fr_.6fr] gap-3 px-4 h-10 items-center text-[12.5px] text-muted border-b border-line">
              <span>Schedule</span><span>Project</span><span>When</span><span>Scope</span><span>Owner</span><span>Next run</span><span>Last</span>
            </div>
            <div id="schedule-rows" phx-update="stream">
              <div
                id="schedule-rows-empty"
                class="hidden only:block px-4 py-10 text-center text-[13px] text-faint"
              >
                {if @loading,
                  do: "Loading…",
                  else: "No schedules yet. Add one from a project's Schedules tab."}
              </div>
              <.link
                :for={{dom_id, s} <- @streams.rows}
                id={dom_id}
                data-kb-row
                navigate={~p"/p/#{s.project.id}/schedules"}
                class="grid grid-cols-[1.4fr_1fr_1fr_.7fr_.7fr_1fr_.6fr] gap-3 px-4 h-11 items-center text-[13.5px] border-b border-line last:border-0 hover:bg-hov transition"
              >
                <span class="font-medium truncate">{s.key}</span>
                <span class="text-muted truncate">{s.project.name}</span>
                <span class="text-muted truncate">{s.when}</span>
                <span class="text-muted">{if s.scope == "me", do: "Only me", else: "Team"}</span>
                <span class="text-muted truncate">{s.owner || "—"}</span>
                <span class="text-muted">{if s.next,
                  do: Calendar.strftime(s.next, "%a %H:%M"),
                  else: "—"}</span>
                <span class={[
                  "text-[12px]",
                  s.last && s.last.status == "done" && "text-add",
                  s.last && s.last.status == "failed" && "text-del",
                  s.last && s.last.status == "running" && "text-run",
                  !s.last && "text-faint"
                ]}>
                  {if s.last, do: s.last.status, else: "new"}
                </span>
              </.link>
            </div>
          </div>

          <div class="grid grid-cols-2 gap-3 text-[13px] text-muted">
            <div class="rounded-xl bg-panel p-4">
              <span class="text-fg font-medium">Only me.</span>
              Runs with your access. Its sessions and Inbox items are visible only to you.
            </div>
            <div class="rounded-xl bg-panel p-4">
              <span class="text-fg font-medium">Team.</span>
              Anyone with access to the project sees its runs, and any of them can approve. The owner is who it runs as.
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
