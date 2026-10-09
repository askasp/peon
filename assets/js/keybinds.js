// Keyboard shortcuts (the "ChatOS Hotkeys" design, now Peon). #app-shell carries the config:
//
//   data-keymap       "tmux": press the prefix, then a key. "standard": alt+1–9, mod+[ ], g …
//   data-prefix       "ctrl+b" | "ctrl+space" | "ctrl+a"
//   data-which-delay  ms before the which-key popup shows after the prefix
//   data-keycast      "true" shows pressed keys in the corner
//   data-keybinds     in-session bindings, OpenCode syntax ("ctrl+g", "<leader>m",
//                     alternatives separated by commas, "none"); <leader> is the prefix
//
// State goes on <html> (data-kb, data-kb-which, data-kb-help, data-kb-focus) and in
// <style id="kb-dyn"> so LiveView patches never undo it; app.css does the showing.

const isMac = /Mac|iPhone|iPad/.test(navigator.platform)
const root = document.documentElement
if (isMac) root.setAttribute("data-mac", "")

const KEY_NAMES = {
  return: "enter", enter: "enter", esc: "escape", escape: "escape", tab: "tab",
  pageup: "pageup", pagedown: "pagedown", home: "home", end: "end", space: " ",
  up: "arrowup", down: "arrowdown", left: "arrowleft", right: "arrowright",
  backspace: "backspace", delete: "delete",
}

const PREFIXES = {
  "ctrl+b": {label: isMac ? "⌃B" : "Ctrl+B", code: "KeyB"},
  "ctrl+space": {label: isMac ? "⌃Space" : "Ctrl+Space", code: "Space"},
  "ctrl+a": {label: isMac ? "⌃A" : "Ctrl+A", code: "KeyA"},
}

// After prefix n / p / [ / ], these repeat without the prefix for 600 ms.
const REPEATABLE = ["n", "p", "[", "]"]
const RING = "inset 0 0 0 1px var(--color-line3)"

// Actions handled in the composer itself, never globally.
const COMPOSER_ONLY = new Set(["input_submit", "input_newline", "input_clear", "agent_cycle", "agent_cycle_reverse"])
const SCROLL = {messages_page_up: "up", messages_page_down: "down", messages_first: "first", messages_last: "last"}
// Opened right here, inside the keypress, so the menu can take focus.
const PICKERS = {model_list: "model-picker", agent_list: "agent-picker"}

const state = {
  prefix: false, chord: null, repeat: false,
  focus: "main", cursor: false, sideIdx: 0, rowIdx: 0,
  cur: location.pathname, prev: null, keys: [],
}
const timers = {}
let hook = null

try { state.prev = sessionStorage.getItem("chatos:prev") } catch (_) {}

// ── Binding syntax ──────────────────────────────────────────────────────────

function parseOne(str) {
  const parts = str.trim().toLowerCase().split("+")
  const combo = {ctrl: false, alt: false, shift: false, meta: false, leader: false, key: null}
  for (let p of parts) {
    if (p.startsWith("<leader>")) { combo.leader = true; p = p.slice(8) }
    if (p === "ctrl" || p === "control") combo.ctrl = true
    else if (p === "alt" || p === "option") combo.alt = true
    else if (p === "shift") combo.shift = true
    else if (p === "meta" || p === "cmd" || p === "super") combo.meta = true
    else if (p) combo.key = KEY_NAMES[p] || p
  }
  return combo
}

export function parse(binding) {
  if (!binding || binding === "none") return []
  return binding.split(",").map(parseOne).filter(c => c.key)
}

function eventKey(e) {
  const k = (e.key || "").toLowerCase()
  return k === "esc" ? "escape" : k
}

function comboMatches(e, c) {
  return eventKey(e) === c.key && e.ctrlKey === c.ctrl && e.altKey === c.alt &&
    e.shiftKey === c.shift && e.metaKey === c.meta
}

// True when `e` matches one of the binding's alternatives. <leader>
// alternatives only match while the prefix is armed.
export function matches(e, binding) {
  return parse(binding).some(c => c.leader === state.prefix && comboMatches(e, c))
}

export function leaderActive() { return state.prefix }

// ── Config and DOM ──────────────────────────────────────────────────────────

const shell = () => document.getElementById("app-shell")
const keymap = () => shell()?.dataset.keymap || "tmux"
const prefix = () => PREFIXES[shell()?.dataset.prefix] || PREFIXES["ctrl+b"]
const binds = () => { try { return JSON.parse(shell()?.dataset.keybinds || "{}") } catch (_) { return {} } }
const $$ = (sel) => Array.from(document.querySelectorAll(sel))

const items = () => $$("#sidebar [data-kb-item]")
const navs = () => $$("#sidebar [data-kb-nav]")
const tabs = () => $$("#project-tabs a")
const rows = () => $$("main [data-kb-row]")
const inSession = () => !!document.getElementById("messages-scroll")
const sidebarHidden = () => shell()?.dataset.sidebar === "hidden"
const current = (list) => list.findIndex(el => el.getAttribute("aria-current") === "page")

const isPrefix = (e) => e.ctrlKey && !e.metaKey && !e.altKey && e.code === prefix().code
const mod = (e) => isMac ? e.metaKey : e.ctrlKey
const plain = (e) => !e.ctrlKey && !e.metaKey && !e.altKey

function editable(el) {
  return el && (el.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(el.tagName))
}

const CAST_NAMES = {" ": "Space", ArrowUp: "↑", ArrowDown: "↓", ArrowLeft: "←", ArrowRight: "→", Enter: "↵", Escape: "Esc", Backspace: "⌫", Tab: "⇥"}

function keyLabel(e) {
  let m = ""
  if (e.ctrlKey) m += isMac ? "⌃" : "Ctrl+"
  if (e.altKey) m += isMac ? "⌥" : "Alt+"
  if (e.metaKey) m += isMac ? "⌘" : "Super+"
  let k = CAST_NAMES[e.key]
  if (!k) {
    if (m && e.code.startsWith("Key")) k = e.code.slice(3)
    else if (m && e.code.startsWith("Digit")) k = e.code.slice(5)
    else if (m && e.code === "Backslash") k = "\\"
    else if (m && e.code === "BracketLeft") k = "["
    else if (m && e.code === "BracketRight") k = "]"
    else k = e.key
  }
  return m + k
}

// ── Feedback: mode, which-key, toast, keycast, cursors ──────────────────────

function setMode() {
  const mode = state.chord === "g" ? "g" : state.repeat ? "repeat" : state.prefix ? "prefix" : null
  if (mode) root.setAttribute("data-kb", mode); else root.removeAttribute("data-kb")
}

function arm(chord = null, repeat = false) {
  clearTimeout(timers.which); clearTimeout(timers.reset)
  const keepOpen = !!chord && root.hasAttribute("data-kb-which")
  Object.assign(state, {prefix: true, chord, repeat})
  root.toggleAttribute("data-kb-which", keepOpen)
  setMode()
  if (repeat) { timers.reset = setTimeout(disarm, 600); return }
  if (keymap() === "standard") timers.reset = setTimeout(disarm, 1500)
  if (!keepOpen) {
    const delay = Number(shell()?.dataset.whichDelay ?? 300)
    timers.which = setTimeout(() => { if (state.prefix) root.setAttribute("data-kb-which", "") }, delay)
  }
}

function disarm() {
  clearTimeout(timers.which); clearTimeout(timers.reset)
  Object.assign(state, {prefix: false, chord: null, repeat: false})
  root.removeAttribute("data-kb-which")
  setMode()
}

function bodyEl(id) {
  let el = document.getElementById(id)
  if (!el) { el = document.createElement("div"); el.id = id; document.body.append(el) }
  return el
}

function toast(msg) {
  document.getElementById("kb-toast")?.remove()
  bodyEl("kb-toast").textContent = msg
  clearTimeout(timers.toast)
  timers.toast = setTimeout(() => document.getElementById("kb-toast")?.remove(), 1800)
}

function cast(label) {
  state.keys = [...state.keys, label].slice(-6)
  bodyEl("kb-keycast").replaceChildren(...state.keys.map(k => {
    const span = document.createElement("span")
    span.textContent = k
    return span
  }))
  clearTimeout(timers.cast)
  timers.cast = setTimeout(() => { state.keys = []; document.getElementById("kb-keycast")?.remove() }, 1600)
}

// Focus ring and cursors only appear once the keyboard is used to move.
function paint() {
  let css = ""
  if (state.cursor) {
    css += `${{sidebar: "#sidebar", tabs: "#project-tabs", main: "main"}[state.focus]}{box-shadow:${RING}}`
    const el = state.focus === "sidebar" ? navs()[state.sideIdx] : state.focus === "main" ? rows()[state.rowIdx] : null
    if (el?.id) {
      css += state.focus === "sidebar"
        ? `#${CSS.escape(el.id)}{box-shadow:${RING}}`
        : `#${CSS.escape(el.id)}{background:var(--color-hov)}`
      el.scrollIntoView({block: "nearest"})
    }
  }
  if (state.prev) css += `[data-kb-win=${JSON.stringify(state.prev)}]:not([data-kb-active])::after{content:"-"}`
  let style = document.getElementById("kb-dyn")
  if (!style) { style = document.createElement("style"); style.id = "kb-dyn"; document.head.append(style) }
  style.textContent = css
  root.setAttribute("data-kb-focus", state.focus)
}

function setHelp(on) { disarm(); root.toggleAttribute("data-kb-help", on) }

// ── Actions ─────────────────────────────────────────────────────────────────

function push(event, payload) { hook?.pushEvent(event, payload) }

function navigate(href) { hook?.js().navigate(href) }

function openIdx(i) {
  const el = items()[i]
  if (el) el.click(); else toast(`No item ${i + 1}`)
}

function openGlobal(key) {
  const el = document.querySelector(`#sidebar [data-kb-gkey="${CSS.escape(key)}"]`)
  if (el) el.click(); else toast(`g ${key}: no destination`)
}

function step(d) {
  const list = items()
  if (list.length === 0) return toast("No projects yet")
  let i = current(list)
  if (i < 0) i = d > 0 ? -1 : 0
  list[(i + d + list.length) % list.length].click()
}

function tabStep(d) {
  const list = tabs()
  if (list.length === 0) return
  list[(Math.max(0, current(list)) + d + list.length) % list.length].click()
}

function last() {
  if (state.prev) navigate(state.prev); else toast("No previous location")
}

function focusSearch() {
  const el = document.querySelector("main [data-kb-search]")
  if (!el) return toast("No search here")
  state.focus = "main"
  paint()
  el.focus()
  el.select?.()
}

function regions() {
  return [!sidebarHidden() && "sidebar", tabs().length > 0 && "tabs", "main"].filter(Boolean)
}

function setFocus(f) {
  if (!regions().includes(f)) return
  state.focus = f
  state.cursor = true
  if (f === "sidebar") state.sideIdx = Math.max(0, current(navs()))
  paint()
}

function cycleFocus() {
  const r = regions()
  setFocus(r[(r.indexOf(state.focus) + 1) % r.length])
}

function focusDir(k) {
  setFocus({ArrowLeft: "sidebar", ArrowRight: "main", ArrowUp: "tabs", ArrowDown: "main"}[k])
}

function zoom() {
  const el = shell()
  if (!el) return
  const hidden = sidebarHidden()
  if (hidden) delete el.dataset.sidebar; else el.dataset.sidebar = "hidden"
  try { localStorage.setItem("chatos:sidebar", hidden ? "shown" : "hidden") } catch (_) {}
  if (!hidden && state.focus === "sidebar") state.focus = "main"
  paint()
}

// Returns false when there is nothing to move over, so the key keeps its default.
function move(d) {
  if (state.focus === "tabs") { tabStep(d); return true }
  const list = state.focus === "sidebar" ? navs() : rows()
  if (list.length === 0) return false
  const key = state.focus === "sidebar" ? "sideIdx" : "rowIdx"
  // The first press only shows the cursor.
  if (state.cursor) state[key] = Math.min(list.length - 1, Math.max(0, state[key] + d))
  else state[key] = Math.min(state[key], list.length - 1)
  state.cursor = true
  paint()
  return true
}

function activate() {
  const el = state.focus === "sidebar" ? navs()[state.sideIdx] : state.focus === "main" ? rows()[state.rowIdx] : null
  if (!el) return false
  el.click()
  state.focus = "main"
  return true
}

function newSession() {
  const button = document.getElementById("new-session")
  if (button) button.click(); else push("keybind", {action: "session_new"})
}

function run() {
  const button = document.getElementById("run-button")
  if (button) button.click(); else toast("Nothing to run here")
}

function rename() {
  const input = document.getElementById("session-title")
  if (!input) return toast("Nothing to rename here")
  input.focus()
  input.select()
}

function openPalette(mode) { disarm(); push("palette_open", {mode}) }

function runAction(action) {
  if (SCROLL[action]) window.dispatchEvent(new CustomEvent("chatos:scroll", {detail: SCROLL[action]}))
  else if (PICKERS[action]) window.dispatchEvent(new CustomEvent("chatos:picker", {detail: {id: PICKERS[action]}}))
  else push("keybind", {action})
}

// In-session bindings from data-keybinds; <leader> ones only while the prefix is armed.
function sessionAction(e, leader, typing) {
  if (!inSession()) return null
  for (const [action, binding] of Object.entries(binds())) {
    if (COMPOSER_ONLY.has(action)) continue
    const combos = parse(binding).filter(c => c.leader === leader && comboMatches(e, c))
    if (combos.length === 0) continue
    // Plain keys (home, end, pageup…) belong to the text field while typing.
    const plainKey = combos.every(c => !c.ctrl && !c.alt && !c.meta)
    if (!leader && typing && plainKey && action !== "session_interrupt") continue
    return action
  }
  return null
}

// Palette actions ("Toggle sidebar", "Keyboard shortcuts", "Run …").
window.addEventListener("chatos:kb", (e) => {
  const action = e.detail?.action
  if (action === "zoom") zoom()
  else if (action === "help") setHelp(true)
  else if (action === "run") run()
})

// ── Key handling ────────────────────────────────────────────────────────────

function prefixKey(e) {
  const k = e.key
  if (k === "Escape") return disarm()
  if (state.chord === "g") { disarm(); return openGlobal(k) }
  if (keymap() !== "tmux") return disarm()
  const once = (fn) => { disarm(); fn() }
  const rep = (fn) => { fn(); arm(null, true) }

  const action = sessionAction(e, true, false)
  if (action) return once(() => runAction(action))
  if (/^[1-9]$/.test(k)) return once(() => openIdx(Number(k) - 1))

  switch (k) {
    case "n": return rep(() => step(1))
    case "p": return rep(() => step(-1))
    case "]": return rep(() => tabStep(1))
    case "[": return rep(() => tabStep(-1))
    case "l": return once(last)
    case "w": return openPalette("switch")
    case ":": return openPalette("all")
    case "i": return once(() => openGlobal("i"))
    case "g": return arm("g")
    case "c": return once(newSession)
    case "r": return once(run)
    case ",": return once(rename)
    case "z": return once(zoom)
    case "o": return once(cycleFocus)
    case "ArrowLeft": case "ArrowRight": case "ArrowUp": case "ArrowDown": return once(() => focusDir(k))
    case "/": return once(focusSearch)
    case "?": return once(() => setHelp(true))
    default: return once(() => toast(`No binding: ${prefix().label} ${keyLabel(e)}`))
  }
}

function onKey(e) {
  if (e.defaultPrevented || e.isComposing || !shell()) return
  if (["Shift", "Control", "Alt", "Meta", "CapsLock", "AltGraph"].includes(e.key)) return
  const t = e.target, typing = editable(t), km = keymap()
  const stop = () => e.preventDefault()

  if (shell().dataset.keycast === "true" && !(typing && plain(e) && e.key.length === 1)) cast(keyLabel(e))

  // The palette handles its own keys.
  if (document.getElementById("palette")) {
    if (mod(e) && e.code === "KeyK") { stop(); push("palette_close", {}) }
    return
  }
  if (root.hasAttribute("data-kb-help")) {
    if (e.key === "Escape" || e.key === "?") { stop(); setHelp(false) }
    return
  }

  if (state.prefix) {
    if (state.repeat && !(plain(e) && REPEATABLE.includes(e.key))) disarm()
    else if (km === "tmux" && isPrefix(e)) { stop(); disarm(); return }
    else { stop(); prefixKey(e); return }
  }
  if (km === "tmux" && isPrefix(e)) { stop(); arm(); return }
  if (mod(e) && e.code === "KeyK") { stop(); openPalette("all"); return }
  if (mod(e) && e.code === "Backslash") { stop(); zoom(); return }
  if (mod(e) && e.key === "Enter") { stop(); run(); return }

  if (km === "standard") {
    const alt = e.altKey && !e.ctrlKey && !e.metaKey
    if (mod(e) && e.code === "KeyP" && !e.shiftKey) { stop(); openPalette("switch"); return }
    if (alt && /^Digit[1-9]$/.test(e.code)) { stop(); openIdx(Number(e.code.slice(5)) - 1); return }
    if (alt && e.key === "ArrowDown") { stop(); step(1); return }
    if (alt && e.key === "ArrowUp") { stop(); step(-1); return }
    if (mod(e) && e.code === "BracketLeft") { stop(); history.back(); return }
    if (mod(e) && e.code === "BracketRight") { stop(); history.forward(); return }
    if (alt && e.code === "BracketLeft") { stop(); tabStep(-1); return }
    if (alt && e.code === "BracketRight") { stop(); tabStep(1); return }
    if (alt && e.code === "KeyN") { stop(); newSession(); return }
    if (!typing && plain(e) && e.key === "g") { stop(); arm("g"); return }
  }

  const action = sessionAction(e, false, typing)
  if (action) { stop(); runAction(action); return }

  if (e.key === "Escape") {
    if (typing) t.blur()
    else if (state.cursor) { state.cursor = false; paint() }
    return
  }
  if (typing || !plain(e)) return

  const k = e.key
  if (k === "/") { stop(); focusSearch() }
  else if (k === "?") { stop(); setHelp(true) }
  else if (k === "j" || k === "ArrowDown") { if (move(1)) stop() }
  else if (k === "k" || k === "ArrowUp") { if (move(-1)) stop() }
  else if (state.focus === "tabs" && (k === "h" || k === "ArrowLeft")) { stop(); tabStep(-1) }
  else if (state.focus === "tabs" && (k === "l" || k === "ArrowRight")) { stop(); tabStep(1) }
  else if (k === "Enter" && state.cursor && !t.closest?.("a, button")) { if (activate()) stop() }
}

window.addEventListener("keydown", onKey)

// Close the overlay by clicking its backdrop.
document.addEventListener("click", (e) => {
  if (e.target.id === "kb-help") setHelp(false)
})

// Track the previous location for prefix l, and reset cursors on navigation.
window.addEventListener("phx:page-loading-start", () => root.removeAttribute("data-kb-help"))
window.addEventListener("phx:page-loading-stop", () => {
  if (location.pathname === state.cur) return
  state.prev = state.cur
  state.cur = location.pathname
  try { sessionStorage.setItem("chatos:prev", state.prev) } catch (_) {}
  Object.assign(state, {focus: "main", cursor: false, rowIdx: 0})
  paint()
})

function restoreSidebar(el) {
  try {
    if (localStorage.getItem("chatos:sidebar") === "hidden") el.dataset.sidebar = "hidden"
  } catch (_) {}
}

export const KeybindsHook = {
  mounted() {
    hook = this
    restoreSidebar(this.el)
    paint()
  },
  // LiveView re-renders data-sidebar away; restore it.
  updated() { restoreSidebar(this.el) },
  destroyed() { if (hook === this) hook = null },
}

window.ChatOSKeys = {matches, parse, leaderActive, isMac}
