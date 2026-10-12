import { useState } from "react";
import { FlatList, StyleSheet, Text, TextInput, View } from "react-native";
import { router } from "expo-router";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { Badge, Dot, Empty, ErrorLine, kbProps, Loading, Tap } from "../ui";
import { Icon } from "../Icon";
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

/** A Folder's chats, newest first by day, under a box that starts a new one. */
export function SessionsTab({ ctx }: { ctx: ProjectCtx }) {
  const insets = useSafeAreaInsets();
  const wide = useWide();
  const [text, setText] = useState("");
  const [starting, setStarting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const { data, error: loadError } = useLoad(
    () => ctx.call<{ sessions: SessionSummary[] }>("sessions").then((r) => r.sessions),
    [ctx.changed],
  );

  const rows: Row[] = [];
  let last = "";
  for (const s of data ?? []) {
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
        { project_id: ctx.project.id, text },
        60000,
      );
      setText("");
      router.push(`/session/${session_id}`);
    } catch (e: any) {
      setError(e.message);
    }
    setStarting(false);
  }

  const name = ctx.project.kind === "home" ? "Home" : ctx.project.name;

  return (
    <View style={{ flex: 1 }}>
      {/* Phone: the + New chat button starts chats; desktop: this box. */}
      {wide ? (
        <View style={[st.tools, st.toolsWide]}>
          <View style={st.start}>
            <Text style={st.plus}>+</Text>
            <TextInput
              testID="start-chat"
              value={text}
              onChangeText={setText}
              placeholder={`New chat in ${name}`}
              placeholderTextColor={color.muted}
              style={st.startInput}
              editable={!starting}
              onSubmitEditing={newSession}
              returnKeyType="send"
              {...kbProps("search")}
            />
            {text.trim() ? (
              <Tap testID="new-session" onPress={newSession} disabled={starting} style={st.send}>
                <Icon name="send" size={14} color={color.accentInk} />
              </Tap>
            ) : (
              <Text style={st.hint}>{starting ? "Starting…" : "Enter to start"}</Text>
            )}
          </View>
        </View>
      ) : null}
      <ErrorLine message={error ?? loadError} />
      <FlatList
        data={rows}
        keyExtractor={(r) => r.key}
        contentContainerStyle={[
          { paddingHorizontal: 18, paddingBottom: (wide ? 40 : 110) + insets.bottom },
          wide && st.listWide,
        ]}
        ListEmptyComponent={data == null ? <Loading /> : <Empty title="No chats yet" />}
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
                  {item.s.status === "running" ? <Badge label="Working" /> : null}
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
    </View>
  );
}

const st = StyleSheet.create({
  tools: { flexDirection: "row", alignItems: "center", gap: 14, paddingHorizontal: 18, paddingBottom: 6 },
  toolsWide: { paddingHorizontal: 32, paddingTop: 8, maxWidth: 868 },
  listWide: { paddingHorizontal: 32, maxWidth: 868 },
  start: {
    flex: 1,
    flexDirection: "row",
    alignItems: "center",
    gap: 10,
    height: 44,
    borderRadius: 10,
    borderWidth: 1,
    borderStyle: "dashed",
    borderColor: color.outline,
    paddingLeft: 12,
    paddingRight: 6,
  },
  plus: { fontSize: 16, color: color.accentText },
  hint: { fontSize: 12, color: "#5d5d66", paddingRight: 6 },
  startInput: { flex: 1, height: 42, color: color.text, fontSize: 14, outlineStyle: "none" } as any,
  send: {
    width: 30,
    height: 30,
    borderRadius: 8,
    backgroundColor: color.accent,
    alignItems: "center",
    justifyContent: "center",
  },
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
});
