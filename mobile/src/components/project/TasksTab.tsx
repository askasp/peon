import { useEffect, useState } from "react";
import { ScrollView, StyleSheet, Text, TextInput, View } from "react-native";
import { Button, ErrorLine, Tap } from "../ui";
import { ago } from "@/lib/time";
import { color } from "@/lib/theme";
import type { Ticket } from "@/lib/types";
import type { ProjectCtx } from "./types";

// A task's state as a quiet dot and word.
const tint = (s: string) =>
  s === "in_progress" ? color.accentText : s === "closed" ? color.faint : color.muted;
const word = (s: string) => (s === "in_progress" ? "Doing" : s === "closed" ? "Done" : "Queued");

/**
 * A Folder's tasks: the `tk` tickets in its `.tickets/` folder. Queue one here
 * or from a chat; open one to read it, follow its notes, and move it along.
 */
export function TasksTab({ ctx }: { ctx: ProjectCtx }) {
  const [tickets, setTickets] = useState<Ticket[] | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const call = ctx.call;

  // Refetched whenever the Folder pushes a change (its "changed" counter).
  useEffect(() => {
    let live = true;
    call<{ tickets: Ticket[] }>("tickets").then(
      (r) => {
        if (!live) return;
        setTickets(r.tickets);
        setLoadError(null);
      },
      (e) => live && setLoadError(e.message),
    );
    return () => {
      live = false;
    };
  }, [call, ctx.changed]);

  const [title, setTitle] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [openId, setOpenId] = useState<string | null>(null);
  const [notes, setNotes] = useState<Record<string, string>>({});

  async function run(event: string, payload: object) {
    setBusy(true);
    setError(null);
    try {
      const r = await ctx.call<{ tickets: Ticket[] }>(event, payload, 40000);
      setTickets(r.tickets);
      return true;
    } catch (e: any) {
      setError(e.message);
      return false;
    } finally {
      setBusy(false);
    }
  }

  async function queue() {
    const t = title.trim();
    if (!t) return;
    if (await run("ticket_create", { params: { title: t, type: "task" } })) setTitle("");
  }

  async function addNote(id: string) {
    const text = (notes[id] ?? "").trim();
    if (!text) return;
    if (await run("ticket_note", { id, text })) setNotes((n) => ({ ...n, [id]: "" }));
  }

  const active = (tickets ?? []).filter((t) => t.status !== "closed");
  const done = (tickets ?? []).filter((t) => t.status === "closed");

  const row = (t: Ticket) => {
    const open = openId === t.id;
    return (
      <View key={t.id} style={st.card}>
        <Tap onPress={() => setOpenId(open ? null : t.id)} style={st.head} kb="row">
          <View style={[st.dot, { backgroundColor: tint(t.status) }]} />
          <Text style={[st.title, t.status === "closed" && { color: color.muted }]} numberOfLines={2}>
            {t.title}
          </Text>
          <Text style={[st.state, { color: tint(t.status) }]}>{word(t.status)}</Text>
        </Tap>
        <Text style={st.meta}>
          {t.type} · P{t.priority}
          {t.notes.length ? ` · ${t.notes.length} note${t.notes.length === 1 ? "" : "s"}` : ""}
          {t.notes.length ? ` · ${ago(t.notes[t.notes.length - 1].at, true)}` : ""}
        </Text>

        {open ? (
          <View style={st.detail}>
            {t.body ? <Text style={st.text}>{t.body}</Text> : null}

            {t.notes.map((n, i) => (
              <View key={i} style={st.note}>
                <Text style={st.noteAt}>{ago(n.at, true)}</Text>
                <Text style={st.text}>{n.text}</Text>
              </View>
            ))}

            <View style={st.actions}>
              {t.status !== "in_progress" && t.status !== "closed" ? (
                <Button
                  label="Start"
                  kind="secondary"
                  height={36}
                  disabled={busy}
                  onPress={() => run("ticket_status", { id: t.id, status: "in_progress" })}
                />
              ) : null}
              {t.status !== "closed" ? (
                <Button
                  label="Done"
                  kind="secondary"
                  height={36}
                  disabled={busy}
                  onPress={() => run("ticket_status", { id: t.id, status: "closed" })}
                />
              ) : (
                <Button
                  label="Reopen"
                  kind="secondary"
                  height={36}
                  disabled={busy}
                  onPress={() => run("ticket_status", { id: t.id, status: "open" })}
                />
              )}
            </View>

            <View style={st.noteRow}>
              <TextInput
                value={notes[t.id] ?? ""}
                onChangeText={(v) => setNotes((n) => ({ ...n, [t.id]: v }))}
                placeholder="Add a note…"
                placeholderTextColor={color.faint}
                style={st.field}
                onSubmitEditing={() => addNote(t.id)}
              />
              <Tap onPress={() => addNote(t.id)} style={st.add} disabled={busy}>
                <Text style={st.addText}>Note</Text>
              </Tap>
            </View>
          </View>
        ) : null}
      </View>
    );
  };

  return (
    <ScrollView contentContainerStyle={st.body}>
      <View style={st.queued}>
        <TextInput
          value={title}
          onChangeText={setTitle}
          placeholder="Queue a task…"
          placeholderTextColor={color.faint}
          style={st.field}
          onSubmitEditing={queue}
          returnKeyType="send"
          testID="task-input"
        />
        <Button
          label="Queue"
          height={38}
          busy={busy}
          disabled={!title.trim()}
          onPress={queue}
          testID="task-queue"
        />
      </View>
      <ErrorLine message={error ?? loadError} />

      {tickets == null ? (
        <Text style={st.none}>Loading…</Text>
      ) : tickets.length === 0 ? (
        <Text style={st.none}>
          No tasks yet. Queue one above, or ask a chat to “track this as a task” — tasks live in the folder’s
          .tickets/ and stay with the code.
        </Text>
      ) : (
        <>
          {active.map(row)}
          {done.length ? (
            <>
              <Text style={st.heading}>Done</Text>
              {done.map(row)}
            </>
          ) : null}
        </>
      )}
    </ScrollView>
  );
}

const st = StyleSheet.create({
  body: { paddingHorizontal: 18, paddingTop: 8, paddingBottom: 40, gap: 10, maxWidth: 760, width: "100%" },
  queued: { flexDirection: "row", alignItems: "center", gap: 8 },
  field: {
    flex: 1,
    height: 38,
    borderRadius: 9,
    backgroundColor: color.raised,
    paddingHorizontal: 12,
    color: color.text,
    fontSize: 15,
    outlineStyle: "none",
  } as any,
  card: {
    paddingVertical: 10,
    paddingHorizontal: 2,
    gap: 3,
    borderBottomWidth: 1,
    borderBottomColor: color.hairline,
  },
  head: { flexDirection: "row", alignItems: "center", gap: 10 },
  dot: { width: 8, height: 8, borderRadius: 4 },
  title: { flex: 1, fontSize: 15, color: color.text },
  state: { fontSize: 12, fontWeight: "600" },
  meta: { fontSize: 12, color: color.muted, paddingLeft: 18 },
  detail: { paddingTop: 8, paddingLeft: 18, gap: 10 },
  text: { fontSize: 14, lineHeight: 20, color: color.textDim },
  note: { gap: 1, paddingLeft: 8, borderLeftWidth: 2, borderLeftColor: color.divider },
  noteAt: { fontSize: 11, color: color.faint, fontVariant: ["tabular-nums"] },
  actions: { flexDirection: "row", gap: 8 },
  noteRow: { flexDirection: "row", alignItems: "center", gap: 8 },
  add: {
    paddingHorizontal: 12,
    height: 34,
    borderRadius: 8,
    backgroundColor: color.field,
    justifyContent: "center",
  },
  addText: { fontSize: 13, color: color.textSoft },
  heading: { fontSize: 13, color: color.muted, marginTop: 8 },
  none: { fontSize: 14, lineHeight: 20, color: color.faint, paddingTop: 4 },
});
