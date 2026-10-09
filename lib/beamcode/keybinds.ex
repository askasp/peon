defmodule Beamcode.Keybinds do
  @moduledoc """
  Keyboard shortcuts.

  Navigation uses one of two keymaps (see `prefs/1`):

    * `tmux` (default) – press the prefix (`ctrl+b`), then a key: `1`–`9`
      sidebar item, `n`/`p` next/previous, `g i` Inbox, `?` all shortcuts…
    * `standard` – `alt+1`–`9`, `mod+[`/`mod+]` back/forward, `g i`…

  In-session shortcuts follow OpenCode's keybind names and syntax (`ctrl+g`,
  `shift+return`, `<leader>m`, alternatives separated by commas, `none` to
  disable); `<leader>` is the prefix key. Users override any of them in
  Settings; everything is stored as one map on the user.

  Key tokens for display (`mod+k`, `ctrl+b`, `alt+1`) are rendered by
  `BeamcodeWeb.CoreComponents.kbd/1`; `mod` is ⌘ on macOS and Ctrl elsewhere.
  """

  @defaults [
    {"session_interrupt", "escape", "Interrupt the running session"},
    {"session_compact", "<leader>k", "Compact the session"},
    {"model_list", "<leader>m", "Pick a model"},
    {"agent_list", "<leader>a", "Pick an agent"},
    {"agent_cycle", "tab", "Next agent (in the composer)"},
    {"agent_cycle_reverse", "shift+tab", "Previous agent (in the composer)"},
    {"messages_page_up", "pageup", "Scroll messages up a page"},
    {"messages_page_down", "pagedown", "Scroll messages down a page"},
    {"messages_first", "ctrl+g,home", "Jump to the first message"},
    {"messages_last", "ctrl+alt+g,end", "Jump to the last message"},
    {"input_submit", "return", "Send the message"},
    {"input_newline", "shift+return,alt+return,ctrl+j", "New line in the composer"},
    {"input_clear", "ctrl+c", "Clear the composer (when nothing is selected)"}
  ]

  @keymaps ~w(tmux standard)
  @prefixes ~w(ctrl+b ctrl+space ctrl+a)
  @pref_defaults %{
    "keymap" => "tmux",
    "prefix" => "ctrl+b",
    "which_key_delay" => 300,
    "status_line" => true,
    "keycast" => false
  }

  # Pages reachable with `g <key>`; admin-only ones are hidden from others.
  @globals [
    {"inbox", "Inbox", "i", "/inbox", false},
    {"schedules", "Schedules", "s", "/schedules", false},
    {"connectors", "Connectors", "c", "/connectors", true},
    {"models", "Models", "m", "/models", true},
    {"users", "Users", "u", "/users", true},
    {"settings", "Settings", ",", "/settings", false}
  ]

  def list, do: @defaults

  def defaults, do: Map.new(@defaults, fn {k, v, _} -> {k, v} end)

  def merged(%{keybinds: overrides}) when is_map(overrides),
    do: Map.merge(defaults(), Map.take(overrides, Map.keys(defaults())))

  def merged(_), do: defaults()

  @doc "Keeps only values that differ from the defaults."
  def overrides(params) do
    defaults = defaults()

    params
    |> Map.take(Map.keys(defaults))
    |> Map.new(fn {k, v} -> {k, v |> to_string() |> String.trim() |> String.downcase()} end)
    |> Enum.reject(fn {k, v} -> v == "" or v == defaults[k] end)
    |> Map.new()
  end

  def keymaps, do: @keymaps
  def prefixes, do: @prefixes
  def pref_defaults, do: @pref_defaults

  @doc "Keymap preferences: keymap, prefix, which_key_delay, status_line, keycast."
  def prefs(%{keybinds: stored}) when is_map(stored),
    do: Map.merge(@pref_defaults, pref_overrides(stored))

  def prefs(_), do: @pref_defaults

  @doc "Validates keymap preferences, keeping only values that differ from the defaults."
  def pref_overrides(params) do
    params
    |> Map.take(Map.keys(@pref_defaults))
    |> Enum.flat_map(fn {k, v} -> List.wrap(cast_pref(k, v)) end)
    |> Enum.reject(fn {k, v} -> v == @pref_defaults[k] end)
    |> Map.new()
  end

  defp cast_pref("keymap", v) when v in @keymaps, do: {"keymap", v}
  defp cast_pref("prefix", v) when v in @prefixes, do: {"prefix", v}
  defp cast_pref(k, v) when k in ~w(status_line keycast), do: {k, v in [true, "true"]}

  defp cast_pref("which_key_delay", v) when is_integer(v),
    do: {"which_key_delay", v |> max(0) |> min(1500)}

  defp cast_pref("which_key_delay", v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> cast_pref("which_key_delay", n)
      :error -> nil
    end
  end

  defp cast_pref(_, _), do: nil

  @doc "Human label: `<leader>n` → `ctrl+b n`."
  def label(binding, prefix) do
    binding
    |> String.split(",")
    |> List.first()
    |> to_string()
    |> String.replace("<leader>", prefix <> " ")
  end

  @doc "`g` destinations visible to `user`: `%{id, name, key, path}`."
  def globals(user) do
    for {id, name, key, path, admin_only} <- @globals, !admin_only or (user && user.admin) do
      %{id: id, name: name, key: key, path: path}
    end
  end

  @doc "Shortcut for sidebar item `i` (0-based), as key tokens."
  def item_keys(%{"keymap" => "tmux", "prefix" => p}, i), do: [p, "#{i + 1}"]
  def item_keys(_prefs, i), do: ["alt+#{i + 1}"]

  @doc "Shortcut for a `g` destination, as key tokens."
  def global_keys(%{"keymap" => "tmux", "prefix" => p}, %{id: "inbox"}), do: [p, "i"]
  def global_keys(%{"keymap" => "tmux", "prefix" => p}, g), do: [p, "g", g.key]
  def global_keys(_prefs, g), do: ["g", g.key]

  def new_session_keys(%{"keymap" => "tmux", "prefix" => p}), do: [p, "c"]
  def new_session_keys(_prefs), do: ["alt+n"]

  def help_keys(%{"keymap" => "tmux", "prefix" => p}), do: [p, "?"]
  def help_keys(_prefs), do: ["?"]

  @doc "Groups for the which-key popup shown after the prefix."
  def which_key do
    [
      {"Navigate",
       [
         {"1–9", "Sidebar item"},
         {"n p", "Next / previous ↻"},
         {"l", "Last location"},
         {"w", "Switch to…"},
         {"i", "Inbox"},
         {"g", "Go to…"}
       ]},
      {"Act", [{"c", "New session"}, {"r", "Run routine"}, {",", "Rename session"}]},
      {"View",
       [
         {"[ ]", "Previous / next tab ↻"},
         {"z", "Zoom"},
         {"o", "Next focus"},
         {"/", "Search"},
         {":", "Command"},
         {"?", "All shortcuts"}
       ]}
    ]
  end

  @doc """
  Sections for the shortcuts overlay: `{title, [{keys, label}]}`, where
  `keys` is a list of key tokens pressed in sequence.
  """
  def help(prefs, user, binds) do
    globals = globals(user)
    session = session_help(binds, prefs["prefix"])

    case prefs["keymap"] do
      "tmux" ->
        p = prefs["prefix"]

        [
          {"Navigate",
           [
             {[p, "1–9"], "Open sidebar item"},
             {[p, "n"], "Next item ↻"},
             {[p, "p"], "Previous item ↻"},
             {[p, "l"], "Last location"},
             {[p, "w"], "Switch to…"},
             {[p, "i"], "Inbox"}
           ]},
          {"Go to (#{p} g …)", Enum.map(globals, &{[p, "g", &1.key], &1.name})},
          {"Act",
           [
             {[p, "c"], "New session"},
             {[p, "r"], "Run routine"},
             {[p, ","], "Rename session"},
             {["mod+enter"], "Run / send"}
           ]},
          {"View",
           [
             {[p, "["], "Previous tab ↻"},
             {[p, "]"], "Next tab ↻"},
             {[p, "z"], "Zoom (hide sidebar)"},
             {[p, "o"], "Next focus region"},
             {[p, "←↑→↓"], "Focus region"},
             {[p, "/"], "Search"},
             {[p, ":"], "Command palette"}
           ]},
          {"Anywhere, no prefix",
           [
             {["mod+k"], "Command palette"},
             {["mod+\\"], "Toggle sidebar"},
             {["/"], "Search"},
             {["j", "k"], "Move"},
             {["enter"], "Open"},
             {["escape"], "Cancel / leave field"},
             {["?"], "Shortcuts"}
           ]},
          {"In a session", session}
        ]

      _ ->
        [
          {"Navigate",
           [
             {["mod+k"], "Command palette"},
             {["mod+p"], "Quick switch"},
             {["alt+1–9"], "Open sidebar item"},
             {["alt+down"], "Next item"},
             {["alt+up"], "Previous item"},
             {["mod+["], "Back"},
             {["mod+]"], "Forward"}
           ]},
          {"Go to (g …)", Enum.map(globals, &{["g", &1.key], &1.name})},
          {"Act", [{["alt+n"], "New session"}, {["mod+enter"], "Run / send"}]},
          {"View",
           [
             {["alt+["], "Previous tab"},
             {["alt+]"], "Next tab"},
             {["mod+\\"], "Toggle sidebar"},
             {["/"], "Search"},
             {["j", "k"], "Move"},
             {["enter"], "Open"},
             {["?"], "Shortcuts"},
             {["escape"], "Cancel"}
           ]},
          {"In a session", session}
        ]
    end
  end

  def help_notes(%{"keymap" => "tmux", "prefix" => p}) do
    [
      {[p], "works inside text fields. Press it twice to cancel."},
      {[], "↻ repeats: for 600 ms after, press the same key again without the prefix."},
      {["mod+t", "mod+w", "mod+n", "mod+1–9", "ctrl+tab"],
       "stay with the browser and are never bound."}
    ]
  end

  def help_notes(_prefs) do
    [
      {[], "Single-key shortcuts (g, j, k, /, ?) are off while typing in a field."},
      {["mod+t", "mod+w", "mod+n", "mod+1–9", "ctrl+tab"],
       "stay with the browser and are never bound."}
    ]
  end

  @session_help ~w(session_interrupt session_compact model_list agent_list agent_cycle messages_first messages_last)

  defp session_help(binds, prefix) do
    for {action, _default, desc} <- @defaults,
        action in @session_help,
        binding = binds[action],
        binding not in [nil, "", "none"] do
      first = binding |> String.split(",") |> List.first() |> String.trim()

      keys =
        case first do
          "<leader>" <> key -> [prefix, key]
          key -> [key]
        end

      {keys, desc}
    end
  end
end
