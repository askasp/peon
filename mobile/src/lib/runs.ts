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
