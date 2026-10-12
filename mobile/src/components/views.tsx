import { useMemo, useState } from "react";
import { Image, Platform, ScrollView, StyleSheet, Text, TextInput, View } from "react-native";
import { Frame } from "./Frame";
import { ErrorLine, Loading, Tap } from "./ui";
import { useLoad } from "@/lib/useLoad";
import { color, font } from "@/lib/theme";

// The Views: how each kind of file is shown, on the phone (full screen) and on
// the web (beside the chat or the file tree).

export type Opened = { path: string; type: string; size: number; url: string; text: string | null };
export type Call = <T = any>(event: string, payload?: object, timeout?: number) => Promise<T>;

/** Markdown as a document: headings, paragraphs, bullets and code blocks. */
export function Doc({ text }: { text: string }) {
  const blocks: { k: "h1" | "h2" | "p" | "li" | "code"; t: string }[] = [];
  let code: string[] | null = null;
  for (const line of text.split("\n")) {
    if (line.startsWith("```")) {
      if (code) blocks.push({ k: "code", t: code.join("\n") });
      code = code ? null : [];
    } else if (code) code.push(line);
    else if (!line.trim()) continue;
    else if (line.startsWith("# ")) blocks.push({ k: "h1", t: line.slice(2) });
    else if (/^#{2,6} /.test(line)) blocks.push({ k: "h2", t: line.replace(/^#+ /, "") });
    else if (/^\s*[-*] /.test(line)) blocks.push({ k: "li", t: line.replace(/^\s*[-*] /, "") });
    else blocks.push({ k: "p", t: line });
  }
  const strip = (t: string) =>
    t
      .replace(/\*\*([^*]+)\*\*/g, "$1")
      .replace(/`([^`]+)`/g, "$1")
      .replace(/\[([^\]]+)\]\([^)]+\)/g, "$1");
  return (
    <ScrollView contentContainerStyle={st.doc}>
      {blocks.map((b, i) =>
        b.k === "h1" ? (
          <Text key={i} style={st.h1}>
            {strip(b.t)}
          </Text>
        ) : b.k === "h2" ? (
          <Text key={i} style={st.h2}>
            {strip(b.t)}
          </Text>
        ) : b.k === "li" ? (
          <View key={i} style={st.li}>
            <Text style={st.bullet}>•</Text>
            <Text style={[st.p, { flex: 1 }]}>{strip(b.t)}</Text>
          </View>
        ) : b.k === "code" ? (
          <ScrollView key={i} horizontal style={st.codeBlock}>
            <Text style={st.codeText}>{b.t}</Text>
          </ScrollView>
        ) : (
          <Text key={i} style={st.p}>
            {strip(b.t)}
          </Text>
        ),
      )}
    </ScrollView>
  );
}

export type Device = "phone" | "desktop" | "both";

/** A design at phone or desktop size (or both), on a dotted canvas. */
export function Canvas({ url, version, mode }: { url: string; version: number; mode: Device }) {
  const [box, setBox] = useState({ w: 0, h: 0 });
  const phone = { w: 390, h: 844 };
  const desk = { w: 1280, h: 800 };
  // Both: the desktop takes what's left beside a phone at the same height.
  const fit = (s: { w: number; h: number }, w: number, pad: number) =>
    Math.min(1, (w - 40 - pad) / s.w, (box.h - 40 - pad) / s.h);
  const phoneScale = fit(phone, mode === "both" ? box.w * 0.32 : box.w, 12);
  const deskScale = fit(desk, mode === "both" ? box.w - phone.w * phoneScale - 40 : box.w, 18);
  return (
    <View
      style={[st.canvas, Platform.OS === "web" && (st.dots as any)]}
      onLayout={(e) => setBox({ w: e.nativeEvent.layout.width, h: e.nativeEvent.layout.height })}
    >
      {box.w > 0 ? (
        <View style={st.devices}>
          {mode !== "phone" ? (
            <View style={st.desk}>
              <View style={st.chrome}>
                <View style={st.light} />
                <View style={st.light} />
                <View style={st.light} />
              </View>
              <Frame url={url} width={desk.w} height={desk.h} scale={deskScale} version={version} />
            </View>
          ) : null}
          {mode !== "desktop" ? (
            <View style={st.phone}>
              <Frame url={url} width={phone.w} height={phone.h} scale={phoneScale} version={version} />
            </View>
          ) : null}
        </View>
      ) : null}
    </View>
  );
}

/** Pick phone, desktop (or both) for the canvas. */
export function DevicePicker({
  value,
  onChange,
  options,
  small,
}: {
  value: Device;
  onChange: (d: Device) => void;
  options: Device[];
  small?: boolean;
}) {
  return (
    <View style={[st.seg, small && st.segSmall]}>
      {options.map((m) => (
        <Tap
          key={m}
          onPress={() => onChange(m)}
          style={[st.segItem, small && st.segItemSmall, value === m && st.segOn]}
        >
          <Text style={[st.segText, small && { fontSize: 12 }, value === m && { color: color.textStrong }]}>
            {m.charAt(0).toUpperCase() + m.slice(1)}
          </Text>
        </Tap>
      ))}
    </View>
  );
}

/** An app the agent wrote, full size. */
export function AppView({ url }: { url: string }) {
  const [box, setBox] = useState({ w: 0, h: 0 });
  return (
    <View
      style={{ flex: 1 }}
      onLayout={(e) => setBox({ w: e.nativeEvent.layout.width, h: e.nativeEvent.layout.height })}
    >
      {box.w > 0 ? <Frame url={url} width={box.w} height={box.h} /> : null}
    </View>
  );
}

/** Rows of a SQLite table (read on the server) or a CSV, view only. */
export function Table({ call, path, text }: { call: Call; path: string; text: string | null }) {
  const csv = path.toLowerCase().endsWith(".csv");
  const [table, setTable] = useState<string | null>(null);
  const [filter, setFilter] = useState("");
  const [sort, setSort] = useState<[string, 1 | -1] | null>(null);
  const { data, error } = useLoad(async (): Promise<{
    tables: { name: string; rows: number | null }[];
    columns: string[];
    rows: any[];
    table: string | null;
  }> => {
    if (!csv) return call("table", { path, table }, 60000);
    const [head = [], ...rest] = parseCsv(text ?? "");
    return {
      tables: [],
      table: null,
      columns: head,
      rows: rest.map((r) => Object.fromEntries(head.map((h, i) => [h, r[i] ?? ""]))),
    };
  }, [path, table]);

  const rows = useMemo(() => {
    if (!data) return [];
    const q = filter.trim().toLowerCase();
    let out = q
      ? data.rows.filter((r) =>
          data.columns.some((c) =>
            String(r[c] ?? "")
              .toLowerCase()
              .includes(q),
          ),
        )
      : data.rows;
    if (sort) {
      const [k, dir] = sort;
      out = [...out].sort((a, b) => (String(a[k]) > String(b[k]) ? 1 : -1) * dir);
    }
    return out;
  }, [data, filter, sort]);

  if (error) return <ErrorLine message={error} />;
  if (!data) return <Loading />;
  const W = 150;
  return (
    <ScrollView contentContainerStyle={st.table}>
      {data.tables.length > 1 ? (
        <View style={st.seg}>
          {data.tables.map((t) => {
            const on = t.name === data.table;
            return (
              <Tap key={t.name} onPress={() => setTable(t.name)} style={[st.segItem, on && st.segOn]}>
                <Text style={[st.segText, on && { color: color.textStrong }]}>
                  {t.name} <Text style={{ color: color.faint }}>{t.rows ?? ""}</Text>
                </Text>
              </Tap>
            );
          })}
        </View>
      ) : null}
      <TextInput
        value={filter}
        onChangeText={setFilter}
        placeholder="Filter rows"
        placeholderTextColor="#62626b"
        autoCapitalize="none"
        style={st.filter}
      />
      <Text style={st.where}>
        {csv ? "CSV" : "SQLite"} · {rows.length} rows · swipe sideways for more columns
      </Text>
      <ScrollView horizontal style={st.grid} showsHorizontalScrollIndicator={false}>
        <View>
          <View style={[st.gridRow, st.gridHead]}>
            {data.columns.map((c) => (
              <Tap
                key={c}
                onPress={() => setSort(sort?.[0] === c ? (sort[1] === 1 ? [c, -1] : null) : [c, 1])}
                style={[st.cell, { width: W }]}
              >
                <Text style={st.headText} numberOfLines={1}>
                  {c} {sort?.[0] === c ? (sort[1] === 1 ? "↑" : "↓") : ""}
                </Text>
              </Tap>
            ))}
          </View>
          {rows.map((r, i) => (
            <View key={i} style={st.gridRow}>
              {data.columns.map((c) => (
                <View key={c} style={[st.cell, { width: W }]}>
                  <Text style={st.cellText} numberOfLines={1}>
                    {r[c] == null ? "" : String(r[c])}
                  </Text>
                </View>
              ))}
            </View>
          ))}
          {rows.length === 0 ? (
            <Text style={[st.cellText, { padding: 12, color: color.faint }]}>No rows.</Text>
          ) : null}
        </View>
      </ScrollView>
      <Text style={st.faintSmall}>View only. Ask in a chat to add or change rows.</Text>
    </ScrollView>
  );
}

export function parseCsv(text: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [];
  let cell = "";
  let quoted = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (quoted) {
      if (ch === '"' && text[i + 1] === '"') {
        cell += '"';
        i++;
      } else if (ch === '"') quoted = false;
      else cell += ch;
    } else if (ch === '"') quoted = true;
    else if (ch === ",") {
      row.push(cell);
      cell = "";
    } else if (ch === "\n") {
      row.push(cell.replace(/\r$/, ""));
      rows.push(row);
      row = [];
      cell = "";
    } else cell += ch;
  }
  if (cell || row.length) rows.push([...row, cell]);
  return rows.filter((r) => r.some((c) => c !== ""));
}

export function Img({ url, file }: { url: string; file: Opened }) {
  return (
    <View style={st.center}>
      <Image source={{ uri: url }} style={st.image} resizeMode="contain" />
      <Text style={st.faint}>
        {file.type.split("/")[1]?.toUpperCase()} · {size(file.size)}
      </Text>
    </View>
  );
}

export function Code({ text }: { text: string }) {
  return (
    <ScrollView>
      <ScrollView horizontal contentContainerStyle={st.code}>
        <View>
          {text.split("\n").map((l, i) => (
            <View key={i} style={st.codeLine}>
              <Text style={st.codeN}>{i + 1}</Text>
              <Text style={st.codeText}>{l || " "}</Text>
            </View>
          ))}
        </View>
      </ScrollView>
    </ScrollView>
  );
}

export function size(bytes: number) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(0)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

const st = StyleSheet.create({
  where: { fontSize: 12, color: color.muted },
  doc: { padding: 22, paddingBottom: 40, gap: 9, maxWidth: 720 },
  h1: {
    fontFamily: font.brand,
    fontSize: 26,
    letterSpacing: -0.8,
    lineHeight: 30,
    color: color.text,
    marginBottom: 4,
  },
  h2: { fontSize: 16, fontWeight: "600", color: color.text, marginTop: 12 },
  p: { fontSize: 16, lineHeight: 25, color: color.textSoft },
  li: { flexDirection: "row", gap: 10 },
  bullet: { fontSize: 16, lineHeight: 25, color: color.faint },
  codeBlock: { borderRadius: 10, backgroundColor: color.bgDeep, padding: 12 },
  seg: { flexDirection: "row", padding: 3, borderRadius: 10, backgroundColor: color.field },
  segItem: { flex: 1, alignItems: "center", paddingVertical: 6, borderRadius: 8 },
  segOn: { backgroundColor: color.pill },
  segText: { fontSize: 14, color: color.textDim },
  canvas: { flex: 1, alignItems: "center", justifyContent: "center", backgroundColor: "#0c0c0f" },
  devices: { flexDirection: "row", alignItems: "center", gap: 24 },
  segSmall: { padding: 2, borderRadius: 7, backgroundColor: color.card },
  segItemSmall: {
    flexGrow: 0,
    flexShrink: 0,
    flexBasis: "auto",
    paddingVertical: 3,
    paddingHorizontal: 9,
    borderRadius: 5,
  },
  dots: { backgroundImage: "radial-gradient(#202027 1px, transparent 1px)", backgroundSize: "18px 18px" },
  phone: {
    borderRadius: 30,
    borderWidth: 6,
    borderColor: "#2c2c34",
    overflow: "hidden",
    backgroundColor: "#fff",
  },
  desk: {
    borderRadius: 9,
    borderWidth: 1,
    borderColor: "#2c2c34",
    overflow: "hidden",
    backgroundColor: "#fff",
  },
  chrome: {
    height: 16,
    flexDirection: "row",
    alignItems: "center",
    gap: 4,
    paddingHorizontal: 7,
    backgroundColor: "#e4e1d8",
  },
  light: { width: 5, height: 5, borderRadius: 3, backgroundColor: "#c9c5ba" },
  table: { padding: 16, paddingBottom: 30, gap: 10 },
  filter: {
    height: 38,
    borderRadius: 10,
    backgroundColor: color.field,
    paddingHorizontal: 12,
    color: color.text,
    fontSize: 15,
    outlineStyle: "none",
  } as any,
  grid: { borderWidth: 1, borderColor: color.divider, borderRadius: 10 },
  gridRow: { flexDirection: "row", borderBottomWidth: 1, borderBottomColor: color.hairline },
  gridHead: { backgroundColor: "#17171c", borderBottomColor: color.divider },
  cell: { paddingHorizontal: 12, paddingVertical: 10 },
  headText: { fontSize: 13, fontWeight: "600", color: color.textSoft },
  cellText: { fontSize: 14, color: color.text },
  center: { flex: 1, alignItems: "center", justifyContent: "center", gap: 14 },
  image: { width: "80%", height: "60%" },
  faint: { fontSize: 13, color: color.muted },
  faintSmall: { fontSize: 12, lineHeight: 17, color: color.faint },
  code: { paddingVertical: 12, paddingBottom: 30 },
  codeLine: { flexDirection: "row", gap: 12, paddingHorizontal: 14 },
  codeN: {
    width: 28,
    textAlign: "right",
    fontSize: 12,
    lineHeight: 20,
    fontFamily: font.mono,
    color: "#4a4a52",
  },
  codeText: { fontSize: 12, lineHeight: 20, fontFamily: font.mono, color: color.textSoft },
});
