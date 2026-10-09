defmodule BeamcodeWeb.SessionHTML do
  use BeamcodeWeb, :html

  def new(assigns) do
    ~H"""
    <main class="min-h-screen flex items-center justify-center px-4">
      <div class="w-full max-w-sm">
        <div class="flex items-end justify-between mb-8">
          <Layouts.logo size="lg" />
          <span class="text-[12.5px] text-muted pb-0.5">on OpenCode server</span>
        </div>

        <div class="rounded-[14px] bg-panel shadow-[inset_0_0_0_1px_var(--color-line)] p-6">
          <h1 class="text-[15px] font-semibold mb-1">
            {if @first_run?, do: "Create the admin account", else: "Sign in"}
          </h1>
          <p :if={@first_run?} class="text-[13px] text-muted mb-5">
            This is the first login. The account you create here is the admin. Admins create everyone else.
          </p>
          <div :if={!@first_run?} class="h-4"></div>

          <p
            :if={msg = Phoenix.Flash.get(@flash, :error)}
            id="login-error"
            class="mb-4 text-[13px] text-del"
          >
            {msg}
          </p>

          <.form for={@form} id="login-form" action={~p"/login"}>
            <.input
              field={@form[:username]}
              label="Username"
              autocomplete="username"
              autocapitalize="none"
              required
              phx-mounted={JS.focus()}
            />
            <.input
              field={@form[:password]}
              type="password"
              label="Password"
              autocomplete={if @first_run?, do: "new-password", else: "current-password"}
              required
            />
            <button type="submit" id="login-submit" class="btn btn-primary w-full mt-2 h-10">
              {if @first_run?, do: "Create admin and sign in", else: "Sign in"}
            </button>
          </.form>
        </div>
      </div>
    </main>
    """
  end
end
