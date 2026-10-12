import { useState } from "react";
import { ActivityIndicator, RefreshControl, ScrollView, StyleSheet, Text, View } from "react-native";
import { router } from "expo-router";
import { Icon } from "@/components/Icon";
import { Empty, ErrorLine, LargeTitle, Screen, Tap } from "@/components/ui";
import { ask, usePeon } from "@/lib/peon";
import { useLoad } from "@/lib/useLoad";
import { runLine, stopRun } from "@/lib/runs";
import { color } from "@/lib/theme";
import type { Project, Run } from "@/lib/types";

// 06 · Operations Folders: each with its schedule and last run; stop a run that's going.
export default function Routines() {
  const projects = usePeon((s) => s.projects);
  const runsChanged = usePeon((s) => s.runsChanged);
  const activity = usePeon((s) => s.activity);
  const routines = projects.filter((p) => p.kind === "routine");
  const [busy, setBusy] = useState<number | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [refreshing, setRefreshing] = useState(false);

  const ids = routines.map((r) => r.id).join(",");

  // The latest run of each routine.
  const { data, reload: load } = useLoad(async (): Promise<Record<number, Run | null>> => {
    const entries = await Promise.all(
      ids
        .split(",")
        .filter(Boolean)
        .map(async (pid) => {
          try {
            const { runs } = await ask<{ runs: Run[] }>("routine", { project_id: Number(pid) });
            return [Number(pid), runs[0] ?? null] as const;
          } catch {
            return [Number(pid), null] as const;
          }
        }),
    );
    return Object.fromEntries(entries);
  }, [ids, runsChanged, activity]);
  const last = data ?? {};

  async function stop(p: Project) {
    const run = last[p.id];
    if (!run?.session_id) return;
    setBusy(p.id);
    setError(null);
    try {
      await stopRun(run.session_id);
      await load();
    } catch (e: any) {
      setError(e.message);
    }
    setBusy(null);
  }

  return (
    <Screen>
      <ScrollView
        contentContainerStyle={st.body}
        refreshControl={
          <RefreshControl
            refreshing={refreshing}
            tintColor={color.muted}
            onRefresh={async () => {
              setRefreshing(true);
              await load();
              setRefreshing(false);
            }}
          />
        }
      >
        <LargeTitle
          right={
            <Tap style={st.pill} onPress={() => router.push("/schedules")} testID="open-schedules">
              <Text style={st.pillText}>Schedules</Text>
            </Tap>
          }
        >
          Operations
        </LargeTitle>
        <ErrorLine message={error} />
        {routines.length === 0 ? (
          <Empty
            title="No Operations Folders yet"
            detail="Make one with +, or from the composer: “make a procedure that…”."
          />
        ) : null}

        {routines.map((p) => {
          const run = last[p.id];
          const line = runLine(run ?? null);
          const running = run?.status === "running";
          return (
            <Tap
              kb="row"
              key={p.id}
              style={st.card}
              onPress={() => router.push(`/routine/${p.id}`)}
              testID={`routine-${p.name}`}
            >
              <View style={{ flex: 1, gap: 4 }}>
                <Text style={st.name}>{p.name}</Text>
                <Text style={st.meta}>
                  {[p.schedule || "On demand", p.scope === "private" ? "Only me" : "Team"].join(" · ")}
                </Text>
                {line ? (
                  <Text style={[st.meta, { color: line.tint }]} numberOfLines={1}>
                    {line.text}
                  </Text>
                ) : null}
              </View>
              {running ? (
                <Tap
                  haptic
                  onPress={() => stop(p)}
                  style={[st.action, st.stop]}
                  disabled={busy === p.id}
                  hitSlop={8}
                >
                  {busy === p.id ? <ActivityIndicator color={color.text} /> : <View style={st.stopSquare} />}
                </Tap>
              ) : (
                <Icon name="chevron" size={16} color={color.muted} />
              )}
            </Tap>
          );
        })}
      </ScrollView>
    </Screen>
  );
}

const st = StyleSheet.create({
  body: { paddingHorizontal: 18, paddingTop: 6, paddingBottom: 24, gap: 10 },
  pill: { paddingHorizontal: 12, paddingVertical: 6, borderRadius: 16, backgroundColor: color.field },
  pillText: { fontSize: 14, color: color.accentText },
  card: {
    flexDirection: "row",
    alignItems: "center",
    gap: 12,
    padding: 14,
    borderRadius: 16,
    backgroundColor: color.card,
  },
  name: { fontSize: 16, color: color.text },
  meta: { fontSize: 13, color: color.muted },
  action: { width: 44, height: 44, borderRadius: 22, alignItems: "center", justifyContent: "center" },
  stop: { borderWidth: 1, borderColor: color.outline },
  stopSquare: { width: 12, height: 12, borderRadius: 2, backgroundColor: color.text },
});
