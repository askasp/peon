import { useMemo, useState } from "react";
import { RefreshControl, ScrollView, StyleSheet, Text, TextInput, View } from "react-native";
import { router } from "expo-router";
import { Letter } from "@/components/desktop/Sidebar";
import { Dot, Empty, kbProps, LargeTitle, Loading, Screen, Tap } from "@/components/ui";
import { filters, folderHref, sortFolders, templateName } from "@/lib/folders";
import { ask, usePeon } from "@/lib/peon";
import { useLoad } from "@/lib/useLoad";
import { ago } from "@/lib/time";
import { color } from "@/lib/theme";
import type { Project } from "@/lib/types";

// Folders: Home, then every Folder, filtered by the template it was made from.
export default function Folders() {
  const projects = usePeon((s) => s.projects);
  const running = usePeon((s) => s.running);
  const joined = usePeon((s) => s.joined);
  const [filter, setFilter] = useState("all");
  const [query, setQuery] = useState("");
  const [refreshing, setRefreshing] = useState(false);

  // Chat counts take a request per Folder, so they come separately.
  const { data, reload: load } = useLoad(async (): Promise<Record<number, Project>> => {
    if (!joined) return {};
    const r = await ask<{ projects: Project[] }>("projects", { stats: true });
    return Object.fromEntries(r.projects.map((p) => [p.id, p]));
  }, [joined]);
  const stats = data ?? {};

  // Per Folder: amber when a chat needs you, green while one works.
  const busy = useMemo(() => {
    const m = new Map<number, string>();
    for (const r of running) if (m.get(r.project.id) !== "waiting") m.set(r.project.id, r.status);
    return m;
  }, [running]);
  const q = query.trim().toLowerCase();
  const { home, folders: all } = sortFolders(projects, filter);
  const folders = all.filter((p) => !q || p.name.includes(q));

  const meta = (p: Project) => {
    const s = stats[p.id];
    const count = s?.sessions != null ? `${s.sessions} chat${s.sessions === 1 ? "" : "s"}` : null;
    return [templateName[p.kind], count, s?.updated ? ago(s.updated, true) : null]
      .filter(Boolean)
      .join(" · ");
  };
  const dot = (p: Project) =>
    busy.has(p.id) ? <Dot tint={busy.get(p.id) === "waiting" ? color.needs : color.accent} /> : null;

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
            <Tap onPress={() => router.push("/new-folder" as any)} hitSlop={10} testID="new-project">
              <Text style={{ fontSize: 28, fontWeight: "300", color: color.textSoft }}>+</Text>
            </Tap>
          }
        >
          Folders
        </LargeTitle>
        <TextInput
          value={query}
          onChangeText={setQuery}
          placeholder="Search Folders"
          placeholderTextColor="#62626b"
          autoCapitalize="none"
          autoCorrect={false}
          style={st.search}
          {...kbProps("search")}
        />
        <ScrollView
          horizontal
          showsHorizontalScrollIndicator={false}
          style={st.chipsWrap}
          contentContainerStyle={st.chips}
        >
          {filters.map((f) => (
            <Tap
              key={f.key}
              onPress={() => setFilter(f.key)}
              style={[st.chip, filter === f.key && st.chipOn]}
            >
              <Text style={[st.chipText, filter === f.key && { color: color.textStrong }]}>{f.label}</Text>
            </Tap>
          ))}
        </ScrollView>

        {home ? (
          <Tap
            kb="row"
            testID="project-home"
            onPress={() => router.push(folderHref(home) as any)}
            style={st.home}
          >
            <View style={st.homeTile}>
              <Text style={st.homeLetter}>H</Text>
            </View>
            <View style={{ flex: 1, gap: 2 }}>
              <Text style={st.name}>Home</Text>
              <Text style={st.meta}>Private · chats without a Folder</Text>
            </View>
            {dot(home)}
            <Text style={st.chev}>›</Text>
          </Tap>
        ) : null}

        {!joined ? <Loading /> : folders.length === 0 ? <Empty title="No Folders match" /> : null}
        {folders.length ? (
          <View style={st.group}>
            {folders.map((p, i) => (
              <Tap
                kb="row"
                key={p.id}
                testID={`project-${p.name}`}
                onPress={() => router.push(folderHref(p) as any)}
                style={[st.row, i < folders.length - 1 && st.rowBorder]}
              >
                <Letter name={p.name} system={p.kind === "system"} size={36} />
                <View style={{ flex: 1, gap: 2 }}>
                  <Text style={st.name} numberOfLines={1}>
                    {p.name}
                  </Text>
                  <Text style={st.meta}>{meta(p)}</Text>
                </View>
                {dot(p)}
                <Text style={st.chev}>›</Text>
              </Tap>
            ))}
          </View>
        ) : null}
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
    outlineStyle: "none",
  } as any,
  chipsWrap: { marginHorizontal: -18, flexGrow: 0, flexShrink: 0 },
  chips: { flexDirection: "row", alignItems: "center", gap: 6, paddingHorizontal: 18 },
  chip: { flexGrow: 0, flexShrink: 0, paddingHorizontal: 13, paddingVertical: 7, borderRadius: 17 },
  chipOn: { backgroundColor: color.pill },
  chipText: { fontSize: 14, color: color.textDim },
  home: {
    flexDirection: "row",
    alignItems: "center",
    gap: 12,
    paddingVertical: 12,
    paddingHorizontal: 14,
    borderRadius: 14,
    backgroundColor: color.card,
  },
  homeTile: {
    width: 36,
    height: 36,
    borderRadius: 9,
    backgroundColor: color.divider,
    borderWidth: 1,
    borderColor: color.outline,
    alignItems: "center",
    justifyContent: "center",
  },
  homeLetter: { fontSize: 16, fontWeight: "700", color: color.textSoft },
  group: { borderRadius: 14, backgroundColor: color.card, overflow: "hidden" },
  row: { flexDirection: "row", alignItems: "center", gap: 12, paddingVertical: 12, paddingHorizontal: 14 },
  rowBorder: { borderBottomWidth: 1, borderBottomColor: color.divider },
  chev: { fontSize: 18, color: "#5d5d66" },
  name: { fontSize: 16, color: color.text },
  meta: { fontSize: 13, color: color.muted },
});
