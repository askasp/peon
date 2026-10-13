import { getSocket, request } from "./peon";
import { duration } from "./time";
import { color } from "./theme";
import type { Run } from "./types";

/** "monday · front, slack": a run's inputs, like the web. */
export const inputsLabel = (inputs: Run["inputs"]) =>
  Object.keys(inputs ?? {})
    .sort()
    .map((k) => (Array.isArray(inputs[k]) ? (inputs[k] as string[]).join(", ") : String(inputs[k])))
    .filter(Boolean)
    .join(" · ");

/** Who started a run: "schedule", "you", or their name. */
export const runWho = (r: Run, me: number | undefined) =>
  r.schedule_key !== "manual" ? "schedule" : r.owner_id === me ? "you" : (r.owner ?? "someone");

/** A run's one-line state, coloured: running green, done teal, failed red. */
export function runLine(run: Run | null): { text: string; tint: string } | null {
  if (!run) return null;
  switch (run.status) {
    case "running":
      return { text: `Running · ${duration(run.started)}`, tint: color.accentText };
    case "done":
      return { text: `Done · ${duration(run.started, run.finished)}`, tint: color.teal };
    case "failed":
      return { text: `Failed${run.error ? ` · ${run.error}` : ""}`, tint: color.red };
    default:
      return { text: run.status.charAt(0).toUpperCase() + run.status.slice(1), tint: color.muted };
  }
}

// Stops a run by interrupting its session, over that session's channel.
export async function stopRun(sessionId: string) {
  const socket = getSocket();
  if (!socket) return;
  const ch = socket.channel(`session:${sessionId}`, {});
  await new Promise<void>((resolve, reject) =>
    ch
      .join()
      .receive("ok", () => resolve())
      .receive("error", () => reject(new Error("Can't open the run."))),
  );
  try {
    await request(ch, "interrupt");
  } finally {
    ch.leave();
  }
}

const parse = (iso: string) => new Date(iso.endsWith("Z") || /[+-]\d\d:\d\d$/.test(iso) ? iso : `${iso}Z`);

/** "09:14". */
export const clock = (iso: string) =>
  parse(iso).toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" });

/** "Today", "Yesterday", "Mon 12 Oct": a day heading in the Runs list. */
export function dayLabel(iso: string) {
  const d = parse(iso);
  const days = Math.round(
    (new Date().setHours(0, 0, 0, 0) - new Date(d.getTime()).setHours(0, 0, 0, 0)) / 86400000,
  );
  if (days === 0) return "Today";
  if (days === 1) return "Yesterday";
  return d.toLocaleDateString("en-GB", { weekday: "short", day: "numeric", month: "short" }).replace(",", "");
}

/** A run's mark and words for its state: ✓ Done, ! Done with failures, ✕ Failed, … */
export function runState(r: Run): { glyph: string; tint: string; text: string } {
  const failures = (r.steps ?? []).some(
    (s) =>
      s.status === "failed" || s.status === "partial" || (s.results ?? []).some((x) => x.status === "failed"),
  );
  switch (r.status) {
    case "running":
      return { glyph: "•", tint: color.accentText, text: "Running" };
    case "waiting":
      return { glyph: "?", tint: color.needs, text: "Waiting for you" };
    case "failed":
      return { glyph: "✕", tint: color.red, text: "Failed" };
    case "done":
      return failures
        ? { glyph: "!", tint: color.needs, text: "Done with failures" }
        : { glyph: "✓", tint: color.accentText, text: "Done" };
    default:
      return { glyph: "·", tint: color.muted, text: r.status };
  }
}

/** What a run came to: its summary, else why it stopped or what it's doing. */
export const runResult = (r: Run) =>
  r.status === "failed"
    ? (r.error ?? r.summary ?? "Failed")
    : r.status === "waiting"
      ? (r.summary ?? "Waiting for you")
      : r.status === "running"
        ? "Running…"
        : (r.summary ?? "Done");
