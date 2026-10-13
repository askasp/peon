// "Chat about this": a file, and how it was being viewed, handed from Files to
// a single-chat Project's composer. The phone's View is its own screen, so it
// goes through here rather than props.

import { useSyncExternalStore } from "react";

export type Attached = { path: string; view: string | null };

let pending: { project: string; file: Attached | null } = { project: "", file: null };
const listeners = new Set<() => void>();
const subscribe = (l: () => void) => {
  listeners.add(l);
  return () => listeners.delete(l);
};

/** Puts `file` in Project `project`'s composer (null takes it out). */
export function attachToChat(project: string | number, file: Attached | null) {
  pending = { project: String(project), file };
  listeners.forEach((l) => l());
}

/** What is attached to Project `project`'s composer. */
export function useAttached(project: string | number): Attached | null {
  const p = useSyncExternalStore(subscribe, () => pending);
  return p.project === String(project) ? p.file : null;
}

/** The text sent for an attached file: an @mention the agent reads, and the view it was seen in. */
export const attachedText = (a: Attached, text: string) =>
  `@${a.path}${a.view ? ` (looking at the ${a.view.toLowerCase()} view)` : ""}\n\n${text}`;
