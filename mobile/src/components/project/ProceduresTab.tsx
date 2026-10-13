import { useState } from "react";
import { ScrollView, StyleSheet, Text, TextInput, View } from "react-native";
import { router } from "expo-router";
import { Sheet } from "../Sheet";
import { Button, ErrorLine, Tap } from "../ui";
import { ProcedureDetail } from "./ProcedureDetail";
import { useLoad } from "@/lib/useLoad";
import { useWide } from "@/lib/useWide";
import { ago } from "@/lib/time";
import { singleChat } from "@/lib/folders";
import { color, font } from "@/lib/theme";
import {
  sinceInput,
  spanLabel,
  starts,
  timeLabel,
  type Procedure,
  type ProcedureInput,
  type Since,
} from "@/lib/procedures";
import type { Run, Schedule } from "@/lib/types";
import type { ProjectCtx } from "./types";

type Values = Record<string, string | string[]>;

/** The procedure a schedule runs: its own, the one its prompt names, or the Project's first. */
export function scheduleProcedure(s: Schedule, procedures: Procedure[]) {
  const named = s.procedure || /^\/([\w.-]+)/.exec(s.prompt ?? "")?.[1];
  return named ?? (s.prompt?.trim() ? null : (procedures[0]?.name ?? null));
}

/**
 * A Project's procedures (U1, U2): one row each with how it starts, its steps
 * and its last run; a row opens its steps (U3, U4). Below, the notes a step
 * can be handed and New procedure.
 */
export function ProceduresTab({
  ctx,
  onRan,
  onOpenChat,
}: {
  ctx: ProjectCtx;
  onRan?: () => void;
  /** An Operations Project: a row opens the procedure's chat, New procedure an empty one. */
  onOpenChat?: (name: string | null) => void;
}) {
  const wide = useWide();
  const [open, setOpen] = useState<string | null>(null);
  const [drafting, setDrafting] = useState(false);
  const { data: notes } = useLoad(
    () => ctx.call<{ notes: string[] }>("procedures", {}, 30000).then((r) => r.notes ?? []),
    [ctx.project.id],
  );
  const { data: runs } = useLoad(() => ctx.call<{ runs: Run[] }>("runs").then((r) => r.runs), [ctx.changed]);
  const single = singleChat(ctx.project.kind);

  // Where a started run shows: the Project's chat, or the new chat it made.
  const ran = (sessionId: string | null | undefined) => {
    if (single) onRan?.();
    else if (sessionId) router.push(`/session/${sessionId}`);
  };

  const shown = ctx.procedures.find((p) => p.name === open);
  if (shown)
    return (
      <ProcedureDetail
        ctx={ctx}
        procedure={shown}
        runs={(runs ?? []).filter((r) => r.procedure === shown.name)}
        onBack={() => setOpen(null)}
        onOpen={setOpen}
        onRan={ran}
      />
    );

  return (
    <ScrollView contentContainerStyle={[st.body, wide && { paddingHorizontal: 28 }]}>
      <ErrorLine message={ctx.proceduresError} />
      {ctx.procedures.length ? (
        <View>
          {wide ? (
            <View style={[st.row, st.headRow]}>
              <Text style={[st.head, st.colName]}>Procedure</Text>
              <Text style={[st.head, st.colStarts]}>Starts</Text>
              <Text style={[st.head, st.colSteps]}>Steps</Text>
              <Text style={[st.head, st.colLast]}>Last run</Text>
            </View>
          ) : null}
          {ctx.procedures.map((p) => (
            <ProcedureRow
              key={p.name}
              p={p}
              all={ctx.procedures}
              wide={wide}
              onPress={() => (onOpenChat && p.source === "folder" ? onOpenChat(p.name) : setOpen(p.name))}
            />
          ))}
        </View>
      ) : (
        <Text style={st.empty}>
          {onOpenChat
            ? "No procedures yet."
            : "No procedures yet. A procedure is a file in .peon/procedures/; New procedure drafts one with you in the chat."}
        </Text>
      )}

      <View style={st.foot}>
        {notes?.length ? <Text style={st.footLabel}>Project notes</Text> : null}
        {(notes ?? []).map((n) => (
          <Text key={n} style={st.note}>
            {n}
          </Text>
        ))}
        <View style={{ flex: 1 }} />
        {ctx.canEdit ? (
          <Tap
            onPress={() => (onOpenChat ? onOpenChat(null) : setDrafting(true))}
            hitSlop={8}
            testID="new-procedure"
          >
            <Text style={st.link}>New procedure</Text>
          </Tap>
        ) : null}
      </View>

      <NewProcedureSheet
        visible={drafting}
        onClose={() => setDrafting(false)}
        onDraft={async (description) => {
          const r = await ctx.call<{ session_id: string }>("draft_procedure", { description }, 60000);
          setDrafting(false);
          ran(r.session_id);
        }}
      />
    </ScrollView>
  );
}

function ProcedureRow({
  p,
  all,
  wide,
  onPress,
}: {
  p: Procedure;
  all: Procedure[];
  wide: boolean;
  onPress: () => void;
}) {
  const chips = starts(p, all);
  const steps = p.steps?.length ?? 1;
  const last = lastLine(p.last ?? null);
  const startChips = (
    <View style={st.chips}>
      {chips.map((c) => (
        <Text key={c.label} style={[st.chip, chipStyle[c.kind]]}>
          {c.label}
        </Text>
      ))}
    </View>
  );
  return (
    <Tap kb="row" onPress={onPress} style={[st.row, !wide && st.rowPhone]} testID={`procedure-${p.name}`}>
      {wide ? (
        <>
          <Text style={[st.name, st.colName]} numberOfLines={1}>
            {p.name}
          </Text>
          <View style={st.colStarts}>{startChips}</View>
          <Text style={[st.cell, st.colSteps]}>{steps}</Text>
          <Text style={[st.lastText, st.colLast, last.tint && { color: last.tint }]} numberOfLines={1}>
            {last.text}
          </Text>
        </>
      ) : (
        <View style={{ flex: 1, gap: 6 }}>
          <View style={{ flexDirection: "row", alignItems: "baseline", gap: 8 }}>
            <Text style={st.name} numberOfLines={1}>
              {p.name}
            </Text>
            <Text style={st.lastText}>
              {steps} step{steps === 1 ? "" : "s"}
            </Text>
          </View>
          {startChips}
          {last.text ? (
            <Text style={[st.lastText, last.tint && { color: last.tint }]} numberOfLines={1}>
              {last.text}
            </Text>
          ) : null}
        </View>
      )}
    </Tap>
  );
}

/** "Mon · 3 to send", "am-5c11 · needs you", "10:12 · refunded". */
export function lastLine(run: Run | null): { text: string; tint?: string } {
  if (!run) return { text: "" };
  const when = ago(run.finished ?? run.started, true);
  if (run.status === "waiting") return { text: `${run.ticket ?? when} · needs you`, tint: color.needs };
  if (run.status === "running") return { text: `${run.ticket ?? when} · running`, tint: color.accentText };
  if (run.status === "failed") return { text: `${when} · ${run.error ?? "failed"}`, tint: color.red };
  return { text: [when, run.summary].filter(Boolean).join(" · ") };
}

const chipStyle = StyleSheet.create({
  slash: { backgroundColor: color.field, fontFamily: font.mono },
  schedule: { backgroundColor: "#14262a", color: color.teal },
  button: { borderWidth: 1, borderColor: "#2c2c34", color: color.textSoft },
  chain: { borderWidth: 1, borderColor: "#2c2c34", color: color.textSoft },
  queue: { backgroundColor: color.accentWash, color: color.accentText },
});

/** New procedure: say what it does; the chat drafts the file with you. */
function NewProcedureSheet({
  visible,
  onClose,
  onDraft,
}: {
  visible: boolean;
  onClose: () => void;
  onDraft: (description: string) => Promise<void>;
}) {
  const [text, setText] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  async function draft() {
    setBusy(true);
    setError(null);
    try {
      await onDraft(text);
      setText("");
    } catch (e: any) {
      setError(e.message);
    }
    setBusy(false);
  }
  return (
    <Sheet visible={visible} onClose={onClose} title="New procedure">
      <View style={{ gap: 12 }}>
        <Text style={st.desc}>
          Say what it should do. The chat writes the file with you, and asks what it needs.
        </Text>
        <TextInput
          value={text}
          onChangeText={setText}
          multiline
          placeholder="Every Monday, read support mail and list who should get a refund"
          placeholderTextColor={color.faint}
          style={st.area}
          testID="new-procedure-text"
        />
        <ErrorLine message={error} />
        <Button
          label="Draft it"
          kind="accent"
          height={46}
          busy={busy}
          disabled={!text.trim()}
          onPress={draft}
        />
      </View>
    </Sheet>
  );
}

/** A procedure's inputs: chips for choices, fields for the rest. */
export function InputFields({
  inputs,
  values,
  onChange,
  since,
}: {
  inputs: ProcedureInput[];
  values: Values;
  onChange: (v: Values) => void;
  /** Where each `last_run` input starts now (from the server). */
  since?: Record<string, Since>;
}) {
  const choose = (input: ProcedureInput, option: string) => {
    if (!input.multi) return onChange({ ...values, [input.name]: option });
    const list = Array.isArray(values[input.name]) ? (values[input.name] as string[]) : [];
    onChange({
      ...values,
      [input.name]: list.includes(option) ? list.filter((o) => o !== option) : [...list, option],
    });
  };
  return (
    <View style={{ gap: 8 }}>
      {inputs.map((input) => (
        <View key={input.name} style={st.input}>
          <Text style={st.inputName}>
            {input.name}
            {input.currency ? ` · ${input.currency}` : ""}
          </Text>
          {sinceInput(input) ? (
            <SinceField
              input={input}
              since={since?.[input.name]}
              value={String(values[input.name] ?? "")}
              onChange={(t) => onChange({ ...values, [input.name]: t })}
            />
          ) : input.options.length ? (
            <View style={st.options}>
              {input.options.map((o) => {
                const v = values[input.name];
                const on = Array.isArray(v) ? v.includes(o) : v === o;
                return (
                  <Tap key={o} onPress={() => choose(input, o)} style={[st.option, on && st.optionOn]}>
                    <Text style={[st.optionText, on && { color: color.textStrong }]}>{o}</Text>
                  </Tap>
                );
              })}
            </View>
          ) : (
            <TextInput
              value={String(values[input.name] ?? "")}
              onChangeText={(t) => onChange({ ...values, [input.name]: t })}
              style={st.field}
              placeholderTextColor={color.faint}
              testID={`input-${input.name}`}
            />
          )}
        </View>
      ))}
    </View>
  );
}

/**
 * A `default: last_run` input: chips for the last run, one day and its max,
 * a field for a date, and a line saying where the run will start.
 */
function SinceField({
  input,
  since,
  value,
  onChange,
}: {
  input: ProcedureInput;
  since?: Since;
  value: string;
  onChange: (v: string) => void;
}) {
  const max = input.max ?? since?.max ?? "7d";
  const spans = Array.from(new Set(["1d", max]));
  const chips = [{ label: "Last run", value: "" }, ...spans.map((s) => ({ label: spanLabel(s), value: s }))];
  const typed = value !== "" && !spans.includes(value);
  const hint = typed
    ? "A date like 2026-10-10, or a span like 12h."
    : value
      ? `The last ${spanLabel(value)}.`
      : !since
        ? `Since the last run, at most ${spanLabel(max)} back.`
        : !since.last
          ? `No run yet · from ${timeLabel(since.value)} (${spanLabel(max)} back).`
          : since.capped
            ? `Last run was ${ago(since.last, true)} · reading only ${spanLabel(max)}, from ${timeLabel(since.value)}.`
            : `From ${timeLabel(since.value)}, when the last run started.`;
  return (
    <View style={{ gap: 6 }}>
      <View style={st.options}>
        {chips.map((c) => {
          const on = value === c.value;
          return (
            <Tap
              key={c.label}
              onPress={() => onChange(c.value)}
              style={[st.option, on && st.optionOn]}
              testID={`since-${input.name}-${c.value || "last"}`}
            >
              <Text style={[st.optionText, on && { color: color.textStrong }]}>{c.label}</Text>
            </Tap>
          );
        })}
      </View>
      <TextInput
        value={typed ? value : ""}
        onChangeText={onChange}
        placeholder="or a date: 2026-10-10"
        style={st.field}
        placeholderTextColor={color.faint}
        testID={`input-${input.name}`}
      />
      <Text style={[st.hint, since?.capped && !value && { color: color.needs }]}>{hint}</Text>
    </View>
  );
}

const st = StyleSheet.create({
  body: { paddingHorizontal: 16, paddingTop: 14, paddingBottom: 40, gap: 16, maxWidth: 900, width: "100%" },
  row: {
    flexDirection: "row",
    alignItems: "center",
    gap: 14,
    paddingVertical: 11,
    borderBottomWidth: 1,
    borderBottomColor: "#1c1c21",
  },
  rowPhone: { alignItems: "flex-start" },
  headRow: { paddingTop: 0, paddingBottom: 8, borderBottomColor: color.divider },
  head: { fontSize: 12, color: color.faint },
  colName: { width: 150 },
  colStarts: { flex: 1, minWidth: 0 },
  colSteps: { width: 50 },
  colLast: { width: 190 },
  name: { fontFamily: font.mono, fontSize: 13, color: color.text, flexShrink: 1 },
  cell: { fontSize: 14, color: color.textSoft },
  lastText: { fontSize: 13, color: color.muted },
  chips: { flexDirection: "row", flexWrap: "wrap", gap: 5 },
  chip: {
    paddingHorizontal: 7,
    paddingVertical: 2,
    borderRadius: 5,
    overflow: "hidden",
    fontSize: 12,
    color: color.text,
  },
  empty: { fontSize: 13, lineHeight: 19, color: color.muted },
  foot: { flexDirection: "row", alignItems: "center", flexWrap: "wrap", gap: 10 },
  footLabel: { fontSize: 13, color: color.faint },
  note: {
    fontFamily: font.mono,
    fontSize: 12,
    color: color.textSoft,
    paddingHorizontal: 8,
    paddingVertical: 2,
    borderRadius: 5,
    borderWidth: 1,
    borderColor: "#2c2c34",
  },
  link: { fontSize: 13, color: color.accentText },
  desc: { fontSize: 13, lineHeight: 19, color: color.textDim },
  area: {
    minHeight: 90,
    borderRadius: 10,
    backgroundColor: color.field,
    borderWidth: 1,
    borderColor: color.border,
    padding: 10,
    color: color.text,
    fontSize: 14,
    textAlignVertical: "top",
    outlineStyle: "none",
  } as any,
  input: { gap: 6 },
  inputName: { fontSize: 12, color: color.muted },
  hint: { fontSize: 12, lineHeight: 17, color: color.faint },
  options: { flexDirection: "row", flexWrap: "wrap", gap: 6 },
  option: { paddingHorizontal: 10, paddingVertical: 5, borderRadius: 7, backgroundColor: color.field },
  optionOn: { backgroundColor: color.pill },
  optionText: { fontSize: 12, color: color.textDim },
  field: {
    height: 34,
    borderRadius: 8,
    backgroundColor: color.field,
    borderWidth: 1,
    borderColor: color.border,
    paddingHorizontal: 10,
    color: color.text,
    fontSize: 14,
    outlineStyle: "none",
  } as any,
});
