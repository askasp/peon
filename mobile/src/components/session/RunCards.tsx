// A procedure run in its chat (R3, C2): a divider where each step starts
// ("2 Build · Sonnet · medium · same session"), what a fresh step or a chain's
// child run said, and the card that waits for you.

import { useState } from "react";
import { ActivityIndicator, StyleSheet, Text, TextInput, View } from "react-native";
import { router } from "expo-router";
import { Markdown } from "../Markdown";
import { Button, ErrorLine, Tap } from "../ui";
import { color, font } from "@/lib/theme";
import type { Message, Run, RunStep } from "@/lib/types";

type Call = <T = any>(event: string, payload?: object, timeout?: number) => Promise<T>;

/** A timeline mark for a run: a step starting, or the wait at its end. */
export type RunMark =
  | { kind: "step"; key: string; run: Run; index: number; children: Run[] }
  | { kind: "wait"; key: string; run: Run; children: Run[] };

/**
 * Where a chat's runs show: each step's divider when it started (a run of one
 * step in the chat itself needs none), and the wait card last (a failed run's where it stopped).
 */
export function runMarks(runs: Run[], chat: string): { at: number; mark: RunMark }[] {
  const out: { at: number; mark: RunMark }[] = [];
  const top = runs.filter((r) => !r.parent_id && r.session_id === chat && (r.steps?.length ?? 0) > 0);
  for (const r of top) {
    const children = runs.filter((c) => c.parent_id === r.id);
    const steps = r.steps ?? [];
    const plain = steps.length === 1 && steps[0].session_id === chat && !steps[0].children;
    if (!plain)
      steps.forEach((s, i) => {
        if (!s.started && !(s.status === "waiting" || s.status === "skipped")) return;
        const at = s.started ? Date.parse(s.started) : Date.parse(r.started);
        out.push({
          at,
          mark: { kind: "step", key: `run-${r.id}-${i}-${s.started ?? ""}`, run: r, index: i, children },
        });
      });
    // A wait stays last; a failed run's card shows where it stopped, before what was asked after.
    if (r.status === "waiting" || r.status === "failed")
      out.push({
        at:
          r.status === "failed" && r.finished && Number.isFinite(Date.parse(r.finished))
            ? Date.parse(r.finished)
            : Number.MAX_SAFE_INTEGER - r.id,
        mark: { kind: "wait", key: `wait-${r.id}`, run: r, children },
      });
  }
  return out.sort((a, b) => a.at - b.at);
}

/** Messages and run marks in time order (`partial`: earlier messages not loaded, so marks before them are left out). */
export function withMarks<B, M>(
  items: Message[],
  marks: { at: number; mark: M }[],
  partial: boolean,
  toBlocks: (m: Message[]) => B[],
): (B | M)[] {
  const first = items[0]?.time?.created ?? 0;
  const shown = marks.filter((m) => !partial || m.at >= first).sort((a, b) => a.at - b.at);
  const out: (B | M)[] = [];
  let start = 0;
  for (const m of shown) {
    let i = start;
    while (i < items.length && (items[i].time?.created ?? 0) <= m.at) i++;
    out.push(...toBlocks(items.slice(start, i)), m.mark);
    start = i;
  }
  out.push(...toBlocks(items.slice(start)));
  return out;
}

export function RunMarkView({ mark, chat, call }: { mark: RunMark; chat: string; call: Call }) {
  return mark.kind === "step" ? (
    <StepMark run={mark.run} index={mark.index} childRuns={mark.children} chat={chat} />
  ) : (
    <WaitCard run={mark.run} call={call} />
  );
}

function StepMark({
  run,
  index,
  childRuns,
  chat,
}: {
  run: Run;
  index: number;
  childRuns: Run[];
  chat: string;
}) {
  const s = (run.steps ?? [])[index];
  const many = (run.steps?.length ?? 0) > 1;
  const fresh = s.session_id && s.session_id !== chat;
  const mine = childRuns.filter((c) => (s.children ?? []).includes(c.id));
  return (
    <View style={st.mark} testID={`step-${run.id}-${index}`}>
      <View style={st.divider}>
        {many ? <Text style={st.no}>{index + 1}</Text> : null}
        <Text style={st.name}>{many ? s.name : run.procedure}</Text>
        {s.model ? <Text style={[st.model, tint(s.model)]}>{s.model}</Text> : null}
        <Text style={st.meta}>
          {[
            s.effort,
            s.session_id ? (fresh ? "fresh session" : "same session") : null,
            (s.loops ?? 0) > 0 ? `round ${(s.loops ?? 0) + 1}` : null,
          ]
            .filter(Boolean)
            .join(" · ")}
        </Text>
        <View style={st.rule} />
        <StatusDot status={s.status} />
      </View>
      {mine.length || s.children ? (
        <View style={st.children}>
          {mine.map((c, i) => (
            <ChildRow key={c.id} run={c} last={i === mine.length - 1} />
          ))}
          {s.status === "running" && !mine.length ? (
            <ActivityIndicator size="small" color={color.muted} />
          ) : null}
        </View>
      ) : fresh && s.text ? (
        <View style={st.result}>
          <Markdown text={s.text} />
          <Tap onPress={() => router.push(`/session/${s.session_id}`)} hitSlop={8}>
            <Text style={st.link}>Show steps</Text>
          </Tap>
        </View>
      ) : fresh && s.status === "running" ? (
        <Tap onPress={() => router.push(`/session/${s.session_id}`)} style={st.working} hitSlop={8}>
          <ActivityIndicator size="small" color={color.muted} />
          <Text style={st.meta}>Working in a fresh session · watch it</Text>
        </Tap>
      ) : !s.session_id && s.text ? (
        <Text style={st.callText}>{s.text}</Text>
      ) : null}
      {s.status === "failed" && s.error ? <ErrorLine message={s.error} /> : null}
    </View>
  );
}

/** A child run in a chain's step: ✓ / ● / ✕, what it said, Open. */
function ChildRow({ run: c, last }: { run: Run; last: boolean }) {
  const label = [
    c.procedure,
    ...Object.entries(c.inputs ?? {})
      .filter(([k]) => ["name", "charge", "amount", "test"].includes(k))
      .map(([, v]) => String(v)),
  ].join(" · ");
  return (
    <Tap
      onPress={() => c.session_id && router.push(`/session/${c.session_id}`)}
      style={[st.child, !last && st.childRule]}
      testID={`child-${c.id}`}
    >
      <StatusDot status={c.status} />
      <View style={{ flex: 1, minWidth: 0, gap: 2 }}>
        <Text style={st.childName} numberOfLines={1}>
          {label}
        </Text>
        {c.summary || c.error ? (
          <Text style={[st.meta, c.error && { color: color.red }]} numberOfLines={2}>
            {c.error ?? c.summary}
          </Text>
        ) : null}
      </View>
      {c.session_id ? <Text style={st.meta}>Open</Text> : null}
    </Tap>
  );
}

function StatusDot({ status }: { status: RunStep["status"] }) {
  const [glyph, tintColor] =
    status === "done"
      ? ["✓", color.accentText]
      : status === "failed"
        ? ["✕", color.red]
        : status === "partial"
          ? ["✓", color.needs]
          : status === "skipped"
            ? ["–", color.faint]
            : status === "running"
              ? ["●", color.textSoft]
              : status === "waiting"
                ? ["●", color.needs]
                : ["○", color.ghost];
  return <Text style={[st.dot, { color: tintColor }]}>{glyph}</Text>;
}

/**
 * What a run waits for (C2, R3): a batch to confirm (Send all, Pick, Skip), a
 * step's work to read (go on, or send it back with a note), or review rounds
 * used up. A failed run shows why, with Stop gone.
 */
function WaitCard({ run, call }: { run: Run; call: Call }) {
  const w = run.waiting;
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [picking, setPicking] = useState(false);
  const [off, setOff] = useState<Set<number>>(new Set());
  const [note, setNote] = useState<string | null>(null);

  async function act(what: string, event: string, payload: object = {}) {
    setBusy(what);
    setError(null);
    try {
      await call(event, { id: run.id, ...payload }, 60000);
    } catch (e: any) {
      setError(e.message);
    }
    setBusy(null);
  }

  if (run.status === "failed")
    return (
      <View style={[st.wait, st.failed]} testID={`run-failed-${run.id}`}>
        <Text style={st.waitTitle}>{run.procedure} stopped</Text>
        <Text style={st.meta}>{run.error}</Text>
      </View>
    );
  if (!w) return null;

  const items = w.items ?? [];
  const picked = items.filter((_, i) => !off.has(i));
  const sum = totalOf(picked);
  const step = run.steps?.[w.step]?.name ?? "This step";

  return (
    <View style={st.wait} testID={`run-wait-${run.id}`}>
      <View style={{ flexDirection: "row", alignItems: "center", gap: 8 }}>
        <Text style={st.waitTitle}>{w.text}</Text>
        <View style={{ flex: 1 }} />
        <Text style={st.waitWho}>{run.procedure} · waiting for you</Text>
      </View>
      {items.length ? (
        <View style={st.items}>
          {items.map((it, i) => {
            const on = !off.has(i);
            return (
              <Tap
                key={i}
                disabled={!picking}
                onPress={() =>
                  setOff((s) => {
                    const n = new Set(s);
                    if (on) n.add(i);
                    else n.delete(i);
                    return n;
                  })
                }
                style={[st.item, i < items.length - 1 && st.itemRule]}
                testID={`wait-item-${i}`}
              >
                {picking ? (
                  <View style={[st.tick, on && st.tickOn]}>
                    {on ? <Text style={st.tickMark}>✓</Text> : null}
                  </View>
                ) : null}
                <Text style={[st.itemName, !on && { color: color.faint }]} numberOfLines={1}>
                  {String(it.name ?? it.title ?? it.test ?? it.charge ?? it.item ?? `Item ${i + 1}`)}
                </Text>
                <Text style={st.itemMeta} numberOfLines={1}>
                  {[
                    it.amount != null ? `${it.amount}${it.currency ? ` ${it.currency}` : ""}` : null,
                    it.charge,
                  ]
                    .filter(Boolean)
                    .join(" · ")}
                </Text>
              </Tap>
            );
          })}
        </View>
      ) : null}
      {note != null ? (
        <View style={{ gap: 8 }}>
          <TextInput
            value={note}
            onChangeText={setNote}
            multiline
            autoFocus
            placeholder={`What should ${w.back ?? "it"} change?`}
            placeholderTextColor={color.faint}
            style={st.noteBox}
            testID="run-back-note"
          />
          <View style={st.buttons}>
            <Button
              label={`Send back to ${w.back}`}
              height={34}
              busy={busy === "back"}
              disabled={!note.trim()}
              onPress={() => act("back", "run_back", { note }).then(() => setNote(null))}
              testID="run-back-send"
            />
            <Tap onPress={() => setNote(null)} hitSlop={8}>
              <Text style={st.meta}>Cancel</Text>
            </Tap>
          </View>
        </View>
      ) : (
        <View style={st.buttons}>
          {w.kind === "before" ? (
            <Button
              label={
                items.length ? `${picking ? "Send" : "Send"} ${picked.length}${sum ? ` · ${sum}` : ""}` : step
              }
              height={34}
              busy={busy === "go"}
              disabled={items.length > 0 && !picked.length}
              onPress={() => act("go", "run_continue", items.length && off.size ? { items: picked } : {})}
              testID="run-continue"
            />
          ) : (
            <Button
              label={w.kind === "changes" ? "Go on anyway" : w.next ? `Go on to ${w.next}` : "Done"}
              height={34}
              busy={busy === "go"}
              onPress={() => act("go", "run_continue")}
              testID="run-continue"
            />
          )}
          {items.length > 1 && !picking ? (
            <Button
              label="Pick"
              kind="secondary"
              height={34}
              onPress={() => setPicking(true)}
              testID="run-pick"
            />
          ) : null}
          {w.back && w.kind !== "before" ? (
            <Button
              label={`Send back to ${w.back}`}
              kind="secondary"
              height={34}
              onPress={() => setNote("")}
              testID="run-back"
            />
          ) : null}
          {w.kind === "before" ? (
            <Tap onPress={() => act("skip", "run_skip")} hitSlop={8} testID="run-skip">
              <Text style={st.meta}>Skip</Text>
            </Tap>
          ) : null}
          <View style={{ flex: 1 }} />
          <Tap onPress={() => act("stop", "run_stop")} hitSlop={8} testID="run-stop">
            <Text style={st.meta}>Stop</Text>
          </Tap>
        </View>
      )}
      {w.kind !== "before" && w.back && note == null ? (
        <Text style={st.hint}>Or reply below to send it back to {w.back} with a note.</Text>
      ) : null}
      <ErrorLine message={error} />
    </View>
  );
}

/** "897 NOK" when every item has an amount in one currency. */
function totalOf(items: Record<string, any>[]) {
  const amounts = items.map((x) => Number(x.amount));
  if (!items.length || amounts.some((n) => !isFinite(n))) return null;
  const currencies = [...new Set(items.map((x) => x.currency).filter(Boolean))];
  const sum = amounts.reduce((a, b) => a + b, 0);
  return [Number.isInteger(sum) ? sum : sum.toFixed(2), currencies.length === 1 ? currencies[0] : null]
    .filter((x) => x != null)
    .join(" ");
}

function tint(model: string) {
  const m = model.toLowerCase();
  if (m.includes("opus")) return { backgroundColor: "#2a2014", color: "#e0b77a" };
  if (m.includes("sonnet")) return { backgroundColor: color.accentWash, color: color.accentText };
  if (m.includes("haiku")) return { backgroundColor: "#221a2a", color: "#c4a6e0" };
  if (m.includes("gpt") || m.includes("codex")) return { backgroundColor: "#14262a", color: color.teal };
  return { backgroundColor: color.field, color: color.textSoft };
}

const st = StyleSheet.create({
  mark: { gap: 10, paddingTop: 6, paddingBottom: 4 },
  divider: { flexDirection: "row", alignItems: "center", gap: 8 },
  no: { fontFamily: font.mono, fontSize: 12, color: color.faint },
  name: { fontSize: 12, fontWeight: "600", color: color.text },
  model: {
    paddingHorizontal: 6,
    paddingVertical: 1,
    borderRadius: 4,
    overflow: "hidden",
    fontFamily: font.mono,
    fontSize: 11,
  },
  meta: { fontSize: 12, color: color.muted },
  rule: { flex: 1, height: 1, backgroundColor: color.divider },
  dot: { fontSize: 12, width: 14, textAlign: "center" },
  result: {
    gap: 6,
    paddingHorizontal: 14,
    paddingVertical: 12,
    borderRadius: 10,
    backgroundColor: "#17171c",
    borderWidth: 1,
    borderColor: color.border,
  },
  link: { fontSize: 12, color: color.accentText },
  working: { flexDirection: "row", alignItems: "center", gap: 8 },
  callText: { fontSize: 13, color: color.textSoft },
  children: { borderRadius: 12, backgroundColor: "#17171c", borderWidth: 1, borderColor: color.border },
  child: { flexDirection: "row", alignItems: "center", gap: 10, paddingHorizontal: 14, paddingVertical: 11 },
  childRule: { borderBottomWidth: 1, borderBottomColor: color.divider },
  childName: { fontFamily: font.mono, fontSize: 13, color: color.text },
  wait: {
    gap: 10,
    padding: 14,
    borderRadius: 10,
    backgroundColor: color.needsCard,
    borderWidth: 1,
    borderColor: color.needsBorder,
    marginVertical: 6,
  },
  failed: { backgroundColor: "#1f1414", borderColor: "#4a2424" },
  waitTitle: { fontSize: 14, lineHeight: 20, color: color.text, flexShrink: 1 },
  waitWho: { fontSize: 12, color: color.needs },
  items: { borderTopWidth: 1, borderTopColor: "#3a2a1e" },
  item: { flexDirection: "row", alignItems: "center", gap: 10, paddingVertical: 7 },
  itemRule: { borderBottomWidth: 1, borderBottomColor: "#2e2218" },
  itemName: { flex: 1, fontSize: 13, color: color.text },
  itemMeta: { fontSize: 13, color: color.textDim },
  tick: {
    width: 18,
    height: 18,
    borderRadius: 5,
    borderWidth: 1,
    borderColor: color.outline,
    alignItems: "center",
    justifyContent: "center",
  },
  tickOn: { backgroundColor: color.accent, borderColor: color.accent },
  tickMark: { fontSize: 11, fontWeight: "700", color: color.accentInk },
  buttons: { flexDirection: "row", alignItems: "center", gap: 8, flexWrap: "wrap" },
  noteBox: {
    minHeight: 60,
    borderRadius: 8,
    backgroundColor: "#121216",
    borderWidth: 1,
    borderColor: color.needsBorder,
    padding: 10,
    color: color.text,
    fontSize: 13,
    textAlignVertical: "top",
    outlineStyle: "none",
  } as any,
  hint: { fontSize: 12, color: color.faint },
});
