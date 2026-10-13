// An Operations Project's runs (O4), newest first, by day. A chain lists the
// runs its steps started under it; a step that ran once per item is one row
// ("refund × 3"). Scheduled runs land here, and in Inbox when they wait for you.

import { useState } from "react";
import { ScrollView, StyleSheet, Text, View } from "react-native";
import { PickSheet } from "../Sheet";
import { Badge, ErrorLine, Loading, Tap } from "../ui";
import { useLoad } from "@/lib/useLoad";
import { useWide } from "@/lib/useWide";
import { usePeon } from "@/lib/peon";
import { clock, dayLabel, runResult, runState } from "@/lib/runs";
import { duration } from "@/lib/time";
import { color, font } from "@/lib/theme";
import type { Run } from "@/lib/types";
import type { ProjectCtx } from "./types";

type Filter = "all" | "needs" | "failed";

export function RunsTab({ ctx, onOpen }: { ctx: ProjectCtx; onOpen: (run: Run) => void }) {
  const wide = useWide();
  const me = usePeon((p) => p.user?.id);
  const { data: runs, error } = useLoad(
    () => ctx.call<{ runs: Run[] }>("runs").then((r) => r.runs),
    [ctx.changed],
  );
  const [filter, setFilter] = useState<Filter>("all");
  const [procedure, setProcedure] = useState<string | null>(null);
  const [picking, setPicking] = useState(false);

  if (!runs) return error ? <ErrorLine message={error} /> : <Loading />;

  const children = new Map<number, Run[]>();
  for (const r of runs) if (r.parent_id) children.set(r.parent_id, [...(children.get(r.parent_id) ?? []), r]);
  const failed = (r: Run) => runState(r).glyph === "✕" || runState(r).glyph === "!";
  const top = runs
    .filter((r) => !r.parent_id || !runs.some((p) => p.id === r.parent_id))
    .filter((r) => !procedure || r.procedure === procedure)
    .filter((r) =>
      filter === "needs"
        ? r.status === "waiting"
        : filter === "failed"
          ? failed(r) || (children.get(r.id) ?? []).some(failed)
          : true,
    );
  const days: { day: string; runs: Run[] }[] = [];
  for (const r of top) {
    const day = dayLabel(r.started);
    const last = days[days.length - 1];
    if (last?.day === day) last.runs.push(r);
    else days.push({ day, runs: [r] });
  }
  const names = [...new Set(runs.map((r) => r.procedure).filter(Boolean))] as string[];

  return (
    <ScrollView contentContainerStyle={[st.body, wide && { paddingHorizontal: 32 }]}>
      <View style={st.filters}>
        {(
          [
            ["all", "All"],
            ["needs", "Needs you"],
            ["failed", "Failed"],
          ] as const
        ).map(([v, label]) => (
          <Tap
            key={v}
            onPress={() => setFilter(v)}
            style={[st.filter, filter === v && st.filterOn]}
            testID={`runs-${v}`}
          >
            <Text style={[st.filterText, filter === v && { color: color.textStrong }]}>{label}</Text>
          </Tap>
        ))}
        <View style={{ flex: 1 }} />
        {names.length > 1 ? (
          <Tap onPress={() => setPicking(true)} style={st.pick} testID="runs-procedure">
            <Text style={st.filterText}>{procedure ?? "All procedures"} ⌄</Text>
          </Tap>
        ) : null}
      </View>

      {wide ? (
        <View style={[st.row, st.headRow]}>
          <Text style={[st.head, st.colName]}>Procedure</Text>
          <Text style={[st.head, st.colResult]}>Result</Text>
          <Text style={[st.head, st.colWho]}>Started by</Text>
          <Text style={[st.head, st.colWhen]}>When</Text>
        </View>
      ) : null}

      {days.length === 0 ? (
        <Text style={st.empty}>{runs.length ? "No runs match." : "No runs yet."}</Text>
      ) : null}
      {days.map((d) => (
        <View key={d.day}>
          <Text style={st.day}>{d.day}</Text>
          {d.runs.map((r) => (
            <View key={r.id} style={st.group}>
              <RunRow run={r} me={me} wide={wide} onPress={() => onOpen(r)} />
              {grouped(children.get(r.id) ?? []).map((c) => (
                <RunRow
                  key={c.key}
                  run={c.run}
                  count={c.count}
                  summary={c.summary}
                  me={me}
                  wide={wide}
                  child
                  onPress={() => onOpen(c.count > 1 ? r : c.run)}
                />
              ))}
            </View>
          ))}
        </View>
      ))}

      <PickSheet
        visible={picking}
        title="Procedure"
        onClose={() => setPicking(false)}
        items={[{ key: "", label: "All procedures" }, ...names.map((n) => ({ key: n, label: n }))]}
        onPick={(k) => {
          setPicking(false);
          setProcedure(k || null);
        }}
      />
    </ScrollView>
  );
}

// A chain's children, one row per procedure: "refund × 3 · 2 done · 1 failed".
function grouped(runs: Run[]) {
  const out: { key: string; run: Run; count: number; summary?: string }[] = [];
  for (const r of runs) {
    const same = out.find((o) => o.run.procedure === r.procedure);
    if (!same) {
      out.push({ key: `c${r.id}`, run: r, count: 1 });
      continue;
    }
    same.count++;
    const all = runs.filter((x) => x.procedure === r.procedure);
    const failed = all.filter((x) => x.status === "failed");
    // The group reads as its worst run.
    if (failed.length) same.run = failed[0];
    same.summary = [`${all.length - failed.length} done`, failed.length ? `${failed.length} failed` : null]
      .filter(Boolean)
      .join(" · ");
  }
  return out;
}

function RunRow({
  run: r,
  count = 1,
  summary,
  me,
  wide,
  child,
  onPress,
}: {
  run: Run;
  count?: number;
  summary?: string;
  me: number | undefined;
  wide: boolean;
  child?: boolean;
  onPress: () => void;
}) {
  const state = runState(r);
  const name = `${r.procedure ?? r.schedule_key}${count > 1 ? ` × ${count}` : ""}`;
  const result = summary ?? runResult(r);
  const who = startedBy(r, me);
  const when = `${clock(r.started)}${r.finished ? ` · ${duration(r.started, r.finished)}` : ""}`;
  const glyph = <Text style={[st.glyph, { color: state.tint }, child && st.glyphChild]}>{state.glyph}</Text>;
  return (
    <Tap kb="row" onPress={onPress} style={[st.row, child && st.childRow]} testID={`run-${r.id}`}>
      {wide ? (
        <>
          <View style={[st.colName, st.nameCell]}>
            {child ? <Text style={st.elbow}>└</Text> : null}
            {glyph}
            <Text style={[st.name, child && st.childName]} numberOfLines={1}>
              {name}
            </Text>
          </View>
          <Text style={[st.result, st.colResult, child && st.childText]} numberOfLines={1}>
            {result}
          </Text>
          <View style={[st.colWho, st.whoCell]}>
            {who.badge ? <Badge label="Schedule" tint="teal" /> : null}
            <Text style={[st.who, child && st.childText]} numberOfLines={1}>
              {who.text}
            </Text>
          </View>
          <Text style={[st.who, st.colWhen, child && st.childText]}>{when}</Text>
        </>
      ) : (
        <>
          {child ? <Text style={st.elbow}>└</Text> : null}
          {glyph}
          <View style={{ flex: 1, gap: 3, minWidth: 0 }}>
            <View style={{ flexDirection: "row", alignItems: "baseline", gap: 8 }}>
              <Text style={[st.name, child && st.childName, { flexShrink: 1 }]} numberOfLines={1}>
                {name}
              </Text>
              <Text style={st.who}>{clock(r.started)}</Text>
            </View>
            <Text style={[st.result, child && st.childText]} numberOfLines={2}>
              {result}
            </Text>
            {child ? null : (
              <Text style={st.who} numberOfLines={1}>
                {who.badge ? "Schedule · " : ""}
                {who.text}
              </Text>
            )}
          </View>
        </>
      )}
    </Tap>
  );
}

/** "you · /refund-asks", a schedule, "weekly-refunds" (a chain). */
function startedBy(r: Run, me: number | undefined): { badge: boolean; text: string } {
  const who = r.owner_id === me ? "you" : (r.owner ?? "someone");
  switch (r.trigger) {
    case "schedule":
      return { badge: true, text: r.schedule_key };
    case "slash":
      return { badge: false, text: `${who} · /${r.procedure}` };
    case "button":
      return { badge: false, text: `${who} · button` };
    case "chain":
      return { badge: false, text: "chain" };
    case "queue":
      return { badge: false, text: `queue${r.ticket ? ` · ${r.ticket}` : ""}` };
    default:
      return r.schedule_key !== "manual"
        ? { badge: true, text: r.schedule_key }
        : { badge: false, text: who };
  }
}

const st = StyleSheet.create({
  body: { paddingHorizontal: 16, paddingTop: 16, paddingBottom: 48, gap: 4 },
  filters: { flexDirection: "row", alignItems: "center", gap: 4, paddingBottom: 10 },
  filter: { paddingHorizontal: 11, paddingVertical: 5, borderRadius: 7 },
  filterOn: { backgroundColor: color.raised },
  filterText: { fontSize: 13.5, color: color.muted },
  pick: {
    paddingHorizontal: 11,
    paddingVertical: 5,
    borderRadius: 7,
    borderWidth: 1,
    borderColor: color.outline,
  },
  row: {
    flexDirection: "row",
    alignItems: "center",
    gap: 10,
    paddingVertical: 11,
    borderBottomWidth: 1,
    borderBottomColor: color.hairline,
  },
  headRow: { paddingVertical: 8 },
  head: { fontSize: 13, color: color.muted },
  group: { borderBottomWidth: 1, borderBottomColor: color.hairline },
  childRow: { paddingVertical: 6, borderBottomWidth: 0 },
  colName: { flexBasis: 0, flexGrow: 2.2, minWidth: 0 },
  colResult: { flexBasis: 0, flexGrow: 3.6, minWidth: 0 },
  colWho: { flexBasis: 0, flexGrow: 2, minWidth: 0 },
  colWhen: { flexBasis: 0, flexGrow: 1.4, minWidth: 0 },
  nameCell: { flexDirection: "row", alignItems: "center", gap: 10 },
  whoCell: { flexDirection: "row", alignItems: "center", gap: 6 },
  glyph: { width: 14, fontSize: 14, fontWeight: "700", textAlign: "center" },
  glyphChild: { fontSize: 12.5 },
  elbow: { color: color.ghost, fontSize: 13, marginLeft: 22, marginRight: -4 },
  name: { fontFamily: font.mono, fontSize: 13.5, color: color.text },
  childName: { fontSize: 12.5, color: color.textSoft },
  result: { fontSize: 14, color: color.text },
  childText: { fontSize: 12.5, color: color.textDim },
  who: { fontSize: 13, color: color.muted },
  day: { fontSize: 12.5, color: color.faint, paddingTop: 16, paddingBottom: 6 },
  empty: { fontSize: 14, color: color.muted, paddingVertical: 24 },
});
