// Procedures in a Procedure Folder, and how one's result starts the next:
// run-links ([Send refund](run:refund?charge=ch_1&amount=299)) become buttons,
// and each row's outcome comes from the transcript (see Beamcode.Routines).

import type { Message, Perm } from "./types";

export type ProcedureInput = { name: string; default: string | string[]; options: string[]; multi: boolean };

export type Procedure = {
  name: string;
  description: string;
  inputs: ProcedureInput[];
  /** The input that identifies what it acts on (a charge id), so a row can't run twice. */
  key: string | null;
};

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
