// Beside a procedure's chat (O2, O3): the procedure as the chat builds and
// edits it. Steps or File; the file shows what the chat's last message changed,
// with Undo. Run starts it in its own run chat.

import { useState } from "react";
import { ScrollView, StyleSheet, Text, View } from "react-native";
import { ErrorLine, Loading, Tap } from "../ui";
import { InputFields } from "./ProceduresTab";
import { ProcedureDetail } from "./ProcedureDetail";
import { lineDiff, type DiffLine } from "@/lib/lineDiff";
import { sinceInput, type Procedure } from "@/lib/procedures";
import { useLoad } from "@/lib/useLoad";
import { color, font } from "@/lib/theme";
import type { Run } from "@/lib/types";
import type { ProjectCtx } from "./types";

/** What `procedure_chat_info` says about a procedure chat. */
export type ProcedureChatInfo = {
  procedure: string | null;
  path: string | null;
  /** The file before the chat's last message ("" when the chat made it), or null. */
  base: string | null;
  new: boolean;
};

type Values = Record<string, string | string[]>;

export function ProcedurePane({
  ctx,
  sessionId,
  info,
  onChanged,
  onRan,
  onOpen,
}: {
  ctx: ProjectCtx;
  sessionId: string;
  info: ProcedureChatInfo | null;
  /** The file changed here (Undo): read the info and procedures again. */
  onChanged: () => void;
  onRan: (run: Run) => void;
  /** Opens another procedure's chat (a step that runs it). */
  onOpen: (name: string) => void;
}) {
  const [view, setView] = useState<"steps" | "file">("steps");
  const p = info?.procedure ? (ctx.procedures.find((x) => x.name === info.procedure) ?? null) : null;
  const { data: runs } = useLoad(() => ctx.call<{ runs: Run[] }>("runs").then((r) => r.runs), [ctx.changed]);
  // The file as it is now, read again when the procedures are (a turn ended, Undo).
  const { data: file, error: fileError } = useLoad(
    () =>
      info?.path
        ? ctx.call<{ text: string | null }>("open_file", { path: info.path }, 30000).then((r) => r.text ?? "")
        : Promise.resolve(null),
    [info?.path, ctx.procedures],
  );
  const diff = info?.base && file != null && info.base !== file ? lineDiff(info.base, file) : null;
  const added = diff?.filter((l) => l.kind === "add").length ?? 0;
  const removed = diff?.filter((l) => l.kind === "del").length ?? 0;
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function undo() {
    setError(null);
    try {
      await ctx.call("procedure_undo", { session_id: sessionId }, 30000);
      onChanged();
    } catch (e: any) {
      setError(e.message);
    }
  }

  // Inputs without a default are asked for first.
  const [asking, setAsking] = useState<Values | null>(null);
  const needs = (x: Procedure) =>
    x.inputs.some((i) => !sinceInput(i) && (i.default == null || i.default === "" || i.default.length === 0));
  async function run(values?: Values) {
    if (!p) return;
    if (!values && needs(p))
      return setAsking(
        Object.fromEntries(p.inputs.map((i) => [i.name, i.default === "last_run" ? "" : i.default])),
      );
    setBusy(true);
    setError(null);
    try {
      const inputs = Object.fromEntries(
        Object.entries(values ?? {}).filter(([, v]) => (Array.isArray(v) ? v.length : v)),
      );
      const r = await ctx.call<{ run: Run }>("run", { procedure: p.name, inputs }, 60000);
      setAsking(null);
      onRan(r.run);
    } catch (e: any) {
      setError(e.message);
    }
    setBusy(false);
  }

  return (
    <View style={st.pane}>
      <View style={st.head}>
        <Text style={st.path} numberOfLines={1}>
          <Text style={{ color: color.faint }}>.peon/procedures/</Text>
          {info?.procedure ? `${info.procedure}.md` : "…"}
        </Text>
        {info?.new && info.procedure ? <Text style={st.newChip}>New</Text> : null}
        <View style={{ flex: 1 }} />
        {p ? (
          <>
            <View style={st.toggle}>
              {(["steps", "file"] as const).map((v) => (
                <Tap
                  key={v}
                  onPress={() => setView(v)}
                  style={[st.toggleItem, view === v && st.toggleOn]}
                  testID={`procedure-view-${v}`}
                >
                  <Text style={[st.toggleText, view === v && { color: color.textStrong }]}>
                    {v === "steps" ? "Steps" : "File"}
                  </Text>
                </Tap>
              ))}
            </View>
            <Tap onPress={() => run()} disabled={busy} style={st.run} testID="procedure-run">
              <Text style={st.runText}>{busy ? "Starting…" : info?.new ? "Try run" : "Run"}</Text>
            </Tap>
          </>
        ) : null}
      </View>
      <ErrorLine message={error} />
      {asking && p ? (
        <View style={st.ask}>
          <InputFields inputs={p.inputs} values={asking} onChange={setAsking} since={p.since} />
          <View style={{ flexDirection: "row", gap: 16, alignItems: "center" }}>
            <Tap onPress={() => run(asking)} disabled={busy} style={st.run} testID="procedure-run-go">
              <Text style={st.runText}>Run</Text>
            </Tap>
            <Tap onPress={() => setAsking(null)} hitSlop={8}>
              <Text style={st.muted}>Cancel</Text>
            </Tap>
          </View>
        </View>
      ) : null}

      {!info ? (
        <Loading />
      ) : !p ? (
        <View style={st.empty}>
          <Text style={st.muted}>
            {info.procedure
              ? `No procedure called ${info.procedure}.`
              : "The procedure shows here as it's written."}
          </Text>
        </View>
      ) : view === "steps" ? (
        <ProcedureDetail
          ctx={ctx}
          procedure={p}
          runs={(runs ?? []).filter((r) => r.procedure === p.name && !r.parent_id)}
          onOpen={onOpen}
          onOpenRun={onRan}
          embedded
        />
      ) : (
        <View style={{ flex: 1, minHeight: 0 }}>
          {diff ? (
            <View style={st.changed}>
              <Text style={st.counts}>
                <Text style={{ color: color.accentText }}>+{added}</Text>{" "}
                <Text style={{ color: color.red }}>−{removed}</Text>
              </Text>
              <Text style={[st.muted, { flex: 1 }]} numberOfLines={1}>
                Changed from the chat
              </Text>
              {ctx.canEdit ? (
                <Tap onPress={undo} hitSlop={8} testID="procedure-undo">
                  <Text style={st.undo}>Undo</Text>
                </Tap>
              ) : null}
            </View>
          ) : null}
          <ErrorLine message={fileError} />
          {file == null ? (
            <Loading />
          ) : (
            <ScrollView contentContainerStyle={st.code} testID="procedure-file">
              {(diff ?? file.split("\n").map((text): DiffLine => ({ kind: "same", text }))).map((l, i) => (
                <Text
                  key={i}
                  style={[st.line, l.kind === "add" && st.lineAdd, l.kind === "del" && st.lineDel]}
                  selectable
                >
                  {l.kind === "add" ? "+ " : l.kind === "del" ? "- " : "  "}
                  {l.text || " "}
                </Text>
              ))}
            </ScrollView>
          )}
        </View>
      )}
    </View>
  );
}

const st = StyleSheet.create({
  pane: { flex: 1, minHeight: 0, backgroundColor: color.bg },
  head: {
    minHeight: 44,
    flexDirection: "row",
    alignItems: "center",
    gap: 10,
    paddingHorizontal: 14,
    paddingVertical: 6,
    borderBottomWidth: 1,
    borderBottomColor: color.hairline,
  },
  path: {
    flexShrink: 1,
    paddingHorizontal: 8,
    paddingVertical: 4,
    borderRadius: 6,
    backgroundColor: color.field,
    fontFamily: font.mono,
    fontSize: 12.5,
    color: color.text,
  },
  newChip: {
    paddingHorizontal: 7,
    paddingVertical: 2,
    borderRadius: 5,
    backgroundColor: color.accentWash,
    color: color.accentText,
    fontSize: 12,
  },
  toggle: { flexDirection: "row", padding: 2, borderRadius: 8, backgroundColor: color.field },
  toggleItem: { paddingHorizontal: 11, paddingVertical: 4, borderRadius: 6 },
  toggleOn: { backgroundColor: color.raised },
  toggleText: { fontSize: 12.5, color: color.muted },
  run: {
    paddingHorizontal: 12,
    paddingVertical: 5,
    borderRadius: 7,
    borderWidth: 1,
    borderColor: color.outline,
  },
  runText: { fontSize: 13, color: color.text },
  ask: {
    gap: 12,
    padding: 16,
    borderBottomWidth: 1,
    borderBottomColor: color.hairline,
    backgroundColor: color.card,
  },
  muted: { fontSize: 13, color: color.muted },
  empty: { padding: 24 },
  changed: {
    flexDirection: "row",
    alignItems: "center",
    gap: 10,
    paddingHorizontal: 18,
    paddingVertical: 10,
    borderBottomWidth: 1,
    borderBottomColor: color.hairline,
  },
  counts: { fontSize: 13, fontFamily: font.mono },
  undo: { fontSize: 13, fontWeight: "600", color: color.text },
  code: { paddingVertical: 14 },
  line: {
    paddingHorizontal: 18,
    fontFamily: font.mono,
    fontSize: 12.5,
    lineHeight: 21,
    color: color.textSoft,
  },
  lineAdd: { backgroundColor: "#14241a", color: color.accentText },
  lineDel: { backgroundColor: "#2a1616", color: color.red },
});
