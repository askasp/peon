import { useState } from "react";
import { StyleSheet, Text, TextInput, View } from "react-native";
import { ErrorLine, Loading, Tap } from "./ui";
import { useLoad } from "@/lib/useLoad";
import { ago } from "@/lib/time";
import { color, font } from "@/lib/theme";

type Call = <T = any>(event: string, payload?: object, timeout?: number) => Promise<T>;

export type Entry = {
  id: number;
  source: string;
  action: string;
  label: string;
  status: "waiting" | "posting" | "posted" | "failed" | "skipped" | "undone";
  origin: string;
  args: Record<string, any>;
  error: string | null;
  created_at: string;
  updated_at: string;
};

// Actions that can be posted in reverse once they're through.
const undoable = new Set(["setField", "close", "reopen", "archive", "assign"]);

/** The connector's letters on a small tile ("GH", "F"), like the design's sidebar. */
export function SourceBadge({ short, size = 22 }: { short: string; size?: number }) {
  return (
    <View style={[st.badge, { width: size, height: size, borderRadius: size / 4 }]}>
      <Text style={[st.badgeText, { fontSize: size * 0.42 }]}>{short}</Text>
    </View>
  );
}

const statusText: Record<Entry["status"], string> = {
  waiting: "Waiting for you",
  posting: "Posting",
  posted: "Posted",
  failed: "Failed",
  skipped: "Skipped",
  undone: "Undone",
};

/**
 * Every change a Dataset posted (or will post) to its sources' services: from
 * views, the chat and scheduled runs. Ask-first actions wait here for Post
 * (editable first) or Skip; posted ones can be undone, failed ones retried.
 */
export function Outbox({ call, onChange }: { call: Call; onChange?: () => void }) {
  const [entries, setEntries] = useState<Entry[] | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [edits, setEdits] = useState<Record<number, string>>({});
  const [error, setError] = useState<string | null>(null);
  const { data, error: loadError } = useLoad(() => call<{ entries: Entry[] }>("outbox", {}, 30000), []);
  const shown = entries ?? data?.entries;

  async function op(e: Entry, name: "post" | "skip" | "undo" | "retry") {
    setBusy(`${name}-${e.id}`);
    setError(null);
    try {
      const args = name === "post" && edits[e.id] != null ? { ...e.args, body: edits[e.id] } : undefined;
      const r = await call<{ entries: Entry[] }>(
        `outbox_${name}`,
        { id: e.id, ...(args ? { args } : {}) },
        60000,
      );
      setEntries(r.entries);
      onChange?.();
    } catch (err: any) {
      setError(err.message);
    }
    setBusy(null);
  }

  if (!shown) return loadError ? <ErrorLine message={loadError} /> : <Loading />;

  return (
    <View style={st.wrap} testID="outbox">
      <ErrorLine message={error} />
      {shown.length === 0 ? (
        <Text style={st.empty}>
          Nothing posted yet. Changes from views, the chat and scheduled runs show up here.
        </Text>
      ) : null}
      {shown.map((e) => {
        const body = typeof e.args?.body === "string" ? e.args.body : null;
        const waiting = e.status === "waiting";
        return (
          <View key={e.id} testID={`outbox-${e.id}`} style={[st.entry, waiting && st.entryWaiting]}>
            <View style={st.head}>
              <View style={{ flex: 1, gap: 2 }}>
                <Text style={st.label} numberOfLines={2}>
                  {e.label}
                </Text>
                <Text style={st.meta} numberOfLines={1}>
                  {e.action} · {e.origin} · {ago(e.created_at, true)}
                </Text>
              </View>
              <Text
                style={[
                  st.status,
                  waiting && { color: color.needs },
                  e.status === "failed" && { color: color.red },
                  e.status === "posted" && { color: color.teal },
                ]}
              >
                {statusText[e.status] ?? e.status}
              </Text>
            </View>
            {body != null ? (
              waiting ? (
                <TextInput
                  value={edits[e.id] ?? body}
                  onChangeText={(t) => setEdits((m) => ({ ...m, [e.id]: t }))}
                  multiline
                  style={st.body}
                  placeholderTextColor={color.faint}
                />
              ) : (
                <Text style={st.bodyText} numberOfLines={4}>
                  {body}
                </Text>
              )
            ) : null}
            {e.status === "failed" && e.error ? <Text style={st.error}>{e.error}</Text> : null}
            <View style={st.actions}>
              {waiting ? (
                <>
                  <Act label="Post" strong busy={busy === `post-${e.id}`} onPress={() => op(e, "post")} />
                  <Act label="Skip" busy={busy === `skip-${e.id}`} onPress={() => op(e, "skip")} />
                </>
              ) : null}
              {e.status === "posted" && undoable.has(e.action) ? (
                <Act label="Undo" busy={busy === `undo-${e.id}`} onPress={() => op(e, "undo")} />
              ) : null}
              {e.status === "failed" ? (
                <Act label="Retry" busy={busy === `retry-${e.id}`} onPress={() => op(e, "retry")} />
              ) : null}
            </View>
          </View>
        );
      })}
    </View>
  );
}

function Act({
  label,
  onPress,
  busy,
  strong,
}: {
  label: string;
  onPress: () => void;
  busy?: boolean;
  strong?: boolean;
}) {
  return (
    <Tap
      haptic
      onPress={onPress}
      disabled={busy}
      testID={`outbox-${label.toLowerCase()}`}
      style={[st.act, strong && st.actStrong]}
    >
      <Text style={[st.actText, strong && { color: color.bg, fontWeight: "600" }]}>{busy ? "…" : label}</Text>
    </Tap>
  );
}

const st = StyleSheet.create({
  wrap: { gap: 8 },
  empty: { fontSize: 13, lineHeight: 19, color: color.muted, paddingVertical: 8 },
  entry: {
    borderWidth: 1,
    borderColor: color.border,
    borderRadius: 12,
    backgroundColor: color.card,
    padding: 12,
    gap: 8,
  },
  entryWaiting: { borderColor: color.needsBorder, backgroundColor: color.needsCard },
  head: { flexDirection: "row", alignItems: "flex-start", gap: 12 },
  label: { fontSize: 14, color: color.text, fontWeight: "500" },
  meta: { fontSize: 12, color: color.faint },
  status: { fontSize: 12, color: color.muted, fontWeight: "600" },
  body: {
    minHeight: 64,
    borderRadius: 8,
    borderWidth: 1,
    borderColor: color.border,
    backgroundColor: color.bg,
    padding: 10,
    color: color.text,
    fontSize: 14,
    lineHeight: 20,
    outlineStyle: "none",
  } as any,
  bodyText: { fontSize: 13, lineHeight: 19, color: color.textDim },
  error: { fontSize: 12, lineHeight: 17, color: color.red, fontFamily: font.mono },
  actions: { flexDirection: "row", gap: 8, justifyContent: "flex-end" },
  act: {
    height: 30,
    paddingHorizontal: 12,
    borderRadius: 8,
    borderWidth: 1,
    borderColor: color.outline,
    alignItems: "center",
    justifyContent: "center",
  },
  actStrong: { backgroundColor: color.textStrong, borderColor: color.textStrong },
  actText: { fontSize: 13, color: color.text },
  badge: { backgroundColor: color.raised, alignItems: "center", justifyContent: "center" },
  badgeText: { color: color.textStrong, fontWeight: "700" },
});
