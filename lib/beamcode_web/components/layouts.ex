defmodule BeamcodeWeb.Layouts do
  @moduledoc """
  App chrome: top bar with session tabs, sidebar with projects and pages,
  command palette and flash messages.
  """
  use BeamcodeWeb, :html

  embed_templates "layouts/*"

  @doc """
  Renders the signed-in app shell. Pass the LiveView's assigns as `shell`
  (they carry the sidebar/tab data set by `BeamcodeWeb.Shell`).

      <Layouts.app flash={@flash} current_scope={@current_scope} shell={assigns} active={:inbox}>
        ...
      </Layouts.app>
  """
  attr :flash, :map, required: true
  attr :current_scope, :map, default: nil
  attr :shell, :map, default: %{}
  attr :active, :any, default: nil, doc: "sidebar item: project id, :inbox, :schedules, ..."
  slot :inner_block, required: true

  def app(assigns) do
    shell = assigns.shell

    assigns =
      assign(assigns,
        projects: Map.get(shell, :shell_projects, []),
        tabs: Map.get(shell, :shell_tabs, []),
        inbox: Map.get(shell, :shell_inbox, 0),
        palette: Map.get(shell, :palette),
        keybinds: Map.get(shell, :keybinds, Beamcode.Keybinds.defaults()),
        prefs: Map.get(shell, :kb_prefs, Beamcode.Keybinds.pref_defaults()),
        current_session_id: Map.get(shell, :current_session_id),
        user: assigns.current_scope && assigns.current_scope.user
      )

    assigns =
      assign(assigns,
        sidebar: BeamcodeWeb.Shell.sidebar_order(assigns.projects),
        globals: Beamcode.Keybinds.globals(assigns.user)
      )

    ~H"""
    <div
      id="app-shell"
      phx-hook="Keybinds"
      data-keybinds={Jason.encode!(@keybinds)}
      data-keymap={@prefs["keymap"]}
      data-prefix={@prefs["prefix"]}
      data-which-delay={@prefs["which_key_delay"]}
      data-keycast={to_string(@prefs["keycast"])}
      class="h-screen flex flex-col overflow-hidden bg-canvas text-fg group/shell"
    >
      <header class="h-[52px] flex-none flex items-center gap-3.5 px-3.5 border-b border-line">
        <button
          id="palette-button"
          type="button"
          phx-click="palette_open"
          class="h-[30px] flex-none flex items-center gap-2 pl-2.5 pr-1.5 rounded-lg bg-panel shadow-[inset_0_0_0_1px_var(--color-line)] text-muted text-[12.5px] hover:text-fg hover:bg-raised transition"
        >
          <.icon name="hero-magnifying-glass-micro" class="size-3.5" />
          <span class="max-sm:hidden">Search or run a command</span>
          <.kbd k="mod+k" class="kb-key" />
        </button>
        <nav id="session-tabs" class="flex items-center gap-2.5 min-w-0 overflow-x-auto">
          <%= for {tab, i} <- Enum.with_index(@tabs) do %>
            <span :if={i > 0} class="w-px h-3.5 bg-line flex-none"></span>
            <.link
              navigate={~p"/s/#{tab.id}"}
              id={"tab-#{tab.id}"}
              title={tab.project.name <> " · " <> tab.title}
              class={[
                "group flex items-center gap-2 rounded-md transition flex-none",
                tab.id == @current_session_id && "pr-2 bg-raised"
              ]}
            >
              <.avatar
                name={tab.project.name}
                active={tab.id == @current_session_id}
                status={tab.status}
              />
              <span
                :if={tab.id == @current_session_id}
                class="text-[12.5px] max-w-[220px] truncate text-soft"
              >
                {tab.title}
              </span>
            </.link>
          <% end %>
        </nav>
        <div class="ml-auto flex items-center gap-4 text-[12.5px] text-muted">
          <.link
            navigate={~p"/inbox"}
            id="topbar-inbox"
            class="flex items-center gap-1.5 hover:text-fg transition"
          >
            Inbox
            <span
              :if={@inbox > 0}
              class="h-[18px] flex items-center px-1.5 rounded-full bg-wait text-[#1a1408] font-mono text-[11px] font-semibold"
            >
              {@inbox}
            </span>
          </.link>
          <.link navigate={~p"/settings"} id="topbar-user" class="hover:text-fg transition">
            {@user && @user.username}
          </.link>
        </div>
      </header>

      <div class="flex-1 min-h-0 flex">
        <aside
          id="sidebar"
          class="w-[268px] flex-none box-border px-4 pt-5 pb-4 flex flex-col gap-0.5 border-r border-line overflow-y-auto group-data-[sidebar=hidden]/shell:hidden"
        >
          <.link navigate={~p"/"} id="sidebar-logo" class="px-2.5 pb-6 w-fit" title="Peon">
            <.logo />
          </.link>
          <.side_heading label="Projects" add={~p"/new?kind=code"} id="new-project-link" />
          <.project_link
            :for={{p, i} <- Enum.with_index(@sidebar)}
            :if={p.kind in ~w(code chat)}
            project={p}
            index={i}
            active={@active == p.id}
          />
          <.side_heading
            label="Routines"
            add={~p"/new?kind=routine"}
            id="new-routine-link"
            class="pt-4"
          />
          <.project_link
            :for={{p, i} <- Enum.with_index(@sidebar)}
            :if={p.kind in ~w(routine system)}
            project={p}
            index={i}
            active={@active == p.id}
          />

          <div class="h-[22px] flex-none"></div>
          <.nav_link
            :for={g <- @globals}
            to={g.path}
            label={g.name}
            key={g.key}
            active={to_string(@active) == g.id}
            id={"nav-" <> g.id}
          >
            <span :if={g.id == "inbox" and @inbox > 0} class="font-mono text-[11px] text-wait">
              {@inbox}
            </span>
          </.nav_link>

          <div class="mt-auto pt-6 px-2.5 flex items-center justify-between text-[12px] text-faint">
            <span>opencode serve · 1 server</span>
            <.link
              href={~p"/logout"}
              method="delete"
              id="logout-link"
              class="hover:text-fg transition"
            >
              Log out
            </.link>
          </div>
        </aside>

        <main class="flex-1 min-w-0 min-h-0 flex flex-col">
          {render_slot(@inner_block)}
        </main>
      </div>

      <.status_line
        :if={@prefs["status_line"]}
        prefs={@prefs}
        sidebar={@sidebar}
        active={@active}
      />
      <.which_key prefs={@prefs} globals={@globals} />
      <.shortcuts_help prefs={@prefs} user={@user} keybinds={@keybinds} />
      <.palette :if={@palette} palette={@palette} />
      <.flash_group flash={@flash} />
    </div>
    """
  end

  attr :prefs, :map, required: true
  attr :sidebar, :list, required: true
  attr :active, :any, default: nil

  # tmux-style status line: mode, numbered "windows", focus region, help hint.
  # The mode and focus labels follow <html data-kb / data-kb-focus> (set by keybinds.js).
  defp status_line(assigns) do
    ~H"""
    <footer
      id="status-line"
      class="h-6 flex-none flex items-center gap-3.5 px-2.5 bg-code border-t border-line font-mono text-[11px] text-faint whitespace-nowrap overflow-hidden"
    >
      <span id="kb-mode" class="kb-mode px-[7px] rounded-[3px] font-semibold">
        <span data-kb-mode="idle">
          <%= if @prefs["keymap"] == "tmux" do %>
            <.kbd k={@prefs["prefix"]} />
          <% else %>
            STD
          <% end %>
        </span>
        <span data-kb-mode="prefix">PREFIX</span>
        <span data-kb-mode="repeat">REPEAT</span>
        <span data-kb-mode="g">g …</span>
      </span>
      <span
        :for={{p, i} <- Enum.with_index(@sidebar)}
        id={"kb-win-#{p.id}"}
        data-kb-win={~p"/p/#{p.id}"}
        data-kb-active={@active == p.id}
        class={if(@active == p.id, do: "text-fg", else: "text-faint")}
      >
        {i + 1}:{p.name}{if @active == p.id, do: "*"}
      </span>
      <span class="flex-1"></span>
      <span>
        focus:
        <span data-kb-focus="sidebar">sidebar</span><span data-kb-focus="tabs">tabs</span><span data-kb-focus="main">main</span>
      </span>
      <span class="max-sm:hidden">
        <.kbd :for={k <- Beamcode.Keybinds.help_keys(@prefs)} k={k} class="mr-1" /> shortcuts
      </span>
    </footer>
    """
  end

  attr :prefs, :map, required: true
  attr :globals, :list, required: true

  # Shown after the prefix (or `g`) when no second key follows within the delay.
  defp which_key(assigns) do
    ~H"""
    <div
      id="kb-which"
      class="fixed left-1/2 bottom-11 -translate-x-1/2 z-30 w-[min(780px,calc(100vw-32px))] rounded-xl bg-panel shadow-[inset_0_0_0_1px_var(--color-line2),0_18px_50px_rgba(0,0,0,.5)] px-[18px] pt-3.5 pb-4"
      style="animation: pop-in .12s ease-out"
    >
      <div class="flex items-center gap-2.5 mb-3 text-[12px] text-muted">
        <span class="font-mono px-[7px] rounded bg-key text-keyfg font-semibold whitespace-nowrap">
          <span data-kb-mode="prefix"><.kbd k={@prefs["prefix"]} /></span>
          <span data-kb-mode="g">
            <%= if @prefs["keymap"] == "tmux" do %>
              <.kbd k={@prefs["prefix"]} /> g
            <% else %>
              g
            <% end %>
          </span>
        </span>
        <span>waiting for key · Esc to cancel</span>
      </div>
      <div
        data-kb-mode="prefix"
        class="grid grid-cols-[repeat(auto-fit,minmax(200px,1fr))] gap-x-6 gap-y-1.5"
      >
        <div :for={{title, items} <- Beamcode.Keybinds.which_key()} class="flex flex-col gap-1.5">
          <div class="text-[11px] tracking-[.06em] uppercase text-faint mb-0.5">{title}</div>
          <div :for={{key, label} <- items} class="flex items-center gap-2.5 text-[13px]">
            <span class="kb-key min-w-[34px] text-center text-[12px]">{key}</span>
            <span class="text-soft">{label}</span>
          </div>
        </div>
      </div>
      <div
        data-kb-mode="g"
        class="grid grid-cols-[repeat(auto-fit,minmax(200px,1fr))] gap-x-6 gap-y-1.5"
      >
        <div class="flex flex-col gap-1.5">
          <div class="text-[11px] tracking-[.06em] uppercase text-faint mb-0.5">Go to</div>
          <div :for={g <- @globals} class="flex items-center gap-2.5 text-[13px]">
            <span class="kb-key min-w-[34px] text-center text-[12px]">{g.key}</span>
            <span class="text-soft">{g.name}</span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :prefs, :map, required: true
  attr :user, :map, default: nil
  attr :keybinds, :map, required: true

  defp shortcuts_help(assigns) do
    ~H"""
    <div
      id="kb-help"
      data-kb-close-help
      class="fixed inset-0 z-40 items-center justify-center p-6 bg-black/50 backdrop-blur-[2px]"
    >
      <div
        id="kb-help-panel"
        class="w-[min(920px,100%)] max-h-full overflow-y-auto rounded-[14px] bg-panel shadow-[inset_0_0_0_1px_var(--color-line2),0_30px_80px_-30px_rgba(0,0,0,.8)] px-7 py-6"
        style="animation: pop-in .14s ease-out"
      >
        <div class="flex items-baseline justify-between mb-5">
          <span class="text-[16px] font-semibold">Keyboard shortcuts</span>
          <span class="text-[12px] text-muted">
            <%= if @prefs["keymap"] == "tmux" do %>
              Prefix <.kbd k={@prefs["prefix"]} />, then a key
            <% else %>
              Standard keymap
            <% end %>
            · <.link navigate={~p"/settings"} class="underline hover:text-fg">change</.link>
          </span>
        </div>
        <div class="grid grid-cols-[repeat(auto-fit,minmax(250px,1fr))] gap-x-8 gap-y-6">
          <div
            :for={{title, items} <- Beamcode.Keybinds.help(@prefs, @user, @keybinds)}
            class="flex flex-col gap-2"
          >
            <div class="text-[11px] tracking-[.06em] uppercase text-faint">{title}</div>
            <div
              :for={{keys, label} <- items}
              class="flex items-center justify-between gap-3 text-[13px]"
            >
              <span class="text-soft">{label}</span>
              <span class="flex gap-1 flex-none">
                <.kbd :for={k <- keys} k={k} class="kb-key" />
              </span>
            </div>
          </div>
        </div>
        <div class="mt-6 pt-4 border-t border-line flex flex-col gap-1.5 text-[12px] text-muted">
          <div :for={{keys, note} <- Beamcode.Keybinds.help_notes(@prefs)} class="text-pretty">
            <%= for {k, i} <- Enum.with_index(keys) do %>
              {if i > 0, do: ", "}<.kbd k={k} />
            <% end %>
            {note}
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :add, :string, required: true
  attr :id, :string, required: true
  attr :class, :string, default: nil

  defp side_heading(assigns) do
    ~H"""
    <div class={["flex items-center px-2.5 pb-2.5 text-[13px] text-muted", @class]}>
      <span class="flex-1">{@label}</span>
      <.link
        navigate={@add}
        id={@id}
        class="text-base leading-none w-5 h-5 flex items-center justify-center rounded hover:bg-raised hover:text-fg transition"
      >
        +
      </.link>
    </div>
    """
  end

  attr :project, :map, required: true
  attr :index, :integer, required: true
  attr :active, :boolean, default: false

  defp project_link(assigns) do
    ~H"""
    <.link
      navigate={~p"/p/#{@project.id}"}
      id={"side-project-#{@project.id}"}
      data-kb-nav
      data-kb-item
      aria-current={@active && "page"}
      class={[
        "h-[38px] flex-none flex items-center gap-2.5 px-2.5 rounded-lg transition",
        if(@active, do: "bg-hov", else: "hover:bg-panel")
      ]}
    >
      <span :if={@index < 9} class="kb-num">{@index + 1}</span>
      <.avatar name={@project.name} class={@index < 9 && "kb-letter"} />
      <span class="flex-1 text-[14px] truncate">{@project.name}</span>
      <span :if={@project.scope == "private"} class="text-faint" title="Only you">
        <.icon name="hero-lock-closed-micro" class="size-3" />
      </span>
      <span class="text-[11.5px] text-faint">
        {Beamcode.Schedules.summary(@project.id) || kind_label(@project.kind)}
      </span>
    </.link>
    """
  end

  defp kind_label("system"), do: "system"
  defp kind_label(kind), do: kind

  attr :to, :string, required: true
  attr :label, :string, required: true
  attr :key, :string, required: true, doc: "the `g` key that opens it"
  attr :active, :boolean, default: false
  attr :id, :string, required: true
  slot :inner_block

  defp nav_link(assigns) do
    ~H"""
    <.link
      navigate={@to}
      id={@id}
      data-kb-nav
      data-kb-gkey={@key}
      aria-current={@active && "page"}
      class={[
        "h-9 flex-none flex items-center gap-2.5 px-2.5 rounded-lg text-[14px] transition",
        if(@active, do: "bg-hov text-fg", else: "text-muted hover:text-fg hover:bg-panel")
      ]}
    >
      <span class="flex-1">{@label}</span>
      {render_slot(@inner_block)}
      <span class="kb-gkey">{@key}</span>
    </.link>
    """
  end

  @doc "Square initial for a project, with an optional running/waiting dot."
  attr :name, :string, required: true
  attr :active, :boolean, default: false
  attr :status, :atom, default: nil
  attr :class, :any, default: nil

  def avatar(assigns) do
    ~H"""
    <span class={[
      @class,
      "relative w-[22px] h-[22px] flex-none box-border rounded-md border text-[11px] leading-[20px] text-center font-semibold",
      if(@active,
        do: "bg-fg border-fg text-canvas",
        else: "bg-raised border-line3 text-fg"
      )
    ]}>
      {@name |> String.first() |> String.upcase()}
      <span
        :if={@status in [:running, :waiting]}
        class={[
          "absolute -top-1 -right-1 w-2 h-2 rounded-full shadow-[0_0_0_2px_var(--color-canvas)]",
          @status == :running && "bg-run pulse",
          @status == :waiting && "bg-wait"
        ]}
      ></span>
    </span>
    """
  end

  @doc "running / waiting for you badge"
  attr :status, :atom, required: true

  def status_badge(assigns) do
    ~H"""
    <span
      :if={@status == :running}
      class="h-5 flex-none flex items-center gap-1.5 px-[7px] rounded-md bg-runbg text-run text-[11.5px] whitespace-nowrap"
    >
      <span class="w-1.5 h-1.5 rounded-full bg-run pulse"></span> running
    </span>
    <span
      :if={@status == :waiting}
      class="h-5 flex-none flex items-center px-[7px] rounded-md bg-waitbg text-wait text-[11.5px] whitespace-nowrap"
    >
      waiting for you
    </span>
    """
  end

  attr :palette, :map, required: true

  defp palette(assigns) do
    ~H"""
    <div
      id="palette"
      class="fixed inset-0 z-40 flex items-start justify-center pt-[12vh] bg-black/50 backdrop-blur-[2px]"
      phx-window-keydown="palette_close"
      phx-key="Escape"
    >
      <div
        id="palette-panel"
        phx-click-away="palette_close"
        phx-hook=".Palette"
        class="w-[560px] max-w-[92vw] rounded-[14px] bg-panel shadow-[inset_0_0_0_1px_var(--color-line2),0_30px_80px_-30px_rgba(0,0,0,.8)] overflow-hidden"
        style="animation: pop-in .14s ease-out"
      >
        <form id="palette-form" phx-change="palette_filter" phx-submit="palette_close">
          <input
            id="palette-input"
            name="q"
            value={@palette.query}
            autocomplete="off"
            placeholder={
              if @palette[:mode] == "switch",
                do: "Switch to project, session or page…",
                else: "Search or run a command…"
            }
            phx-mounted={JS.focus()}
            phx-debounce="60"
            class="w-full h-12 px-4 bg-transparent outline-none text-[14.5px] placeholder:text-faint border-b border-line"
          />
        </form>
        <div id="palette-items" class="max-h-[50vh] overflow-y-auto p-1.5">
          <div :if={@palette.items == []} class="px-3 py-6 text-center text-[13px] text-faint">
            Nothing matches.
          </div>
          <%= for {item, i} <- Enum.with_index(@palette.items) do %>
            <.link
              :if={item[:to]}
              navigate={item.to}
              id={"palette-item-#{i}"}
              data-palette-item
              class="h-10 flex items-center gap-3 px-3 rounded-lg text-[14px] outline-none hover:bg-hov focus:bg-hov aria-selected:bg-hov"
            >
              <span class="w-16 flex-none text-[11.5px] text-faint">{item.sub}</span>
              <span class="flex-1 truncate">{item.label}</span>
              <.palette_keys keys={item[:keys]} />
            </.link>
            <button
              :if={item[:event] || item[:kb]}
              type="button"
              phx-click={
                if item[:kb],
                  do:
                    JS.dispatch("chatos:kb", detail: %{action: item.kb}) |> JS.push("palette_close"),
                  else: item.event
              }
              id={"palette-item-#{i}"}
              data-palette-item
              class="w-full h-10 flex items-center gap-3 px-3 rounded-lg text-[14px] text-left outline-none hover:bg-hov focus:bg-hov aria-selected:bg-hov"
            >
              <span class="w-16 flex-none text-[11.5px] text-faint">{item.sub}</span>
              <span class="flex-1 truncate">{item.label}</span>
              <.palette_keys keys={item[:keys]} />
            </button>
          <% end %>
        </div>
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".Palette">
        export default {
          mounted() {
            this.index = 0
            this.select()
            this.onKey = (e) => {
              const items = this.items()
              if (e.key === "ArrowDown" || (e.ctrlKey && e.key === "n")) { e.preventDefault(); this.index = Math.min(this.index + 1, items.length - 1); this.select() }
              else if (e.key === "ArrowUp" || (e.ctrlKey && e.key === "p")) { e.preventDefault(); this.index = Math.max(this.index - 1, 0); this.select() }
              else if (e.key === "Enter") { e.preventDefault(); items[this.index] && items[this.index].click() }
            }
            this.el.addEventListener("keydown", this.onKey)
          },
          updated() { this.index = 0; this.select() },
          items() { return Array.from(this.el.querySelectorAll("[data-palette-item]")) },
          select() {
            this.items().forEach((el, i) => el.setAttribute("aria-selected", i === this.index ? "true" : "false"))
            const el = this.items()[this.index]
            el && el.scrollIntoView({block: "nearest"})
          }
        }
      </script>
    </div>
    """
  end

  attr :keys, :list, default: nil

  defp palette_keys(assigns) do
    ~H"""
    <span :if={@keys} class="flex gap-1 font-mono text-[11px] text-muted">
      <.kbd :for={k <- @keys} k={k} />
    </span>
    """
  end

  @doc """
  The Peon wordmark with its "work work." tagline (design 4b).
  `sm` sits on one line at the top of the sidebar; `lg` stacks for the login page.
  """
  attr :size, :string, default: "sm", values: ~w(sm lg)

  def logo(assigns) do
    ~H"""
    <span
      id={"logo-" <> @size}
      class={[
        "flex select-none",
        if(@size == "lg", do: "flex-col items-start gap-1.5", else: "items-baseline gap-2")
      ]}
    >
      <span class={[
        "font-brand font-bold tracking-[-0.04em] leading-none text-fg",
        if(@size == "lg", do: "text-[44px]", else: "text-[24px]")
      ]}>
        peon
      </span>
      <span class={[
        "font-tagline text-key whitespace-nowrap",
        if(@size == "lg", do: "text-[13px]", else: "text-[11px]")
      ]}>
        work work.
      </span>
    </span>
    """
  end

  @doc "Page header used inside the main area."
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  slot :actions
  slot :inner_block

  def page_header(assigns) do
    ~H"""
    <div class="flex-none flex items-center gap-3 px-6 h-14 border-b border-line">
      <div class="min-w-0 flex flex-col">
        <span class="text-[14.5px] font-semibold truncate">{@title}</span>
        <span :if={@subtitle} class="text-[12px] text-muted truncate">{@subtitle}</span>
      </div>
      {render_slot(@inner_block)}
      <div class="ml-auto flex items-center gap-2">{render_slot(@actions)}</div>
    </div>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite" class="z-50">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
