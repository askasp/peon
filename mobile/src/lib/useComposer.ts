// The global composer's logic, shared by the phone sheet and the desktop top
// bar: a live rule reading while you type or talk, then submit (which may come
// back as a plan to confirm, an answer, a note, or a session to open).

import { useEffect, useState } from "react";
import { router } from "expo-router";
import { currentPayload } from "./current";
import { ask } from "./peon";
import { say } from "./voice";
import type { ComposeResult, PlanRow } from "./types";

export type Preview = { action: string; rows: PlanRow[]; sure: boolean; button: string } | null;
export type Plan = { action: string; summary: string | null; rows: PlanRow[]; button: string };
export type Answer = ComposeResult & { kind: "answer" };

/** `line` is what is typed (or being said). `open` replaces the composer with the session. */
export function useComposer(
  line: string,
  open: (sessionId: string) => void = (id) => router.replace(`/session/${id}`),
) {
  const [preview, setPreview] = useState<Preview>(null);
  const [plan, setPlan] = useState<Plan | null>(null);
  const [answer, setAnswer] = useState<Answer | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // The rule reading follows along.
  useEffect(() => {
    if (!line.trim()) return;
    const t = setTimeout(() => {
      ask<{ preview: Preview }>("compose:preview", { text: line })
        .then((r) => setPreview(r.preview))
        .catch(() => {});
    }, 150);
    return () => clearTimeout(t);
  }, [line]);

  function finish(result: ComposeResult) {
    say(result.spoken);
    if (result.kind === "navigate") open(result.session_id);
    else if (result.kind === "answer") setAnswer(result);
    else setNote(result.message);
  }

  async function submit(value = line) {
    if (!value.trim()) return;
    setBusy(true);
    setError(null);
    setNote(null);
    setAnswer(null);
    try {
      const r = plan
        ? await ask<{ result: ComposeResult }>("compose:confirm", {}, 60000)
        : await ask<{ plan?: Plan; result?: ComposeResult }>(
            "compose:submit",
            // The page on screen, so "new session here" or "send this to this session" work.
            {
              text: value,
              current: currentPayload(),
            },
            60000,
          );
      if ("plan" in r && r.plan) {
        setPlan(r.plan);
        say(`${r.plan.summary ?? ""} Press ${r.plan.button} to go.`);
      } else if (r.result) {
        setPlan(null);
        finish(r.result);
      }
    } catch (e: any) {
      setError(e.message);
    }
    setBusy(false);
  }

  /** Call when the line is edited by hand: a plan read from the old line no longer holds. */
  const edited = () => setPlan(null);

  const reset = () => {
    setPlan(null);
    setAnswer(null);
    setNote(null);
    setError(null);
  };

  const shown = line.trim() ? preview : null;
  // The rules aren't sure what the line means: Enter has the model read it.
  const unsure = !plan && !answer && shown != null && !shown.sure;
  return {
    rows: plan?.rows ?? (unsure ? [] : (shown?.rows ?? [])),
    button: plan?.button ?? (unsure ? "Understand" : (shown?.button ?? "Go")),
    unsure,
    plan,
    answer,
    note,
    busy,
    error,
    submit,
    edited,
    reset,
  };
}
