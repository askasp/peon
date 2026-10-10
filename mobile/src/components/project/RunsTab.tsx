import { useEffect, useState } from "react";
import { ScrollView, StyleSheet, Text, TextInput, View } from "react-native";
import { router } from "expo-router";
import { Icon } from "../Icon";
import { Sheet } from "../Sheet";
import { Button, Card, Empty, ErrorLine, kbProps, Loading, Tap } from "../ui";
import { usePeon } from "@/lib/peon";
import { inputsLabel, runWho, stopRun } from "@/lib/runs";
import { useLoad } from "@/lib/useLoad";
import { ago, duration } from "@/lib/time";
import { color } from "@/lib/theme";
import type { Run } from "@/lib/types";
import type { ProjectCtx, RoutineInput } from "./types";

const statusTint = (s: string) =>
  s === "done" ? color.teal : s === "failed" ? color.red : s === "running" ? color.accentText : color.muted;

const label = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);

function dayLabel(iso: string): string {
  const d = new Date(iso.endsWith("Z") ? iso : `${iso}Z`);
  const day = (x: Date) => new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime();
  const days = Math.round((day(new Date()) - day(d)) / 86400000);
  if (days === 0) return "Today";
  if (days === 1) return "Yesterday";
  if (days < 7) return d.toLocaleDateString("en-GB", { weekday: "long" });
  return d.toLocaleDateString("en-GB", { day: "numeric", month: "long" });
}

/** A routine's runs: run it (with inputs, if it has any), follow the current run, open past ones. */
export function RunsTab({ ctx }: { ctx: ProjectCtx }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [asking, setAsking] = useState(false);
  const [query, setQuery] = useState("");
  const me = usePeon((s) => s.user?.id);
  const [, tick] = useState(0);
  const { data: runs, error: loadError } = useLoad(
    () => ctx.call<{ runs: Run[] }>("runs").then((r) => r.runs),
    [ctx.changed],
  );
  const current = runs?.find((r) => r.status === "running") ?? null;

  // The running clock.
  useEffect(() => {
    if (!current) return;
    const t = setInterval(() => tick((n) => n + 1), 1000);
    return () => clearInterval(t);
  }, [current]);

  async function run(inputs?: Record<string, string | string[]>) {
    setBusy(true);
    setError(null);
    setAsking(false);
    try {
      const { session_id } = await ctx.call<{ session_id: string }>("run", { inputs }, 60000);
      router.push(`/session/${session_id}`);
    } catch (e: any) {
      setError(e.message);
    }
    setBusy(false);
  }

  const number = (r: Run) => (runs ? runs.length - runs.indexOf(r) : 0);
  const who = (r: Run) => runWho(r, me);
  const q = query.trim().toLowerCase();
  const past = (runs ?? [])
    .filter((r) => r !== current)
    .filter(
      (r) => !q || `${r.summary ?? ""} ${r.error ?? ""} ${inputsLabel(r.inputs)}`.toLowerCase().includes(q),
    );

  return (
    <ScrollView contentContainerStyle={st.body}>
      <View style={{ flexDirection: "row", gap: 10 }}>
        {current?.session_id ? (
          <Button
            label="Stop"
            kind="secondary"
            height={50}
            style={{ flex: 1 }}
            onPress={() => stopRun(current.session_id!).catch((e) => setError(e.message))}
          />
        ) : (
          <Button
            label="Run"
            height={50}
            style={{ flex: 1 }}
            busy={busy}
            onPress={() => run()}
            icon={<Icon name="play" size={13} color={color.bg} />}
            testID="run-routine"
          />
        )}
        {ctx.inputs.length && !current ? (
          <Button label="Run with…" kind="secondary" height={50} onPress={() => setAsking(true)} />
        ) : null}
      </View>
      <ErrorLine message={error ?? loadError} />

      {current ? (
        <Tap onPress={() => current.session_id && router.push(`/session/${current.session_id}`)}>
          <Card accent>
            <View style={st.cardHead}>
              <Text style={st.cardTitle}>
                Run #{number(current)} · {current.schedule_key === "manual" ? "manual" : current.schedule_key}
              </Text>
              <Text style={{ color: color.accentText, fontVariant: ["tabular-nums"] }}>
                {duration(current.started)}
              </Text>
            </View>
            <Text style={st.cardBody}>Working. Tap to follow along.</Text>
          </Card>
        </Tap>
      ) : null}

      <TextInput
        value={query}
        onChangeText={setQuery}
        placeholder="Search runs and results"
        placeholderTextColor={color.faint}
        autoCapitalize="none"
        style={st.search}
        {...kbProps("search")}
      />
      {runs == null ? <Loading /> : null}
      {runs && runs.length === 0 ? <Empty title="No runs yet" /> : null}
      {runs && runs.length > 0 && past.length === 0 && q ? <Empty title="No runs match" /> : null}
      <View>
        {past.map((r, i) => {
          const day = dayLabel(r.started);
          const header = i === 0 || dayLabel(past[i - 1].started) !== day ? day : null;
          const inputs = inputsLabel(r.inputs);
          return (
            <View key={r.id}>
              {header ? <Text style={st.day}>{header}</Text> : null}
              <Tap
                kb="row"
                onPress={() => r.session_id && router.push(`/session/${r.session_id}`)}
                style={st.run}
              >
                <View style={st.runTop}>
                  <Text style={st.runTitle}>
                    #{number(r)} <Text style={{ color: statusTint(r.status) }}>{label(r.status)}</Text>
                  </Text>
                  <Text style={st.runMeta}>
                    {who(r)} · {duration(r.started, r.finished)} · {ago(r.started, true)}
                  </Text>
                </View>
                {inputs ? <Text style={st.runMeta}>{inputs}</Text> : null}
                {r.error || r.summary ? (
                  <Text style={st.runSummary} numberOfLines={2}>
                    {r.error || r.summary}
                  </Text>
                ) : null}
              </Tap>
            </View>
          );
        })}
      </View>

      <InputsSheet visible={asking} inputs={ctx.inputs} onClose={() => setAsking(false)} onRun={run} />
    </ScrollView>
  );
}

// The routine's inputs: choices as chips (several for multi inputs), free text otherwise.
function InputsSheet({
  visible,
  inputs,
  onClose,
  onRun,
}: {
  visible: boolean;
  inputs: RoutineInput[];
  onClose: () => void;
  onRun: (values: Record<string, string | string[]>) => void;
}) {
  const [values, setValues] = useState<Record<string, string | string[]>>(() =>
    Object.fromEntries(inputs.map((i) => [i.name, i.default])),
  );

  const toggle = (input: RoutineInput, option: string) =>
    setValues((v) => {
      if (!input.multi) return { ...v, [input.name]: option };
      const list = Array.isArray(v[input.name]) ? (v[input.name] as string[]) : [];
      return {
        ...v,
        [input.name]: list.includes(option) ? list.filter((o) => o !== option) : [...list, option],
      };
    });

  return (
    <Sheet visible={visible} title="Run with" onClose={onClose}>
      <ScrollView style={{ maxHeight: 460 }} contentContainerStyle={{ gap: 14, paddingHorizontal: 4 }}>
        {inputs.map((input) => (
          <View key={input.name} style={{ gap: 6 }}>
            <Text style={st.inputName}>{input.name}</Text>
            {input.options.length ? (
              <View style={st.options}>
                {input.options.map((o) => {
                  const v = values[input.name];
                  const on = Array.isArray(v) ? v.includes(o) : v === o;
                  return (
                    <Tap key={o} onPress={() => toggle(input, o)} style={[st.option, on && st.optionOn]}>
                      <Text style={[st.optionText, on && { color: color.accentInk }]}>{o}</Text>
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
        <Button label="Run" height={44} onPress={() => onRun(values)} />
      </ScrollView>
    </Sheet>
  );
}

const st = StyleSheet.create({
  body: { paddingHorizontal: 18, paddingTop: 8, paddingBottom: 40, gap: 14 },
  cardHead: { flexDirection: "row", justifyContent: "space-between" },
  cardTitle: { fontSize: 14, fontWeight: "600", color: color.text },
  cardBody: { fontSize: 14, color: color.textDim },
  run: {
    paddingVertical: 12,
    paddingHorizontal: 2,
    gap: 3,
    borderBottomWidth: 1,
    borderBottomColor: color.hairline,
  },
  runTop: { flexDirection: "row", justifyContent: "space-between", gap: 10 },
  runTitle: { fontSize: 15, color: color.text },
  runMeta: { fontSize: 13, color: color.muted },
  runSummary: { fontSize: 13, color: color.textDim },
  search: {
    height: 38,
    borderRadius: 10,
    backgroundColor: color.field,
    paddingHorizontal: 12,
    color: color.text,
    fontSize: 14,
  },
  day: { fontSize: 12, color: color.muted, paddingTop: 14, paddingBottom: 2 },
  inputName: { fontSize: 13, color: color.muted },
  options: { flexDirection: "row", flexWrap: "wrap", gap: 6 },
  option: { paddingHorizontal: 12, paddingVertical: 7, borderRadius: 14, backgroundColor: color.field },
  optionOn: { backgroundColor: color.accent },
  optionText: { fontSize: 13, color: color.text },
  field: {
    height: 40,
    borderRadius: 10,
    backgroundColor: color.field,
    paddingHorizontal: 12,
    color: color.text,
    fontSize: 14,
  },
});
