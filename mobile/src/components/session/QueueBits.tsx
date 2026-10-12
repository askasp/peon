import { ScrollView, StyleSheet, Text, View } from "react-native";
import { Tap } from "../ui";
import { TreeCard, type QueueAct } from "../project/QueueTab";
import type { Procedure } from "@/lib/procedures";
import { nextTask, sortTree, taskState } from "@/lib/queue";
import { color, font } from "@/lib/theme";
import type { QueueTree } from "@/lib/types";

/** A "queue …" turn in a chat: what was asked, and the tasks it wrote (or listed). */
export type QueueCard = { key: string; text: string; mode: "add" | "list"; ids: string[]; undone?: boolean };

const stateLook = {
  running: ["Running", color.accentText],
  needs: ["Needs you", color.needs],
  ready: ["Ready", color.textDim],
  blocked: ["Blocked", color.needs],
  done: ["Done", color.teal],
} as const;

/** The tasks a "queue …" message wrote to this worktree's .tickets/, live from the queue. */
export function TasksCard({
  card,
  tree,
  onOpen,
  onUndo,
}: {
  card: QueueCard;
  tree: QueueTree | null;
  onOpen: () => void;
  onUndo: () => void;
}) {
  const n = card.ids.length;
  const where = tree ? `worktree ${tree.worktree}` : "this worktree";
  const head = card.undone
    ? `Removed ${n} task${n === 1 ? "" : "s"}`
    : card.mode === "add"
      ? `Queued ${n} task${n === 1 ? "" : "s"} · ${where}`
      : `Tasks · ${where}`;
  const rows = card.undone
    ? []
    : card.ids.map((id) => tree?.tickets.find((t) => t.id === id)).filter((t) => !!t);
  // Undo while none of them has started.
  const canUndo =
    card.mode === "add" && !card.undone && rows.length > 0 && rows.every((t) => t.status === "open");

  return (
    <View style={st.wrap}>
      <Text style={st.asked} numberOfLines={3}>
        {card.text}
      </Text>
      <View style={st.card}>
        <View style={st.head}>
          <Text style={st.icon}>☰</Text>
          <Text style={st.headText} numberOfLines={1}>
            {head}
          </Text>
          <Text style={st.tk}>tk</Text>
          <Tap onPress={onOpen} hitSlop={8}>
            <Text style={st.open}>Open queue</Text>
          </Tap>
        </View>
        {rows.map((t) => {
          const [word, tint] = stateLook[taskState(t, tree!)];
          return (
            <View key={t.id} style={st.row}>
              <View style={[st.dot, { backgroundColor: tint }]} />
              <Text style={st.id}>{t.id}</Text>
              <Text style={[st.title, t.status === "closed" && { color: color.muted }]} numberOfLines={1}>
                {t.title}
              </Text>
              <Text style={[st.state, { color: tint }]}>{word}</Text>
            </View>
          );
        })}
        <View style={st.foot}>
          <Text style={st.footText}>
            {card.undone
              ? "Deleted from .tickets/"
              : card.mode === "add"
                ? "Written to .tickets/ in this worktree"
                : rows.length
                  ? "Live from tk"
                  : "Nothing queued here"}
          </Text>
          {canUndo ? (
            <Tap onPress={onUndo} hitSlop={8}>
              <Text style={st.undo}>Undo</Text>
            </Tap>
          ) : null}
        </View>
      </View>
    </View>
  );
}

/** The header's way into this worktree's queue: ☰ and how many tasks are left. */
export function QueueButton({
  tree,
  open,
  onPress,
}: {
  tree: QueueTree | null;
  open: boolean;
  onPress: () => void;
}) {
  const left = tree ? tree.tickets.filter((t) => t.status !== "closed").length : 0;
  return (
    <Tap
      onPress={onPress}
      hitSlop={10}
      style={[st.qButton, open && st.qButtonOpen]}
      testID="queue-button"
      aria-label={open ? "Hide the queue" : "Show the queue"}
    >
      <Text style={[st.qButtonIcon, open && { color: color.accentText }]}>☰</Text>
      {left ? <Text style={st.qButtonCount}>{left}</Text> : null}
    </Tap>
  );
}

/**
 * Above the reply box in a worktree chat with tasks: what the queue is doing,
 * "Start next" when the chat is free, and the worktree's queue on demand.
 */
export function QueueStrip({
  tree,
  act,
  folder,
  canEdit,
  idle,
  panel,
  onPanel,
  onAll,
  procedures,
}: {
  tree: QueueTree;
  act: QueueAct;
  folder: number;
  canEdit: boolean;
  idle: boolean;
  panel: boolean;
  onPanel: () => void;
  onAll: () => void;
  procedures?: Procedure[];
}) {
  const { running, needs, ready, blocked } = sortTree(tree);
  const live = running.length + needs.length + ready.length + blocked.length;
  // Nothing queued: only the panel, opened from the header, to add the first.
  if (!live)
    return panel ? (
      <View style={st.stripWrap}>
        <TreeCard
          tree={tree}
          act={act}
          folder={folder}
          canEdit={canEdit}
          inChat
          focusAdd
          procedures={procedures}
        />
      </View>
    ) : null;
  const next = nextTask(tree);
  const text = needs.length
    ? `${needs[0].id} needs you · ${next ? `${next.id} doesn't depend on it` : "the queued tasks wait on it"}`
    : running.length
      ? `Working on ${running[0].id}${live > 1 ? ` · ${live - 1} more queued` : ""}`
      : next
        ? `${ready.length} ready · next ${next.id}`
        : `${blocked.length} blocked`;
  const canStart = canEdit && idle && !running.length && !needs.length && !!next;

  return (
    <View style={st.stripWrap}>
      {panel ? (
        <ScrollView style={st.panel} contentContainerStyle={{ paddingBottom: 2 }}>
          <TreeCard tree={tree} act={act} folder={folder} canEdit={canEdit} inChat procedures={procedures} />
        </ScrollView>
      ) : null}
      <View style={st.strip}>
        <Text style={st.stripIcon}>☰</Text>
        <Text style={st.stripText} numberOfLines={1}>
          {text}
        </Text>
        {canStart ? (
          <Tap
            onPress={() => act("queue_start", { ref: tree.ref, id: next!.id })}
            style={st.stripButton}
            testID="queue-start-next"
          >
            <Text style={st.stripButtonText}>Start next</Text>
          </Tap>
        ) : null}
        <Tap onPress={onPanel} hitSlop={8} testID="queue-panel">
          <Text style={st.open}>{panel ? "Hide queue" : "Show queue"}</Text>
        </Tap>
        <Tap onPress={onAll} hitSlop={8}>
          <Text style={st.all}>All</Text>
        </Tap>
      </View>
    </View>
  );
}

const st = StyleSheet.create({
  wrap: { gap: 8 },
  asked: {
    alignSelf: "flex-end",
    maxWidth: "85%",
    paddingVertical: 8,
    paddingHorizontal: 12,
    borderRadius: 14,
    backgroundColor: color.raised,
    color: color.text,
    fontSize: 15,
    lineHeight: 21,
  },
  card: {
    borderRadius: 12,
    borderWidth: 1,
    borderColor: color.border,
    backgroundColor: "#17171c",
    overflow: "hidden",
  },
  head: {
    flexDirection: "row",
    alignItems: "center",
    gap: 10,
    paddingVertical: 10,
    paddingHorizontal: 14,
    borderBottomWidth: 1,
    borderBottomColor: color.divider,
  },
  icon: {
    width: 24,
    height: 24,
    borderRadius: 6,
    backgroundColor: color.divider,
    color: color.textDim,
    fontSize: 12,
    textAlign: "center",
    lineHeight: 24,
    overflow: "hidden",
  },
  headText: { flex: 1, minWidth: 0, fontSize: 13, color: color.text },
  tk: { fontFamily: font.mono, fontSize: 11, color: color.faint },
  open: { fontSize: 12, color: color.accentText },
  row: {
    flexDirection: "row",
    alignItems: "center",
    gap: 12,
    paddingVertical: 9,
    paddingHorizontal: 14,
    borderBottomWidth: 1,
    borderBottomColor: color.hairline,
  },
  dot: { width: 7, height: 7, borderRadius: 4 },
  id: { width: 64, fontFamily: font.mono, fontSize: 12, color: color.muted },
  title: { flex: 1, minWidth: 0, fontSize: 13, color: color.text },
  state: { fontSize: 12 },
  foot: {
    flexDirection: "row",
    alignItems: "center",
    gap: 14,
    paddingTop: 8,
    paddingBottom: 10,
    paddingHorizontal: 14,
  },
  footText: { flex: 1, fontSize: 12, color: color.faint },
  undo: { fontSize: 12, color: color.textDim },

  stripWrap: { gap: 8, marginBottom: 8 },
  panel: { maxHeight: 360 },
  strip: {
    flexDirection: "row",
    alignItems: "center",
    gap: 10,
    paddingVertical: 8,
    paddingHorizontal: 12,
    borderRadius: 10,
    backgroundColor: "#17171c",
    borderWidth: 1,
    borderColor: color.divider,
  },
  stripIcon: { fontSize: 12, color: color.textDim },
  stripText: { flex: 1, minWidth: 0, fontSize: 13, color: color.textSoft },
  stripButton: {
    paddingVertical: 3,
    paddingHorizontal: 10,
    borderRadius: 7,
    borderWidth: 1,
    borderColor: color.outline,
  },
  stripButtonText: { fontSize: 12, color: color.text },
  all: { fontSize: 12, color: color.muted },

  qButton: {
    flexDirection: "row",
    alignItems: "center",
    gap: 5,
    paddingVertical: 4,
    paddingHorizontal: 8,
    borderRadius: 8,
  },
  qButtonOpen: { backgroundColor: color.divider },
  qButtonIcon: { fontSize: 15, color: color.textDim },
  qButtonCount: { fontSize: 12, color: color.textSoft, fontVariant: ["tabular-nums"] },
});
