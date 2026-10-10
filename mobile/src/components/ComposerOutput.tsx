import { StyleSheet, Text, View } from "react-native";
import { router } from "expo-router";
import { Tap } from "./ui";
import { color } from "@/lib/theme";
import { ago } from "@/lib/time";
import type { Answer, Plan } from "@/lib/useComposer";
import type { PlanRow } from "@/lib/types";

/** What the composer read the line as (rows), and what came back (answer or note). */
export function ComposerOutput({
  plan,
  rows,
  answer,
  note,
  unsure = false,
  busy = false,
  open = (id) => router.replace(`/session/${id}`),
}: {
  plan: Plan | null;
  rows: PlanRow[];
  answer: Answer | null;
  note: string | null;
  /** The rules can't read the line; the model will (busy: it is reading now). */
  unsure?: boolean;
  busy?: boolean;
  open?: (sessionId: string) => void;
}) {
  return (
    <>
      {unsure ? (
        <Text style={st.unsure} testID="composer-unsure">
          {busy ? "Reading it…" : "Press Enter and Peon reads it, in any wording or language."}
        </Text>
      ) : null}
      {plan?.summary ? <Text style={st.summary}>{plan.summary}</Text> : null}
      {rows.length ? (
        <View style={st.rows}>
          {rows.map(([k, v]) => (
            <View key={k} style={st.row}>
              <Text style={st.rowKey}>{k}</Text>
              <Text style={[st.rowValue, k === "Action" && { fontWeight: "500" }]}>{v}</Text>
            </View>
          ))}
        </View>
      ) : null}
      {answer ? (
        <View style={{ gap: 8 }}>
          <Text style={st.answer}>{answer.text}</Text>
          {answer.reply ? (
            <Text style={st.reply} selectable>
              <Text style={{ color: color.faint }}>Last reply: </Text>
              {answer.reply}
            </Text>
          ) : null}
          {answer.items.map((it) => (
            <Tap key={it.id} style={st.item} onPress={() => open(it.id)}>
              <Text style={st.itemTitle} numberOfLines={1}>
                {it.title}
              </Text>
              <Text style={st.itemMeta}>
                {[it.project, it.status === "idle" ? null : it.status, ago(it.updated, true)]
                  .filter(Boolean)
                  .join(" · ")}
              </Text>
            </Tap>
          ))}
        </View>
      ) : null}
      {note ? <Text style={st.answer}>{note}</Text> : null}
    </>
  );
}

const st = StyleSheet.create({
  summary: { fontSize: 14, color: color.textSoft },
  unsure: { fontSize: 13.5, color: color.textSoft },
  rows: { gap: 9 },
  row: { flexDirection: "row", gap: 12 },
  rowKey: { width: 72, fontSize: 14, color: color.faint },
  rowValue: { flex: 1, fontSize: 14, color: color.text },
  answer: { fontSize: 15, lineHeight: 21, color: color.text },
  reply: { fontSize: 14, lineHeight: 20, color: color.textSoft },
  item: { flexDirection: "row", justifyContent: "space-between", gap: 10, paddingVertical: 6 },
  itemTitle: { flex: 1, fontSize: 14, color: color.textSoft },
  itemMeta: { fontSize: 13, color: color.muted },
});
