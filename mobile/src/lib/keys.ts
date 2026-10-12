// Keyboard shortcuts on the web, ported from assets/js/keybinds.js (the
// "ChatOS Hotkeys" design). The user's keymap comes from the server (Keys):
//
//   tmux      press the prefix (ctrl+b), then a key: 1–9 sidebar item, n/p next/previous,
//             [ ] running tabs, l last place, w switch, i inbox, g … go to, c new session,
//             r run routine, , rename, z zoom, / and : palette, ? all shortcuts
//   standard  alt+1–9, alt+↑/↓, mod+[ ] back/forward, alt+[ ] tabs, alt+n, g …, ?
//
// In-session shortcuts (OpenCode syntax, "<leader>" = the prefix) go to the session
// screen as commands ("session:interrupt", …). mod+K opens the palette anywhere.

import { useEffect, useSyncExternalStore } from "react";
import { Platform } from "react-native";
import { router } from "expo-router";
import { emit } from "./commands";
import { folderHref, sortFolders } from "./folders";
import { getCurrent } from "./current";
import { closePalette, openPalette } from "./palette";
import { ask, getState } from "./peon";
import { isListening, isSpeaking, stopListening, stopSpeaking } from "./voice";
import type { Keys, Project } from "./types";

// ── Overlay state (which-key, help, toast, zoom) ──────────────────────────

type KbState = {
  mode: "prefix" | "g" | "repeat" | null;
  which: boolean;
  help: boolean;
  toast: string | null;
  zoom: boolean;
  /** Keycast: the last keys pressed, shown in a corner when turned on. */
  cast: string[];
  /** Letters on the page's rows, tabs and text boxes while the prefix is armed. */
  hints: Hint[];
  /** The first letter of a two-letter hint, once typed. */
  typed: string;
};
export type Hint = { label: string; x: number; y: number };
let kb: KbState = {
  mode: null,
  which: false,
  help: false,
  toast: null,
  zoom: false,
  cast: [],
  hints: [],
  typed: "",
};
const listeners = new Set<() => void>();
const setKb = (patch: Partial<KbState>) => {
  kb = { ...kb, ...patch };
  listeners.forEach((l) => l());
};

export function useKb(): KbState {
  return useSyncExternalStore(
    (l) => {
      listeners.add(l);
      return () => listeners.delete(l);
    },
    () => kb,
  );
}

export const setHelp = (help: boolean) => setKb({ help });
export const toggleZoom = () => setKb({ zoom: !kb.zoom });

let toastTimer: ReturnType<typeof setTimeout> | undefined;
export function toast(text: string) {
  clearTimeout(toastTimer);
  setKb({ toast: text });
  toastTimer = setTimeout(() => setKb({ toast: null }), 1800);
}

// ── Binding syntax ────────────────────────────────────────────────────────

const KEY_NAMES: Record<string, string> = {
  return: "enter",
  enter: "enter",
  esc: "escape",
  escape: "escape",
  tab: "tab",
  pageup: "pageup",
  pagedown: "pagedown",
  home: "home",
  end: "end",
  space: " ",
  up: "arrowup",
  down: "arrowdown",
  left: "arrowleft",
  right: "arrowright",
  backspace: "backspace",
  delete: "delete",
};

type Combo = {
  ctrl: boolean;
  alt: boolean;
  shift: boolean;
  meta: boolean;
  leader: boolean;
  key: string | null;
};

function parseOne(str: string): Combo {
  const combo: Combo = { ctrl: false, alt: false, shift: false, meta: false, leader: false, key: null };
  for (let p of str.trim().toLowerCase().split("+")) {
    if (p.startsWith("<leader>")) {
      combo.leader = true;
      p = p.slice(8);
    }
    if (p === "ctrl" || p === "control") combo.ctrl = true;
    else if (p === "alt" || p === "option") combo.alt = true;
    else if (p === "shift") combo.shift = true;
    else if (p === "meta" || p === "cmd" || p === "super") combo.meta = true;
    else if (p) combo.key = KEY_NAMES[p] ?? p;
  }
  return combo;
}

const parse = (binding: string | undefined) =>
  !binding || binding === "none"
    ? []
    : binding
        .split(",")
        .map(parseOne)
        .filter((c) => c.key);

const eventKey = (e: KeyboardEvent) => {
  const k = (e.key || "").toLowerCase();
  return k === "esc" ? "escape" : k;
};

const comboMatches = (e: KeyboardEvent, c: Combo) =>
  eventKey(e) === c.key &&
  e.ctrlKey === c.ctrl &&
  e.altKey === c.alt &&
  e.shiftKey === c.shift &&
  e.metaKey === c.meta;

/** True when a key event matches one of a binding's non-<leader> alternatives (composer keys). */
export function bindingMatches(
  e: { key: string; ctrlKey?: boolean; altKey?: boolean; shiftKey?: boolean; metaKey?: boolean },
  binding: string | undefined,
): boolean {
  return parse(binding).some(
    (c) =>
      !c.leader &&
      eventKey(e as KeyboardEvent) === c.key &&
      !!e.ctrlKey === c.ctrl &&
      !!e.altKey === c.alt &&
      !!e.shiftKey === c.shift &&
      !!e.metaKey === c.meta,
  );
}

// Actions the composer handles itself (Enter, Shift+Enter…), never globally.
const COMPOSER_ONLY = new Set([
  "input_submit",
  "input_newline",
  "input_clear",
  "agent_cycle",
  "agent_cycle_reverse",
]);
const SESSION_COMMANDS: Record<string, string> = {
  session_interrupt: "session:interrupt",
  session_compact: "session:compact",
  model_list: "session:model",
  agent_list: "session:agent",
  messages_page_up: "session:page-up",
  messages_page_down: "session:page-down",
  messages_first: "session:first",
  messages_last: "session:last",
};

function sessionAction(keys: Keys, e: KeyboardEvent, leader: boolean, typing: boolean): string | null {
  for (const [action, binding] of Object.entries(keys.binds)) {
    if (COMPOSER_ONLY.has(action) || !SESSION_COMMANDS[action]) continue;
    const combos = parse(binding).filter((c) => c.leader === leader && comboMatches(e, c));
    if (combos.length === 0) continue;
    // Plain keys (home, end, pageup…) belong to the text field while typing.
    const plainKey = combos.every((c) => !c.ctrl && !c.alt && !c.meta);
    if (!leader && typing && plainKey && action !== "session_interrupt") continue;
    return action;
  }
  return null;
}

// ── Places ────────────────────────────────────────────────────────────────

export const isMac =
  Platform.OS === "web" && typeof navigator !== "undefined" && /Mac|iPhone|iPad/.test(navigator.platform);
const mod = (e: KeyboardEvent) => (isMac ? e.metaKey : e.ctrlKey);
const plain = (e: KeyboardEvent) => !e.ctrlKey && !e.metaKey && !e.altKey;
const PREFIX_CODES: Record<string, string> = { "ctrl+b": "KeyB", "ctrl+space": "Space", "ctrl+a": "KeyA" };

export const prefixLabel = (p: string) =>
  ({
    "ctrl+b": isMac ? "⌃B" : "Ctrl+B",
    "ctrl+space": isMac ? "⌃Space" : "Ctrl+Space",
    "ctrl+a": isMac ? "⌃A" : "Ctrl+A",
  })[p] ?? p;

/** Sidebar order: Home, then every other Folder (system last), as the sidebar lists them. */
export function sidebarItems(projects: Project[]): { project: Project; href: string }[] {
  const { home, folders } = sortFolders(projects);
  return [...(home ? [home] : []), ...folders].map((p) => ({ project: p, href: folderHref(p) }));
}

// Our paths for the server's `g` destinations (LiveView paths).
export const appPath = (path: string) => (path === "/inbox" ? "/" : path);

let path = "/";
let lastPath: string | null = null;

/** The shell reports route changes, for "last place" and next/previous. */
export function trackPath(next: string) {
  if (next !== path) {
    lastPath = path;
    path = next;
    nav.cursor = false;
    nav.idx = { side: 0, tabs: 0, main: 0 };
    paint();
  }
}

// ── Cursor and focus regions ──────────────────────────────────────────────
// Sidebar items, tabs and rows in the main area carry data-kb (see kbProps).
// j/k (or ↑↓) move a cursor in the focused region, Enter opens; h/l (←→) on
// tabs; o or the prefix + arrows switch regions.

type Region = "side" | "tabs" | "main";
const REGIONS: Region[] = ["side", "tabs", "main"];
const SELECTOR: Record<Region, string> = {
  side: '[data-kb="item"]',
  tabs: '[data-kb="tab"]',
  main: '[data-kb="row"]',
};
const nav: { focus: Region; cursor: boolean; idx: Record<Region, number> } = {
  focus: "main",
  cursor: false,
  idx: { side: 0, tabs: 0, main: 0 },
};

const els = (r: Region): HTMLElement[] =>
  typeof document === "undefined"
    ? []
    : Array.from(document.querySelectorAll<HTMLElement>(SELECTOR[r])).filter(
        (el) => el.offsetParent !== null,
      );

const currentIn = (list: HTMLElement[]) =>
  Math.max(
    0,
    list.findIndex((el) => el.dataset.kbCurrent === "1"),
  );

function paint() {
  if (typeof document === "undefined") return;
  document.querySelectorAll<HTMLElement>("[data-kb-cursor]").forEach((el) => {
    el.removeAttribute("data-kb-cursor");
    el.style.boxShadow = "";
  });
  if (!nav.cursor) return;
  const el = els(nav.focus)[nav.idx[nav.focus]];
  if (!el) return;
  el.setAttribute("data-kb-cursor", "");
  el.style.boxShadow = "inset 0 0 0 1.5px #8bbd50";
  el.scrollIntoView({ block: "nearest" });
}

/** Moves the cursor in the focused region; false when the region has nothing. */
function move(dir: number): boolean {
  const list = els(nav.focus);
  if (!list.length) return false;
  if (!nav.cursor) {
    nav.cursor = true;
    nav.idx[nav.focus] = nav.focus === "main" ? 0 : currentIn(list);
    if (nav.focus !== "main")
      nav.idx[nav.focus] = Math.min(list.length - 1, Math.max(0, nav.idx[nav.focus] + dir));
  } else {
    nav.idx[nav.focus] = Math.min(list.length - 1, Math.max(0, nav.idx[nav.focus] + dir));
  }
  paint();
  return true;
}

function activate(): boolean {
  const el = els(nav.focus)[nav.idx[nav.focus]];
  if (!nav.cursor || !el) return false;
  el.click();
  return true;
}

function focusRegion(r: Region) {
  if (!els(r).length) return toast(`Nothing to focus in the ${r === "side" ? "sidebar" : r}`);
  nav.focus = r;
  nav.cursor = true;
  nav.idx[r] = r === "main" ? Math.min(nav.idx.main, els(r).length - 1) : currentIn(els(r));
  paint();
}

function cycleFocus() {
  const start = REGIONS.indexOf(nav.focus);
  for (let i = 1; i <= REGIONS.length; i++) {
    const r = REGIONS[(start + i) % REGIONS.length];
    if (els(r).length) return focusRegion(r);
  }
}

function tabMove(dir: number) {
  const list = els("tabs");
  if (!list.length) return;
  const next = list[(currentIn(list) + dir + list.length) % list.length];
  next.click();
}

const go = (href: string) => router.navigate(href as any);

// "/": the page's own search box when it has one (like the web), else the palette.
function focusSearch() {
  const el =
    typeof document === "undefined"
      ? null
      : Array.from(document.querySelectorAll<HTMLElement>('[data-kb="search"]')).find(
          (x) => x.offsetParent !== null,
        );
  if (el) el.focus();
  else if (!emit("composer:commands")) openPalette("all");
}

function openIdx(i: number) {
  const item = sidebarItems(getState().projects)[i];
  if (item) go(item.href);
  else toast(`No item ${i + 1}`);
}

function step(dir: number) {
  const items = sidebarItems(getState().projects);
  if (!items.length) return;
  const cur = items.findIndex((it) => path === it.href || path.startsWith(`${it.href}/`));
  go(items[(cur + dir + items.length) % items.length].href);
}

/** A project page's tabs (Sessions, Skills, …), when one is open. */
function pageTabs(): HTMLElement[] {
  return Array.from(
    document.querySelectorAll<HTMLElement>('[data-kb-tabs="project"] [data-kb="tab"]'),
  ).filter((el) => el.offsetParent !== null);
}

/** `[` / `]`: a project's tabs, like the web; elsewhere the running sessions. */
function tabStep(dir: number) {
  const tabs = pageTabs();
  if (tabs.length) {
    const cur = Math.max(
      0,
      tabs.findIndex((el) => el.dataset.kbCurrent === "1"),
    );
    tabs[(cur + dir + tabs.length) % tabs.length].click();
    return;
  }
  const running = getState().running;
  if (!running.length) return toast("Nothing running");
  const cur = running.findIndex((r) => path === `/session/${r.id}`);
  const next = running[(cur + dir + running.length) % running.length];
  go(`/session/${next.id}`);
}

function openGlobal(keys: Keys, key: string) {
  const g = keys.globals.find((x) => x.key === key);
  if (g) go(appPath(g.path));
  else toast(`No place on g ${key}`);
}

async function newSession() {
  // On a folder page its "New chat" box, so its branch picker applies.
  const box = Array.from(document.querySelectorAll<HTMLElement>('[data-testid="start-chat"]')).find(
    (el) => el.offsetParent !== null,
  );
  if (box) return box.focus();
  // Elsewhere a page's own button, so its "New worktree" toggle applies.
  const button = Array.from(document.querySelectorAll<HTMLElement>('[data-testid="new-session"]')).find(
    (el) => el.offsetParent !== null,
  );
  if (button) return button.click();
  const { projectId } = getCurrent();
  if (projectId == null) return openPalette("new");
  try {
    const { session_id } = await ask<{ session_id: string }>("new_session", { project_id: projectId }, 60000);
    go(`/session/${session_id}`);
  } catch (e: any) {
    toast(e.message);
  }
}

async function run() {
  const { projectId, sessionId } = getCurrent();
  const project = getState().projects.find((p) => p.id === projectId);
  if (sessionId && emit("session:run-again")) return;
  if (project?.kind !== "routine") return toast("Open a procedure to run it");
  try {
    const { session_id } = await ask<{ session_id: string }>(
      "run_routine",
      { project_id: project.id },
      60000,
    );
    go(`/session/${session_id}`);
  } catch (e: any) {
    toast(e.message);
  }
}

function runSessionAction(action: string) {
  if (!emit(SESSION_COMMANDS[action])) toast("Open a session first");
}

// ── Hints ─────────────────────────────────────────────────────────────────
// While the prefix is armed every row, tab and text box in view shows a letter
// (the sidebar shows numbers); pressing it opens the row or focuses the box.
// Letters that are prefix commands, or <leader> keys, are never hints.

const HINT_TARGETS =
  '[data-kb="row"], [data-kb="tab"], [data-kb="search"], input:not([type="hidden"]), textarea';
const COMMAND_KEYS = new Set("nplwigcrzo");
let hintEls: HTMLElement[] = [];

function hintLetters(keys: Keys): string[] {
  const leader = new Set(
    Object.values(keys.binds).flatMap((b) =>
      parse(b)
        .filter((c) => c.leader)
        .map((c) => c.key),
    ),
  );
  return [..."sdfjehtyuqvxbakm"].filter((k) => !COMMAND_KEYS.has(k) && !leader.has(k));
}

// In view and not covered (a row scrolled under a header doesn't count).
function inView(el: HTMLElement): boolean {
  if (el.offsetParent === null || el.closest('[aria-disabled="true"]')) return false;
  const r = el.getBoundingClientRect();
  if (!r.width || r.bottom <= 0 || r.top >= innerHeight || r.right <= 0 || r.left >= innerWidth) return false;
  const top = Math.max(r.top, 0);
  const bottom = Math.min(r.bottom, innerHeight);
  const hit = document.elementFromPoint(
    Math.min(Math.max(r.left + Math.min(r.width / 2, 24), 0), innerWidth - 1),
    (top + bottom) / 2,
  );
  return !!hit && (hit === el || el.contains(hit));
}

function showHints(keys: Keys) {
  const letters = hintLetters(keys);
  const found = Array.from(document.querySelectorAll<HTMLElement>(HINT_TARGETS)).filter(inView);
  // Each element once (a row may hold a text box), top to bottom, left to right.
  hintEls = found
    .filter((el) => !found.some((o) => o !== el && o.contains(el) && o.matches("input, textarea")))
    .slice(0, letters.length * letters.length);
  const rects = new Map(hintEls.map((el) => [el, el.getBoundingClientRect()]));
  hintEls.sort((a, b) => rects.get(a)!.top - rects.get(b)!.top || rects.get(a)!.left - rects.get(b)!.left);
  const n = letters.length;
  const label = (i: number) =>
    hintEls.length <= n ? letters[i] : letters[Math.floor(i / n)] + letters[i % n];
  setKb({
    typed: "",
    hints: hintEls.map((el, i) => {
      const r = rects.get(el)!;
      // On the top-left corner, so the label underneath stays readable.
      return { label: label(i), x: Math.max(r.left - 8, 2), y: Math.max(r.top - 7, 2) };
    }),
  });
}

function openHint(el: HTMLElement) {
  if (el.matches("input, textarea")) el.focus();
  else el.click();
}

/** A hint letter: opens it, or waits for the second letter. False when no hint starts so. */
function hintKey(keys: Keys, k: string): boolean {
  const typed = kb.typed + k;
  const i = kb.hints.findIndex((h) => h.label === typed);
  if (i >= 0) {
    const el = hintEls[i];
    disarm();
    openHint(el);
    return true;
  }
  if (!kb.hints.some((h) => h.label.startsWith(typed))) return false;
  setKb({ typed });
  arm(keys, "prefix", false);
  return true;
}

// ── Key handling ──────────────────────────────────────────────────────────

const REPEATABLE = ["n", "p", "[", "]"];
const timers: { which?: ReturnType<typeof setTimeout>; reset?: ReturnType<typeof setTimeout> } = {};

function arm(keys: Keys, mode: KbState["mode"] = "prefix", fresh = true) {
  clearTimeout(timers.which);
  clearTimeout(timers.reset);
  if (fresh) setKb({ mode, which: false, hints: [], typed: "" });
  if (mode === "prefix") {
    if (fresh) showHints(keys);
    timers.which = setTimeout(() => setKb({ which: true }), keys.prefs.which_key_delay);
  }
  // Long enough to find a letter among the hints.
  timers.reset = setTimeout(disarm, mode === "repeat" ? 600 : mode === "prefix" ? 6000 : 3000);
}

function disarm() {
  clearTimeout(timers.which);
  clearTimeout(timers.reset);
  hintEls = [];
  setKb({ mode: null, which: false, hints: [], typed: "" });
}

function prefixKey(keys: Keys, e: KeyboardEvent) {
  const k = e.key;
  if (k === "Escape") return disarm();
  if (kb.mode === "g") {
    disarm();
    return openGlobal(keys, k);
  }
  if (keys.prefs.keymap !== "tmux") return disarm();
  const once = (fn: () => void) => {
    disarm();
    fn();
  };
  const rep = (fn: () => void) => {
    fn();
    arm(keys, "repeat");
  };

  const action = sessionAction(keys, e, true, false);
  if (action) return once(() => runSessionAction(action));
  if (/^[1-9]$/.test(k)) return once(() => openIdx(Number(k) - 1));
  if (kb.hints.length && /^[a-z]$/.test(k) && !COMMAND_KEYS.has(k) && hintKey(keys, k)) return;
  const typed = kb.typed;
  if (typed) return once(() => toast(`No hint ${typed}${k}`));

  switch (k) {
    case "n":
      return rep(() => step(1));
    case "p":
      return rep(() => step(-1));
    case "]":
      return rep(() => tabStep(1));
    case "[":
      return rep(() => tabStep(-1));
    case "l":
      return once(() => (lastPath ? go(lastPath) : toast("No last place yet")));
    case "w":
      return once(() => openPalette("switch"));
    case ":":
      return once(() => openPalette("all"));
    case "/":
      return once(focusSearch);
    case "i":
      return once(() => go("/"));
    case "g":
      return arm(keys, "g");
    case "c":
      return once(newSession);
    case "r":
      return once(run);
    case ",":
      return once(() => emit("session:rename") || toast("Open a session to rename it"));
    case "z":
      return once(toggleZoom);
    case "o":
      return once(cycleFocus);
    case "ArrowLeft":
      return once(() => focusRegion("side"));
    case "ArrowRight":
    case "ArrowDown":
      return once(() => focusRegion("main"));
    case "ArrowUp":
      return once(() => focusRegion("tabs"));
    case "?":
      return once(() => setHelp(true));
    default:
      return once(() => toast(`No binding: ${prefixLabel(keys.prefs.prefix)} ${k}`));
  }
}

function editable(el: EventTarget | null) {
  const t = el as HTMLElement | null;
  return !!t && (t.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(t.tagName));
}

let paletteOpen = false;
export const notePaletteOpen = (open: boolean) => {
  paletteOpen = open;
};

const CAST_NAMES: Record<string, string> = {
  " ": "Space",
  ArrowUp: "↑",
  ArrowDown: "↓",
  ArrowLeft: "←",
  ArrowRight: "→",
  Enter: "↵",
  Escape: "Esc",
  Backspace: "⌫",
  Tab: "⇥",
};

function keyLabel(e: KeyboardEvent) {
  let m = "";
  if (e.ctrlKey) m += isMac ? "⌃" : "Ctrl+";
  if (e.altKey) m += isMac ? "⌥" : "Alt+";
  if (e.metaKey) m += isMac ? "⌘" : "Super+";
  let k = CAST_NAMES[e.key];
  if (!k) {
    if (m && e.code.startsWith("Key")) k = e.code.slice(3);
    else if (m && e.code.startsWith("Digit")) k = e.code.slice(5);
    else k = e.key;
  }
  return m + k;
}

let castTimer: ReturnType<typeof setTimeout> | undefined;
function cast(label: string) {
  clearTimeout(castTimer);
  setKb({ cast: [...kb.cast, label].slice(-6) });
  castTimer = setTimeout(() => setKb({ cast: [] }), 1500);
}

function onKey(e: KeyboardEvent) {
  const keys = getState().keys;
  if (!keys || e.defaultPrevented || e.isComposing) return;
  if (["Shift", "Control", "Alt", "Meta", "CapsLock", "AltGraph"].includes(e.key)) return;
  const typing = editable(e.target);
  if (keys.prefs.keycast && !(typing && plain(e) && e.key.length === 1)) cast(keyLabel(e));
  const km = keys.prefs.keymap;
  const isPrefix = e.ctrlKey && !e.metaKey && !e.altKey && e.code === PREFIX_CODES[keys.prefs.prefix];
  const stop = () => e.preventDefault();

  // The palette handles its own keys.
  if (paletteOpen) {
    if (mod(e) && e.code === "KeyK") {
      stop();
      closePalette();
    }
    return;
  }
  if (kb.help) {
    if (e.key === "Escape" || e.key === "?") {
      stop();
      setHelp(false);
    }
    return;
  }

  // Escape first stops voice typing, then Peon talking, before it interrupts anything.
  if (e.key === "Escape" && !kb.mode && isListening()) {
    stopListening();
    return stop();
  }
  if (e.key === "Escape" && !kb.mode && isSpeaking()) {
    stopSpeaking();
    return stop();
  }

  if (kb.mode) {
    if (kb.mode === "repeat" && !(plain(e) && REPEATABLE.includes(e.key))) disarm();
    else if (km === "tmux" && isPrefix) {
      stop();
      return disarm();
    } else {
      stop();
      return prefixKey(keys, e);
    }
  }
  if (km === "tmux" && isPrefix) {
    stop();
    return arm(keys);
  }
  // mod+K: the top bar with ">" for commands; shift+mod+K: the top bar empty, for a task.
  if (mod(e) && e.code === "KeyK") {
    stop();
    return void (emit(e.shiftKey ? "composer:focus" : "composer:commands") || openPalette("all"));
  }
  if (mod(e) && e.code === "Backslash") {
    stop();
    return toggleZoom();
  }
  // mod+Enter: send in a session, run on a routine.
  if (mod(e) && e.key === "Enter") {
    stop();
    return void (emit("session:send") || run());
  }
  // alt+k: the composer; alt+v: talk (into the session's reply box when one is open).
  if (e.altKey && !e.ctrlKey && !e.metaKey && e.code === "KeyK") {
    stop();
    return void emit("composer:focus");
  }
  if (e.altKey && !e.ctrlKey && !e.metaKey && e.code === "KeyV") {
    stop();
    return void (emit("session:talk") || emit("composer:talk"));
  }

  if (km === "standard") {
    const alt = e.altKey && !e.ctrlKey && !e.metaKey;
    const done = (fn: () => void) => {
      stop();
      fn();
    };
    if (mod(e) && e.code === "KeyP" && !e.shiftKey) return done(() => openPalette("switch"));
    if (alt && /^Digit[1-9]$/.test(e.code)) return done(() => openIdx(Number(e.code.slice(5)) - 1));
    if (alt && e.key === "ArrowDown") return done(() => step(1));
    if (alt && e.key === "ArrowUp") return done(() => step(-1));
    if (mod(e) && e.code === "BracketLeft") return done(() => history.back());
    if (mod(e) && e.code === "BracketRight") return done(() => history.forward());
    if (alt && e.code === "BracketLeft") return done(() => tabStep(-1));
    if (alt && e.code === "BracketRight") return done(() => tabStep(1));
    if (alt && e.code === "KeyN") return done(newSession);
    if (!typing && plain(e) && e.key === "g") return done(() => arm(keys, "g"));
  }

  const action = sessionAction(keys, e, false, typing);
  if (action && emit(SESSION_COMMANDS[action])) return stop();

  if (e.key === "Escape") {
    if (typing) return (e.target as HTMLElement).blur();
    if (nav.cursor) {
      nav.cursor = false;
      paint();
    }
    return;
  }
  if (typing || !plain(e)) return;
  const k = e.key;
  if ((k === "j" || k === "ArrowDown") && move(1)) return stop();
  if ((k === "k" || k === "ArrowUp") && move(-1)) return stop();
  if (nav.focus === "tabs" && (k === "h" || k === "ArrowLeft")) {
    stop();
    return tabMove(-1);
  }
  if (nav.focus === "tabs" && (k === "l" || k === "ArrowRight")) {
    stop();
    return tabMove(1);
  }
  if (k === "Enter" && activate()) return stop();
  if (e.key === "/") {
    stop();
    focusSearch();
  } else if (e.key === "?") {
    stop();
    setHelp(true);
  }
}

/** Installs the shortcuts while the desktop shell is up. */
export function useShortcuts() {
  useEffect(() => {
    if (Platform.OS !== "web") return;
    // react-native-web's TextInput stops keydown from bubbling, so keys typed in a
    // text field are caught on the way down; everything else on the way up.
    const down = (e: KeyboardEvent) => editable(e.target) && onKey(e);
    const up = (e: KeyboardEvent) => !editable(e.target) && onKey(e);
    window.addEventListener("keydown", down, true);
    window.addEventListener("keydown", up);
    return () => {
      window.removeEventListener("keydown", down, true);
      window.removeEventListener("keydown", up);
    };
  }, []);
}
