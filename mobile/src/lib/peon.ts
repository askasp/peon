// The one websocket to the Peon (beamcode) server, and the app state it feeds.
//
//   "auth"          log in with username + password → token
//   "app"           projects, inbox, running sessions, routines, the composer
//   "session:<id>"  one session (see useSession)
//
// The server pushes changes; screens read state with usePeon() and send
// requests with request().

import { Channel, Socket } from "phoenix";
import { useSyncExternalStore } from "react";
import { Platform } from "react-native";
import * as storage from "./storage";
import type { InboxItem, Keys, Project, RunningSession, User } from "./types";

type State = {
  ready: boolean; // stored login read
  server: string | null;
  token: string | null;
  connected: boolean;
  joined: boolean;
  user: User | null;
  projects: Project[];
  inbox: InboxItem[];
  running: RunningSession[];
  /** The session on screen, so the top bar can show it as a tab while it's idle. */
  viewing: { id: string; title: string } | null;
  // Bumped on every session activity so lists can refetch.
  activity: number;
  runsChanged: number;
  schedulesChanged: number;
  keys: Keys | null;
};

let state: State = {
  ready: false,
  server: null,
  token: null,
  connected: false,
  joined: false,
  user: null,
  projects: [],
  inbox: [],
  running: [],
  viewing: null,
  activity: 0,
  runsChanged: 0,
  schedulesChanged: 0,
  keys: null,
};

const listeners = new Set<() => void>();

function set(patch: Partial<State>) {
  state = { ...state, ...patch };
  listeners.forEach((l) => l());
}

/** Marks the session on screen (null when leaving it). */
export const setViewing = (viewing: { id: string; title: string } | null) => {
  if (state.viewing?.id !== viewing?.id || state.viewing?.title !== viewing?.title) set({ viewing });
};

export function usePeon<T>(select: (s: State) => T): T {
  return useSyncExternalStore(
    (l) => {
      listeners.add(l);
      return () => listeners.delete(l);
    },
    () => select(state),
  );
}

export const getState = () => state;

let socket: Socket | null = null;
let app: Channel | null = null;

// "peon.stadler.no" → wss://peon.stadler.no/socket; "10.0.2.2:4000" → ws://…
export function socketUrl(server: string): string {
  const s = server.trim().replace(/\/+$/, "");
  if (/^wss?:\/\//.test(s)) return `${s}/socket`;
  if (s.startsWith("https://")) return `wss://${s.slice(8)}/socket`;
  if (s.startsWith("http://")) return `ws://${s.slice(7)}/socket`;
  const local = /^(localhost|\d+\.\d+\.\d+\.\d+)(:\d+)?$/.test(s);
  return `${local ? "ws" : "wss"}://${s}/socket`;
}

function open(server: string, params: Record<string, string> | (() => Record<string, string>)): Socket {
  const sock = new Socket(socketUrl(server), {
    params,
    reconnectAfterMs: (tries: number) => [500, 1000, 2000, 5000][tries - 1] ?? 10000,
  });
  sock.onOpen(() => set({ connected: true }));
  sock.onClose(() => set({ connected: false }));
  sock.onError(() => set({ connected: false }));
  sock.connect();
  return sock;
}

/** Sends `event` on `channel` and resolves with the reply, or rejects with its message. */
export function request<T = any>(
  channel: Channel | null,
  event: string,
  payload: object = {},
  timeout = 30000,
): Promise<T> {
  return new Promise((resolve, reject) => {
    if (!channel) return reject(new Error("Not connected"));
    channel
      .push(event, payload, timeout)
      .receive("ok", (r: T) => resolve(r))
      .receive("error", (e: any) => reject(new Error(e?.message || e?.reason || "Failed")))
      .receive("timeout", () => reject(new Error("The server didn't answer in time.")));
  });
}

/** A request on the "app" channel. */
export async function ask<T = any>(event: string, payload: object = {}, timeout?: number): Promise<T> {
  // Just after the page opens the socket may still be connecting: wait for it, up to 10 seconds.
  for (let waited = 0; !app && waited < 10000; waited += 100) await new Promise((r) => setTimeout(r, 100));
  return request<T>(app, event, payload, timeout);
}

export function getSocket() {
  return socket;
}

// Served by Phoenix (/app): the page carries a token for the web login, and
// the server is the page's own host. Nothing to store.
function hostedLogin(): { server: string; token: string } | null {
  if (Platform.OS !== "web" || typeof document === "undefined") return null;
  const token = document.querySelector('meta[name="peon-token"]')?.getAttribute("content");
  return token ? { server: `${location.protocol}//${location.host}`, token } : null;
}

export const hosted = () => hostedLogin() != null;

/** Reads the stored server and token, and connects if logged in. */
export async function boot() {
  const web = hostedLogin();
  if (web) {
    set({ ...web, ready: true });
    return connect(web.server, web.token);
  }
  const [server, token] = await Promise.all([storage.getItem("server"), storage.getItem("token")]);
  set({ server, token, ready: true });
  if (server && token) connect(server, token);
}

function connect(server: string, token: string) {
  socket?.disconnect();
  // Read on every (re)connect, so a new token (after a password change) is used.
  socket = open(server, () => ({ token: state.token ?? token }));
  app = socket.channel("app", {});

  app.on("inbox", ({ items }) => set({ inbox: items }));
  app.on("running", ({ sessions }) => set({ running: sessions }));
  app.on("projects", ({ projects }) => set({ projects }));
  app.on("activity", () => set({ activity: state.activity + 1 }));
  app.on("runs_changed", () => set({ runsChanged: state.runsChanged + 1 }));
  app.on("schedules_changed", () => set({ schedulesChanged: state.schedulesChanged + 1 }));

  app
    .join()
    .receive("ok", ({ user, projects, keys }) => set({ user, projects, keys, joined: true }))
    .receive("error", ({ reason }) => {
      // A stale or revoked token: back to the connect screen.
      if (reason === "unauthorized") {
        // Hosted: a fresh page gets a fresh token, or the login page.
        if (hosted()) location.reload();
        else signOut();
      }
    });
}

/** Logs in over the "auth" channel, keeps the token, and connects for real. */
export function login(server: string, username: string, password: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const sock = open(server, {});
    let settled = false;
    const fail = (message: string) => {
      if (settled) return;
      settled = true;
      sock.disconnect();
      reject(new Error(message));
    };

    const timer = setTimeout(() => fail("Can't reach the server."), 10000);
    const auth = sock.channel("auth", {});

    auth
      .join()
      .receive("ok", () => {
        clearTimeout(timer);
        request<{ token: string; user: User }>(auth, "login", { username, password })
          .then(async ({ token }) => {
            settled = true;
            sock.disconnect();
            await storage.setItem("server", server.trim());
            await storage.setItem("token", token);
            set({ server: server.trim(), token });
            connect(server.trim(), token);
            resolve();
          })
          .catch((e) => fail(e.message));
      })
      .receive("error", () => fail("The server refused the connection."));
  });
}

/**
 * Changes the password. The server hands back a new token and then closes
 * every socket of ours: this one reconnects with the new token, other devices
 * have to log in again.
 */
export async function changePassword(password: string) {
  const { token } = await ask<{ token: string }>("change_password", { password });
  set({ token });
  if (!hosted()) await storage.setItem("token", token);
}

export async function signOut() {
  if (hosted()) return webLogOut();
  socket?.disconnect();
  socket = null;
  app = null;
  await storage.deleteItem("token");
  set({ token: null, user: null, joined: false, projects: [], inbox: [], running: [] });
}

/** Pulls the inbox and running sessions now (pull to refresh); pushes keep them current otherwise. */
export async function refreshInbox() {
  const [{ items }, { sessions }] = await Promise.all([
    ask<{ items: InboxItem[] }>("inbox"),
    ask<{ sessions: RunningSession[] }>("running"),
  ]);
  set({ inbox: items, running: sessions });
}

// The web login's own logout (DELETE /logout with the CSRF token).
function webLogOut() {
  const form = document.createElement("form");
  form.method = "post";
  form.action = "/logout";
  const field = (name: string, value: string) => {
    const input = document.createElement("input");
    input.type = "hidden";
    input.name = name;
    input.value = value;
    form.appendChild(input);
  };
  field("_method", "delete");
  field("_csrf_token", document.querySelector('meta[name="csrf-token"]')?.getAttribute("content") ?? "");
  document.body.appendChild(form);
  form.submit();
}

/** Saves keymap preferences and/or in-session shortcuts; the store follows. */
export async function saveKeys(change: { prefs?: Partial<Keys["prefs"]>; binds?: Record<string, string> }) {
  const { keys } = await ask<{ keys: Keys }>("save_keys", change);
  set({ keys });
}
