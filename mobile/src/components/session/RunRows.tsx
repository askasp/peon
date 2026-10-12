import { createContext, useContext, useState } from "react";
import { ActivityIndicator, StyleSheet, Text, View } from "react-native";
import { Tap } from "../ui";
import { total, type RowState, type RunLink } from "@/lib/procedures";
import { color } from "@/lib/theme";
import type { Perm } from "@/lib/types";

/** One row a result offered: what it's about, and the run-link its button starts. */
export type OfferedRow = { link: RunLink; title: string; detail: string };

/**
 * What a chat lets its run-links do. Without it (an earlier chat, a View),
 * run-links show as plain text.
 */
export type RunLinksApi = {
  state: (link: RunLink) => RowState;
  run: (link: RunLink) => Promise<unknown>;
  /** "Send all": asks first (count, each row, total), then one message. */
  confirm: (rows: OfferedRow[]) => void;
  approve: (perm: Perm) => Promise<unknown>;
};

export const RunLinksContext = createContext<RunLinksApi | null>(null);

/** A markdown line holding a run-link → the row's text and its link. */
export function offeredRow(line: string, link: RunLink): OfferedRow {
  let text = line.trim();
  // A table row: its cells, without the one holding the link.
  if (/^\|.*\|$/.test(text)) {
    const cells = text
      .slice(1, -1)
      .split("|")
      .map((c) => c.trim())
      .filter((c) => c && !/\]\(run:/.test(c));
    return { link, title: plain(cells[0] ?? link.label), detail: cells.slice(1).map(plain).join(" · ") };
  }
  text = text.replace(/^([-*+]|\d+[.)])\s+/, "").replace(/\[[^\]]+\]\(run:[^)\s]+\)/g, "");
  const bold = /^\*\*([^*]+)\*\*/.exec(text);
  const title = bold ? bold[1] : text.split(/\s+[·—–-]\s+|:\s+/)[0];
  const rest = text.slice(bold ? bold[0].length : title.length);
  return {
    link,
    title: plain(title) || link.label,
    detail: plain(rest.replace(/^[\s·—–:,-]+|[\s·—–:,-]+$/g, "")),
  };
}

const plain = (s: string) => s.replace(/\*\*|`/g, "").trim();

/** Rows with a button each (P1), each following its own run (P5), and Send all. */
export function RunRows({ rows }: { rows: OfferedRow[] }) {
  const api = useContext(RunLinksContext);
  if (!api) return null;
  const states = rows.map((r) => api.state(r.link));
  const ready = rows.filter((_, i) => states[i].kind === "ready");
  // Send all: the ready rows of the most offered action.
  const first = ready[0]?.link;
  const batch = first
    ? ready.filter((r) => r.link.procedure === first.procedure && r.link.label === first.label)
    : [];
  const sum = total(batch.map((r) => r.link));

  return (
    <View style={{ gap: 10 }}>
      <View style={st.card}>
        {rows.map((r, i) => (
          <Row key={i} row={r} state={states[i]} api={api} last={i === rows.length - 1} />
        ))}
      </View>
      {batch.length >= 2 ? (
        <Tap haptic onPress={() => api.confirm(batch)} style={st.all} testID="send-all">
          <Text style={st.allText}>
            {first!.label.split(" ")[0]} all {batch.length}
            {sum ? ` · ${sum}` : ""}
          </Text>
        </Tap>
      ) : null}
    </View>
  );
}

function Row({
  row,
  state,
  api,
  last,
}: {
  row: OfferedRow;
  state: RowState;
  api: RunLinksApi;
  last: boolean;
}) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const act = async (f: () => Promise<unknown>) => {
    setBusy(true);
    setError(null);
    try {
      await f();
    } catch (e: any) {
      setError(e.message);
    }
    setBusy(false);
  };

  const amount = [row.link.values.amount, row.link.values.currency].filter(Boolean).join(" ");
  const [line, tint] =
    error != null
      ? [error, color.red]
      : state.kind === "done"
        ? [state.note || "Done", color.teal]
        : state.kind === "failed"
          ? [`Failed${state.note ? ` · ${state.note}` : ""}`, color.red]
          : state.kind === "skipped"
            ? [`Not sent${state.note ? ` · ${state.note}` : ""}`, color.red]
            : state.kind === "waiting"
              ? [`Waiting for your approval${amount ? ` · ${amount}` : ""}`, color.needs]
              : [row.detail, color.muted];

  return (
    <View
      style={[st.row, !last && st.rowLine, state.kind === "waiting" && { backgroundColor: color.needsCard }]}
    >
      <View style={st.rowText}>
        <Text style={st.title} numberOfLines={1}>
          {row.title}
        </Text>
        {line ? (
          <Text style={[st.detail, { color: tint }]} numberOfLines={2}>
            {line}
          </Text>
        ) : null}
      </View>
      {busy ? (
        <ActivityIndicator size="small" color={color.muted} style={{ width: 40 }} />
      ) : state.kind === "ready" ? (
        <Tap haptic onPress={() => act(() => api.run(row.link))} style={st.go} testID="run-link">
          <Text style={st.goText}>{row.link.label}</Text>
        </Tap>
      ) : state.kind === "sent" ? (
        <View style={st.sent}>
          <Text style={st.sentText}>Sent</Text>
        </View>
      ) : state.kind === "waiting" ? (
        <Tap
          haptic
          onPress={() => act(() => api.approve(state.perm))}
          style={st.approve}
          testID="row-approve"
        >
          <Text style={st.approveText}>Approve</Text>
        </Tap>
      ) : state.kind === "failed" ? (
        <Tap haptic onPress={() => act(() => api.run(row.link))} style={st.retry}>
          <Text style={st.retryText}>Retry</Text>
        </Tap>
      ) : state.kind === "done" ? (
        <Text style={st.check}>✓</Text>
      ) : null}
    </View>
  );
}

const st = StyleSheet.create({
  card: {
    borderRadius: 12,
    backgroundColor: "#17171c",
    borderWidth: 1,
    borderColor: color.border,
    overflow: "hidden",
  },
  row: { flexDirection: "row", alignItems: "center", gap: 10, paddingHorizontal: 12, paddingVertical: 10 },
  rowLine: { borderBottomWidth: 1, borderBottomColor: color.divider },
  rowText: { flex: 1, minWidth: 0, gap: 2 },
  title: { fontSize: 15, color: color.text },
  detail: { fontSize: 12, lineHeight: 16 },
  go: { paddingHorizontal: 12, paddingVertical: 7, borderRadius: 16, backgroundColor: color.accent },
  goText: { fontSize: 13, fontWeight: "600", color: color.accentInk },
  sent: { paddingHorizontal: 12, paddingVertical: 6, borderRadius: 16, backgroundColor: color.raised },
  sentText: { fontSize: 13, color: color.textDim },
  approve: { paddingHorizontal: 12, paddingVertical: 7, borderRadius: 16, backgroundColor: color.textStrong },
  approveText: { fontSize: 13, fontWeight: "600", color: color.bg },
  retry: {
    paddingHorizontal: 12,
    paddingVertical: 6,
    borderRadius: 16,
    borderWidth: 1,
    borderColor: color.outline,
  },
  retryText: { fontSize: 13, color: color.text },
  check: { fontSize: 16, color: color.teal, paddingHorizontal: 6 },
  all: {
    alignSelf: "flex-start",
    paddingHorizontal: 14,
    paddingVertical: 8,
    borderRadius: 18,
    borderWidth: 1,
    borderColor: color.accentBorder,
    backgroundColor: color.accentWash,
  },
  allText: { fontSize: 13, fontWeight: "600", color: color.accentText },
});
