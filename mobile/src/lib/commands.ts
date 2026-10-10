// A tiny bus from keyboard shortcuts (and the palette) to whichever screen
// can act on them: "session:interrupt", "session:compact", "session:model", …

import { useEffect, useRef } from "react";

type Handler = () => void;
const handlers = new Map<string, Set<Handler>>();

/** Runs `command`; true when some screen took it. */
export function emit(command: string): boolean {
  const set = handlers.get(command);
  set?.forEach((h) => h());
  return !!set && set.size > 0;
}

/** Handles `command` while the calling component is mounted. */
export function useCommand(command: string, handler: Handler) {
  const latest = useRef(handler);
  useEffect(() => {
    latest.current = handler;
  });
  useEffect(() => {
    const h = () => latest.current();
    if (!handlers.has(command)) handlers.set(command, new Set());
    handlers.get(command)!.add(h);
    return () => {
      handlers.get(command)?.delete(h);
    };
  }, [command]);
}
