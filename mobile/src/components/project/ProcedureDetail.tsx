// One procedure (U3, U4, C1): how it starts, its inputs and steps, its
// schedule with Pause, and its recent runs. A Project's own file can be edited
// here: each step's prompt, model, effort and session, adding and removing steps.

import { useState } from "react";
import { ScrollView, StyleSheet, Text, TextInput, View } from "react-native";
import { router } from "expo-router";
import { Icon } from "../Icon";
import { Button, ErrorLine, Tap, Toggle } from "../ui";
import { InputFields, lastLine } from "./ProceduresTab";
import { useWide } from "@/lib/useWide";
import { ago } from "@/lib/time";
import { color, font } from "@/lib/theme";
import { sinceInput, spanLabel, starts, type Procedure, type ProcedureStep } from "@/lib/procedures";
import type { Run } from "@/lib/types";
import type { ProjectCtx } from "./types";

type Values = Record<string, string | string[]>;

const models = ["", "haiku", "sonnet", "opus"];
const efforts = ["", "low", "medium", "high"];

export function ProcedureDetail({
  ctx,
  procedure: p,
  runs,
  onBack,
  onOpen,
  onRan,
  embedded,
  onOpenRun,
}: {
  ctx: ProjectCtx;
  procedure: Procedure;
  runs: Run[];
  onBack?: () => void;
  /** Opens another procedure (a step that runs it). */
  onOpen: (name: string) => void;
  onRan?: (sessionId: string | null | undefined) => void;
  /** Beside its chat (an Operations Project): no back or Run here, the pane has them. */
  embedded?: boolean;
  /** Opens a recent run (else its session). */
  onOpenRun?: (run: Run) => void;
}) {
  const wide = useWide();
  const steps = p.steps ?? [];
  const many = steps.length > 1;
  const editable = ctx.canEdit && p.source === "folder";
  const [values, setValues] = useState<Values>(() =>
    Object.fromEntries(p.inputs.map((i) => [i.name, i.default === "last_run" ? "" : i.default])),
  );
  const [asking, setAsking] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [editing, setEditing] = useState<number | null>(null);
  const single = steps.length === 1 ? steps[0] : null;

  async function run() {
    // Inputs without a default are asked for first.
    if (p.inputs.length && !asking) return setAsking(true);
    setBusy(true);
    setError(null);
    try {
      const inputs = Object.fromEntries(
        Object.entries(values).filter(([, v]) => (Array.isArray(v) ? v.length : v)),
      );
      const r = await ctx.call<{ session_id: string | null }>("run", { procedure: p.name, inputs }, 60000);
      setAsking(false);
      onRan?.(r.session_id);
    } catch (e: any) {
      setError(e.message);
    }
    setBusy(false);
  }

  async function save(edit: object) {
    setError(null);
    try {
      await ctx.call("save_procedure", { name: p.name, edit }, 30000);
      ctx.reloadProcedures();
      return true;
    } catch (e: any) {
      setError(e.message);
      return false;
    }
  }

  async function pause(paused: boolean) {
    setError(null);
    try {
      await ctx.call("pause_schedule", { procedure: p.name, paused }, 30000);
      ctx.reloadProcedures();
    } catch (e: any) {
      setError(e.message);
    }
  }

  return (
    <ScrollView contentContainerStyle={[st.body, wide && { paddingHorizontal: embedded ? 24 : 28 }]}>
      {embedded ? (
        <Text style={st.embeddedTitle} numberOfLines={1}>
          {p.name}
        </Text>
      ) : null}
      <View style={[st.top, embedded && { display: "none" }]}>
        <Tap onPress={onBack} hitSlop={8} style={st.back} testID="procedure-back">
          <Icon name="back" size={14} color={color.muted} strokeWidth={2.4} />
          <Text style={st.backText}>Procedures</Text>
        </Tap>
        <Text style={st.title} numberOfLines={1}>
          {p.name}
        </Text>
        {wide && p.path ? (
          <Text style={st.path} numberOfLines={1}>
            {p.path}
          </Text>
        ) : (
          <View style={{ flex: 1 }} />
        )}
        <Tap onPress={run} disabled={busy} style={st.runNow} testID="procedure-run-now">
          <Text style={st.runNowText}>{busy ? "Starting…" : asking ? "Run" : "Run now"}</Text>
        </Tap>
      </View>
      {p.description ? <Text style={st.desc}>{p.description}</Text> : null}
      {p.source === "global" ? (
        <Text style={st.meta}>
          Global: from the setup Project, in every Project. A file here with this name replaces it.
        </Text>
      ) : p.source === "legacy" ? (
        <Text style={st.meta}>
          A skill from before procedure files. Ask the chat to move it to .peon/procedures/ to edit it here.
        </Text>
      ) : p.overrides ? (
        <Text style={st.meta}>Replaces the global {p.name}.</Text>
      ) : null}

      {asking ? (
        <View style={st.ask}>
          <InputFields inputs={p.inputs} values={values} onChange={setValues} since={p.since} />
          <Tap onPress={() => setAsking(false)} hitSlop={8}>
            <Text style={st.muted}>Cancel</Text>
          </Tap>
        </View>
      ) : null}
      <ErrorLine message={error} />

      {p.schedule ? (
        <View style={st.sched}>
          <View style={{ flex: 1, gap: 3 }}>
            <View style={{ flexDirection: "row", alignItems: "center", gap: 8 }}>
              <Text style={[st.chip, st.schedChip]}>{p.schedule.when ?? p.schedule.at}</Text>
              {p.schedule.tz ? <Text style={st.soft}>{p.schedule.tz}</Text> : null}
            </View>
            <Text style={st.muted}>
              {p.schedule.paused
                ? "Paused until you start it"
                : p.schedule.next
                  ? `Next run ${new Date(p.schedule.next).toLocaleString("en-GB", { weekday: "short", day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" })} · uses input defaults`
                  : `Can't read "${p.schedule.at}" as a time`}
            </Text>
          </View>
          {ctx.canEdit ? (
            <Tap onPress={() => pause(!p.schedule!.paused)} style={st.pause} testID="schedule-pause">
              <Text style={st.pauseText}>{p.schedule.paused ? "Start schedule" : "Pause"}</Text>
            </Tap>
          ) : null}
        </View>
      ) : null}
      {(p.warnings ?? []).map((w) => (
        <Text key={w} style={[st.meta, { color: color.needs }]}>
          {w}
        </Text>
      ))}

      <View style={st.grid}>
        <Text style={st.label}>Starts</Text>
        <View style={st.chips}>
          {starts(p, ctx.procedures).map((c) => (
            <Text
              key={c.label}
              style={[st.chip, c.kind === "slash" && st.mono, c.kind === "schedule" && st.schedChip]}
            >
              {c.label}
            </Text>
          ))}
        </View>
        {p.inputs.length ? (
          <>
            <Text style={st.label}>Inputs</Text>
            <View style={st.chips}>
              {p.inputs.map((i) => (
                <Text key={i.name} style={st.inputLine}>
                  <Text style={st.mono}>{i.name}</Text>{" "}
                  <Text style={st.muted}>
                    {i.currency ?? i.type ?? "text"}
                    {sinceInput(i)
                      ? ` · since the last run, at most ${spanLabel(i.max ?? "7d")} back`
                      : i.default && !Array.isArray(i.default)
                        ? ` · ${i.default}`
                        : ""}
                  </Text>
                </Text>
              ))}
            </View>
          </>
        ) : null}
        {single?.kind === "call" ? <CallRows step={single} /> : null}
      </View>

      {single?.kind === "call" ? (
        <>
          {single.confirm ? (
            <View style={{ gap: 6 }}>
              <Text style={st.label}>Asks first</Text>
              <Text style={st.confirm}>{single.confirm}</Text>
            </View>
          ) : null}
          {editable ? (
            <View style={st.actions}>
              <Tap onPress={() => save({ op: "add_step" })} hitSlop={8}>
                <Text style={st.link}>Add step</Text>
              </Tap>
              <Tap onPress={() => save({ op: "use_prompt", index: 0 })} hitSlop={8}>
                <Text style={st.muted}>Use a prompt instead</Text>
              </Tap>
            </View>
          ) : null}
        </>
      ) : (
        <>
          <View style={st.steps}>
            {steps.map((s, i) => (
              <StepRow
                key={`${i}-${s.name}`}
                step={s}
                index={i}
                many={many}
                last={i === steps.length - 1}
                all={ctx.procedures}
                editing={editing === i}
                editable={editable}
                onEdit={() => setEditing(editing === i ? null : i)}
                onOpen={onOpen}
                onSave={async (attrs) => (await save({ op: "step", index: i, attrs })) && setEditing(null)}
                onRemove={async () => (await save({ op: "remove_step", index: i })) && setEditing(null)}
              />
            ))}
          </View>
          {editable ? (
            <Tap onPress={() => save({ op: "add_step" })} hitSlop={8} testID="add-step">
              <Text style={st.link}>Add step</Text>
            </Tap>
          ) : null}
        </>
      )}

      {runs.length ? (
        <View style={{ gap: 2 }}>
          <Text style={[st.label, { paddingBottom: 6 }]}>Recent runs</Text>
          {runs.slice(0, 12).map((r) => (
            <RecentRun key={r.id} run={r} procedure={p} onOpen={onOpenRun} />
          ))}
        </View>
      ) : null}
    </ScrollView>
  );
}

/** Calls / Params / Model for a one-call procedure (U4). */
function CallRows({ step }: { step: ProcedureStep }) {
  const [connector, ...tool] = (step.call ?? "").split(".");
  return (
    <>
      <Text style={st.label}>Calls</Text>
      <View style={[st.chips, { alignItems: "center" }]}>
        <Text style={[st.chip, st.callChip]}>{cap(connector)}</Text>
        <Text style={st.mono}>{tool.join(".")}</Text>
      </View>
      {Object.keys(step.params ?? {}).length ? (
        <>
          <Text style={st.label}>Params</Text>
          <View style={{ gap: 4 }}>
            {Object.entries(step.params).map(([k, v]) => (
              <Text key={k} style={st.mono}>
                <Text style={{ color: color.muted }}>{k}</Text> {v}
              </Text>
            ))}
          </View>
        </>
      ) : null}
      <Text style={st.label}>Model</Text>
      <Text style={st.muted}>None. The call runs as written.</Text>
    </>
  );
}

function StepRow({
  step: s,
  index,
  many,
  last,
  all,
  editing,
  editable,
  onEdit,
  onOpen,
  onSave,
  onRemove,
}: {
  step: ProcedureStep;
  index: number;
  many: boolean;
  last: boolean;
  all: Procedure[];
  editing: boolean;
  editable: boolean;
  onEdit: () => void;
  onOpen: (name: string) => void;
  onSave: (attrs: Record<string, unknown>) => void;
  onRemove: () => void;
}) {
  const child = s.run ? all.find((x) => x.name === s.run) : null;
  const what =
    s.kind === "run"
      ? null
      : s.kind === "queue"
        ? `Adds a ticket ${s.for_each ? `per ${s.for_each} item` : ""} for ${s.queue}${s.title ? `: ${s.title}` : ""}`
        : s.kind === "call"
          ? `Calls ${s.call}`
          : s.kind === "wait"
            ? null
            : firstLine(s.prompt) || (s.skill ? `Uses the ${s.skill} skill` : null);

  return (
    <View style={[st.step, !last && st.stepRule, editing && { backgroundColor: "#1b1b21" }]}>
      <Tap onPress={editable ? onEdit : undefined} disabled={!editable} style={st.stepTop}>
        <Text style={st.stepNo}>{index + 1}</Text>
        <View style={{ flex: 1, minWidth: 0, gap: 4 }}>
          <View style={{ flexDirection: "row", alignItems: "baseline", gap: 8, flexWrap: "wrap" }}>
            <Text style={st.stepName}>{s.name}</Text>
            {s.run ? (
              <>
                <Text style={st.muted}>runs</Text>
                <Tap onPress={() => onOpen(s.run!)} hitSlop={6}>
                  <Text style={[st.mono, { color: color.accentText }]}>{s.run}</Text>
                </Tap>
                {s.for_each ? <Text style={st.muted}>for each {s.for_each.split(".").pop()}</Text> : null}
              </>
            ) : null}
          </View>
          {what ? (
            <Text style={st.stepWhat} numberOfLines={editing ? undefined : 2}>
              {what}
            </Text>
          ) : null}
          {s.on_fail === "continue" ? <Text style={st.muted}>If it fails, carry on</Text> : null}
          {s.wait ? (
            <Text style={[st.small, { color: color.needs }]}>
              {s.confirm
                ? `Waits for you once: "${s.confirm}"`
                : s.kind === "prompt" && s.model
                  ? "Waits for you"
                  : "Waits for you · no model"}
            </Text>
          ) : null}
          {s.on_changes ? (
            <Text style={st.muted}>
              Changes needed: back to {s.on_changes.back_to}, at most {s.on_changes.max} times, then wait for
              you
            </Text>
          ) : null}
          {s.hand_over.length ? (
            <View style={[st.chips, { alignItems: "center" }]}>
              <Text style={st.small}>Hands over</Text>
              {s.hand_over.map((h) => (
                <Text key={h} style={st.handChip}>
                  {/^[A-Z][^.]*$/.test(h) ? `${h}'s answer` : h}
                </Text>
              ))}
            </View>
          ) : null}
          {s.returns ? (
            <View style={[st.chips, { alignItems: "center" }]}>
              <Text style={st.small}>Returns</Text>
              <Text style={st.handChip}>{s.returns}</Text>
            </View>
          ) : null}
          {s.offers ? (
            <View style={[st.chips, { alignItems: "center" }]}>
              <Text style={st.small}>Offers</Text>
              <Text style={st.offer}>{offerLabel(s.offers)}</Text>
              <Text style={st.muted}>
                per row, starts <Text style={st.mono}>{s.offers}</Text>
              </Text>
            </View>
          ) : null}
        </View>
        <View style={st.tags}>
          {s.kind === "run" && child ? (
            <Text style={st.tag}>
              {child.steps?.length ?? 1} step{(child.steps?.length ?? 1) === 1 ? "" : "s"}
            </Text>
          ) : null}
          {s.kind === "call" ? (
            <Text style={[st.tag, st.callChip]}>{cap(s.call?.split(".")[0] ?? "")} call</Text>
          ) : null}
          {many && s.kind === "prompt" ? (
            <>
              {s.model_label ? <Text style={[st.tag, modelTint(s.model)]}>{s.model_label}</Text> : null}
              {s.effort ? <Text style={st.tag}>{s.effort}</Text> : null}
              <Text style={st.tag}>{s.session}</Text>
            </>
          ) : null}
          {s.uses.map((u) => (
            <Text key={u} style={st.tag}>
              {cap(u)}
            </Text>
          ))}
        </View>
      </Tap>
      {editing ? (
        <StepEditor step={s} many={many} onSave={onSave} onRemove={many ? onRemove : undefined} />
      ) : null}
    </View>
  );
}

/** A step's prompt, and (with two steps or more) its model, effort, session and wait. */
function StepEditor({
  step: s,
  many,
  onSave,
  onRemove,
}: {
  step: ProcedureStep;
  many: boolean;
  onSave: (attrs: Record<string, unknown>) => void;
  onRemove?: () => void;
}) {
  const [name, setName] = useState(s.name);
  const [prompt, setPrompt] = useState(s.prompt ?? "");
  const [model, setModel] = useState(s.model ?? "");
  const [effort, setEffort] = useState(s.effort ?? "");
  const [session, setSession] = useState(s.session);
  const [wait, setWait] = useState(s.wait);
  const choices = model && !models.includes(model) ? [...models, model] : models;
  const prompted = s.kind === "prompt" || s.kind === "wait";

  return (
    <View style={st.editor}>
      {many ? (
        <TextInput value={name} onChangeText={setName} style={st.field} placeholder="Step name" />
      ) : null}
      {prompted ? (
        <TextInput
          value={prompt}
          onChangeText={setPrompt}
          multiline
          style={st.area}
          placeholder="What this step does. {input} fills in an input."
          placeholderTextColor={color.faint}
          testID="step-prompt"
        />
      ) : null}
      {many && prompted ? (
        <>
          <Pick label="Model" options={choices} value={model} onChange={setModel} />
          <Pick label="Effort" options={efforts} value={effort} onChange={setEffort} />
          <Pick
            label="Session"
            options={["same", "fresh"]}
            value={session}
            onChange={(v) => setSession(v as any)}
          />
        </>
      ) : null}
      <View style={{ flexDirection: "row", alignItems: "center", gap: 10 }}>
        <Toggle value={wait} onChange={setWait} label="Wait for you" />
        <Text style={st.soft}>Wait for you</Text>
      </View>
      <View style={st.actions}>
        <Button
          label="Save"
          kind="accent"
          height={34}
          onPress={() =>
            onSave({
              ...(many ? { name } : {}),
              ...(prompted ? { prompt } : {}),
              ...(many && prompted ? { model, effort, session: session === "same" ? "" : session } : {}),
              wait,
            })
          }
          testID="step-save"
        />
        {onRemove ? (
          <Tap onPress={onRemove} hitSlop={8}>
            <Text style={[st.muted, { color: color.red }]}>Remove step</Text>
          </Tap>
        ) : null}
      </View>
    </View>
  );
}

function Pick({
  label,
  options,
  value,
  onChange,
}: {
  label: string;
  options: string[];
  value: string;
  onChange: (v: string) => void;
}) {
  return (
    <View style={st.pick}>
      <Text style={[st.small, { width: 64 }]}>{label}</Text>
      <View style={st.chips}>
        {options.map((o) => (
          <Tap key={o || "none"} onPress={() => onChange(o)} style={[st.opt, value === o && st.optOn]}>
            <Text style={[st.optText, value === o && { color: color.textStrong }]}>
              {o ? cap(o) : "Default"}
            </Text>
          </Tap>
        ))}
      </View>
    </View>
  );
}

/** A run in Recent runs: when, what it worked on, how it ended. Opens where it ran. */
function RecentRun({
  run: r,
  procedure: p,
  onOpen,
}: {
  run: Run;
  procedure: Procedure;
  onOpen?: (run: Run) => void;
}) {
  const v = r.inputs ?? {};
  const currency = p.inputs.find((i) => i.name === "amount")?.currency;
  const amount = v.amount != null && v.amount !== "" ? `${v.amount}${currency ? ` ${currency}` : ""}` : null;
  const keyed = p.key && v[p.key] ? String(v[p.key]) : null;
  // What a `since` run covered: from its since to when it started.
  const since = p.inputs.find(sinceInput);
  const from = since && typeof v[since.name] === "string" ? Date.parse(v[since.name] as string) : NaN;
  const window = Number.isFinite(from) ? `${short(from)} → ${short(Date.parse(r.started))}` : null;
  const what =
    [window, v.name, amount].filter(Boolean).join(" · ") ||
    r.summary ||
    keyed ||
    (r.trigger === "chain" ? "Started by a chain" : (r.trigger ?? ""));
  const end = lastLine(r);
  const state =
    r.status === "done"
      ? { text: r.summary?.startsWith("Done with") ? "Done with failures" : "Done", tint: color.accentText }
      : r.status === "waiting"
        ? { text: "Waiting for you", tint: color.needs }
        : r.status === "failed"
          ? { text: "Failed", tint: color.red }
          : { text: "Running", tint: color.textSoft };
  return (
    <Tap
      kb="row"
      onPress={() => (onOpen ? onOpen(r) : r.session_id && router.push(`/session/${r.session_id}`))}
      style={st.recent}
      testID={`recent-${r.id}`}
    >
      <Text style={st.recentWhen}>{ago(r.started, true)}</Text>
      <Text style={st.recentWhat} numberOfLines={1}>
        {what || end.text}
      </Text>
      <Text style={[st.small, { color: state.tint }]}>{state.text}</Text>
    </Tap>
  );
}

/** "12 Oct 07:00" */
const short = (t: number) =>
  new Date(t).toLocaleString("en-GB", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });

const firstLine = (s: string | null) =>
  (s ?? "")
    .split("\n")
    .find((l) => l.trim())
    ?.trim() ?? "";
const cap = (s: string) => (s ? s[0].toUpperCase() + s.slice(1) : s);
const offerLabel = (name: string) => `Send ${name}`;

function modelTint(model: string | null) {
  const m = (model ?? "").toLowerCase();
  if (m.includes("opus")) return { backgroundColor: "#2a2014", color: "#e0b77a" };
  if (m.includes("sonnet")) return { backgroundColor: color.accentWash, color: color.accentText };
  if (m.includes("haiku")) return { backgroundColor: "#221a2a", color: "#c4a6e0" };
  if (m.includes("gpt") || m.includes("codex")) return { backgroundColor: "#14262a", color: color.teal };
  return null;
}

const st = StyleSheet.create({
  body: { paddingHorizontal: 16, paddingTop: 14, paddingBottom: 40, gap: 14, maxWidth: 900, width: "100%" },
  top: { flexDirection: "row", alignItems: "center", gap: 10 },
  embeddedTitle: {
    fontSize: 18,
    fontWeight: "700",
    fontFamily: font.mono,
    color: color.textStrong,
    marginBottom: -8,
  },
  back: { flexDirection: "row", alignItems: "center", gap: 3 },
  backText: { fontSize: 13, color: color.muted },
  title: { fontFamily: font.mono, fontSize: 17, fontWeight: "600", color: color.text, flexShrink: 1 },
  path: { flex: 1, fontFamily: font.mono, fontSize: 12, color: color.faint },
  runNow: {
    paddingHorizontal: 10,
    paddingVertical: 5,
    borderRadius: 7,
    borderWidth: 1,
    borderColor: "#2c2c34",
  },
  runNowText: { fontSize: 12, color: color.text },
  desc: { fontSize: 13, lineHeight: 19, color: color.textDim },
  meta: { fontSize: 12, lineHeight: 18, color: color.faint },
  ask: {
    gap: 10,
    padding: 12,
    borderRadius: 10,
    backgroundColor: "#17171c",
    borderWidth: 1,
    borderColor: color.border,
  },
  sched: {
    flexDirection: "row",
    alignItems: "center",
    gap: 12,
    paddingHorizontal: 14,
    paddingVertical: 12,
    borderRadius: 10,
    backgroundColor: "#14262a33",
    borderWidth: 1,
    borderColor: "#1f3a40",
  },
  schedChip: { backgroundColor: "#14262a", color: color.teal },
  pause: {
    paddingHorizontal: 10,
    paddingVertical: 5,
    borderRadius: 7,
    borderWidth: 1,
    borderColor: "#2c2c34",
  },
  pauseText: { fontSize: 12, color: color.text },
  grid: { flexDirection: "row", flexWrap: "wrap", rowGap: 10, alignItems: "center" },
  label: { width: 92, fontSize: 13, color: color.faint },
  chips: { flex: 1, flexDirection: "row", flexWrap: "wrap", gap: 5, minWidth: 180 },
  chip: {
    paddingHorizontal: 7,
    paddingVertical: 2,
    borderRadius: 5,
    overflow: "hidden",
    fontSize: 12,
    color: color.textSoft,
    borderWidth: 1,
    borderColor: "#2c2c34",
  },
  mono: { fontFamily: font.mono, fontSize: 12, color: color.text },
  inputLine: { fontSize: 12, marginRight: 10 },
  callChip: { backgroundColor: "#1c1830", color: "#b9a8ec", borderWidth: 0 },
  confirm: {
    padding: 12,
    borderRadius: 10,
    backgroundColor: color.needsCard,
    borderWidth: 1,
    borderColor: color.needsBorder,
    fontSize: 13,
    lineHeight: 19,
    color: color.text,
  },
  steps: {
    borderRadius: 10,
    borderWidth: 1,
    borderColor: color.border,
    backgroundColor: "#17171c",
    overflow: "hidden",
  },
  step: { paddingHorizontal: 14, paddingVertical: 12, gap: 10 },
  stepRule: { borderBottomWidth: 1, borderBottomColor: color.divider },
  stepTop: { flexDirection: "row", alignItems: "flex-start", gap: 12 },
  stepNo: { width: 14, fontFamily: font.mono, color: color.faint, paddingTop: 1 },
  stepName: { fontWeight: "600", fontSize: 14, color: color.text },
  stepWhat: { fontSize: 12, lineHeight: 17, color: color.muted },
  small: { fontSize: 11, color: color.faint },
  handChip: {
    paddingHorizontal: 7,
    paddingVertical: 1,
    borderRadius: 5,
    borderWidth: 1,
    borderColor: "#2c2c34",
    fontSize: 11,
    color: color.textSoft,
  },
  offer: {
    paddingHorizontal: 9,
    paddingVertical: 3,
    borderRadius: 12,
    overflow: "hidden",
    backgroundColor: color.accent,
    color: color.accentInk,
    fontWeight: "600",
    fontSize: 11,
  },
  tags: { flexDirection: "row", flexWrap: "wrap", gap: 5, justifyContent: "flex-end", maxWidth: 220 },
  tag: {
    paddingHorizontal: 7,
    paddingVertical: 2,
    borderRadius: 5,
    overflow: "hidden",
    backgroundColor: color.field,
    color: color.textSoft,
    fontFamily: font.mono,
    fontSize: 11,
  },
  editor: { gap: 10, paddingLeft: 26 },
  field: {
    height: 34,
    borderRadius: 8,
    backgroundColor: "#121216",
    borderWidth: 1,
    borderColor: "#2c2c34",
    paddingHorizontal: 10,
    color: color.text,
    fontSize: 14,
    outlineStyle: "none",
  } as any,
  area: {
    minHeight: 80,
    borderRadius: 8,
    backgroundColor: "#121216",
    borderWidth: 1,
    borderColor: "#2c2c34",
    padding: 10,
    color: color.textSoft,
    fontSize: 13,
    lineHeight: 19,
    textAlignVertical: "top",
    outlineStyle: "none",
  } as any,
  pick: { flexDirection: "row", alignItems: "center", gap: 10 },
  opt: { paddingHorizontal: 9, paddingVertical: 3, borderRadius: 6 },
  optOn: { backgroundColor: color.border },
  optText: { fontSize: 12, color: color.muted },
  actions: { flexDirection: "row", alignItems: "center", gap: 16 },
  link: { fontSize: 13, color: color.accentText },
  muted: { fontSize: 12, color: color.muted },
  soft: { fontSize: 13, color: color.textSoft },
  recent: {
    flexDirection: "row",
    alignItems: "center",
    gap: 12,
    paddingVertical: 8,
    borderTopWidth: 1,
    borderTopColor: "#1c1c21",
  },
  recentWhen: { width: 90, fontSize: 13, color: color.faint },
  recentWhat: { flex: 1, fontSize: 13, color: color.text },
});
