// A Procedure Folder's chat: chips above the composer that run a procedure
// (with its inputs in a sheet), the Send all sheet, and scheduled results.

import { useState } from "react";
import { ActivityIndicator, ScrollView, StyleSheet, Text, View } from "react-native";
import { router } from "expo-router";
import { Markdown } from "../Markdown";
import { Sheet } from "../Sheet";
import { Button, ErrorLine, Tap } from "../ui";
import { InputFields } from "../project/ProceduresTab";
import { useLoad } from "@/lib/useLoad";
import { total, type Procedure } from "@/lib/procedures";
import { color, font } from "@/lib/theme";
import type { Run } from "@/lib/types";
import type { OfferedRow } from "./RunRows";

/** The Folder's procedures as chips above the composer (P1). */
export function ProcedureChips({
  procedures,
  onPick,
}: {
  procedures: Procedure[];
  onPick: (p: Procedure) => void;
}) {
  if (!procedures.length) return null;
  return (
    <ScrollView
      horizontal
      showsHorizontalScrollIndicator={false}
      style={st.chipRow}
      contentContainerStyle={st.chips}
      keyboardShouldPersistTaps="handled"
    >
      {procedures.map((p) => (
        <Tap key={p.name} onPress={() => onPick(p)} style={st.chip} testID={`chip-${p.name}`}>
          <Text style={st.chipText}>/{p.name}</Text>
        </Tap>
      ))}
    </ScrollView>
  );
}

/** A picked chip: the procedure's inputs as fields, then Run. */
export function ProcedureSheet({
  procedure: p,
  onClose,
  onRun,
}: {
  procedure: Procedure | null;
  onClose: () => void;
  onRun: (p: Procedure, values: Record<string, string | string[]>) => Promise<unknown>;
}) {
  const [values, setValues] = useState<Record<string, string | string[]>>({});
  const [shown, setShown] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  if (p && p.name !== shown) {
    setShown(p.name);
    setValues(Object.fromEntries(p.inputs.map((i) => [i.name, i.default])));
    setError(null);
  }
  async function run() {
    if (!p) return;
    setBusy(true);
    setError(null);
    try {
      await onRun(p, values);
      setShown(null);
      onClose();
    } catch (e: any) {
      setError(e.message);
    }
    setBusy(false);
  }
  return (
    <Sheet visible={p != null} onClose={onClose} title={p ? `/${p.name}` : undefined}>
      {p ? (
        <View style={{ gap: 14 }}>
          {p.description ? <Text style={st.desc}>{p.description}</Text> : null}
          {p.inputs.length ? <InputFields inputs={p.inputs} values={values} onChange={setValues} /> : null}
          <ErrorLine message={error} />
          <Button label="Run" kind="accent" height={46} busy={busy} onPress={run} testID="procedure-run" />
        </View>
      ) : null}
    </Sheet>
  );
}

/**
 * Send all (P4): the count, each row with its key, and the total. Untick a row
 * to skip it. Sends one message that runs the procedure once per row.
 */
export function SendAllSheet({
  rows,
  keyName,
  onClose,
  onSend,
}: {
  rows: OfferedRow[] | null;
  keyName: string | null;
  onClose: () => void;
  onSend: (rows: OfferedRow[]) => Promise<unknown>;
}) {
  const [off, setOff] = useState<Set<number>>(new Set());
  const [shown, setShown] = useState<OfferedRow[] | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  if (rows !== shown) {
    setShown(rows);
    setOff(new Set());
    setError(null);
  }
  const picked = (rows ?? []).filter((_, i) => !off.has(i));
  const sum = total(picked.map((r) => r.link));
  const label = rows?.[0]?.link.label ?? "Run";
  const procedure = rows?.[0]?.link.procedure ?? "";

  async function send() {
    setBusy(true);
    setError(null);
    try {
      await onSend(picked);
      onClose();
    } catch (e: any) {
      setError(e.message);
    }
    setBusy(false);
  }

  return (
    <Sheet visible={rows != null} onClose={onClose}>
      <View style={{ gap: 14 }}>
        <View style={{ gap: 4 }}>
          <Text style={st.sheetTitle}>
            {label} · {picked.length}
          </Text>
          <Text style={st.desc}>
            Runs /{procedure} once per row, in this order, as one message. Each one still asks for your
            approval where its connector does.
          </Text>
        </View>
        <View style={st.list}>
          {(rows ?? []).map((r, i) => {
            const on = !off.has(i);
            const key = keyName ? r.link.values[keyName] : null;
            return (
              <Tap
                key={i}
                onPress={() =>
                  setOff((s) => {
                    const n = new Set(s);
                    if (on) n.add(i);
                    else n.delete(i);
                    return n;
                  })
                }
                style={[st.line, i < rows!.length - 1 && st.lineRule]}
                testID={`send-all-row-${i}`}
              >
                <View style={[st.tick, on && st.tickOn]}>
                  {on ? <Text style={st.tickMark}>✓</Text> : null}
                </View>
                <View style={{ flex: 1, minWidth: 0, gap: 2 }}>
                  <Text style={[st.lineTitle, !on && { color: color.faint }]} numberOfLines={1}>
                    {r.title}
                  </Text>
                  {key ? (
                    <Text style={st.lineKey} numberOfLines={1}>
                      {key}
                    </Text>
                  ) : null}
                </View>
                {r.link.values.amount ? (
                  <Text style={[st.amount, !on && { color: color.faint }]}>{r.link.values.amount}</Text>
                ) : null}
              </Tap>
            );
          })}
        </View>
        {sum ? (
          <View style={st.total}>
            <Text style={{ color: color.textDim, fontSize: 15 }}>Total</Text>
            <Text style={st.totalValue}>{sum}</Text>
          </View>
        ) : null}
        <ErrorLine message={error} />
        <Button
          label={`${label} · ${picked.length}`}
          kind="accent"
          height={50}
          busy={busy}
          disabled={!picked.length}
          onPress={send}
          testID="send-all-confirm"
        />
        <Button label="Cancel" kind="secondary" height={44} onPress={onClose} />
      </View>
    </Sheet>
  );
}

/**
 * A scheduled run's result, shown in the Folder's chat where it finished
 * (change 5): its buttons work here. Show steps opens the run.
 */
export function ScheduledResult({
  run,
  call,
}: {
  run: Run;
  call: <T = any>(event: string, payload?: object, timeout?: number) => Promise<T>;
}) {
  const { data: text, error } = useLoad(
    () => call<{ text: string }>("run_result", { id: run.id }, 60000).then((r) => r.text),
    [run.id, run.status],
  );
  const when = new Date(run.finished ?? run.started).toLocaleString("en-GB", {
    weekday: "short",
    hour: "2-digit",
    minute: "2-digit",
  });
  return (
    <View style={{ gap: 10 }} testID={`scheduled-${run.id}`}>
      <View style={st.schedHead}>
        <Text style={st.schedBadge}>Scheduled</Text>
        <Text style={st.schedMeta} numberOfLines={1}>
          /{run.procedure ?? run.schedule_key} · {when}
        </Text>
        <Tap onPress={() => run.session_id && router.push(`/session/${run.session_id}`)} hitSlop={8}>
          <Text style={st.steps}>Show steps</Text>
        </Tap>
      </View>
      {run.status === "failed" ? <ErrorLine message={run.error ?? "The run failed."} /> : null}
      <ErrorLine message={error} />
      {text == null && !error ? (
        <ActivityIndicator size="small" color={color.muted} style={{ alignSelf: "flex-start" }} />
      ) : text ? (
        <Markdown text={text} />
      ) : null}
    </View>
  );
}

const st = StyleSheet.create({
  // A short horizontal list would otherwise stretch to the chat's height on the web.
  chipRow: { flexGrow: 0, flexShrink: 0 },
  chips: { gap: 6, paddingHorizontal: 12, paddingBottom: 8, alignItems: "center" },
  chip: { paddingHorizontal: 10, paddingVertical: 5, borderRadius: 14, backgroundColor: color.field },
  chipText: { fontFamily: font.mono, fontSize: 12, color: color.textSoft },
  desc: { fontSize: 13, lineHeight: 19, color: color.textDim },
  sheetTitle: { fontFamily: font.brand, fontSize: 22, letterSpacing: -0.4, color: color.text },
  list: { borderRadius: 12, backgroundColor: "#17171c", borderWidth: 1, borderColor: color.border },
  line: { flexDirection: "row", alignItems: "center", gap: 10, paddingHorizontal: 12, paddingVertical: 11 },
  lineRule: { borderBottomWidth: 1, borderBottomColor: color.divider },
  tick: {
    width: 20,
    height: 20,
    borderRadius: 6,
    borderWidth: 1,
    borderColor: color.outline,
    alignItems: "center",
    justifyContent: "center",
  },
  tickOn: { backgroundColor: color.accent, borderColor: color.accent },
  tickMark: { fontSize: 12, fontWeight: "700", color: color.accentInk },
  lineTitle: { fontSize: 15, color: color.text },
  lineKey: { fontFamily: font.mono, fontSize: 11, color: color.faint },
  amount: { fontSize: 15, color: color.text, fontVariant: ["tabular-nums"] },
  total: { flexDirection: "row", justifyContent: "space-between", paddingHorizontal: 2 },
  totalValue: { fontSize: 15, fontWeight: "600", color: color.text, fontVariant: ["tabular-nums"] },
  schedHead: { flexDirection: "row", alignItems: "center", gap: 8 },
  schedBadge: {
    paddingHorizontal: 7,
    paddingVertical: 2,
    borderRadius: 5,
    overflow: "hidden",
    backgroundColor: "#14262a",
    color: color.teal,
    fontSize: 12,
  },
  schedMeta: { flex: 1, fontSize: 12, color: color.faint },
  steps: { fontSize: 12, color: color.accentText },
});
