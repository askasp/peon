// A Code Project's task queue (tk tickets by worktree): how to read a tree, and
// what in a chat message asks to queue tasks rather than do them now.

import type { QueueTree, Ticket } from "./types";

const cap = (s: string) => (s ? s[0].toUpperCase() + s.slice(1) : s);

/** A task's place in its tree: running, needs you, ready, blocked or done. */
export type TaskState = "running" | "needs" | "ready" | "blocked" | "done";

export function taskState(t: Ticket, tree: QueueTree): TaskState {
  if (t.status === "closed") return "done";
  // A procedure run says where it is; between steps the chat is idle for a moment.
  if (t.status === "in_progress" && t.run?.status === "waiting") return "needs";
  if (t.status === "in_progress" && t.run?.status === "running") return "running";
  if (t.status === "in_progress") return tree.chat?.status === "running" ? "running" : "needs";
  return t.blocked_by?.length ? "blocked" : "ready";
}

/** The tree's tasks sorted into what's on screen: running, needs you, ready (next first), blocked, done. */
export function sortTree(tree: QueueTree) {
  const by = (s: TaskState) => tree.tickets.filter((t) => taskState(t, tree) === s);
  return {
    running: by("running"),
    needs: by("needs"),
    ready: by("ready"),
    blocked: by("blocked"),
    done: by("done"),
  };
}

/** The first ready task that isn't paused: what starts next. */
export const nextTask = (tree: QueueTree) => sortTree(tree).ready.find((t) => !t.paused) ?? null;

/** Done or cancelled, from the task's last note. */
export const cancelled = (t: Ticket) => /^cancel/i.test(t.notes[t.notes.length - 1]?.text ?? "");

/**
 * A chat message that asks to queue tasks, not to do them: "queue the
 * follow-ups: x, then y", "add a task to …", "… for later". `list` for "what's
 * queued?". Null for anything else.
 */
export function queueIntent(text: string): { list: true } | { titles: string[]; chain: boolean } | null {
  const t = text.trim();
  const lo = t.toLowerCase();
  if (
    /\b(what'?s|what is|show( me)?|list)\b.*\b(queue|queued|tasks|tickets|tk)\b/.test(lo) ||
    /^(queue|tasks|tk)\??$/.test(lo)
  )
    return { list: true };
  // Only an opening "queue …" / "add a task …", or a closing "… for later" / "… in tk".
  if (
    !/^(please\s+)?(can you\s+)?(queue|add (a |an )?(tasks?|tickets?|follow-?ups?)|create (a |an )?(tasks?|tickets?))\b/.test(
      lo,
    ) &&
    !/\b(for later|in(to)? tk|to tk)\.?$/.test(lo)
  )
    return null;
  const body = t
    .replace(/^(please\s+)?(can you\s+)?/i, "")
    .replace(
      /^(queue( up)?|add|create|make|put)\s+(a |an |the )?(tasks?|tickets?|follow-?ups?)?\s*(in(to)? tk|to tk|for)?\s*/i,
      "",
    )
    .replace(/^(the )?follow-?ups?/i, "")
    .replace(/^[:\-–\s]+/, "")
    .replace(/\s*(in(to)? tk|to tk|for later|later)\.?$/i, "");
  const chain = /\b(then|after that|afterwards)\b/i.test(body);
  const titles = body
    .split(/\s*(?:;|\n|,\s*then\s+|\s+then\s+|,\s*and\s+|,\s+|\s+and\s+)\s*/i)
    .map((x) =>
      x
        .replace(/^(and|then|also)\s+/i, "")
        .replace(/[.]+$/, "")
        .trim(),
    )
    .filter((x) => x.length > 2)
    .map(cap)
    .slice(0, 6);
  return titles.length ? { titles, chain } : null;
}
