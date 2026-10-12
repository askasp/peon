// One session over its own channel ("session:<id>"): stored messages, text
// streaming in, status and permission requests, all pushed by the server.

import { useCallback, useEffect, useRef, useState } from "react";
import type { Channel } from "phoenix";
import { getSocket, request, usePeon } from "./peon";
import type { DiffFile, Form, Message, Perm, Project, Run, SessionSummary, Status } from "./types";
import type { Attachment } from "./images";

type Streamed = { text: string; reasoning: string };

type SessionState = {
  for: string | null;
  joined: boolean;
  error: string | null;
  session: SessionSummary | null;
  project: Project | null;
  ids: string[];
  messages: Record<string, Message>;
  streaming: Record<string, Streamed>;
  status: Status;
  perms: Perm[];
  /** Questions the agent is waiting on. */
  forms: Form[];
  run: Run | null;
  diff: DiffFile[];
  /** Cursor for the page of messages just older than the ones loaded, or null. */
  older: string | null;
};

const initial: SessionState = {
  for: null,
  joined: false,
  error: null,
  session: null,
  project: null,
  ids: [],
  messages: {},
  streaming: {},
  status: "idle",
  perms: [],
  forms: [],
  run: null,
  diff: [],
  older: null,
};

const storedTextLength = (m: Message) =>
  (m.content ?? []).reduce((n, p) => n + (p.type === "text" ? p.text.length : 0), 0);

// Streamed text is dropped once the stored message has caught up with it.
function dropCaughtUp(streaming: Record<string, Streamed>, messages: Record<string, Message>) {
  const left: Record<string, Streamed> = {};
  for (const [id, s] of Object.entries(streaming)) {
    const m = messages[id];
    if (!m || (!m.time?.completed && storedTextLength(m) < s.text.length)) left[id] = s;
  }
  return left;
}

/** `id` may be null (nothing to join yet, e.g. hands-free before a session starts). */
export function useSession(id: string | null, onSpeak?: (text: string) => void) {
  const [stored, setState] = useState<SessionState>(initial);
  // State left from another session reads as nothing loaded yet.
  const state = stored.for === id ? stored : initial;
  const channel = useRef<Channel | null>(null);
  const speak = useRef(onSpeak);
  useEffect(() => {
    speak.current = onSpeak;
  });
  const joined = usePeon((s) => s.joined);

  useEffect(() => {
    const socket = getSocket();
    if (!socket || !joined || !id) return;
    const ch = socket.channel(`session:${id}`, {});
    channel.current = ch;

    ch.on("delta", ({ message_id, kind, delta }) =>
      setState((s) => {
        const prev = s.streaming[message_id] ?? { text: "", reasoning: "" };
        const next = { ...prev, [kind]: prev[kind as keyof Streamed] + delta };
        return { ...s, streaming: { ...s.streaming, [message_id]: next } };
      }),
    );

    ch.on("messages", ({ upsert, ids }: { upsert: Message[]; ids: string[] }) =>
      setState((s) => {
        // Older messages already loaded stay above the window the server tracks.
        const kept = s.ids.filter((mid) => !ids.includes(mid));
        const merged = [...kept, ...ids];
        const messages: Record<string, Message> = {};
        for (const mid of merged) if (s.messages[mid]) messages[mid] = s.messages[mid];
        for (const m of upsert) messages[m.id] = m;
        return { ...s, ids: merged, messages, streaming: dropCaughtUp(s.streaming, messages) };
      }),
    );

    ch.on("status", ({ status, perms }) => setState((s) => ({ ...s, status, perms })));
    ch.on("forms", ({ forms }) => setState((s) => ({ ...s, forms })));
    ch.on("session", ({ session }) => setState((s) => ({ ...s, session })));
    ch.on("diff", ({ files }) => setState((s) => ({ ...s, diff: files })));
    ch.on("run", ({ run }) => setState((s) => ({ ...s, run })));
    ch.on("speak", ({ text }) => speak.current?.(text));
    // The server closed it: the project was made private or removed.
    ch.on("gone", () =>
      setState((s) => ({ ...s, joined: false, error: "This is no longer available to you." })),
    );

    // Also fires again after a reconnect, so the view starts over from the server.
    ch.join()
      .receive("ok", (r) => {
        const messages: Record<string, Message> = {};
        for (const m of r.messages as Message[]) messages[m.id] = m;
        setState((s) => ({
          ...(s.for === id ? s : initial),
          for: id,
          joined: true,
          error: null,
          session: r.session,
          project: r.project,
          ids: (r.messages as Message[]).map((m) => m.id),
          messages,
          streaming: dropCaughtUp(s.streaming, messages),
          status: r.status,
          perms: r.perms,
          forms: r.forms ?? [],
          run: r.run,
          diff: r.diff ?? [],
          older: r.older ?? null,
        }));
      })
      .receive("error", ({ reason }) =>
        setState((s) => ({
          ...(s.for === id ? s : initial),
          for: id,
          error: reason === "not_found" ? "Session not found, or not yours to see." : reason,
        })),
      );

    return () => {
      ch.leave();
      channel.current = null;
    };
  }, [id, joined]);

  const send = useCallback(
    (text: string, files: Attachment[] = []) => request(channel.current, "send", { text, files }),
    [],
  );
  /** Any other session request (options, set_model, set_agent, rename, compact, run_again, find_files). */
  const call = useCallback(
    <T = any>(event: string, payload: object = {}, timeout?: number) =>
      request<T>(channel.current, event, payload, timeout),
    [],
  );
  const interrupt = useCallback(() => request(channel.current, "interrupt"), []);
  const answer = useCallback(
    (permId: string, decision: "once" | "always" | "reject") =>
      request(channel.current, "permission", { id: permId, decision }),
    [],
  );

  // Messages in order, with text still streaming in merged into its message.
  const items: Message[] = state.ids.map((mid) => {
    const m = state.messages[mid];
    const s = state.streaming[mid];
    if (!s) return m;
    const parts = m.content ?? [];
    // Thinking streams too: shown until the stored message has its own.
    const reasoning =
      s.reasoning && !parts.some((p) => p.type === "reasoning")
        ? [{ type: "reasoning" as const, text: s.reasoning }]
        : [];
    return {
      ...m,
      content: [
        ...reasoning,
        ...parts.filter((p) => p.type !== "text"),
        ...(s.text
          ? [{ type: "text" as const, text: s.text, streaming: true }]
          : parts.filter((p) => p.type === "text")),
      ],
    };
  });
  for (const [mid, s] of Object.entries(state.streaming)) {
    if (!state.messages[mid])
      items.push({
        id: mid,
        type: "assistant",
        time: {},
        content: [
          ...(s.reasoning ? [{ type: "reasoning" as const, text: s.reasoning }] : []),
          ...(s.text ? [{ type: "text" as const, text: s.text, streaming: true }] : []),
        ],
      });
  }

  const reply = useCallback(
    (formId: string, answer: Record<string, unknown>) =>
      request(channel.current, "form_reply", { id: formId, answer }),
    [],
  );
  const skip = useCallback((formId: string) => request(channel.current, "form_cancel", { id: formId }), []);

  // Older messages load a page at a time as you scroll up.
  const olderRef = useRef<string | null>(null);
  const loadingOlder = useRef(false);
  const [olderBusy, setOlderBusy] = useState(false);
  useEffect(() => {
    olderRef.current = state.older;
  }, [state.older]);
  const loadOlder = useCallback(async () => {
    const cursor = olderRef.current;
    if (!cursor || loadingOlder.current) return;
    loadingOlder.current = true;
    setOlderBusy(true);
    try {
      const r = await request<{ messages: Message[]; older: string | null }>(channel.current, "older", {
        cursor,
      });
      setState((s) => {
        const messages = { ...s.messages };
        const fresh: string[] = [];
        for (const m of r.messages) {
          if (!s.messages[m.id]) fresh.push(m.id);
          messages[m.id] = m;
        }
        return { ...s, ids: [...fresh, ...s.ids], messages, older: r.older ?? null };
      });
      olderRef.current = r.older ?? null;
    } catch {
      // Leave the cursor as it was, so scrolling up can try again.
    }
    loadingOlder.current = false;
    setOlderBusy(false);
  }, []);

  return {
    ...state,
    items,
    send,
    interrupt,
    answer,
    reply,
    skip,
    call,
    loadOlder,
    loadingOlder: olderBusy,
  };
}
