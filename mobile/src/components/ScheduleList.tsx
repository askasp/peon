import { useEffect, useState } from "react";
import { ScrollView, StyleSheet, Text, View } from "react-native";
import { router } from "expo-router";
import { Empty, ErrorLine, Group, Loading, SectionLabel, Tap } from "./ui";
import { ask, usePeon } from "@/lib/peon";
import { color } from "@/lib/theme";
import type { Schedule } from "@/lib/types";

// "Today", "Tonight", "Tomorrow", or the weekday of the next run.
function dayLabel(next: Date): string {
  const now = new Date();
  const day = (d: Date) => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
  const days = Math.round((day(next) - day(now)) / 86400000);
  if (days === 0) return next.getHours() >= 18 ? "Tonight" : "Today";
  if (days === 1) return next.getHours() < 6 ? "Tonight" : "Tomorrow";
  if (days < 7) return next.toLocaleDateString("en-GB", { weekday: "long" });
  return next.toLocaleDateString("en-GB", { day: "numeric", month: "short" });
}

const time = (d: Date) =>
  `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;

/** Schedules by when they next run. `scope` filters: "me" (only me), "team" or all. */
export function ScheduleList({ projectId, scope }: { projectId?: number; scope?: "me" | "team" | "all" }) {
  const runsChanged = usePeon((s) => s.runsChanged);
  const schedulesChanged = usePeon((s) => s.schedulesChanged);
  const [list, setList] = useState<Schedule[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    ask<{ schedules: Schedule[] }>("schedules")
      .then((r) => setList(r.schedules))
      .catch((e) => setError(e.message));
  }, [runsChanged, schedulesChanged]);

  if (error) return <ErrorLine message={error} />;
  if (!list) return <Loading />;

  const shown = list
    .filter((s) => projectId == null || s.project.id === projectId)
    .filter((s) => !scope || scope === "all" || s.scope === scope)
    // Soonest first; schedules with no next run (paused or invalid) last.
    .sort((a, b) => (a.next ? Date.parse(a.next) : Infinity) - (b.next ? Date.parse(b.next) : Infinity));

  if (shown.length === 0)
    return <Empty title="No schedules" detail="Add one on a project's Schedules tab, or ask Peon to." />;

  const groups: { label: string; items: Schedule[] }[] = [];
  for (const s of shown) {
    const label = s.next ? dayLabel(new Date(s.next)) : "Not scheduled";
    const g = groups.find((x) => x.label === label);
    if (g) g.items.push(s);
    else groups.push({ label, items: [s] });
  }

  return (
    <ScrollView contentContainerStyle={st.body}>
      {groups.map((g) => (
        <View key={g.label} style={{ gap: 8 }}>
          <SectionLabel>{g.label}</SectionLabel>
          <Group>
            {g.items.map((s, i) => {
              const running = s.last?.status === "running";
              return (
                <Tap
                  kb="row"
                  key={`${s.project.id}-${s.key}`}
                  style={[st.row, i < g.items.length - 1 && st.border]}
                  onPress={() =>
                    router.push({
                      pathname: s.project.kind === "routine" ? "/routine/[id]" : "/project/[id]",
                      params: { id: String(s.project.id), tab: "schedules" },
                    })
                  }
                >
                  <Text style={[st.time, running && { color: color.faint }]}>
                    {s.next ? time(new Date(s.next)) : "—"}
                  </Text>
                  <View style={{ flex: 1, gap: 2 }}>
                    <Text style={[st.name, running && { color: color.textDim }]} numberOfLines={1}>
                      {s.key}
                    </Text>
                    <Text style={st.meta} numberOfLines={1}>
                      {[
                        projectId == null ? s.project.name : null,
                        s.scope === "me" ? "Only me" : "Team",
                        s.owner ? `set by ${s.owner}` : null,
                        running ? "running now" : s.when,
                      ]
                        .filter(Boolean)
                        .join(" · ")}
                    </Text>
                  </View>
                  {s.last && s.last.status !== "running" ? (
                    <Text style={[st.last, { color: s.last.status === "failed" ? color.red : color.teal }]}>
                      {s.last.status}
                    </Text>
                  ) : null}
                </Tap>
              );
            })}
          </Group>
        </View>
      ))}
    </ScrollView>
  );
}

const st = StyleSheet.create({
  body: { paddingHorizontal: 18, paddingTop: 8, paddingBottom: 40, gap: 14 },
  row: { flexDirection: "row", alignItems: "center", gap: 14, paddingVertical: 13, paddingHorizontal: 14 },
  border: { borderBottomWidth: 1, borderBottomColor: color.divider },
  time: { width: 46, fontSize: 15, color: color.text, fontVariant: ["tabular-nums"] },
  name: { fontSize: 15, color: color.text },
  meta: { fontSize: 12, color: color.muted },
  last: { fontSize: 12 },
});
