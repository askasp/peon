import { useMemo, useState } from "react";
import { RefreshControl, ScrollView, StyleSheet, Text, TextInput, View } from "react-native";
import { router } from "expo-router";
import {
  Dot,
  Empty,
  Group,
  kbProps,
  LargeTitle,
  Loading,
  Screen,
  SectionLabel,
  Tap,
  Tile,
} from "@/components/ui";
import { ask, usePeon } from "@/lib/peon";
import { useLoad } from "@/lib/useLoad";
import { ago } from "@/lib/time";
import { color } from "@/lib/theme";
import type { Project } from "@/lib/types";

const groups: { kind: Project["kind"]; label: string }[] = [
  { kind: "code", label: "Code" },
  { kind: "chat", label: "Chat" },
  { kind: "system", label: "System" },
];

// 03 · Projects: code and chat projects, with their session count and last activity.
export default function Projects() {
  const projects = usePeon((s) => s.projects);
  const running = usePeon((s) => s.running);
  const joined = usePeon((s) => s.joined);
  const [query, setQuery] = useState("");
  const [refreshing, setRefreshing] = useState(false);

  // Session counts take a request per project, so they come separately.
  const { data, reload: load } = useLoad(async (): Promise<Record<number, Project>> => {
    if (!joined) return {};
    const r = await ask<{ projects: Project[] }>("projects", { stats: true });
    return Object.fromEntries(r.projects.map((p) => [p.id, p]));
  }, [joined]);
  const stats = data ?? {};

  const busy = useMemo(() => new Set(running.map((r) => r.project.id)), [running]);
  const q = query.trim().toLowerCase();
  const shown = projects.filter((p) => p.kind !== "routine" && (!q || p.name.toLowerCase().includes(q)));

  return (
    <Screen>
      <ScrollView
        contentContainerStyle={st.body}
        keyboardShouldPersistTaps="handled"
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
            <Tap onPress={() => router.push("/new")} hitSlop={10} testID="new-project">
              <Text style={{ fontSize: 28, fontWeight: "300", color: color.textSoft }}>+</Text>
            </Tap>
          }
        >
          Projects
        </LargeTitle>
        <TextInput
          value={query}
          onChangeText={setQuery}
          placeholder="Search"
          placeholderTextColor={color.faint}
          style={st.search}
          autoCorrect={false}
          autoCapitalize="none"
          {...kbProps("search")}
        />

        {!joined ? <Loading /> : null}
        {joined && shown.length === 0 ? <Empty title={q ? "No match" : "No projects yet"} /> : null}

        {groups.map(({ kind, label }) => {
          const list = shown.filter((p) => p.kind === kind);
          if (list.length === 0) return null;
          return (
            <View key={kind} style={{ gap: 8 }}>
              <SectionLabel>{label}</SectionLabel>
              <Group>
                {list.map((p, i) => {
                  const st2 = stats[p.id];
                  const count = st2?.sessions;
                  const meta =
                    count == null
                      ? p.scope === "private"
                        ? "Only you"
                        : "Team"
                      : `${count} ${kind === "chat" ? "chat" : "session"}${count === 1 ? "" : "s"}${
                          st2?.updated ? ` · ${ago(st2.updated, true)}` : ""
                        }`;
                  return (
                    <Tap
                      kb="row"
                      key={p.id}
                      testID={`project-${p.name}`}
                      onPress={() => router.push(`/project/${p.id}`)}
                      style={[st.row, i < list.length - 1 && st.rowBorder]}
                    >
                      <Tile name={p.name} />
                      <View style={{ flex: 1, gap: 2 }}>
                        <Text style={st.name}>{p.name}</Text>
                        <Text style={st.meta}>{meta}</Text>
                      </View>
                      {busy.has(p.id) ? <Dot /> : null}
                    </Tap>
                  );
                })}
              </Group>
            </View>
          );
        })}
      </ScrollView>
    </Screen>
  );
}

const st = StyleSheet.create({
  body: { paddingHorizontal: 18, paddingTop: 6, paddingBottom: 24, gap: 14 },
  search: {
    height: 40,
    borderRadius: 11,
    backgroundColor: color.field,
    paddingHorizontal: 14,
    color: color.text,
    fontSize: 15,
  },
  row: { flexDirection: "row", alignItems: "center", gap: 12, paddingVertical: 12, paddingHorizontal: 14 },
  rowBorder: { borderBottomWidth: 1, borderBottomColor: color.divider },
  name: { fontSize: 16, color: color.text },
  meta: { fontSize: 13, color: color.muted },
});
