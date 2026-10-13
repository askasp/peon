import { useState } from "react";
import { RefreshControl, ScrollView, StyleSheet, Text, View } from "react-native";
import { router } from "expo-router";
import { Button, Card, Dot, Empty, ErrorLine, LargeTitle, Screen, SectionLabel, Tap } from "@/components/ui";
import { Letter } from "@/components/desktop/Sidebar";
import { ask, refreshInbox, usePeon } from "@/lib/peon";
import { PermResources } from "@/components/PermResources";
import { ago, duration } from "@/lib/time";
import { color } from "@/lib/theme";
import { useWide } from "@/lib/useWide";
import type { InboxItem } from "@/lib/types";

// 1a · Inbox: everything waiting on you, answerable without opening anything.
export default function Inbox() {
  const user = usePeon((s) => s.user);
  const inbox = usePeon((s) => s.inbox);
  const running = usePeon((s) => s.running);
  const connected = usePeon((s) => s.connected);
  const [refreshing, setRefreshing] = useState(false);

  const busy = running.filter((r) => r.status === "running").length;
  const summary = [
    inbox.length ? `${inbox.length} need${inbox.length === 1 ? "s" : ""} you` : "Nothing waiting",
    busy ? `${busy} running` : null,
  ]
    .filter(Boolean)
    .join(" · ");

  async function refresh() {
    setRefreshing(true);
    try {
      await refreshInbox();
    } catch {}
    setRefreshing(false);
  }

  return (
    <Screen>
      <ScrollView
        contentContainerStyle={st.body}
        refreshControl={
          <RefreshControl refreshing={refreshing} onRefresh={refresh} tintColor={color.muted} />
        }
      >
        <LargeTitle
          right={
            <View style={st.avatar}>
              <Text style={st.avatarText}>{(user?.username ?? "?").slice(0, 1).toUpperCase()}</Text>
            </View>
          }
        >
          Inbox
        </LargeTitle>
        <Text style={st.summary}>{connected ? summary : "Connecting…"}</Text>

        {inbox.map((item) => (
          <InboxCard key={item.key} item={item} />
        ))}

        {inbox.length === 0 && connected ? (
          <Empty title="All clear" detail="Approvals, questions and runs waiting for you show up here." />
        ) : null}

        {running.length > 0 ? (
          <>
            <SectionLabel style={{ marginTop: 6 }}>Running</SectionLabel>
            {running.map((r) => (
              <Tap kb="row" key={r.id} style={st.running} onPress={() => router.push(`/session/${r.id}`)}>
                <Dot tint={r.status === "waiting" ? color.needs : color.accent} />
                <Text style={st.runningTitle} numberOfLines={1}>
                  {r.title}
                </Text>
                <Text style={st.runningMeta}>{r.status === "waiting" ? "Needs you" : r.project.name}</Text>
              </Tap>
            ))}
          </>
        ) : null}
      </ScrollView>
    </Screen>
  );
}

/** On desktop, a card's kind as a small glyph tile at its head. */
function KindTile({ glyph, tint, bg }: { glyph: string; tint: string; bg: string }) {
  const wide = useWide();
  if (!wide) return null;
  return (
    <View style={[st.kindTile, { backgroundColor: bg }]}>
      <Text style={[st.kindGlyph, { color: tint }]}>{glyph}</Text>
    </View>
  );
}

/** Where a card comes from: the Project's letter and name, then a detail. */
function Source({ name, detail }: { name: string; detail: string }) {
  return (
    <View style={st.source}>
      <Letter name={name} size={16} />
      <Text style={st.meta} numberOfLines={1}>
        {name} · {detail}
      </Text>
    </View>
  );
}

function InboxCard({ item }: { item: InboxItem }) {
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function act(name: string, fn: () => Promise<unknown>) {
    setBusy(name);
    setError(null);
    try {
      await fn();
    } catch (e: any) {
      setError(e.message);
      setBusy(null);
    }
  }

  if (item.type === "permission") {
    const perm = item.perm;
    const reply = (decision: string) =>
      act(decision, () => ask("permission", { session_id: perm.session_id, id: perm.id, decision }));

    return (
      <Tap kb="row" style={st.cardWrap} onPress={() => router.push(`/session/${item.session.id}`)}>
        <Card needs>
          <View style={st.cardHead}>
            <KindTile glyph="!" tint={color.needs} bg={color.needsWash} />
            <Text style={[st.kind, { color: color.needs }]}>Permission</Text>
            <Source name={item.project.name} detail={item.session.title} />
          </View>
          <Text style={st.cardText}>{perm.title}</Text>
          <PermResources resources={perm.resources} />
          <ErrorLine message={error} />
          <View style={st.actions}>
            <Button
              label="Allow once"
              height={44}
              style={{ flex: 1 }}
              busy={busy === "once"}
              onPress={() => reply("once")}
            />
            <Button
              label="Deny"
              kind="secondary"
              height={44}
              style={{ flex: 1 }}
              busy={busy === "reject"}
              onPress={() => reply("reject")}
            />
          </View>
        </Card>
      </Tap>
    );
  }

  if (item.type === "question") {
    const open = () => router.push(`/session/${item.session.id}`);
    return (
      <Tap kb="row" style={st.cardWrap} onPress={open}>
        <Card needs>
          <View style={st.cardHead}>
            <KindTile glyph="?" tint={color.needs} bg={color.needsWash} />
            <Text style={[st.kind, { color: color.needs }]}>
              {item.form.count > 1 ? `${item.form.count} questions` : "Question"}
            </Text>
            <Source name={item.project.name} detail={item.session.title} />
          </View>
          <Text style={st.cardText}>{item.form.text}</Text>
          <View style={st.actions}>
            <Button label="Answer" height={44} style={{ flex: 1 }} onPress={open} testID="inbox-answer" />
          </View>
        </Card>
      </Tap>
    );
  }

  const run = item.run;
  const failed = run.status === "failed";
  // A procedure run that waits for you (a batch to confirm, a step to read).
  const waiting = run.status === "waiting";
  return (
    <Tap
      kb="row"
      style={st.cardWrap}
      onPress={() => run.session_id && router.push(`/session/${run.session_id}`)}
    >
      <Card>
        <View style={st.cardHead}>
          <KindTile
            glyph={failed ? "✕" : waiting ? "?" : "✓"}
            tint={failed ? color.red : waiting ? color.needs : color.teal}
            bg={color.divider}
          />
          <Text style={[st.kind, { color: failed ? color.red : waiting ? color.needs : color.teal }]}>
            {failed ? "Run failed" : waiting ? `${run.procedure} needs you` : "Run finished"}
          </Text>
          <Source name={item.project.name} detail={ago(run.finished ?? run.started)} />
        </View>
        <Text style={st.cardText}>
          {waiting
            ? run.waiting?.text
            : run.error ||
              run.summary ||
              `${run.schedule_key} ran for ${duration(run.started, run.finished)}.`}
        </Text>
        <ErrorLine message={error} />
        <View style={st.actions}>
          {waiting && run.waiting?.kind === "before" ? (
            <>
              <Button
                label="Go ahead"
                height={44}
                style={{ flex: 1 }}
                busy={busy === "continue"}
                onPress={() => act("continue", () => ask("inbox_continue", { id: run.id }))}
                testID="inbox-continue"
              />
              <Button
                label="Skip"
                kind="secondary"
                height={44}
                style={{ flex: 1 }}
                busy={busy === "skip"}
                onPress={() => act("skip", () => ask("inbox_skip", { id: run.id }))}
                testID="inbox-skip"
              />
            </>
          ) : null}
          {run.session_id || !waiting ? (
            <Button
              label="Open"
              kind={waiting ? "secondary" : undefined}
              height={44}
              style={{ flex: 1 }}
              disabled={!run.session_id}
              onPress={() => router.push(`/session/${run.session_id}`)}
            />
          ) : null}
          <Button
            label="Dismiss"
            kind="secondary"
            height={44}
            style={{ flex: 1 }}
            busy={busy === "dismiss"}
            onPress={() => act("dismiss", () => ask("dismiss_run", { id: run.id }))}
          />
        </View>
      </Card>
    </Tap>
  );
}

const st = StyleSheet.create({
  body: { paddingHorizontal: 18, paddingTop: 6, paddingBottom: 24, gap: 12 },
  avatar: {
    width: 34,
    height: 34,
    borderRadius: 17,
    backgroundColor: color.raised,
    alignItems: "center",
    justifyContent: "center",
  },
  avatarText: { color: color.text, fontSize: 14, fontWeight: "600" },
  summary: { fontSize: 14, color: color.muted, marginTop: -8 },
  cardWrap: {},
  cardHead: { flexDirection: "row", alignItems: "center", gap: 10 },
  kindTile: { width: 26, height: 26, borderRadius: 7, alignItems: "center", justifyContent: "center" },
  kindGlyph: { fontSize: 13, fontWeight: "700" },
  kind: { fontSize: 12, fontWeight: "600" },
  meta: { fontSize: 12, color: color.muted, flexShrink: 1 },
  source: { flexDirection: "row", alignItems: "center", gap: 6, flexShrink: 1, marginLeft: "auto" },
  cardText: { fontSize: 15, lineHeight: 21, color: color.text },
  actions: { flexDirection: "row", gap: 8 },
  running: { flexDirection: "row", alignItems: "center", gap: 12, paddingVertical: 6, paddingHorizontal: 2 },
  runningTitle: { flex: 1, color: color.text, fontSize: 15 },
  runningMeta: { fontSize: 13, color: color.muted },
});
