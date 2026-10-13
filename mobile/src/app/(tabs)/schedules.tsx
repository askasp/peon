import { useEffect, useState } from "react";
import { ScrollView, StyleSheet, Text, View } from "react-native";
import { router } from "expo-router";
import { Letter } from "@/components/desktop/Sidebar";
import { Empty, ErrorLine, LargeTitle, Loading, Screen, Tap, Toggle } from "@/components/ui";
import { folderHref } from "@/lib/folders";
import { ask, usePeon } from "@/lib/peon";
import { color } from "@/lib/theme";
import type { Schedule } from "@/lib/types";

// Schedules across every Project; each one lives in its Project's schedules.json.
export default function Schedules() {
  const runsChanged = usePeon((s) => s.runsChanged);
  const schedulesChanged = usePeon((s) => s.schedulesChanged);
  const [list, setList] = useState<Schedule[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    ask<{ schedules: Schedule[] }>("schedules")
      .then((r) => setList(r.schedules))
      .catch((e) => setError(e.message));
  }, [runsChanged, schedulesChanged]);

  async function pause(s: Schedule, paused: boolean) {
    setList((l) => l && l.map((x) => (x === s ? { ...x, paused } : x)));
    try {
      await ask("pause_schedule", { project_id: s.project.id, key: s.key, paused });
    } catch (e: any) {
      setError(e.message);
      setList((l) => l && l.map((x) => (x.key === s.key && x.project.id === s.project.id ? s : x)));
    }
  }

  const open = (s: Schedule) =>
    router.push({
      pathname: folderHref(s.project) as any,
      params: { tab: s.project.kind === "routine" ? "runs" : "settings" },
    });

  return (
    <Screen>
      <ScrollView contentContainerStyle={st.body}>
        <LargeTitle>Schedules</LargeTitle>
        <ErrorLine message={error} />
        {list == null ? (
          error ? null : (
            <Loading />
          )
        ) : list.length === 0 ? (
          <Empty title="No schedules" />
        ) : (
          <View style={st.group}>
            {list.map((s, i) => (
              <View key={`${s.project.id}-${s.key}`} style={[st.row, i < list.length - 1 && st.line]}>
                <Tap onPress={() => open(s)} style={st.left} kb="row">
                  <Letter name={s.project.name} size={32} />
                  <View style={{ flex: 1, gap: 2 }}>
                    <Text style={st.name} numberOfLines={1}>
                      {s.key}
                    </Text>
                    <Text style={st.meta} numberOfLines={1}>
                      {s.when} · {s.project.name} · {s.scope === "me" ? "only you" : "team"}
                    </Text>
                  </View>
                </Tap>
                <Toggle value={!s.paused} onChange={(on) => pause(s, !on)} label={`Run ${s.key}`} />
              </View>
            ))}
          </View>
        )}
        {list?.length ? (
          <Text style={st.foot}>Each schedule lives in its Project&apos;s schedules.json.</Text>
        ) : null}
      </ScrollView>
    </Screen>
  );
}

const st = StyleSheet.create({
  body: { paddingHorizontal: 18, paddingTop: 6, paddingBottom: 24, gap: 14, maxWidth: 760, width: "100%" },
  group: { borderRadius: 14, backgroundColor: color.card, overflow: "hidden" },
  row: { flexDirection: "row", alignItems: "center", gap: 12, paddingHorizontal: 14, paddingVertical: 12 },
  line: { borderBottomWidth: 1, borderBottomColor: color.divider },
  left: { flex: 1, flexDirection: "row", alignItems: "center", gap: 12 },
  name: { fontSize: 15, color: color.text },
  meta: { fontSize: 12, color: color.muted },
  foot: { fontSize: 13, lineHeight: 19, color: color.faint },
});
