import { createContext, ReactNode, useContext, useState } from "react";
import * as Clipboard from "expo-clipboard";
import { Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { color, font } from "@/lib/theme";
import { parseRunLink } from "@/lib/procedures";
import { offeredRow, RunLinksContext, RunRows, type OfferedRow } from "./session/RunRows";
import { Tap } from "./ui";

/**
 * A run chat's `[Edit name](edit:name)`: a button that opens that procedure's
 * chat with the reply attached. Without it, the link shows as its text.
 */
export const EditLinkContext = createContext<((procedure: string, reply: string) => void) | null>(null);

// Just enough markdown for agent replies: paragraphs, headings, lists, code
// blocks, **bold**, `code` and [links](…) as their text. In a chat that can run
// them, lines with run-links ([Send refund](run:refund?…)) become rows with a
// button, and `peon-status`, `peon-output` and `peon-step` blocks (for Peon) aren't shown.

function inline(text: string, key: string): ReactNode[] {
  const out: ReactNode[] = [];
  const re = /(\*\*[^*]+\*\*|`[^`]+`|\[[^\]]+\]\([^)]+\))/g;
  let last = 0;
  let m: RegExpExecArray | null;
  let i = 0;
  while ((m = re.exec(text))) {
    if (m.index > last) out.push(text.slice(last, m.index));
    const tok = m[0];
    if (tok.startsWith("**"))
      out.push(
        <Text key={`${key}-${i++}`} style={st.bold}>
          {tok.slice(2, -2)}
        </Text>,
      );
    else if (tok.startsWith("`"))
      out.push(
        <Text key={`${key}-${i++}`} style={st.code}>
          {tok.slice(1, -1)}
        </Text>,
      );
    else
      out.push(
        <Text key={`${key}-${i++}`} style={st.link}>
          {tok.slice(1, tok.indexOf("]"))}
        </Text>,
      );
    last = m.index + tok.length;
  }
  if (last < text.length) out.push(text.slice(last));
  return out;
}

function CopyButton({ text }: { text: string }) {
  const [done, setDone] = useState(false);
  return (
    <Pressable
      style={(s: any) => [st.copy, s.hovered && { backgroundColor: color.pill }]}
      onPress={async () => {
        await Clipboard.setStringAsync(text);
        setDone(true);
        setTimeout(() => setDone(false), 1500);
      }}
    >
      <Text style={st.copyText}>{done ? "Copied" : "Copy"}</Text>
    </Pressable>
  );
}

export function Markdown({ text, streaming }: { text: string; streaming?: boolean }) {
  const runnable = useContext(RunLinksContext) != null;
  const edit = useContext(EditLinkContext);
  const blocks: ReactNode[] = [];
  const parts = text.split(/```/);

  parts.forEach((part, pi) => {
    // What a step hands back to Peon (per-row status, outputs, "changes needed").
    if (pi % 2 === 1 && /^peon-(status|output|step)\b/.test(part)) return;
    if (pi % 2 === 1) {
      // A code block; drop the language line.
      const code = part.replace(/^[^\n]*\n/, "").replace(/\n$/, "");
      blocks.push(
        <View key={`c${pi}`} style={st.preWrap}>
          <ScrollView horizontal style={st.pre} contentContainerStyle={{ padding: 12, paddingRight: 48 }}>
            <Text style={st.preText} selectable>
              {code}
            </Text>
          </ScrollView>
          <CopyButton text={code} />
        </View>,
      );
      return;
    }

    let para: string[] = [];
    let rows: OfferedRow[] = [];
    const flush = (k: string) => {
      if (para.length)
        blocks.push(
          <Text key={k} style={st.p} selectable>
            {inline(para.join(" "), k)}
          </Text>,
        );
      para = [];
      if (rows.length) blocks.push(<RunRows key={`${k}r`} rows={rows} />);
      rows = [];
    };

    part.split("\n").forEach((line, li) => {
      const k = `${pi}-${li}`;
      const trimmed = line.trim();
      const heading = /^#{1,6}\s+(.*)$/.exec(trimmed);
      const bullet = /^([-*+]|\d+[.)])\s+(.*)$/.exec(trimmed);
      const href = runnable ? /\[([^\]]+)\]\((run:[^)\s]+)\)/.exec(trimmed) : null;
      const link = href ? parseRunLink(href[2], href[1]) : null;

      const editing = edit ? /^\[([^\]]+)\]\(edit:([\w.-]+)\)$/.exec(trimmed) : null;

      if (editing && edit) {
        flush(`${k}p`);
        const reply = text
          .replace(/```peon-[\s\S]*?(```|$)/g, "")
          .replace(trimmed, "")
          .trim();
        blocks.push(
          <Tap key={k} onPress={() => edit(editing[2], reply)} style={st.edit} testID={`edit-${editing[2]}`}>
            <Text style={st.editText}>{editing[1]}</Text>
          </Tap>,
        );
      } else if (link) {
        if (para.length) flush(`${k}p`);
        rows.push(offeredRow(trimmed, link));
      } else if (!trimmed) {
        // Blank lines between rows keep them in one card.
        if (!rows.length) flush(k);
      } else if (heading) {
        flush(`${k}p`);
        blocks.push(
          <Text key={k} style={[st.p, st.heading]}>
            {inline(heading[1], k)}
          </Text>,
        );
      } else if (bullet) {
        flush(`${k}p`);
        const marker = /\d/.test(bullet[1]) ? bullet[1] : "•";
        blocks.push(
          <View key={k} style={st.li}>
            <Text style={[st.p, st.marker]}>{marker}</Text>
            <Text style={[st.p, { flex: 1 }]}>{inline(bullet[2], k)}</Text>
          </View>,
        );
      } else if (/^\|.*\|$/.test(trimmed) || /^[-=*_]{3,}$/.test(trimmed)) {
        // Tables and rules: shown as plain lines.
        flush(`${k}p`);
        if (!/^\|?[\s:-|]+\|?$/.test(trimmed))
          blocks.push(
            <Text key={k} style={st.table}>
              {trimmed}
            </Text>,
          );
      } else {
        if (rows.length) flush(`${k}r`);
        para.push(trimmed);
      }
    });
    flush(`${pi}-end`);
  });

  return (
    <View style={{ gap: 8 }}>
      {blocks}
      {streaming ? <Text style={st.cursor}>▍</Text> : null}
    </View>
  );
}

const st = StyleSheet.create({
  p: { fontSize: 15, lineHeight: 22, color: color.text },
  heading: { fontWeight: "700", fontSize: 16 },
  bold: { fontWeight: "700" },
  code: { fontFamily: font.mono, fontSize: 13, color: color.accentText },
  link: { color: color.accentText },
  li: { flexDirection: "row", gap: 8, paddingLeft: 2 },
  marker: { color: color.muted, minWidth: 12 },
  preWrap: { position: "relative" },
  copy: {
    position: "absolute",
    top: 6,
    right: 6,
    paddingHorizontal: 8,
    paddingVertical: 3,
    borderRadius: 6,
    backgroundColor: color.raised,
  },
  copyText: { fontSize: 11, color: color.textDim },
  pre: { borderRadius: 10, backgroundColor: color.bgDeep, borderWidth: 1, borderColor: color.border },
  preText: { fontFamily: font.mono, fontSize: 12.5, lineHeight: 18, color: color.textSoft },
  table: { fontFamily: font.mono, fontSize: 12, color: color.textDim },
  cursor: { color: color.accent, marginTop: -6 },
  edit: {
    alignSelf: "flex-start",
    paddingHorizontal: 13,
    paddingVertical: 7,
    borderRadius: 8,
    borderWidth: 1,
    borderColor: color.outline,
  },
  editText: { fontSize: 13.5, fontWeight: "600", color: color.text },
});
