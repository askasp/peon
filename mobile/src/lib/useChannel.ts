// Joins a channel for as long as a screen shows it. The join reply is kept;
// `on` handlers get pushes; `call` sends requests. Rejoins after reconnects.

import { useCallback, useEffect, useRef, useState } from "react";
import type { Channel } from "phoenix";
import { getSocket, request, usePeon } from "./peon";

export function useChannel<J = any>(topic: string | null, on: Record<string, (payload: any) => void> = {}) {
  const [state, setState] = useState<{ topic: string | null; reply: J | null; error: string | null }>({
    topic: null,
    reply: null,
    error: null,
  });
  const channel = useRef<Channel | null>(null);
  const handlers = useRef(on);
  useEffect(() => {
    handlers.current = on;
  });
  const joined = usePeon((s) => s.joined);

  useEffect(() => {
    const socket = getSocket();
    if (!socket || !joined || !topic) return;
    const ch = socket.channel(topic, {});
    channel.current = ch;
    const events = Object.keys(handlers.current);
    for (const event of events) ch.on(event, (payload) => handlers.current[event]?.(payload));
    // The server closed it: the project was made private or removed.
    ch.on("gone", () => setState({ topic, reply: null, error: "This is no longer available to you." }));
    ch.join()
      .receive("ok", (reply: J) => setState({ topic, reply, error: null }))
      .receive("error", ({ reason }) =>
        setState({
          topic,
          reply: null,
          error: reason === "not_found" ? "Not found, or not yours to see." : reason,
        }),
      );
    return () => {
      ch.leave();
      channel.current = null;
    };
  }, [topic, joined]);

  // A request made before the channel exists (the socket is still connecting
  // just after the page opens) waits for it, up to 10 seconds.
  const call = useCallback(async <T = any>(event: string, payload: object = {}, timeout?: number) => {
    for (let waited = 0; !channel.current && waited < 10000; waited += 100)
      await new Promise((r) => setTimeout(r, 100));
    return request<T>(channel.current, event, payload, timeout);
  }, []);

  // A reply from another topic (before this one joined) reads as not joined yet.
  const current = state.topic === topic;
  return {
    joined: current && state.reply != null,
    reply: current ? state.reply : null,
    error: current ? state.error : null,
    call,
  };
}
