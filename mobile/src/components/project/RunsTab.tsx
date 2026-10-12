import { useEffect, useState } from "react";
import { ScrollView, StyleSheet, Text, TextInput, View } from "react-native";
import { router } from "expo-router";
import { Icon } from "../Icon";
import { Button, ErrorLine, Loading, Tap, Toggle } from "../ui";
import { ask, usePeon } from "@/lib/peon";
import { inputsLabel, stopRun } from "@/lib/runs";
import { useLoad } from "@/lib/useLoad";
import { ago, duration } from "@/lib/time";
import { color, font } from "@/lib/theme";
import type { Run, Schedule } from "@/lib/types";
import type { ProjectCtx, RoutineInput } from "./types";

const statusTint = (s: string) =>
  s === "done" ? color.teal : s === "failed" ? color.red : s === "running" ? color.accentText : color.muted;

const label = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);

/**
 * A routine: what it does and its inputs, Run now, its schedule, and past runs.
 * (Any Folder's scheduled runs are listed too.)
 */
export function RunsTab({ ctx }: { ctx: ProjectCtx }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [values, setValues] = useState<Record<string, string | string[]>>(() =>
    Object.fromEntries(ctx.inputs.map((i) => [i.name, i.default])),
  );
  const [paused, setPaused] = useState<Record<string, boolean>>({});
  const schedulesChanged = usePeon((s) => s.schedulesChanged);
  const [, tick] = useState(0);
  const { data: runs, error: loadError } = useLoad(
    () => ctx.call<{ runs: Run[] }>("runs").then((r) => r.runs),
    [ctx.changed],
  );
  const { data: scheds } = useLoad(
    () => ctx.call<{ schedules: Schedule[] }>("schedules", {}, 60000).then((r) => r.schedules),
    [schedulesChanged],
  );
  const current = runs?.find((r) => r.status === "running") ?? null;
  const sched = scheds?.[0];

  // The running clock.
  useEffect(() => {
    if (!current) return;
    const t = setInterval(() => tick((n) => n + 1), 1000);
    return () => clearInterval(t);
  }, [current]);

  async function run() {
    setBusy(true);
    setError(null);
    try {
      const { session_id } = await ctx.call<{ session_id: string }>(
        "run",
        { inputs: ctx.inputs.length ? values : undefined },
        60000,
      );
      router.push(`/session/${session_id}`);
    } catch (e: any) {
      setError(e.message);
    }
    setBusy(false);
  }

  async function pause(s: Schedule, on: boolean) {
    setPaused((p) => ({ ...p, [s.key]: !on }));
    try {
      await ask("pause_schedule", { project_id: ctx.project.id, key: s.key, paused: !on });
    } catch (e: any) {
      setError(e.message);
      setPaused((p) => ({ ...p, [s.key]: s.paused }));
    }
  }

  const choose = (input: RoutineInput, option: string) =>
    setValues((v) => {
      if (!input.multi) return { ...v, [input.name]: option };
      const list = Array.isArray(v[input.name]) ? (v[input.name] as string[]) : [];
      return {
        ...v,
        [input.name]: list.includes(option) ? list.filter((o) => o !== option) : [...list, option],
      };
    });

  const number = (r: Run) => (runs ? runs.length - runs.indexOf(r) : 0);
  const past = (runs ?? []).filter((r) => r !== current);

  return (
    <ScrollView contentContainerStyle={st.body}>
      {ctx.routine ? (
        <View style={st.card}>
          <View style={st.cardTop}>
            <Text style={st.cardName}>{ctx.project.name}</Text>
            <Text style={st.file}>routine.json</Text>
          </View>
          <Text style={st.prompt} selectable>
            {ctx.routine.run}
          </Text>
          <ErrorLine message={ctx.routine.error} />
          {ctx.inputs.map((input) => (
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
                  onChangeText={(t) => setValues((v) => ({ ...v, [input.name]: t }))}
                  style={st.field}
                  placeholderTextColor={color.faint}
                />
              )}
            </View>
          ))}
          {current?.session_id ? (
            <Button
              label="Stop"
              kind="secondary"
              height={50}
              onPress={() => stopRun(current.session_id!).catch((e) => setError(e.message))}
            />
          ) : (
            <Button
              label="Run now"
              height={50}
              busy={busy}
              onPress={run}
              icon={<Icon name="play" size={13} color={color.bg} />}
              testID="run-routine"
            />
          )}
        </View>
      ) : null}
      <ErrorLine message={error ?? loadError} />

      {current ? (
        <Tap
          onPress={() => current.session_id && router.push(`/session/${current.session_id}`)}
          style={st.live}
        >
          <View style={st.cardTop}>
            <Text style={st.liveTitle}>Run #{number(current)}</Text>
            <Text style={st.liveTime}>{duration(current.started)}</Text>
          </View>
          <Text style={st.prompt}>Working. Tap to follow along.</Text>
        </Tap>
      ) : null}

      {sched ? (
        <View style={st.sched}>
          <View style={{ flex: 1, gap: 2 }}>
            <Text style={st.schedWhen}>{sched.when}</Text>
            <Text style={st.schedMeta}>
              schedules.json · {sched.scope === "me" ? "only you" : "team"}
              {sched.owner ? ` · set by ${sched.owner}` : ""}
            </Text>
          </View>
          <Toggle
            value={!(paused[sched.key] ?? sched.paused)}
            onChange={(on) => pause(sched, on)}
            label={`Run ${sched.key} on schedule`}
          />
        </View>
      ) : scheds ? (
        <Text style={st.noSched}>
          No schedule yet. Ask in a chat, for example “run this every Monday at 07:00”.
        </Text>
      ) : null}

      <Text style={st.heading}>History</Text>
      {runs == null ? <Loading /> : null}
      {runs && past.length === 0 ? <Text style={st.none}>No runs yet.</Text> : null}
      <View>
        {past.map((r) => (
          <Tap
            key={r.id}
            kb="row"
            onPress={() => r.session_id && router.push(`/session/${r.session_id}`)}
            style={st.run}
          >
            <View style={st.runTop}>
              <Text style={st.runTitle}>
                #{number(r)} <Text style={{ color: statusTint(r.status) }}>{label(r.status)}</Text>
              </Text>
              <Text style={st.runMeta}>
                {r.schedule_key === "manual" ? "manual" : "schedule"} · {duration(r.started, r.finished)} ·{" "}
                {ago(r.started, true)}
              </Text>
            </View>
            {r.error || r.summary || inputsLabel(r.inputs) ? (
              <Text style={st.runSummary} numberOfLines={2}>
                {r.error || r.summary || inputsLabel(r.inputs)}
              </Text>
            ) : null}
          </Tap>
        ))}
      </View>
    </ScrollView>
  );
}

const st = StyleSheet.create({
  body: { paddingHorizontal: 18, paddingTop: 8, paddingBottom: 40, gap: 14, maxWidth: 760, width: "100%" },
  card: { padding: 16, borderRadius: 16, backgroundColor: color.card, gap: 12 },
  cardTop: { flexDirection: "row", justifyContent: "space-between", alignItems: "baseline", gap: 8 },
  cardName: { fontSize: 17, fontWeight: "600", color: color.text },
  file: { fontSize: 11, fontFamily: font.mono, color: color.faint },
  prompt: { fontSize: 14, lineHeight: 20, color: color.textDim },
  input: { gap: 8, minHeight: 40, justifyContent: "center" },
  inputName: { fontSize: 15, color: color.textSoft },
  options: { flexDirection: "row", flexWrap: "wrap", gap: 6 },
  option: { paddingHorizontal: 12, paddingVertical: 7, borderRadius: 9, backgroundColor: color.raised },
  optionOn: { backgroundColor: color.pill },
  optionText: { fontSize: 14, color: color.textDim },
  field: {
    height: 36,
    borderRadius: 9,
    backgroundColor: color.raised,
    paddingHorizontal: 10,
    color: color.text,
    fontSize: 15,
    outlineStyle: "none",
  } as any,
  live: {
    gap: 8,
    padding: 14,
    borderRadius: 14,
    borderWidth: 1,
    borderColor: color.accentBorder,
    backgroundColor: color.card,
  },
  liveTitle: { fontSize: 14, fontWeight: "600", color: color.text },
  liveTime: { fontSize: 14, color: color.accentText, fontVariant: ["tabular-nums"] },
  sched: {
    flexDirection: "row",
    alignItems: "center",
    gap: 12,
    paddingHorizontal: 14,
    paddingVertical: 12,
    borderRadius: 14,
    backgroundColor: color.card,
  },
  schedWhen: { fontSize: 15, color: color.text },
  schedMeta: { fontSize: 12, color: color.muted },
  noSched: {
    padding: 14,
    borderRadius: 14,
    borderWidth: 1,
    borderStyle: "dashed",
    borderColor: color.outline,
    fontSize: 13,
    lineHeight: 19,
    color: color.muted,
  },
  heading: { fontSize: 13, color: color.muted, marginTop: 4 },
  none: { fontSize: 14, color: color.faint },
  run: {
    paddingVertical: 12,
    paddingHorizontal: 2,
    gap: 3,
    borderBottomWidth: 1,
    borderBottomColor: color.hairline,
  },
  runTop: { flexDirection: "row", justifyContent: "space-between", gap: 10 },
  runTitle: { fontSize: 15, color: color.text },
  runMeta: { fontSize: 12, color: color.muted },
  runSummary: { fontSize: 13, color: color.textDim },
});
