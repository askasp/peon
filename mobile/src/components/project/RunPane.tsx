// Beside a run's chat (O5, O6): what it ran with, each step, and for a chain
// the runs each step started, one row per item. Select a child to see what it
// did; Chat about this attaches it to your message, › opens its own run.

import { useState } from "react";
import { ScrollView, StyleSheet, Text, View } from "react-native";
import { ErrorLine, Loading, Tap } from "../ui";
import type { Attached } from "@/lib/attach";
import { useLoad } from "@/lib/useLoad";
import { useWide } from "@/lib/useWide";
import { clock, dayLabel, runState } from "@/lib/runs";
import { duration } from "@/lib/time";
import { color, font } from "@/lib/theme";
import type { Procedure } from "@/lib/procedures";
import type { Run, RunStep } from "@/lib/types";
import type { ProjectCtx } from "./types";

type Detail = { run: Run; children: Run[]; outputs: Record<string, unknown> };

export function RunPane({
  ctx,
  runId,
  onOpenRun,
  onOpenProcedure,
  onAttach,
}: {
  ctx: ProjectCtx;
  runId: number;
  onOpenRun: (run: Run) => void;
  onOpenProcedure: (name: string) => void;
  onAttach: (a: Attached) => void;
}) {
  const { data, error } = useLoad(
    () => ctx.call<Detail>("run_detail", { id: runId }, 30000),
    [runId, ctx.changed],
  );
  const [busy, setBusy] = useState(false);
  const [actError, setActError] = useState<string | null>(null);
  const [json, setJson] = useState(false);
  const wide = useWide();

  if (!data) return error ? <ErrorLine message={error} /> : <Loading />;
  const r = data.run;
  const proc = ctx.procedures.find((p) => p.name === r.procedure) ?? null;
  const state = runState(r);

  async function start(procedure: string, inputs: Run["inputs"]) {
    setBusy(true);
    setActError(null);
    try {
      const res = await ctx.call<{ run: Run }>("run", { procedure, inputs }, 60000);
      onOpenRun(res.run);
    } catch (e: any) {
      setActError(e.message);
    }
    setBusy(false);
  }

  const inputs = Object.entries(r.inputs ?? {});
  const outputs = Object.entries(r.outputs ?? {});

  return (
    <View style={st.pane}>
      <View style={[st.head, !wide && st.headPhone]}>
        <Text style={st.title} numberOfLines={1}>
          {r.procedure}
        </Text>
        <Text style={[st.state, { color: state.tint }]}>{state.text}</Text>
        <Text style={st.when} numberOfLines={1}>
          {dayLabel(r.started)} {clock(r.started)}
          {r.finished ? ` · ${duration(r.started, r.finished)}` : ""}
        </Text>
        {/* The phone puts the buttons on a line of their own. */}
        <View style={wide ? { flex: 1 } : { flexBasis: "100%", height: 0 }} />
        {!r.parent_id && r.status !== "running" && r.procedure ? (
          <Tap
            onPress={() => start(r.procedure!, r.inputs)}
            disabled={busy}
            style={st.button}
            testID="run-again"
          >
            <Text style={st.buttonText}>{busy ? "Starting…" : "Run again"}</Text>
          </Tap>
        ) : null}
        {proc?.source === "folder" ? (
          <Tap onPress={() => onOpenProcedure(proc.name)} style={st.button} testID="open-procedure">
            <Text style={st.buttonText}>Open procedure</Text>
          </Tap>
        ) : null}
      </View>
      <ScrollView contentContainerStyle={st.body}>
        <ErrorLine message={actError} />
        {inputs.length ? (
          <View style={st.line}>
            <Text style={st.label}>Inputs</Text>
            <View style={st.chips}>
              {inputs.map(([k, v]) => (
                <Text key={k} style={st.chip} numberOfLines={1}>
                  {k}: {Array.isArray(v) ? v.join(", ") : String(v)}
                </Text>
              ))}
            </View>
          </View>
        ) : null}

        <View style={st.steps}>
          {(r.steps ?? []).map((s, i) => (
            <StepBlock
              key={i}
              step={s}
              def={proc?.steps?.[i] ?? null}
              kids={data.children.filter((c) => (s.children ?? []).includes(c.id))}
              proc={proc}
              first={i === 0}
              procedures={ctx.procedures}
              onOpenRun={onOpenRun}
              onAttach={onAttach}
              onRetry={(c) => start(c.procedure!, c.inputs)}
            />
          ))}
        </View>

        {outputs.length ? (
          <View style={st.line}>
            <Text style={st.label}>Returned</Text>
            <View style={[st.chips, { flex: 1 }]}>
              {outputs.map(([k, n]) => (
                <Text key={k} style={st.chip}>
                  {k} {n}
                </Text>
              ))}
            </View>
            <Tap onPress={() => setJson(!json)} hitSlop={8}>
              <Text style={st.link}>{json ? "Hide JSON" : "View JSON"}</Text>
            </Tap>
          </View>
        ) : null}
        {json ? (
          <Text style={st.json} selectable>
            {JSON.stringify(data.outputs, null, 2)}
          </Text>
        ) : null}
      </ScrollView>
    </View>
  );
}

const stepGlyph = (status: string) =>
  status === "done"
    ? { glyph: "✓", tint: color.accentText }
    : status === "failed"
      ? { glyph: "✕", tint: color.red }
      : status === "partial"
        ? { glyph: "!", tint: color.needs }
        : status === "waiting"
          ? { glyph: "?", tint: color.needs }
          : status === "running"
            ? { glyph: "•", tint: color.accentText }
            : { glyph: "·", tint: color.faint };

function StepBlock({
  step: s,
  def,
  kids: children,
  proc,
  first,
  procedures,
  onOpenRun,
  onAttach,
  onRetry,
}: {
  step: RunStep;
  def: NonNullable<Procedure["steps"]>[number] | null;
  /** The runs this step started. */
  kids: Run[];
  proc: Procedure | null;
  first: boolean;
  procedures: Procedure[];
  onOpenRun: (run: Run) => void;
  onAttach: (a: Attached) => void;
  onRetry: (run: Run) => void;
}) {
  const [open, setOpen] = useState(false);
  const [picked, setPicked] = useState<number | null>(null);
  const g = stepGlyph(s.status);
  const failed = children.filter((c) => c.status === "failed").length;
  const sub = children.length
    ? [`${children.length - failed} done`, failed ? `${failed} failed` : null].filter(Boolean).join(" · ")
    : (s.error ?? firstLine(s.text));
  const runs = def?.run ?? null;
  const time = s.started && (s.finished || s.status === "running") ? duration(s.started, s.finished) : null;
  return (
    <View style={[st.step, !first && st.stepLine]}>
      <Tap onPress={() => setOpen(!open)} style={st.stepHead} kb="row">
        <Text style={[st.glyph, { color: g.tint }]}>{g.glyph}</Text>
        <View style={{ flex: 1, gap: 2, minWidth: 0 }}>
          <Text style={st.stepName} numberOfLines={1}>
            {s.name}
            {runs ? (
              <Text style={st.stepRuns}>
                {"  "}runs <Text style={st.code}>{runs}</Text>
                {def?.for_each ? `  for each · ${children.length}` : ""}
              </Text>
            ) : null}
          </Text>
          {sub ? (
            <Text style={[st.stepSub, s.error && { color: color.red }]} numberOfLines={open ? undefined : 2}>
              {sub}
            </Text>
          ) : null}
        </View>
        {s.model ? <Text style={st.model}>{s.model.split("/").pop()}</Text> : null}
        {s.effort ? <Text style={st.model}>{s.effort}</Text> : null}
        {time ? <Text style={st.time}>{time}</Text> : null}
      </Tap>
      {open && s.text && !children.length ? (
        <Text style={st.text} selectable>
          {s.text}
        </Text>
      ) : null}
      {children.length ? (
        <View style={st.children}>
          {children.map((c) => {
            const cg = stepGlyph(c.status);
            const childProc = procedures.find((p) => p.name === c.procedure) ?? proc;
            const { label, detail } = childLabel(c, childProc);
            const on = picked === c.id;
            const why = c.error ?? (c.steps ?? []).map((x) => x.error ?? firstLine(x.text)).find(Boolean);
            return (
              <View key={c.id} style={[st.child, on && st.childOn]}>
                <Tap
                  onPress={() => setPicked(on ? null : c.id)}
                  style={st.childHead}
                  kb="row"
                  testID={`child-${c.id}`}
                >
                  <Text style={[st.glyph, { color: cg.tint }]}>{cg.glyph}</Text>
                  <Text style={st.childName} numberOfLines={1}>
                    {label}
                  </Text>
                  <Text style={st.childDetail} numberOfLines={1}>
                    {detail}
                  </Text>
                  <Tap onPress={() => onOpenRun(c)} hitSlop={8} testID={`child-open-${c.id}`}>
                    <Text style={st.chev}>›</Text>
                  </Tap>
                </Tap>
                {on ? (
                  <View style={st.childBody}>
                    {(c.steps ?? []).map((x, j) =>
                      x.text || x.error ? (
                        <Text key={j} style={st.callText} selectable numberOfLines={12}>
                          {x.text ?? ""}
                          {x.error ? `${x.text ? "\n" : ""}${x.error}` : ""}
                        </Text>
                      ) : null,
                    )}
                    {why && !(c.steps ?? []).some((x) => x.text || x.error) ? (
                      <Text style={st.error}>{why}</Text>
                    ) : null}
                    <View style={{ flexDirection: "row", gap: 8 }}>
                      <Tap
                        onPress={() =>
                          onAttach({
                            path: `${c.procedure} · ${label}`,
                            view: null,
                            text: childText(c),
                          })
                        }
                        style={st.attach}
                        testID={`child-chat-${c.id}`}
                      >
                        <Text style={st.attachText}>Chat about this</Text>
                      </Tap>
                      {c.status === "failed" && c.procedure ? (
                        <Tap onPress={() => onRetry(c)} style={st.button}>
                          <Text style={st.buttonText}>Retry</Text>
                        </Tap>
                      ) : null}
                    </View>
                  </View>
                ) : null}
              </View>
            );
          })}
        </View>
      ) : null}
    </View>
  );
}

const firstLine = (t?: string | null) =>
  t
    ? (t
        .replace(/```[\s\S]*?(```|$)/g, "")
        .split("\n")
        .map((l) => l.trim())
        .find(Boolean) ?? null)
    : null;

/** A child run's row: who or what it acted on, and the amount and key. */
function childLabel(c: Run, proc: Procedure | null) {
  const v = c.inputs ?? {};
  const key = proc?.key ? v[proc.key] : null;
  const name = v.name ?? v.customer ?? v.email ?? key ?? Object.values(v)[0] ?? c.procedure ?? "";
  const currency = proc?.inputs.find((i) => i.name === "amount")?.currency;
  const amount = v.amount != null && v.amount !== "" ? `${v.amount}${currency ? ` ${currency}` : ""}` : null;
  const detail = [amount, key && key !== name ? key : null].filter(Boolean).join(" · ");
  return { label: Array.isArray(name) ? name.join(", ") : String(name), detail };
}

/** What "Chat about this" sends along about a child run. */
function childText(c: Run) {
  const steps = (c.steps ?? [])
    .map(
      (s) =>
        `- ${s.name}: ${s.status}${s.error ? ` (${s.error})` : ""}${s.text ? `\n${s.text.slice(0, 1500)}` : ""}`,
    )
    .join("\n");
  return [
    `Run ${c.id} of ${c.procedure} (${c.status}${c.error ? `: ${c.error}` : ""})`,
    `Inputs: ${JSON.stringify(c.inputs ?? {})}`,
    c.summary ? `Summary: ${c.summary}` : null,
    steps ? `Steps:\n${steps}` : null,
  ]
    .filter(Boolean)
    .join("\n");
}

const st = StyleSheet.create({
  pane: { flex: 1, minHeight: 0, backgroundColor: color.bg },
  head: {
    minHeight: 44,
    flexDirection: "row",
    alignItems: "center",
    gap: 10,
    paddingHorizontal: 16,
    paddingVertical: 6,
    borderBottomWidth: 1,
    borderBottomColor: color.hairline,
  },
  headPhone: { flexWrap: "wrap", rowGap: 8, paddingVertical: 10 },
  title: { fontFamily: font.mono, fontWeight: "700", fontSize: 13.5, color: color.textStrong, flexShrink: 1 },
  state: { fontSize: 13 },
  when: { fontSize: 13, color: color.muted, flexShrink: 1 },
  button: {
    paddingHorizontal: 11,
    paddingVertical: 5,
    borderRadius: 7,
    borderWidth: 1,
    borderColor: color.outline,
  },
  buttonText: { fontSize: 13, color: color.text },
  body: { padding: 20, gap: 16, paddingBottom: 48 },
  line: { flexDirection: "row", alignItems: "center", gap: 14, flexWrap: "wrap" },
  label: { fontSize: 13, color: color.muted, minWidth: 64 },
  chips: { flexDirection: "row", flexWrap: "wrap", gap: 6 },
  chip: {
    paddingHorizontal: 8,
    paddingVertical: 3,
    borderRadius: 6,
    backgroundColor: color.field,
    fontFamily: font.mono,
    fontSize: 12.5,
    color: color.text,
  },
  link: { fontSize: 13, color: color.muted },
  error: { fontSize: 13, color: color.red },
  steps: { borderRadius: 12, borderWidth: 1, borderColor: color.border, overflow: "hidden" },
  step: { paddingHorizontal: 14, paddingVertical: 12, gap: 8 },
  stepLine: { borderTopWidth: 1, borderTopColor: color.border },
  stepHead: { flexDirection: "row", alignItems: "center", gap: 12 },
  glyph: { width: 14, fontSize: 13.5, fontWeight: "700", textAlign: "center" },
  stepName: { fontSize: 14.5, fontWeight: "600", color: color.textStrong },
  stepRuns: { fontSize: 13, fontWeight: "400", color: color.muted },
  code: { fontFamily: font.mono, color: color.accentText },
  stepSub: { fontSize: 12.5, color: color.muted },
  model: {
    paddingHorizontal: 6,
    paddingVertical: 2,
    borderRadius: 5,
    backgroundColor: color.field,
    fontFamily: font.mono,
    fontSize: 11.5,
    color: color.textSoft,
  },
  time: { fontSize: 12, color: color.muted, fontVariant: ["tabular-nums"] },
  text: {
    marginLeft: 26,
    fontSize: 12.5,
    lineHeight: 18,
    color: color.textDim,
    fontFamily: font.mono,
  },
  children: { marginLeft: 6, paddingLeft: 12, borderLeftWidth: 1, borderLeftColor: color.border, gap: 2 },
  child: { borderRadius: 8, borderWidth: 1, borderColor: "transparent" },
  childOn: { borderColor: color.border, backgroundColor: color.card },
  childHead: {
    flexDirection: "row",
    alignItems: "center",
    gap: 10,
    paddingHorizontal: 8,
    paddingVertical: 7,
  },
  childName: { flex: 1, fontSize: 13.5, color: color.text },
  childDetail: { fontSize: 12.5, color: color.muted, fontFamily: font.mono, flexShrink: 1 },
  chev: { fontSize: 15, color: color.muted, paddingHorizontal: 2 },
  childBody: { gap: 10, paddingHorizontal: 12, paddingBottom: 12, paddingLeft: 32 },
  callText: {
    padding: 10,
    borderRadius: 8,
    backgroundColor: color.bgDeep,
    fontFamily: font.mono,
    fontSize: 12,
    lineHeight: 18,
    color: color.textSoft,
  },
  attach: {
    paddingHorizontal: 11,
    paddingVertical: 5,
    borderRadius: 7,
    borderWidth: 1,
    borderColor: color.accentBorder,
    backgroundColor: color.accentWash,
  },
  attachText: { fontSize: 13, fontWeight: "600", color: color.accentText },
  json: {
    padding: 12,
    borderRadius: 8,
    backgroundColor: color.bgDeep,
    fontFamily: font.mono,
    fontSize: 12,
    lineHeight: 18,
    color: color.textSoft,
  },
});
