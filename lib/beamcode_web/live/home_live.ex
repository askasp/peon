defmodule BeamcodeWeb.HomeLive do
  @moduledoc "Opens the first project, or offers to make one."
  use BeamcodeWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    case Enum.find(socket.assigns.shell_projects, &(&1.kind in ~w(code chat routine))) do
      nil -> {:ok, assign(socket, :page_title, "Welcome")}
      project -> {:ok, push_navigate(socket, to: ~p"/p/#{project.id}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} shell={assigns}>
      <div class="flex-1 flex items-center justify-center p-10">
        <div class="max-w-md text-center flex flex-col items-center gap-4">
          <span class="text-[22px] font-semibold">A project is a folder.</span>
          <span class="text-[14.5px] text-muted text-pretty">
            A coding repo, a routine that does one job, and general chat are all projects.
            Start with one.
          </span>
          <div class="flex gap-2 mt-2">
            <.link navigate={~p"/new?kind=code"} class="btn btn-primary" id="home-new-code">
              New code project
            </.link>
            <.link navigate={~p"/new?kind=routine"} class="btn" id="home-new-routine">New routine</.link>
            <.link navigate={~p"/new?kind=chat"} class="btn" id="home-new-chat">New chat</.link>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
