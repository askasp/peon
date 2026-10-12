import { useRef, useState } from "react";
import { FlatList, StyleSheet, Text, TextInput, View } from "react-native";
import { router } from "expo-router";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { Badge, Dot, Empty, ErrorLine, kbProps, Loading, Tap } from "../ui";
import { Icon } from "../Icon";
import { PickSheet } from "../Sheet";
import { Completions, useCompletions } from "../Completions";
import { ask } from "@/lib/peon";
import { useLoad } from "@/lib/useLoad";
import { ago } from "@/lib/time";
import { color } from "@/lib/theme";
import { useWide } from "@/lib/useWide";
import type { SessionOptions, SessionSummary } from "@/lib/types";
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

type Branch = { name: string; worktree: string | null; remote: boolean; updated: number };

// Where a new chat starts: a fresh worktree, the Folder itself, or a branch's worktree.
const NEW = "\u0000new";
const MAIN = "\u0000main";

type Row = { kind: "day"; key: string; label: string } | { kind: "session"; key: string; s: SessionSummary };

/** A Folder's chats, newest first by day, under a box that starts a new one. */
export function SessionsTab({ ctx }: { ctx: ProjectCtx }) {
  const insets = useSafeAreaInsets();
  const wide = useWide();
  const [text, setText] = useState("");
  const [starting, setStarting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // Code Folders: null follows the header's "New worktree" switch.
  const code = ctx.project.kind === "code";
  const [picked, setWhere] = useState<string | null>(null);
  const where = picked ?? (ctx.project.always_worktree ? NEW : MAIN);
  const [picking, setPicking] = useState(false);
  const [branches, setBranches] = useState<Branch[] | null>(null);
  const main = ctx.project.default_branch ?? "main";
  function openPicker() {
    setPicking(true);
    ctx
      .call<{ branches: Branch[] }>("branches", {}, 60000)
      .then((r) => setBranches(r.branches))
      .catch((e) => {
        setBranches([]);
        setError(e.message);
      });
  }
  const whereLabel = where === NEW ? "New worktree" : where === MAIN ? main : where;
  // `/` completes from the Folder's skills and commands, fetched when the box is focused.
  const input = useRef<TextInput>(null);
  const [slash, setSlash] = useState<{ project: number; items: SessionOptions["slash"] } | null>(null);
  function loadSlash() {
    const project = ctx.project.id;
    if (slash?.project === project) return;
    ctx
      .call<{ slash: SessionOptions["slash"] }>("slash", {}, 30000)
      .then((r) => setSlash({ project, items: r.slash }))
      .catch(() => {});
  }
  const { items, pick, setPick, complete, onKey } = useCompletions({
    draft: text,
    setDraft: setText,
    slash: slash?.project === ctx.project.id ? slash.items : null,
    input,
  });
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
        {
          project_id: ctx.project.id,
          text,
          ...(!code ? {} : where === NEW || where === MAIN ? { worktree: where === NEW } : { branch: where }),
        },
        // Checking a branch out in a new worktree can take a while.
        120000,
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
              ref={input}
              testID="start-chat"
              value={text}
              onChangeText={(v) => {
                setText(v);
                setPick(0);
              }}
              onFocus={loadSlash}
              // Arrows move through the `/` list, Tab or Enter completes; the next Enter starts.
              onKeyPress={onKey}
              placeholder={`New chat in ${name}`}
              placeholderTextColor={color.muted}
              style={st.startInput}
              editable={!starting}
              onSubmitEditing={newSession}
              returnKeyType="send"
              {...kbProps("search")}
            />
            {code ? (
              <Tap
                testID="start-where"
                onPress={openPicker}
                disabled={starting}
                style={st.where}
                aria-label="Where the chat starts"
              >
                <Icon name="branch" size={13} color={where === NEW ? color.accentText : color.textDim} />
                <Text style={st.whereText} numberOfLines={1}>
                  {whereLabel}
                </Text>
                <Text style={st.whereCaret}>▾</Text>
              </Tap>
            ) : null}
            {text.trim() ? (
              <Tap testID="new-session" onPress={newSession} disabled={starting} style={st.send}>
                <Icon name="send" size={14} color={color.accentInk} />
              </Tap>
            ) : (
              <Text style={st.hint}>{starting ? "Starting…" : "Enter to start"}</Text>
            )}
            <Completions items={items} pick={pick} onPick={complete} style={st.completions} />
          </View>
        </View>
      ) : null}
      <ErrorLine message={error ?? loadError} />
      <PickSheet
        visible={picking}
        title="Start the chat on"
        items={[
          { key: NEW, label: "New worktree", detail: `from ${main}`, active: where === NEW },
          { key: MAIN, label: main, detail: "the Folder itself, no worktree", active: where === MAIN },
          ...(branches ?? []).map((b) => ({
            key: b.name,
            label: b.name,
            detail: [
              b.worktree
                ? `open worktree ${b.worktree}`
                : b.remote
                  ? "remote · new worktree"
                  : "new worktree",
              ago(b.updated, true),
            ].join(" · "),
            active: where === b.name,
          })),
          ...(branches == null ? [{ key: "\u0000loading", label: "Loading branches…" }] : []),
        ]}
        onClose={() => setPicking(false)}
        onPick={(k) => {
          if (k === "\u0000loading") return;
          setPicking(false);
          setWhere(k);
        }}
      />
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
  // Above the list, so the `/` list can cover it.
  toolsWide: { paddingHorizontal: 32, paddingTop: 8, maxWidth: 868, zIndex: 10 },
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
  completions: { top: "100%", left: 0, right: 0, marginTop: 6 },
  where: {
    flexDirection: "row",
    alignItems: "center",
    gap: 6,
    maxWidth: 240,
    height: 30,
    paddingHorizontal: 10,
    borderRadius: 8,
    backgroundColor: color.field,
  },
  whereText: { flexShrink: 1, fontSize: 12.5, color: color.textSoft },
  whereCaret: { fontSize: 10, color: color.muted },
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
