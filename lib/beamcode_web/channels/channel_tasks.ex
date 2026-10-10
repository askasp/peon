defmodule BeamcodeWeb.ChannelTasks do
  @moduledoc """
  Answers channel requests from a task, so a slow OpenCode call doesn't hold
  up the pushes queued behind it.

  `reply_async(socket, fun)` runs `fun` (returning `{:ok, map}` or
  `{:error, map}`) and replies with its result. Pass `then` to turn the result
  into the reply and update the socket, e.g. to keep something server side.
  The channel forwards task messages here from its `handle_info/2`:

      def handle_info({ref, _} = msg, socket) when is_reference(ref),
        do: ChannelTasks.handle_info(msg, socket)
      def handle_info({:DOWN, _, :process, _, _} = msg, socket),
        do: ChannelTasks.handle_info(msg, socket)
  """
  require Logger

  @doc "`{:ok, project}` while the user can still see project `id`, else `:gone`."
  def still_visible(id, user) do
    case Beamcode.Projects.get_project(id) do
      %{} = project ->
        if Beamcode.Projects.visible?(project, user), do: {:ok, project}, else: :gone

      nil ->
        :gone
    end
  end

  @doc "An OpenCode or context error as a sentence for the app."
  def error_message({_status, msg}) when is_binary(msg), do: msg
  def error_message({:transport, msg}), do: "OpenCode server unreachable (#{msg})"
  def error_message(msg) when is_binary(msg), do: msg
  def error_message(other), do: inspect(other)

  def reply_async(socket, fun, then \\ fn result, socket -> {result, socket} end) do
    ref = Phoenix.Channel.socket_ref(socket)
    task = Task.Supervisor.async_nolink(Beamcode.TaskSupervisor, fun)
    tasks = Map.put(socket.assigns[:tasks] || %{}, task.ref, {ref, then})
    {:noreply, Phoenix.Socket.assign(socket, :tasks, tasks)}
  end

  def handle_info({task_ref, result}, socket) when is_reference(task_ref) do
    Process.demonitor(task_ref, [:flush])
    {:noreply, finish(socket, task_ref, result)}
  end

  def handle_info({:DOWN, task_ref, :process, _pid, reason}, socket) do
    Logger.warning("channel task failed: #{inspect(reason, limit: 5)}")
    {:noreply, finish(socket, task_ref, {:error, %{message: "Something went wrong."}})}
  end

  defp finish(socket, task_ref, result) do
    case Map.pop(socket.assigns[:tasks] || %{}, task_ref) do
      {nil, _} ->
        socket

      {{ref, then}, tasks} ->
        {reply, socket} = then.(result, Phoenix.Socket.assign(socket, :tasks, tasks))
        Phoenix.Channel.reply(ref, reply)
        socket
    end
  end
end
