import { ScrollView, StyleSheet, Text, View } from "react-native";
import { color, font } from "@/lib/theme";
import type { DiffFile } from "@/lib/types";

type Line = { kind: " " | "+" | "-" | "@"; n: number | null; text: string };

// A patch's lines with the line number each has in its file (old for removed).
function lines(patch: string): Line[] {
  const out: Line[] = [];
  let a = 0;
  let b = 0;
  for (const l of patch.split("\n")) {
    if (l.startsWith("+++") || l.startsWith("---") || l.startsWith("diff ") || l.startsWith("index "))
      continue;
    const hunk = /^@@ -(\d+)(?:,\d+)? \+(\d+)/.exec(l);
    if (hunk) {
      a = Number(hunk[1]);
      b = Number(hunk[2]);
      out.push({ kind: "@", n: null, text: l });
    } else if (l.startsWith("+")) out.push({ kind: "+", n: b++, text: l.slice(1) });
    else if (l.startsWith("-")) out.push({ kind: "-", n: a++, text: l.slice(1) });
    else if (l.length) {
      out.push({ kind: " ", n: b, text: l.slice(1) });
      a++;
      b++;
    }
  }
  return out;
}

const look = {
  "+": { bg: "#0f2226", fg: "#9fd3d6", n: "#3d5a60" },
  "-": { bg: "#2a1616", fg: "#e6a49c", n: "#6c4a4a" },
  " ": { bg: "transparent", fg: color.textDim, n: "#4a4a52" },
  "@": { bg: "transparent", fg: color.faint, n: "#4a4a52" },
};

/** The changed files: a summary, then each file's patch with its lines coloured. */
export function DiffView({ files }: { files: DiffFile[] }) {
  if (files.length === 0) return <Text style={st.empty}>No changed files yet.</Text>;
  const added = files.reduce((n, f) => n + (f.additions ?? 0), 0);
  const removed = files.reduce((n, f) => n + (f.deletions ?? 0), 0);

  return (
    <View>
      <Text style={st.summary}>
        <Text style={{ color: color.teal }}>+{added}</Text>{" "}
        <Text style={{ color: color.red }}>−{removed}</Text> · {files.length} file
        {files.length === 1 ? "" : "s"} changed
      </Text>
      {files.map((f) => (
        <View key={f.file}>
          <View style={st.head}>
            <Text style={st.path} numberOfLines={1}>
              {f.file}
            </Text>
            <Text style={st.counts}>
              <Text style={{ color: color.teal }}>+{f.additions ?? 0}</Text>{" "}
              <Text style={{ color: color.red }}>−{f.deletions ?? 0}</Text>
            </Text>
          </View>
          {f.patch ? (
            <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={st.patch}>
              <View style={{ minWidth: "100%" }}>
                {lines(f.patch).map((l, i) => (
                  <View key={i} style={[st.line, { backgroundColor: look[l.kind].bg }]}>
                    <Text style={[st.n, { color: look[l.kind].n }]}>{l.n ?? ""}</Text>
                    <Text style={[st.code, { color: look[l.kind].fg }]}>
                      {l.kind === "@" ? l.text : `${l.kind === " " ? " " : l.kind} ${l.text}`}
                    </Text>
                  </View>
                ))}
              </View>
            </ScrollView>
          ) : null}
        </View>
      ))}
    </View>
  );
}

const st = StyleSheet.create({
  empty: { fontSize: 13, color: color.muted, padding: 16 },
  summary: { fontSize: 13, color: color.muted, paddingHorizontal: 16, paddingVertical: 10 },
  head: {
    flexDirection: "row",
    justifyContent: "space-between",
    gap: 8,
    paddingHorizontal: 16,
    paddingVertical: 9,
    borderTopWidth: 1,
    borderBottomWidth: 1,
    borderColor: color.hairline,
    backgroundColor: "#141418",
  },
  path: { flex: 1, fontSize: 11.5, fontFamily: font.mono, color: color.textSoft },
  counts: { fontSize: 11.5, fontFamily: font.mono },
  patch: { paddingVertical: 6, paddingBottom: 10, minWidth: "100%" },
  line: { flexDirection: "row", gap: 10, paddingHorizontal: 14 },
  n: { width: 26, textAlign: "right", fontSize: 11.5, lineHeight: 19.5, fontFamily: font.mono },
  code: { fontSize: 11.5, lineHeight: 19.5, fontFamily: font.mono },
});
