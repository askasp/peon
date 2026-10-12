import { useState } from "react";
import { ScrollView, StyleSheet, Text, TextInput, View } from "react-native";
import { router } from "expo-router";
import { Icon } from "../Icon";
import { ErrorLine, Tap, Toggle } from "../ui";
import { ask, usePeon } from "@/lib/peon";
import { useLoad } from "@/lib/useLoad";
import { ago } from "@/lib/time";
import { color, font } from "@/lib/theme";
import type { Procedure, ProcedureInput } from "@/lib/procedures";
import type { Run, Schedule } from "@/lib/types";
import type { ProjectCtx } from "./types";

type Values = Record<string, string | string[]>;

/** The procedure a schedule runs: its own, the one its prompt names, or the Folder's first. */
export function scheduleProcedure(s: Schedule, procedures: Procedure[]) {
  const named = s.procedure || /^\/([\w.-]+)/.exec(s.prompt ?? "")?.[1];
  return named ?? (s.prompt?.trim() ? null : (procedures[0]?.name ?? null));
}

/**
 * A Procedure Folder's procedures (P6): one card each, with its inputs and
 * schedule. Run sends it into the Folder's chat and opens the chat.
 */
export function ProceduresTab({ ctx, onRan }: { ctx: ProjectCtx; onRan: () => void }) {
  const schedulesChanged = usePeon((s) => s.schedulesChanged);
  const { data: scheds } = useLoad(
    () => ctx.call<{ schedules: Schedule[] }>("schedules", {}, 60000).then((r) => r.schedules),
    [schedulesChanged],
  );
  const { data: runs } = useLoad(() => ctx.call<{ runs: Run[] }>("runs").then((r) => r.runs), [ctx.changed]);
  const scheduled = (runs ?? []).filter((r) => r.schedule_key !== "manual").slice(0, 8);

  return (
    <ScrollView contentContainerStyle={st.body}>
      <ErrorLine message={ctx.proceduresError} />
      {ctx.procedures.map((p) => (
        <ProcedureCard
          key={p.name}
          ctx={ctx}
          procedure={p}
          schedules={(scheds ?? []).filter((s) => scheduleProcedure(s, ctx.procedures) === p.name)}
          onRan={onRan}
        />
      ))}
      <Text style={st.hint}>
        {ctx.procedures.length
          ? "To add a procedure, say “add a procedure that…” in the chat."
          : "No procedures yet. Say “add a procedure that…” in the chat."}
      </Text>

      {scheduled.length ? <Text style={st.heading}>Scheduled runs</Text> : null}
      <View>
        {scheduled.map((r) => (
          <Tap
            key={r.id}
            kb="row"
            onPress={() => r.session_id && router.push(`/session/${r.session_id}`)}
            style={st.run}
          >
            <Text style={st.runText} numberOfLines={1}>
              /{r.procedure ?? r.schedule_key}
              <Text style={{ color: r.status === "failed" ? color.red : color.muted }}>
                {" · "}
                {r.status === "running" ? "running" : r.error || r.summary || r.status}
              </Text>
            </Text>
            <Text style={st.runWhen}>{ago(r.started, true)}</Text>
          </Tap>
        ))}
      </View>
    </ScrollView>
  );
}

function ProcedureCard({
  ctx,
  procedure: p,
  schedules,
  onRan,
}: {
  ctx: ProjectCtx;
  procedure: Procedure;
  schedules: Schedule[];
  onRan: () => void;
}) {
  const [values, setValues] = useState<Values>(() =>
    Object.fromEntries(p.inputs.map((i) => [i.name, i.default])),
  );
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [paused, setPaused] = useState<Record<string, boolean>>({});
  const sched = schedules[0];

  async function run() {
    setBusy(true);
    setError(null);
    try {
      await ctx.call("run", { procedure: p.name, inputs: values }, 60000);
      onRan();
    } catch (e: any) {
      setError(e.message);
    }
    setBusy(false);
  }

  async function pause(s: Schedule, on: boolean) {
    setPaused((v) => ({ ...v, [s.key]: !on }));
    try {
      await ask("pause_schedule", { project_id: ctx.project.id, key: s.key, paused: !on });
    } catch (e: any) {
      setError(e.message);
      setPaused((v) => ({ ...v, [s.key]: s.paused }));
    }
  }

  return (
    <View style={st.card} testID={`procedure-${p.name}`}>
      <View style={st.cardTop}>
        <Text style={st.name}>/{p.name}</Text>
        <Tap haptic onPress={run} disabled={busy} style={st.run1} testID={`run-${p.name}`}>
          <Icon name="play" size={9} color={color.bg} />
          <Text style={st.runLabel}>{busy ? "Starting…" : "Run"}</Text>
        </Tap>
      </View>
      {p.description ? <Text style={st.desc}>{p.description}</Text> : null}
      {p.inputs.length ? <InputFields inputs={p.inputs} values={values} onChange={setValues} /> : null}
      <ErrorLine message={error} />
      {sched ? (
        <View style={st.foot}>
          <Text style={st.footText} numberOfLines={1}>
            {sched.when}
            {sched.last?.summary ? ` · last: ${sched.last.summary}` : ""}
          </Text>
          <Toggle
            value={!(paused[sched.key] ?? sched.paused)}
            onChange={(on) => pause(sched, on)}
            label={`Run ${p.name} on schedule`}
          />
        </View>
      ) : p.key ? (
        <View style={st.foot}>
          <Text style={st.footText}>One run per {p.key} · no schedule</Text>
        </View>
      ) : null}
    </View>
  );
}

/** A procedure's inputs: chips for choices, fields for the rest. */
export function InputFields({
  inputs,
  values,
  onChange,
}: {
  inputs: ProcedureInput[];
  values: Values;
  onChange: (v: Values) => void;
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
          <Text style={st.inputName}>{input.name}</Text>
          {input.options.length ? (
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

const st = StyleSheet.create({
  body: { paddingHorizontal: 16, paddingTop: 14, paddingBottom: 40, gap: 10, maxWidth: 760, width: "100%" },
  card: {
    gap: 10,
    paddingHorizontal: 14,
    paddingVertical: 13,
    borderRadius: 12,
    backgroundColor: "#17171c",
    borderWidth: 1,
    borderColor: color.divider,
  },
  cardTop: { flexDirection: "row", justifyContent: "space-between", alignItems: "center", gap: 10 },
  name: { fontFamily: font.mono, fontSize: 14, color: color.text },
  run1: {
    flexDirection: "row",
    alignItems: "center",
    gap: 6,
    paddingHorizontal: 12,
    paddingVertical: 6,
    borderRadius: 8,
    backgroundColor: color.textStrong,
  },
  runLabel: { fontSize: 13, fontWeight: "600", color: color.bg },
  desc: { fontSize: 13, lineHeight: 19, color: color.textDim },
  input: { gap: 6 },
  inputName: { fontSize: 12, color: color.muted },
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
  foot: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    gap: 10,
    paddingTop: 8,
    borderTopWidth: 1,
    borderTopColor: color.divider,
  },
  footText: { flex: 1, fontSize: 12, color: color.muted },
  hint: {
    padding: 12,
    borderRadius: 12,
    borderWidth: 1,
    borderStyle: "dashed",
    borderColor: "#2c2c34",
    fontSize: 13,
    lineHeight: 19,
    color: color.muted,
  },
  heading: { fontSize: 12, color: color.muted, marginTop: 4 },
  run: {
    flexDirection: "row",
    justifyContent: "space-between",
    gap: 10,
    paddingVertical: 8,
    paddingHorizontal: 2,
    borderBottomWidth: 1,
    borderBottomColor: color.hairline,
  },
  runText: { flex: 1, fontSize: 13, color: color.text },
  runWhen: { fontSize: 13, color: color.muted },
});
