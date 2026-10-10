import { useState } from "react";
import { FlatList, StyleSheet, Text, TextInput, View } from "react-native";
import { router } from "expo-router";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { Badge, Dot, Empty, ErrorLine, kbProps, Loading, Tap, Toggle } from "../ui";
import { ask } from "@/lib/peon";
import { useLoad } from "@/lib/useLoad";
import { ago } from "@/lib/time";
import { color } from "@/lib/theme";
import { useWide } from "@/lib/useWide";
import type { SessionSummary } from "@/lib/types";
import type { ProjectCtx } from "./types";

function dayLabel(ms: number | null): string {
  if (!ms) return "Earlier";
  const d = new Date(ms);
  const today = new Date();
  const day = (x: Date) => new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime();
  const days = Math.round((day(today) - day(d)) / 86400000);
  if (days === 0) return "Today";
  if (days === 1) return "Yesterday";
  if (days < 7) return d.toLocaleDateString("en-GB", { weekday: "long" });
  return d.toLocaleDateString("en-GB", { day: "numeric", month: "long" });
}

type Row = { kind: "day"; key: string; label: string } | { kind: "session"; key: string; s: SessionSummary };

/** Sessions (or chats), newest first by day, with search and "+ New session". */
export function SessionsTab({ ctx }: { ctx: ProjectCtx }) {
  const insets = useSafeAreaInsets();
  const wide = useWide();
  const [query, setQuery] = useState("");
  const [worktree, setWorktree] = useState(ctx.project.always_worktree);
  const [starting, setStarting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const { data, error: loadError } = useLoad(
    () => ctx.call<{ sessions: SessionSummary[] }>("sessions").then((r) => r.sessions),
    [ctx.changed],
  );

  const q = query.trim().toLowerCase();
  const rows: Row[] = [];
  let last = "";
  for (const s of (data ?? []).filter((s) => !q || s.title.toLowerCase().includes(q))) {
    const label = dayLabel(s.updated);
    if (label !== last) rows.push({ kind: "day", key: `day-${label}`, label });
    last = label;
    rows.push({ kind: "session", key: s.id, s });
  }

  async function newSession() {
    setStarting(true);
    setError(null);
    try {
      const { session_id } = await ask<{ session_id: string }>(
        "new_session",
        { project_id: ctx.project.id, worktree },
        60000,
      );
      router.push(`/session/${session_id}`);
    } catch (e: any) {
      setError(e.message);
    }
    setStarting(false);
  }

  const noun = ctx.project.kind === "chat" ? "chat" : "session";

  return (
    <View style={{ flex: 1 }}>
      <View style={st.tools}>
        <TextInput
          value={query}
          onChangeText={setQuery}
          placeholder={`Search ${noun}s`}
          placeholderTextColor={color.faint}
          style={st.search}
          autoCapitalize="none"
          {...kbProps("search")}
        />
        {ctx.project.kind === "code" ? (
          <View style={st.worktree}>
            <Text style={st.worktreeText}>New worktree</Text>
            <Toggle value={worktree} onChange={setWorktree} />
          </View>
        ) : null}
      </View>
      <ErrorLine message={error ?? loadError} />
      <FlatList
        data={rows}
        keyExtractor={(r) => r.key}
        contentContainerStyle={{ paddingHorizontal: 18, paddingBottom: 120 + insets.bottom }}
        ListEmptyComponent={
          data == null ? (
            <Loading />
          ) : (
            <Empty title={q ? "No match" : `No ${noun}s yet`} detail={q ? undefined : "Start one below."} />
          )
        }
        renderItem={({ item }) =>
          item.kind === "day" ? (
            <Text style={st.day}>{item.label}</Text>
          ) : (
            <Tap
              kb="row"
              testID={`session-${item.s.id}`}
              onPress={() => router.push(`/session/${item.s.id}`)}
              style={[st.row, wide && st.rowWide]}
            >
              {wide ? (
                <View style={st.dotCol}>
                  <Dot
                    size={8}
                    tint={
                      item.s.status === "waiting"
                        ? color.needs
                        : item.s.status === "running"
                          ? color.accent
                          : color.ghost
                    }
                  />
                </View>
              ) : null}
              <View style={{ flex: 1, gap: 4 }}>
                <View style={st.rowTop}>
                  <Text style={st.rowTitle} numberOfLines={2}>
                    {item.s.title}
                  </Text>
                  {item.s.status === "waiting" ? <Badge label="Needs you" tint="needs" /> : null}
                  {item.s.status === "running" ? <Badge label="Running" /> : null}
                </View>
                <Text style={st.rowMeta}>
                  {[
                    item.s.branch,
                    ago(item.s.updated, true),
                    item.s.started_by,
                    item.s.scope === "private" ? "only you" : null,
                    item.s.scheduled ? "scheduled" : null,
                    item.s.worktree ? `worktree ${item.s.worktree}` : null,
                  ]
                    .filter(Boolean)
                    .join(" · ")}
                </Text>
              </View>
            </Tap>
          )
        }
      />
      <Tap
        testID="new-session"
        haptic
        onPress={newSession}
        disabled={starting}
        style={[st.fab, { bottom: 24 + insets.bottom }]}
      >
        <Text style={st.fabText}>{starting ? "Starting…" : `+ New ${noun}`}</Text>
      </Tap>
    </View>
  );
}

const st = StyleSheet.create({
  tools: { flexDirection: "row", alignItems: "center", gap: 12, paddingHorizontal: 18, paddingBottom: 6 },
  search: {
    flex: 1,
    height: 38,
    borderRadius: 10,
    backgroundColor: color.field,
    paddingHorizontal: 12,
    color: color.text,
    fontSize: 14,
  },
  worktree: { flexDirection: "row", alignItems: "center", gap: 8 },
  worktreeText: { fontSize: 13, color: color.textDim },
  day: { fontSize: 12, color: color.muted, paddingTop: 16, paddingBottom: 4 },
  row: {
    paddingVertical: 12,
    paddingHorizontal: 2,
    gap: 4,
    borderBottomWidth: 1,
    borderBottomColor: color.hairline,
  },
  rowWide: { flexDirection: "row", gap: 14 },
  dotCol: { paddingTop: 7 },
  rowTop: { flexDirection: "row", justifyContent: "space-between", alignItems: "flex-start", gap: 10 },
  rowTitle: { flex: 1, fontSize: 15.5, color: color.text },
  rowMeta: { fontSize: 13, color: color.muted },
  fab: {
    position: "absolute",
    right: 18,
    height: 50,
    paddingHorizontal: 20,
    borderRadius: 25,
    backgroundColor: color.textStrong,
    justifyContent: "center",
    shadowColor: "#000",
    shadowOpacity: 0.4,
    shadowRadius: 24,
    shadowOffset: { width: 0, height: 8 },
    elevation: 8,
  },
  fabText: { color: color.bg, fontWeight: "600", fontSize: 15 },
});
