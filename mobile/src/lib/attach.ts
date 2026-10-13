// "Chat about this": a file, and how it was being viewed, handed from Files to
// a single-chat Project's composer. The phone's View is its own screen, so it
// goes through here rather than props.

import { useSyncExternalStore } from "react";

/**
 * A file and the view it was seen in, or (with `text`) something else the
 * message is about, such as a run: `path` is then its label, and `text` goes
 * along in a ```peon-about block the bubble shows as a chip.
 */
export type Attached = { path: string; view: string | null; text?: string };

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
  a.text != null
    ? `\`\`\`peon-about ${a.path}\n${a.text.trim()}\n\`\`\`\n\n${text}`
    : `@${a.path}${a.view ? ` (looking at the ${a.view.toLowerCase()} view)` : ""}\n\n${text}`;

/**
 * What a person typed, without what the app sent along with it: the
 * ```peon-context block (an Operations chat's run or procedure) and a
 * ```peon-about block, whose label comes back as `about`.
 */
export function userText(text: string): { text: string; about: string | null } {
  let about: string | null = null;
  const out = text
    .replace(/\n*```peon-context\n[\s\S]*?(```|$)/g, "")
    .replace(/^```peon-about ([^\n]*)\n[\s\S]*?```\n*/, (_, label: string) => {
      about = label.trim();
      return "";
    });
  return { text: out.trim(), about };
}
