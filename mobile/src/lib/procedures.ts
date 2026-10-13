// Procedures (.peon/procedures/<name>.md, see Beamcode.Procedures) and how
// one's result starts the next: run-links ([Send refund](run:refund?charge=ch_1&amount=299))
// become buttons, and each row's outcome comes from the transcript.

import type { Message, Perm, Run } from "./types";

export type ProcedureInput = {
  name: string;
  default: string | string[];
  options: string[];
  multi: boolean;
  type?: string;
  currency?: string | null;
  /** How far back a `default: last_run` input may go: "4d". */
  max?: string | null;
};

/** Where a `last_run` input starts now: `value` (ISO), the last good run's start, and whether `max` cut it. */
export type Since = { value: string; last: string | null; capped: boolean; max: string };

export type ProcedureStep = {
  name: string;
  /** prompt: a message to a model; run: other procedures; queue: tickets; call: a connector, no model; wait: only waits. */
  kind: "prompt" | "run" | "queue" | "call" | "wait";
  prompt: string | null;
  model: string | null;
  model_label: string | null;
  effort: string | null;
  session: "same" | "fresh";
  wait: boolean;
  uses: string[];
  hand_over: string[];
  offers: string | null;
  skill: string | null;
  run: string | null;
  for_each: string | null;
  returns: string | null;
  on_fail: "stop" | "continue";
  queue: string | null;
  title: string | null;
  call: string | null;
  params: Record<string, string>;
  confirm: string | null;
  on_changes: { back_to: string | null; max: number } | null;
};

export type Procedure = {
  name: string;
  description: string;
  inputs: ProcedureInput[];
  /** The input that identifies what it acts on (a charge id), so a row can't run twice. */
  key: string | null;
  /** folder: its own file; global: from setup, in every Project; legacy: a skill from before files. */
  source?: "folder" | "global" | "legacy";
  path?: string | null;
  /** A Project file that replaces a global one with its name. */
  overrides?: boolean;
  /** "default": what the Queue runs a task through. */
  queue?: string | null;
  outputs?: Record<string, string[]>;
  schedule?: {
    at: string;
    tz: string | null;
    when: string | null;
    next: string | null;
    paused: boolean;
  } | null;
  steps?: ProcedureStep[];
  last?: Run | null;
  warnings?: string[];
  /** Per `last_run` input, by name. */
  since?: Record<string, Since>;
};

/** "4d" → "4 days", "12h" → "12 hours", "1d" → "1 day". */
export function spanLabel(span: string): string {
  const m = /^\s*(\d+)\s*([a-z]*)/i.exec(span);
  if (!m) return span;
  const n = Number(m[1]);
  const unit = { d: "day", w: "week", h: "hour", m: "minute" }[(m[2][0] ?? "d").toLowerCase()] ?? "day";
  return `${n} ${unit}${n === 1 ? "" : "s"}`;
}

/** "Mon 12 Oct, 07:00" in the viewer's time. */
export function timeLabel(iso: string): string {
  const t = new Date(iso);
  if (Number.isNaN(t.getTime())) return iso;
  return t.toLocaleString("en-GB", {
    weekday: "short",
    day: "numeric",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
  });
}

/** Whether an input picks up where the last run started. */
export const sinceInput = (i: ProcedureInput) => i.default === "last_run";

/** How a procedure gets started, for the Starts column: /name, its schedule, buttons, the Queue, chains. */
export function starts(p: Procedure, all: Procedure[]) {
  const out: { kind: "slash" | "schedule" | "button" | "queue" | "chain"; label: string }[] = [];
  out.push({ kind: "slash", label: `/${p.name}` });
  if (p.schedule)
    out.push({ kind: "schedule", label: p.schedule.paused ? "Paused" : (p.schedule.when ?? p.schedule.at) });
  for (const o of all) {
    if (o.name === p.name) continue;
    for (const s of o.steps ?? []) {
      if (s.offers === p.name) out.push({ kind: "button", label: `Button in ${o.name}` });
      if (s.run === p.name) out.push({ kind: "chain", label: `Run by ${o.name}` });
      if (s.queue === p.name) out.push({ kind: "queue", label: `Queued by ${o.name}` });
    }
  }
  if (p.queue === "default") out.unshift({ kind: "queue", label: "Queue default" });
  return out.filter((x, i) => out.findIndex((y) => y.label === x.label) === i);
}

export type RunLink = { procedure: string; label: string; values: Record<string, string> };

/** `run:refund?charge=ch_1&amount=299` → the procedure and its values, or null. */
export function parseRunLink(href: string, label = ""): RunLink | null {
  const m = /^run:([\w.-]+)(?:\?(.*))?$/.exec(href.trim());
  if (!m) return null;
  const values: Record<string, string> = {};
  for (const pair of (m[2] ?? "").split("&")) {
    if (!pair) continue;
    const [k, v = ""] = pair.split("=");
    try {
      values[decodeURIComponent(k)] = decodeURIComponent(v.replace(/\+/g, " "));
    } catch {
      values[k] = v;
    }
  }
  return { procedure: m[1], label, values };
}

/** Every run-link in a text. */
export function runLinks(text: string): RunLink[] {
  const out: RunLink[] = [];
  for (const m of text.matchAll(/\[([^\]]+)\]\((run:[^)\s]+)\)/g)) {
    const link = parseRunLink(m[2], m[1]);
    if (link) out.push(link);
  }
  return out;
}

/** "897 NOK" when every link has an amount in one currency, else null. */
export function total(links: RunLink[]): string | null {
  const currency = links[0]?.values.currency;
  if (!currency || links.some((x) => x.values.currency !== currency)) return null;
  const amounts = links.map((x) => (x.values.amount?.trim() ? Number(x.values.amount) : NaN));
  if (amounts.some((n) => !isFinite(n))) return null;
  const sum = amounts.reduce((a, b) => a + b, 0);
  return `${Number.isInteger(sum) ? sum : sum.toFixed(2)} ${currency}`;
}

/** The `peon-status` block, which the app reads and doesn't show. */
export const STATUS_BLOCK = /```peon-status[^\n]*\n([\s\S]*?)(```|$)/g;

export type RowState =
  | { kind: "ready" }
  | { kind: "sent" }
  | { kind: "waiting"; perm: Perm }
  | { kind: "done" | "skipped" | "failed"; note: string };

type Outcome = { status: string; note: string };

/** Which rows have the same identity: the key's value, else all the values. */
const identity = (link: RunLink, key: string | null) =>
  `${link.procedure}\u0000${key && link.values[key] ? link.values[key] : JSON.stringify(link.values)}`;

/**
 * What happened to each row a result offered, read from the chat. A row is
 * sent once a later message ran its procedure with its key; its outcome is the
 * reply's `peon-status` line for that key. A pending approval that names the
 * key, or else the first one for the first row still open, is "waiting".
 * `keys` is each procedure's key input.
 */
export function rowStates(items: Message[], perms: Perm[], keys: Record<string, string | null>) {
  const sent: { procedure: string; text: string; at: number }[] = [];
  const outcomes = new Map<string, Outcome>();
  const offered: RunLink[] = [];

  items.forEach((m, i) => {
    if (m.type === "user") {
      const text = m.text ?? "";
      const slash = /^\/([\w.-]+)/.exec(text)?.[1];
      for (const name of [...(m.skills ?? []).map((s) => s.name), ...(slash ? [slash] : [])])
        sent.push({ procedure: name, text, at: i });
    } else if (m.type === "assistant") {
      for (const p of m.content ?? []) {
        const text = (p as any).type === "text" ? ((p as any).text as string) : "";
        offered.push(...runLinks(text));
        for (const block of text.matchAll(STATUS_BLOCK)) {
          for (const line of block[1].split("\n")) {
            try {
              const j = JSON.parse(line);
              if (j && j.key != null)
                outcomes.set(String(j.key), { status: String(j.status ?? ""), note: String(j.note ?? "") });
            } catch {
              // Not a status line.
            }
          }
        }
      }
    }
  });

  const states = new Map<string, RowState>();
  // Sent rows still open, in the order they were sent: approvals go to the first.
  const open: { id: string; at: number; matches: (t: string) => boolean }[] = [];
  for (const link of offered) {
    const key = keys[link.procedure] ?? null;
    const id = identity(link, key);
    if (states.has(id)) continue;
    const keyValue = key ? link.values[key] : undefined;
    const values = Object.values(link.values).filter(Boolean);
    const matches = (text: string) =>
      keyValue ? text.includes(keyValue) : values.every((v) => text.includes(v));
    const hit = sent.find((s) => s.procedure === link.procedure && matches(s.text));
    if (!hit) {
      states.set(id, { kind: "ready" });
      continue;
    }
    const outcome =
      (keyValue && outcomes.get(keyValue)) || [...outcomes].find(([k]) => values.includes(k))?.[1];
    if (outcome) {
      const s = outcome.status.toLowerCase();
      const kind = /fail|error/.test(s) ? "failed" : /skip|not|refus|already/.test(s) ? "skipped" : "done";
      states.set(id, { kind, note: outcome.note });
    } else {
      states.set(id, { kind: "sent" });
      open.push({ id, at: hit.at * 1e6 + hit.text.indexOf(keyValue ?? values[0] ?? ""), matches });
    }
  }
  open.sort((a, b) => a.at - b.at);
  const left = [...perms];
  for (const row of open) {
    const i = left.findIndex((p) => row.matches(`${p.detail ?? ""} ${p.resources.join(" ")}`));
    if (i >= 0) states.set(row.id, { kind: "waiting", perm: left.splice(i, 1)[0] });
  }
  if (left.length && open.length) {
    const first = open.find((r) => states.get(r.id)?.kind === "sent");
    if (first) states.set(first.id, { kind: "waiting", perm: left[0] });
  }

  return (link: RunLink): RowState =>
    states.get(identity(link, keys[link.procedure] ?? null)) ?? { kind: "ready" };
}
