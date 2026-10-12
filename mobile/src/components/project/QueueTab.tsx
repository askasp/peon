import { useCallback, useEffect, useState } from "react";
import { ScrollView, StyleSheet, Text, TextInput, View } from "react-native";
import { router } from "expo-router";
import { ErrorLine, Tap, Toggle } from "../ui";
import { confirm } from "@/lib/confirm";
import { cancelled, sortTree } from "@/lib/queue";
import { ago } from "@/lib/time";
import { useWide } from "@/lib/useWide";
import { color, font } from "@/lib/theme";
import type { Procedure } from "@/lib/procedures";
import type { Queue, QueueTree, Ticket } from "@/lib/types";
import type { ProjectCtx } from "./types";

type Call = ProjectCtx["call"];

/** The run of a queue request: the new queue comes back with every change. */
export type QueueAct = <T = object>(
  event: string,
  payload?: object,
) => Promise<(T & { queue: Queue }) | null>;

/**
 * A Code Folder's queue, fetched again when the Folder changes. `view` is a
 * chat whose worktree to list even while it has no tasks.
 */
export function useQueue(call: Call | null, changed: unknown, view?: string) {
  const [queue, setQueue] = useState<Queue | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!call) return;
    let live = true;
    call<{ queue: Queue }>("queue", view ? { view } : {}, 40000).then(
      (r) => live && (setQueue(r.queue), setError(null)),
      (e) => live && setError(e.message),
    );
    return () => {
      live = false;
    };
  }, [call, changed, view]);

  const act: QueueAct = useCallback(
    async (event, payload = {}) => {
      if (!call) return null;
      setError(null);
      try {
        const r = await call<any>(event, { ...payload, ...(view ? { view } : {}) }, 90000);
        setQueue(r.queue);
        return r;
      } catch (e: any) {
        setError(e.message);
        return null;
      }
    },
    [call, view],
  );

  return { queue, error, act };
}

// Priority 0 (highest) to 4, as tk has it.
const prioTint = [color.red, color.needs, color.textSoft, color.muted, color.faint];

/**
 * The Queue tab: every tree with tasks, worktrees that are working first and
 * main last, then what's done. Each worktree runs its tasks one at a time.
 */
export function QueueTab({ ctx }: { ctx: ProjectCtx }) {
  const { queue, error, act } = useQueue(ctx.call, ctx.changed);
  const wide = useWide();
  const auto = queue?.auto ?? ctx.project.queue_auto ?? true;

  const trees = (queue?.trees ?? [])
    .filter((t) => t.ref === "main" || t.tickets.some((x) => x.status !== "closed"))
    .sort((a, b) => rank(a) - rank(b));
  const done = (queue?.trees ?? [])
    .flatMap((tree) => tree.tickets.filter((t) => t.status === "closed").map((t) => ({ t, tree })))
    .sort((a, b) => lastAt(b.t).localeCompare(lastAt(a.t)));

  return (
    <ScrollView contentContainerStyle={[st.body, wide && st.bodyWide]}>
      <View style={st.top}>
        <Text style={st.heading}>Tasks</Text>
        <View style={{ flex: 1 }} />
        <Text style={st.autoLabel}>Continue with the next task</Text>
        <Toggle
          value={auto}
          label="Continue with the next task"
          onChange={(on) => ctx.canEdit && act("queue_auto", { on })}
        />
      </View>
      <ErrorLine message={error} />

      {queue == null ? (
        <Text style={st.none}>Loading…</Text>
      ) : (
        trees.map((tree) => (
          <TreeCard
            key={tree.ref}
            tree={tree}
            act={act}
            folder={ctx.project.id}
            canEdit={ctx.canEdit}
            procedures={ctx.procedures}
          />
        ))
      )}

      {done.length ? (
        <View style={st.history}>
          <Text style={st.historyHead}>Done</Text>
          {done.slice(0, 30).map(({ t, tree }) => {
            const c = cancelled(t);
            return (
              <View key={`${tree.ref}:${t.id}`} style={st.histRow}>
                <Text style={st.histId}>{t.id}</Text>
                <Text style={[st.histState, { color: c ? color.muted : color.teal }]}>
                  {c ? "Cancelled" : "Done"}
                </Text>
                <Text style={st.histTitle} numberOfLines={1}>
                  {t.title}
                </Text>
                {wide ? (
                  <Text style={st.histMeta} numberOfLines={1}>
                    {[tree.worktree, ago(lastAt(t) || null, true)].filter(Boolean).join(" · ")}
                  </Text>
                ) : null}
              </View>
            );
          })}
        </View>
      ) : null}
    </ScrollView>
  );
}

const lastAt = (t: Ticket) => t.notes[t.notes.length - 1]?.at ?? t.created ?? "";

// Working worktrees first, then idle ones, main last.
const rank = (t: QueueTree) =>
  t.ref === "main" ? 3 : t.tickets.some((x) => x.status === "in_progress") ? 0 : 1;

const openChat = (id: string) => router.push(`/session/${id}`);

/**
 * One tree's queue: what runs, what needs you, what's ready (next first) and
 * what's blocked, with a line to add a task. `inChat`: shown in that chat's
 * own queue panel, so no "Open chat".
 */
export function TreeCard({
  tree,
  act,
  folder,
  canEdit,
  inChat = false,
  focusAdd = false,
  procedures = [],
}: {
  tree: QueueTree;
  act: QueueAct;
  folder: number;
  canEdit: boolean;
  inChat?: boolean;
  focusAdd?: boolean;
  /** The Folder's procedures: a task can pick the one it runs through. */
  procedures?: Procedure[];
}) {
  const wide = useWide();
  const main = tree.ref === "main";
  const { running, needs, ready, blocked } = sortTree(tree);
  const busy = running.length + needs.length > 0;
  const waiting = needs.length > 0 || tree.chat?.status === "waiting";
  const [openId, setOpenId] = useState<string | null>(null);
  const [showBlocked, setShowBlocked] = useState(false);
  const [title, setTitle] = useState("");
  const [adding, setAdding] = useState(false);
  const [working, setWorking] = useState<string | null>(null);
  // The procedure new tasks run through: the Queue default unless picked.
  const fallback = procedures.find((p) => p.queue === "default")?.name ?? null;
  const [procedure, setProcedure] = useState<string | null>(null);
  const [picking, setPicking] = useState(false);

  const dot = running.length ? color.accent : waiting ? color.needs : color.faint;
  const state = main
    ? `${ready.length} ready`
    : running.length && waiting
      ? "Running · needs you"
      : running.length
        ? "Running"
        : waiting
          ? "Waiting for you"
          : "Idle";

  async function add() {
    const t = title.trim();
    if (!t || adding) return;
    setAdding(true);
    const picked = procedure && procedure !== fallback ? { procedure } : {};
    if (await act("queue_add", { ref: tree.ref, titles: [t], ...picked })) setTitle("");
    setAdding(false);
  }

  // A button's request, showing which task it's for while it runs.
  async function run(key: string, event: string, payload: object) {
    setWorking(key);
    const r = await act<{ session_id?: string }>(event, { ref: tree.ref, ...payload });
    setWorking(null);
    return r;
  }

  async function start(t: Ticket) {
    const r = await run(`start:${t.id}`, "queue_start", { id: t.id });
    // A task on main starts a new chat: go there.
    if (r?.session_id && main) openChat(r.session_id);
  }

  const firstReady = ready.find((t) => !t.paused)?.id;

  return (
    <View style={[st.card, { borderColor: running.length ? color.accentBorder : color.divider }]}>
      <View style={st.cardHead}>
        <View style={[st.dot, { backgroundColor: dot }]} />
        <Text style={st.treeLabel} numberOfLines={1}>
          {main ? "main" : wide ? `worktree ${tree.worktree}` : tree.worktree}
        </Text>
        <Text style={st.chatTitle} numberOfLines={1}>
          {main
            ? wide
              ? "Starting a task here makes a new worktree and chat"
              : ""
            : (tree.chat?.title ?? "")}
        </Text>
        <Text style={[st.treeState, { color: dot }]}>{state}</Text>
        {tree.chat && !inChat ? (
          <Tap onPress={() => openChat(tree.chat!.id)} hitSlop={8}>
            <Text style={st.link}>Open chat</Text>
          </Tap>
        ) : null}
      </View>

      {running.map((t) => (
        <View key={t.id} style={st.running}>
          <View style={st.runHead}>
            <Text style={st.runMark}>▶</Text>
            {wide ? <Text style={[st.id, { width: 72 }]}>{t.id}</Text> : null}
            <Text style={st.runTitle} numberOfLines={1}>
              {t.title}
            </Text>
          </View>
          {t.run ? (
            <StepsLine run={t.run} />
          ) : (
            <View style={st.track}>
              <View style={st.trackFill} />
            </View>
          )}
          <View style={st.runFoot}>
            <Text style={st.runNote} numberOfLines={1}>
              {t.notes[t.notes.length - 1]?.text ?? "Working in the chat"}
            </Text>
            <View style={st.actions}>
              {!inChat && tree.chat ? (
                <Pill label="Steer in chat" strong onPress={() => openChat(tree.chat!.id)} />
              ) : null}
              {canEdit ? (
                <>
                  <Pill
                    label="Pause"
                    busy={working === `pause:${t.id}`}
                    onPress={() => run(`pause:${t.id}`, "queue_pause", { id: t.id })}
                  />
                  <Pill
                    label="Cancel"
                    danger
                    busy={working === `cancel:${t.id}`}
                    onPress={() => run(`cancel:${t.id}`, "queue_cancel", { id: t.id })}
                  />
                </>
              ) : null}
            </View>
          </View>
        </View>
      ))}

      {needs.map((t) => {
        const waitsOnIt = blocked.filter((b) => b.blocked_by?.includes(t.id)).map((b) => b.id);
        return (
          <View key={t.id} style={st.needs}>
            <Text style={st.needsMark}>?</Text>
            {wide ? <Text style={[st.id, { width: 72 }]}>{t.id}</Text> : null}
            <View style={st.grow}>
              <Text style={st.rowTitle} numberOfLines={1}>
                {t.title}
              </Text>
              {t.run ? <StepsLine run={t.run} /> : null}
              <Text style={st.needsSub} numberOfLines={2}>
                {[
                  t.run?.waiting
                    ? `Needs you: ${t.run.waiting}`
                    : tree.chat?.status === "waiting"
                      ? "Needs you: a question in the chat"
                      : "Stopped before it was done",
                  waitsOnIt.length
                    ? `${waitsOnIt.join(", ")} wait${waitsOnIt.length > 1 ? "" : "s"} on it`
                    : null,
                ]
                  .filter(Boolean)
                  .join(" · ")}
              </Text>
            </View>
            {!inChat && tree.chat ? (
              <Pill label="Answer in chat" strong onPress={() => openChat(tree.chat!.id)} />
            ) : canEdit ? (
              <Pill
                label="Done"
                busy={working === `close:${t.id}`}
                onPress={() => run(`close:${t.id}`, "queue_done", { id: t.id })}
              />
            ) : null}
          </View>
        );
      })}

      {ready.map((t) => (
        <TaskRow
          key={t.id}
          t={t}
          tree={tree}
          act={act}
          canEdit={canEdit}
          open={openId === t.id}
          onToggle={() => setOpenId(openId === t.id ? null : t.id)}
          // One at a time per worktree; main's each start their own.
          start={
            canEdit && (main || !busy)
              ? {
                  label: main ? (wide ? "Start in new worktree" : "Start") : t.paused ? "Resume" : "Start",
                  run: () => start(t),
                }
              : null
          }
          starting={working === `start:${t.id}`}
          next={!main && busy && t.id === firstReady}
        />
      ))}

      {blocked.length ? (
        <Tap onPress={() => setShowBlocked(!showBlocked)} style={st.blockedHead}>
          <Text style={st.blockedText}>
            {showBlocked ? "▾" : "▸"} Blocked · {blocked.length}
          </Text>
        </Tap>
      ) : null}
      {showBlocked
        ? blocked.map((t) => (
            <TaskRow
              key={t.id}
              t={t}
              tree={tree}
              act={act}
              canEdit={canEdit}
              open={openId === t.id}
              onToggle={() => setOpenId(openId === t.id ? null : t.id)}
              start={null}
              starting={false}
              next={false}
            />
          ))
        : null}

      {canEdit ? (
        <View style={st.addRow}>
          <Text style={st.plus}>+</Text>
          <TextInput
            value={title}
            onChangeText={setTitle}
            onSubmitEditing={add}
            editable={!adding}
            placeholder={`Add a task to ${main ? "main" : tree.worktree}`}
            placeholderTextColor={color.faint}
            returnKeyType="done"
            autoFocus={focusAdd}
            style={st.addInput}
            testID={`queue-add-${tree.ref}`}
          />
          {procedures.length ? (
            <Tap
              onPress={() => setPicking(!picking)}
              style={st.recipe}
              testID={`queue-procedure-${tree.ref}`}
            >
              <Text style={st.recipeLabel}>Procedure</Text>
              <Text style={st.recipeName}>{procedure ?? fallback ?? "none"}</Text>
              <Text style={st.recipeLabel}>▾</Text>
            </Tap>
          ) : null}
        </View>
      ) : null}
      {picking ? (
        <View style={st.recipes}>
          {[null, ...procedures.map((p) => p.name)].map((name) => (
            <Tap
              key={name ?? "-"}
              onPress={() => {
                setProcedure(name);
                setPicking(false);
              }}
              style={[st.recipeChip, (procedure ?? fallback) === name && st.recipeOn]}
            >
              <Text style={st.recipeChipText}>
                {name ?? "No procedure: one message"}
                {name && name === fallback ? " · default" : ""}
              </Text>
            </Tap>
          ))}
        </View>
      ) : null}
    </View>
  );
}

/** "ship · Plan ✓ Build ✓ Review Sonnet · Preview · Merge": where a task is in its procedure (R2). */
function StepsLine({ run }: { run: NonNullable<Ticket["run"]> }) {
  return (
    <View style={st.stepsLine}>
      <Text style={st.stepsProc}>{run.procedure}</Text>
      <Text style={st.stepsText}>·</Text>
      {run.steps.map((s, i) => {
        const current = i === run.step && run.status !== "done";
        const waiting = current && run.status === "waiting";
        return (
          <View key={`${i}-${s.name}`} style={st.stepItem}>
            <Text
              style={[
                st.stepsText,
                current && { color: waiting ? color.needs : color.text },
                s.status === "failed" && { color: color.red },
              ]}
            >
              {s.name}
              {s.status === "done" && !current ? " ✓" : ""}
            </Text>
            {current && s.model && !waiting ? <Text style={st.stepModel}>{s.model}</Text> : null}
          </View>
        );
      })}
    </View>
  );
}

/** A ready or blocked task; open, it edits the ticket file. */
function TaskRow({
  t,
  tree,
  act,
  canEdit,
  open,
  onToggle,
  start,
  starting,
  next,
}: {
  t: Ticket;
  tree: QueueTree;
  act: QueueAct;
  canEdit: boolean;
  open: boolean;
  onToggle: () => void;
  start: { label: string; run: () => void } | null;
  starting: boolean;
  next: boolean;
}) {
  const wide = useWide();
  const [title, setTitle] = useState(t.title);
  const [body, setBody] = useState(t.body);
  const [picking, setPicking] = useState(false);
  // The file changed on the server (an edit saved, or the agent's): show it.
  const [seen, setSeen] = useState({ title: t.title, body: t.body });
  if (seen.title !== t.title || seen.body !== t.body) {
    setSeen({ title: t.title, body: t.body });
    setTitle(t.title);
    setBody(t.body);
  }

  const blocked = t.blocked_by ?? [];
  const sub = blocked.length
    ? `Waits on ${blocked.join(", ")}`
    : t.paused
      ? "Paused"
      : t.notes.length
        ? t.notes[t.notes.length - 1].text
        : (t.body.split("\n")[0] ?? "");
  const edit = (params: object) => act("queue_edit", { ref: tree.ref, id: t.id, params });
  const others = tree.tickets.filter((x) => x.id !== t.id && x.status !== "closed" && !t.deps.includes(x.id));
  const tint = (id: string) =>
    tree.tickets.find((x) => x.id === id)?.status === "closed" ? color.teal : color.needs;

  async function remove() {
    if (await confirm(`Delete ${t.id}?`, `${t.title}\n\nIts file in .tickets/ is deleted.`, "Delete"))
      act("queue_delete", { ref: tree.ref, id: t.id });
  }

  return (
    <View style={[st.row, open && { backgroundColor: "#18181d" }]}>
      <Tap onPress={onToggle} style={st.rowHead} kb="row">
        <Text style={[st.prio, { color: prioTint[t.priority] ?? color.muted }]}>P{t.priority}</Text>
        {wide ? <Text style={[st.id, { width: 72 }]}>{t.id}</Text> : null}
        <View style={st.grow}>
          <Text style={[st.rowTitle, !start && !next && { color: color.textDim }]} numberOfLines={1}>
            {t.title}
          </Text>
          {wide && !sub ? null : (
            <Text
              style={[st.rowSub, (blocked.length > 0 || t.paused) && { color: color.needs }]}
              numberOfLines={1}
            >
              {wide ? sub : [t.id, sub].filter(Boolean).join(" · ")}
            </Text>
          )}
        </View>
        {start ? <Pill label={start.label} busy={starting} onPress={start.run} /> : null}
        {next ? <Text style={st.next}>Next</Text> : null}
      </Tap>

      {open ? (
        <View style={[st.detail, wide && { paddingLeft: 118 }]}>
          <TextInput
            value={title}
            onChangeText={setTitle}
            onBlur={() => title.trim() && title !== t.title && edit({ title })}
            editable={canEdit}
            style={st.field}
          />
          <TextInput
            value={body}
            onChangeText={setBody}
            onBlur={() => body !== t.body && edit({ body })}
            editable={canEdit}
            multiline
            placeholder="Notes for the agent"
            placeholderTextColor={color.faint}
            style={[st.field, st.area]}
          />
          <View style={st.meta}>
            <View style={st.metaGroup}>
              <Text style={st.metaLabel}>Priority</Text>
              <View style={st.prios}>
                {[0, 1, 2, 3, 4].map((n) => (
                  <Tap
                    key={n}
                    disabled={!canEdit}
                    onPress={() => n !== t.priority && edit({ priority: n })}
                    style={[st.prioOpt, n === t.priority && { backgroundColor: "#2c2c34" }]}
                  >
                    <Text style={[st.prioText, n === t.priority && { color: prioTint[n] }]}>P{n}</Text>
                  </Tap>
                ))}
              </View>
            </View>
            <View style={st.metaGroup}>
              <Text style={st.metaLabel}>Waits on</Text>
              {t.deps.map((d) => (
                <Tap
                  key={d}
                  disabled={!canEdit}
                  onPress={() => act("queue_dep", { ref: tree.ref, id: t.id, dep: d, on: false })}
                  style={st.chip}
                >
                  <Text style={[st.chipText, { color: tint(d) }]}>
                    {d} <Text style={{ color: color.faint }}>×</Text>
                  </Text>
                </Tap>
              ))}
              {canEdit && others.length ? (
                <Tap onPress={() => setPicking(!picking)} style={[st.chip, st.chipAdd]}>
                  <Text style={st.chipAddText}>+ add</Text>
                </Tap>
              ) : null}
              {picking
                ? others.map((x) => (
                    <Tap
                      key={x.id}
                      onPress={() => {
                        setPicking(false);
                        act("queue_dep", { ref: tree.ref, id: t.id, dep: x.id, on: true });
                      }}
                      style={[st.chip, st.chipPick]}
                    >
                      <Text style={st.chipText}>{x.id}</Text>
                    </Tap>
                  ))
                : null}
            </View>
          </View>
          <View style={st.foot}>
            <Text style={st.file} numberOfLines={1}>
              {tree.ref === "main" ? "" : `${tree.worktree}:`}.tickets/{t.id}.md
            </Text>
            <View style={st.grow} />
            {canEdit ? (
              <Tap onPress={remove} hitSlop={8}>
                <Text style={st.delete}>Delete</Text>
              </Tap>
            ) : null}
          </View>
        </View>
      ) : null}
    </View>
  );
}

function Pill({
  label,
  onPress,
  strong,
  danger,
  busy,
}: {
  label: string;
  onPress: () => void;
  strong?: boolean;
  danger?: boolean;
  busy?: boolean;
}) {
  return (
    <Tap onPress={onPress} disabled={busy} style={[st.pill, strong && st.pillStrong]}>
      <Text style={[st.pillText, strong && st.pillTextStrong, danger && { color: color.red }]}>
        {busy ? "…" : label}
      </Text>
    </Tap>
  );
}

const st = StyleSheet.create({
  stepsLine: { flexDirection: "row", flexWrap: "wrap", alignItems: "center", gap: 6 },
  stepsProc: { fontFamily: font.mono, fontSize: 12, color: color.muted },
  stepItem: { flexDirection: "row", alignItems: "center", gap: 5 },
  stepsText: { fontSize: 12, color: color.faint },
  stepModel: {
    paddingHorizontal: 6,
    paddingVertical: 1,
    borderRadius: 4,
    overflow: "hidden",
    backgroundColor: color.accentWash,
    color: color.accentText,
    fontFamily: font.mono,
    fontSize: 11,
  },
  recipe: {
    flexDirection: "row",
    alignItems: "center",
    gap: 6,
    paddingHorizontal: 10,
    paddingVertical: 5,
    borderRadius: 7,
    backgroundColor: color.raised,
  },
  recipeLabel: { fontSize: 12, color: color.muted },
  recipeName: { fontFamily: font.mono, fontSize: 12, color: color.text },
  recipes: { flexDirection: "row", flexWrap: "wrap", gap: 6, paddingTop: 4 },
  recipeChip: { paddingHorizontal: 10, paddingVertical: 5, borderRadius: 7, backgroundColor: color.field },
  recipeOn: { backgroundColor: color.pill },
  recipeChipText: { fontSize: 12, color: color.textSoft },
  body: { paddingHorizontal: 16, paddingTop: 8, paddingBottom: 40, gap: 14, width: "100%" },
  bodyWide: { maxWidth: 900, paddingHorizontal: 32, paddingTop: 22 },
  top: { flexDirection: "row", alignItems: "center", gap: 10 },
  heading: { fontSize: 16, fontWeight: "600", color: color.text },
  autoLabel: { fontSize: 13, color: color.textSoft },
  none: { fontSize: 14, color: color.faint },

  card: { borderRadius: 12, borderWidth: 1, backgroundColor: "#141418", overflow: "hidden" },
  cardHead: {
    flexDirection: "row",
    alignItems: "center",
    gap: 10,
    paddingVertical: 11,
    paddingHorizontal: 14,
  },
  dot: { width: 8, height: 8, borderRadius: 4 },
  treeLabel: { flexShrink: 1, fontFamily: font.mono, fontSize: 12, color: color.text },
  chatTitle: { flex: 1, minWidth: 0, fontSize: 13, color: color.muted },
  treeState: { flexShrink: 0, fontSize: 12 },
  link: { fontSize: 12, color: color.textDim },

  running: {
    gap: 10,
    paddingTop: 12,
    paddingBottom: 14,
    paddingHorizontal: 14,
    borderTopWidth: 1,
    borderTopColor: color.divider,
    backgroundColor: "#17171c",
  },
  runHead: { flexDirection: "row", alignItems: "center", gap: 10, minWidth: 0 },
  runMark: { width: 22, fontFamily: font.mono, fontSize: 11, fontWeight: "700", color: color.accentText },
  runTitle: { flex: 1, minWidth: 0, fontSize: 15, color: color.text },
  track: { height: 3, borderRadius: 2, backgroundColor: color.raised, overflow: "hidden" },
  trackFill: { height: 3, width: "100%", backgroundColor: color.accent, opacity: 0.55 },
  runFoot: { flexDirection: "row", alignItems: "center", gap: 8, flexWrap: "wrap" },
  runNote: { flex: 1, minWidth: 120, fontSize: 13, color: color.textSoft },
  actions: { flexDirection: "row", gap: 8 },

  needs: {
    flexDirection: "row",
    alignItems: "center",
    gap: 10,
    paddingVertical: 11,
    paddingHorizontal: 14,
    borderTopWidth: 1,
    borderTopColor: color.divider,
    backgroundColor: color.needsCard,
  },
  needsMark: { width: 22, fontFamily: font.mono, fontSize: 12, fontWeight: "700", color: color.needs },
  needsSub: { fontSize: 12, color: color.needs },

  id: { fontFamily: font.mono, fontSize: 12, color: color.muted },
  grow: { flex: 1, minWidth: 0, gap: 2 },
  row: { borderTopWidth: 1, borderTopColor: color.hairline },
  rowHead: {
    flexDirection: "row",
    alignItems: "center",
    gap: 12,
    paddingVertical: 10,
    paddingHorizontal: 14,
  },
  prio: { width: 22, fontFamily: font.mono, fontSize: 11, fontWeight: "700" },
  rowTitle: { fontSize: 14, color: color.text },
  rowSub: { fontSize: 12, color: color.faint },
  next: { fontSize: 12, color: color.faint },

  blockedHead: {
    paddingVertical: 8,
    paddingHorizontal: 14,
    borderTopWidth: 1,
    borderTopColor: color.hairline,
  },
  blockedText: { fontSize: 12, color: color.muted },

  detail: { gap: 12, paddingTop: 2, paddingBottom: 16, paddingHorizontal: 14 },
  field: {
    minHeight: 34,
    paddingHorizontal: 10,
    paddingVertical: 7,
    borderRadius: 8,
    backgroundColor: color.field,
    borderWidth: 1,
    borderColor: color.border,
    color: color.text,
    fontSize: 14,
    outlineStyle: "none",
  } as any,
  area: { minHeight: 72, fontSize: 13, lineHeight: 19, textAlignVertical: "top" },
  meta: { flexDirection: "row", flexWrap: "wrap", gap: 12, columnGap: 22, alignItems: "center" },
  metaGroup: { flexDirection: "row", alignItems: "center", gap: 6, flexWrap: "wrap" },
  metaLabel: { fontSize: 12, color: color.muted, marginRight: 2 },
  prios: { flexDirection: "row", gap: 2, padding: 2, borderRadius: 8, backgroundColor: color.card },
  prioOpt: { paddingVertical: 3, paddingHorizontal: 8, borderRadius: 6 },
  prioText: { fontSize: 12, color: color.muted },
  chip: { paddingVertical: 3, paddingHorizontal: 8, borderRadius: 6, backgroundColor: color.divider },
  chipText: { fontFamily: font.mono, fontSize: 11, color: color.textSoft },
  chipAdd: {
    backgroundColor: "transparent",
    borderWidth: 1,
    borderStyle: "dashed",
    borderColor: color.outline,
  },
  chipAddText: { fontSize: 11, color: color.muted },
  chipPick: { backgroundColor: "transparent", borderWidth: 1, borderColor: color.border },
  foot: { flexDirection: "row", alignItems: "center", gap: 14 },
  file: { flexShrink: 1, fontFamily: font.mono, fontSize: 12, color: color.faint },
  delete: { fontSize: 12, color: color.red },

  addRow: {
    flexDirection: "row",
    alignItems: "center",
    gap: 12,
    paddingVertical: 4,
    paddingHorizontal: 14,
    borderTopWidth: 1,
    borderTopColor: color.hairline,
  },
  plus: { fontSize: 16, color: color.accentText },
  addInput: {
    flex: 1,
    minWidth: 0,
    height: 32,
    color: color.text,
    fontSize: 14,
    outlineStyle: "none",
  } as any,

  pill: {
    paddingVertical: 5,
    paddingHorizontal: 11,
    borderRadius: 7,
    borderWidth: 1,
    borderColor: color.outline,
  },
  pillStrong: { backgroundColor: color.textStrong, borderColor: color.textStrong },
  pillText: { fontSize: 12, color: color.text },
  pillTextStrong: { color: color.bg, fontWeight: "600" },

  history: { marginTop: 6 },
  historyHead: { fontSize: 12, color: color.muted, marginBottom: 4 },
  histRow: {
    flexDirection: "row",
    alignItems: "center",
    gap: 14,
    paddingVertical: 11,
    paddingHorizontal: 6,
    borderBottomWidth: 1,
    borderBottomColor: color.hairline,
  },
  histId: { width: 72, fontFamily: font.mono, fontSize: 12, color: color.textDim },
  histState: { width: 70, fontSize: 13 },
  histTitle: { flex: 1, minWidth: 0, fontSize: 14, color: color.text },
  histMeta: { maxWidth: 220, fontSize: 12, color: color.muted, textAlign: "right" },
});
