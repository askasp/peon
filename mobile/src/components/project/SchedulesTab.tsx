import { useEffect, useState } from "react";
import { ScrollView, StyleSheet, Text, TextInput, View } from "react-native";
import { router } from "expo-router";
import { PickSheet } from "../Sheet";
import { Button, Card, Empty, ErrorLine, Loading, Segmented, Tap } from "../ui";
import { confirm } from "@/lib/confirm";
import { useLoad } from "@/lib/useLoad";
import { color, font } from "@/lib/theme";
import { ago } from "@/lib/time";
import type { Run } from "@/lib/types";
import type { ProjectCtx } from "./types";

type Params = Record<string, string>;
type Sched = {
  key: string;
  when: string;
  cron: string;
  prompt: string;
  scope: string;
  owner: string | null;
  next: string | null;
  last: Run | null;
  /** The last five runs, newest first. */
  runs: Run[];
  params: Params;
};
type Loaded = {
  schedules: Sched[];
  agents: string[];
  models: { value: string; name: string }[];
  blank: Params;
};

const presets = [
  { value: "every", label: "Every" },
  { value: "hourly", label: "Hourly" },
  { value: "daily", label: "Daily" },
  { value: "weekdays", label: "Weekdays" },
  { value: "mondays", label: "Mondays" },
  { value: "fridays", label: "Fridays" },
  { value: "custom", label: "Cron" },
];

const when = (iso: string | null) =>
  iso
    ? new Date(iso).toLocaleString("en-GB", { weekday: "short", hour: "2-digit", minute: "2-digit" })
    : "never";

const runTint = (status: string) =>
  status === "failed" ? color.red : status === "running" ? color.accentText : color.teal;

/** The project's schedules: list, run now, and a form to add or change one. */
export function SchedulesTab({ ctx }: { ctx: ProjectCtx }) {
  const [version, setVersion] = useState(0);
  const [form, setForm] = useState<Params | null>(null);
  const [editing, setEditing] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const { data, error: loadError } = useLoad(
    () => ctx.call<Loaded>("schedules", {}, 60000),
    [version, ctx.changed],
  );

  const edit = (s: Sched | null) => {
    setError(null);
    setEditing(s?.key ?? null);
    setForm(s ? s.params : { ...(data?.blank ?? {}) });
  };

  async function runNow(key: string) {
    try {
      const { session_id } = await ctx.call<{ session_id: string }>("run_schedule", { key }, 60000);
      router.push(`/session/${session_id}`);
    } catch (e: any) {
      setError(e.message);
    }
  }

  async function remove(key: string) {
    if (!(await confirm(`Delete ${key}?`, "It is removed from schedules.json.", "Delete"))) return;
    try {
      await ctx.call("delete_schedule", { key });
      setVersion((v) => v + 1);
    } catch (e: any) {
      setError(e.message);
    }
  }

  if (form)
    return (
      <ScheduleForm
        ctx={ctx}
        params={form}
        editing={editing}
        agents={data?.agents ?? []}
        models={data?.models ?? []}
        onCancel={() => setForm(null)}
        onSaved={() => {
          setForm(null);
          setVersion((v) => v + 1);
        }}
      />
    );

  return (
    <ScrollView contentContainerStyle={st.body}>
      <View style={{ flexDirection: "row", justifyContent: "flex-end" }}>
        <Button
          label="+ New schedule"
          height={36}
          onPress={() => edit(null)}
          disabled={!data}
          testID="new-schedule"
        />
      </View>
      <ErrorLine message={error ?? loadError} />
      {data == null ? <Loading /> : null}
      {data && data.schedules.length === 0 ? (
        <Empty
          title="No schedules"
          detail="Run this project's prompt on a timer: every morning, weekdays, hourly…"
        />
      ) : null}
      {(data?.schedules ?? []).map((s) => (
        <Card key={s.key}>
          <View style={st.head}>
            <Text style={st.name}>{s.key}</Text>
            <Text style={st.meta}>{s.scope === "me" ? "Only me" : "Team"}</Text>
          </View>
          <Text style={st.meta}>
            {s.when} · next {when(s.next)} · owner {s.owner ?? "—"}
          </Text>
          {s.prompt ? (
            <Text style={st.prompt} numberOfLines={2}>
              {s.prompt}
            </Text>
          ) : null}
          <View style={st.runs}>
            <Text style={st.meta}>Runs · each one is a normal session</Text>
            {s.runs.length === 0 ? <Text style={st.faint}>No runs yet.</Text> : null}
            {s.runs.map((r) => (
              <Tap
                key={r.id}
                kb="item"
                style={st.run}
                disabled={!r.session_id}
                onPress={() => r.session_id && router.push(`/session/${r.session_id}`)}
              >
                <Text style={[st.runStatus, { color: runTint(r.status) }]}>{r.status}</Text>
                <Text style={st.runText} numberOfLines={1}>
                  {r.error ?? r.summary ?? ""}
                </Text>
                <Text style={st.faint}>{ago(r.started, true)}</Text>
              </Tap>
            ))}
          </View>
          <View style={st.actions}>
            <Button label="Run now" kind="secondary" height={32} onPress={() => runNow(s.key)} />
            <Button label="Edit" kind="secondary" height={32} onPress={() => edit(s)} />
            <Button label="Delete" kind="danger" height={32} onPress={() => remove(s.key)} />
          </View>
        </Card>
      ))}
    </ScrollView>
  );
}

function ScheduleForm({
  ctx,
  params,
  editing,
  agents,
  models,
  onCancel,
  onSaved,
}: {
  ctx: ProjectCtx;
  params: Params;
  editing: string | null;
  agents: string[];
  models: { value: string; name: string }[];
  onCancel: () => void;
  onSaved: () => void;
}) {
  const [p, setP] = useState<Params>(params);
  const [described, setDescribed] = useState<{ cron: string; when: string; next: string | null } | null>(
    null,
  );
  const [picker, setPicker] = useState<"agent" | "model" | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const set = (k: string, v: string) => setP((x) => ({ ...x, [k]: v }));

  // What the form means, as the server reads it.
  useEffect(() => {
    const t = setTimeout(() => {
      ctx
        .call<{ cron: string; when: string; next: string | null }>("describe_schedule", { params: p })
        .then(setDescribed)
        .catch(() => {});
    }, 200);
    return () => clearTimeout(t);
  }, [p, ctx]);

  async function save() {
    setBusy(true);
    setError(null);
    try {
      await ctx.call("save_schedule", { params: p }, 30000);
      onSaved();
    } catch (e: any) {
      setError(e.message);
      setBusy(false);
    }
  }

  const routine = ctx.project.kind === "routine";

  return (
    <ScrollView contentContainerStyle={st.body}>
      <Text style={st.formTitle}>{editing ? `Edit ${editing}` : "New schedule"}</Text>
      <Field label="Name">
        <TextInput
          value={p.key}
          onChangeText={(v) => set("key", v)}
          editable={!editing}
          placeholder="morning-digest"
          placeholderTextColor={color.faint}
          autoCapitalize="none"
          style={[st.input, editing ? { opacity: 0.6 } : null]}
        />
      </Field>
      <Field label="When">
        <ScrollView horizontal showsHorizontalScrollIndicator={false}>
          <View style={{ minWidth: 520 }}>
            <Segmented options={presets} value={p.preset} onChange={(v) => set("preset", v)} />
          </View>
        </ScrollView>
        <View style={st.whenRow}>
          {p.preset === "every" ? (
            <>
              <Text style={st.meta}>every</Text>
              <TextInput
                value={p.every}
                onChangeText={(v) => set("every", v)}
                keyboardType="number-pad"
                style={[st.input, st.small]}
              />
              <Text style={st.meta}>minutes</Text>
            </>
          ) : p.preset === "custom" ? (
            <TextInput
              value={p.cron}
              onChangeText={(v) => set("cron", v)}
              placeholder="0 8 * * 1-5"
              placeholderTextColor={color.faint}
              autoCapitalize="none"
              style={[st.input, { flex: 1, fontFamily: font.mono }]}
            />
          ) : (
            <>
              <Text style={st.meta}>{p.preset === "hourly" ? "at minute of" : "at"}</Text>
              <TextInput
                value={p.at}
                onChangeText={(v) => set("at", v)}
                placeholder="08:00"
                placeholderTextColor={color.faint}
                style={[st.input, st.small]}
              />
            </>
          )}
        </View>
        <Text style={[st.meta, { color: described?.next ? color.textDim : color.red }]}>
          {described
            ? described.next
              ? `${described.when} (${described.cron}) · next ${when(described.next)}`
              : `Not a valid time (${described.cron || "empty"})`
            : " "}
        </Text>
      </Field>
      <Field label={routine ? "Prompt (empty runs the routine)" : "Prompt"}>
        <TextInput
          value={p.prompt}
          onChangeText={(v) => set("prompt", v)}
          multiline
          placeholder="/digest since the last run"
          placeholderTextColor={color.faint}
          style={[st.input, { minHeight: 80, paddingTop: 10, textAlignVertical: "top" }]}
        />
      </Field>
      <Field label="Who sees the runs">
        <Segmented
          options={[
            { value: "team", label: "Team" },
            { value: "me", label: "Only me" },
          ]}
          value={p.scope}
          onChange={(v) => set("scope", v)}
        />
      </Field>
      <View style={st.whenRow}>
        <Tap style={st.pick} onPress={() => setPicker("agent")}>
          <Text style={st.pickText}>Agent: {p.agent || "default"}</Text>
        </Tap>
        <Tap style={st.pick} onPress={() => setPicker("model")}>
          <Text style={st.pickText} numberOfLines={1}>
            Model: {models.find((m) => m.value === p.model)?.name ?? (p.model || "default")}
          </Text>
        </Tap>
      </View>
      <ErrorLine message={error} />
      <View style={st.actions}>
        <Button label="Cancel" kind="secondary" height={40} onPress={onCancel} />
        <Button
          label="Save"
          height={40}
          busy={busy}
          onPress={save}
          style={{ flex: 1 }}
          testID="save-schedule"
        />
      </View>

      <PickSheet
        visible={picker === "agent"}
        title="Agent"
        items={[{ key: "", label: "default" }, ...agents.map((a) => ({ key: a, label: a }))].map((i) => ({
          ...i,
          active: i.key === p.agent,
        }))}
        onClose={() => setPicker(null)}
        onPick={(v) => {
          set("agent", v);
          setPicker(null);
        }}
      />
      <PickSheet
        visible={picker === "model"}
        title="Model"
        items={[
          { key: "", label: "default", detail: null },
          ...models.map((m) => ({ key: m.value, label: m.name, detail: m.value })),
        ].map((i) => ({ ...i, active: i.key === p.model }))}
        onClose={() => setPicker(null)}
        onPick={(v) => {
          set("model", v);
          setPicker(null);
        }}
      />
    </ScrollView>
  );
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <View style={{ gap: 6 }}>
      <Text style={st.label}>{label}</Text>
      {children}
    </View>
  );
}

const st = StyleSheet.create({
  runs: { gap: 2 },
  run: { flexDirection: "row", alignItems: "center", gap: 10, paddingVertical: 5 },
  runStatus: { width: 58, fontSize: 12.5, fontFamily: font.mono },
  runText: { flex: 1, fontSize: 13, color: color.textSoft },
  faint: { fontSize: 12, color: color.faint },
  body: { paddingHorizontal: 18, paddingTop: 8, paddingBottom: 40, gap: 12 },
  head: { flexDirection: "row", justifyContent: "space-between" },
  name: { fontSize: 15, fontWeight: "600", color: color.text },
  meta: { fontSize: 13, color: color.muted },
  prompt: { fontSize: 13, color: color.textDim, fontFamily: font.mono },
  actions: { flexDirection: "row", gap: 8 },
  formTitle: { fontSize: 18, fontWeight: "600", color: color.text },
  label: { fontSize: 13, color: color.muted },
  input: {
    height: 40,
    borderRadius: 10,
    backgroundColor: color.field,
    paddingHorizontal: 12,
    color: color.text,
    fontSize: 14,
  },
  small: { width: 80 },
  whenRow: { flexDirection: "row", alignItems: "center", gap: 8, flexWrap: "wrap" },
  pick: {
    paddingHorizontal: 12,
    paddingVertical: 9,
    borderRadius: 10,
    backgroundColor: color.field,
    maxWidth: 280,
  },
  pickText: { fontSize: 13, color: color.textSoft },
});
