import { useState } from "react";
import { Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { color, font } from "@/lib/theme";
import type { DiffFile } from "@/lib/types";

const lineColor = (line: string) =>
  line.startsWith("+") && !line.startsWith("+++")
    ? color.teal
    : line.startsWith("-") && !line.startsWith("---")
      ? color.red
      : line.startsWith("@@")
        ? color.faint
        : color.textDim;

/** The session's changed files with +/- counts; a file opens to its patch. */
export function DiffView({ files }: { files: DiffFile[] }) {
  const [open, setOpen] = useState<string | null>(null);
  const added = files.reduce((n, f) => n + (f.additions ?? 0), 0);
  const removed = files.reduce((n, f) => n + (f.deletions ?? 0), 0);

  if (files.length === 0) return <Text style={st.empty}>No changed files yet.</Text>;

  return (
    <View style={{ gap: 6 }}>
      <Text style={st.summary}>
        {files.length} file{files.length === 1 ? "" : "s"} ·{" "}
        <Text style={{ color: color.teal }}>+{added}</Text>{" "}
        <Text style={{ color: color.red }}>−{removed}</Text>
      </Text>
      {files.map((f) => {
        const isOpen = open === f.file;
        return (
          <View key={f.file} style={st.file}>
            <Pressable
              onPress={() => setOpen(isOpen ? null : f.file)}
              style={(s: any) => [st.head, s.hovered && { backgroundColor: color.raised }]}
            >
              <Text style={st.name} numberOfLines={1}>
                {f.file}
              </Text>
              <Text style={st.count}>
                <Text style={{ color: color.teal }}>+{f.additions ?? 0}</Text>{" "}
                <Text style={{ color: color.red }}>−{f.deletions ?? 0}</Text>
              </Text>
            </Pressable>
            {isOpen ? (
              <ScrollView horizontal style={st.patch} contentContainerStyle={{ padding: 10 }}>
                <View>
                  {(f.patch ?? "No patch to show.").split("\n").map((line, i) => (
                    <Text key={i} style={[st.line, { color: lineColor(line) }]}>
                      {line || " "}
                    </Text>
                  ))}
                </View>
              </ScrollView>
            ) : null}
          </View>
        );
      })}
    </View>
  );
}

const st = StyleSheet.create({
  empty: { fontSize: 13, color: color.muted, padding: 8 },
  summary: { fontSize: 13, color: color.textDim, paddingHorizontal: 2, paddingBottom: 4 },
  file: { borderRadius: 10, borderWidth: 1, borderColor: color.divider, overflow: "hidden" },
  head: { flexDirection: "row", alignItems: "center", gap: 10, paddingHorizontal: 10, paddingVertical: 8 },
  name: { flex: 1, fontSize: 12.5, fontFamily: font.mono, color: color.text },
  count: { fontSize: 12, fontFamily: font.mono },
  patch: { backgroundColor: color.bgDeep, borderTopWidth: 1, borderTopColor: color.divider, maxHeight: 420 },
  line: { fontSize: 12, lineHeight: 17, fontFamily: font.mono },
});
