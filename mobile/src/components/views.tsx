import { useEffect, useMemo, useRef, useState } from "react";
import { FlatList, Image, Platform, ScrollView, StyleSheet, Text, TextInput, View } from "react-native";
import { Frame } from "./Frame";
import { Outbox, SourceBadge } from "./Outbox";
import { ErrorLine, Loading, Tap } from "./ui";
import { useLoad } from "@/lib/useLoad";
import { ago } from "@/lib/time";
import { color, font } from "@/lib/theme";

// The Views: how each kind of file is shown, on the phone (full screen) and on
// the web (beside the chat or the file tree).

export type Opened = { path: string; type: string; size: number; url: string; text: string | null };
export type Call = <T = any>(event: string, payload?: object, timeout?: number) => Promise<T>;

type DocBlock = { k: "h1" | "h2" | "p" | "li" | "code"; t: string };

function parseDoc(text: string): DocBlock[] {
  const blocks: DocBlock[] = [];
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
  return blocks;
}

const strip = (t: string) =>
  t
    .replace(/\*\*([^*]+)\*\*/g, "$1")
    .replace(/`([^`]+)`/g, "$1")
    .replace(/\[([^\]]+)\]\([^)]+\)/g, "$1");

function DocItem({ b }: { b: DocBlock }) {
  if (b.k === "h1") return <Text style={st.h1}>{strip(b.t)}</Text>;
  if (b.k === "h2") return <Text style={st.h2}>{strip(b.t)}</Text>;
  if (b.k === "li")
    return (
      <View style={st.li}>
        <Text style={st.bullet}>•</Text>
        <Text style={[st.p, { flex: 1 }]}>{strip(b.t)}</Text>
      </View>
    );
  if (b.k === "code")
    return (
      <ScrollView horizontal style={st.codeBlock}>
        <Text style={st.codeText}>{b.t}</Text>
      </ScrollView>
    );
  return <Text style={st.p}>{strip(b.t)}</Text>;
}

/**
 * Markdown as a document: headings, paragraphs, bullets and code blocks.
 * A list that only draws what's on screen, so a long document opens at once.
 */
export function Doc({ text }: { text: string }) {
  const blocks = useMemo(() => parseDoc(text), [text]);
  return (
    <FlatList
      data={blocks}
      keyExtractor={(_, i) => String(i)}
      renderItem={({ item }) => <DocItem b={item} />}
      contentContainerStyle={st.doc}
      initialNumToRender={40}
      windowSize={11}
    />
  );
}

export type Device = "phone" | "desktop" | "both";

const ZOOMS = [0.25, 0.33, 0.5, 0.67, 0.75, 0.9, 1, 1.25, 1.5, 2, 3];

const SIZES = { phone: { w: 390, h: 844 }, desktop: { w: 1280, h: 800 } } as const;

/**
 * A design on a pannable canvas: the phone and the desktop layout side by side,
 * with no device chrome, so the design fills the pane. It opens fitted to the
 * pane's height; scrolling moves between the phone and the desktop, − / + (or
 * ctrl/⌘ + scroll and trackpad pinch on the web) zoom it, anchored on the point
 * under the pointer so zooming doesn't jump.
 */
export function Canvas({ url, version, mode = "both" }: { url: string; version: number; mode?: Device }) {
  const [box, setBox] = useState({ w: 0, h: 0 });
  // null: fit the canvas.
  const [zoom, setZoom] = useState<number | null>(null);
  const pad = 16;
  const gap = 32;
  const devices: ("phone" | "desktop")[] =
    mode === "phone" ? ["phone"] : mode === "desktop" ? ["desktop"] : ["desktop", "phone"];
  const tallest = Math.max(...devices.map((d) => SIZES[d].h));
  // Fit the tallest design to the pane's height: the design fills the view, and
  // scrolling left/right swings between the phone and the desktop.
  const base = box.h > 0 ? Math.min(1.5, (box.h - pad * 2) / tallest) : 1;
  const scale = zoom ?? base;

  const step = (dir: 1 | -1) => {
    const next =
      dir > 0 ? ZOOMS.find((z) => z > scale + 0.001) : [...ZOOMS].reverse().find((z) => z < scale - 0.001);
    setZoom(next ?? (dir > 0 ? ZOOMS[ZOOMS.length - 1] : ZOOMS[0]));
  };

  const outer = useRef<View>(null);
  const vref = useRef<ScrollView>(null);
  const href = useRef<ScrollView>(null);
  const scaleRef = useRef(scale);
  useEffect(() => {
    scaleRef.current = scale;
  }, [scale]);
  const ready = box.w > 0;

  // Web: ctrl/⌘ + wheel, or a trackpad pinch, zooms the canvas (not the page),
  // anchored on the point under the pointer.
  useEffect(() => {
    const el = outer.current as unknown as HTMLElement | null;
    if (Platform.OS !== "web" || !ready || !el?.addEventListener) return;
    const scrollNode = (r: typeof vref) =>
      (r.current as unknown as { getScrollableNode?: () => HTMLElement })?.getScrollableNode?.();
    const onWheel = (e: WheelEvent) => {
      if (!e.ctrlKey && !e.metaKey) return;
      e.preventDefault();
      const prev = scaleRef.current;
      const next = Math.min(3, Math.max(0.1, prev * Math.exp(-e.deltaY * 0.01)));
      if (next === prev) return;
      const rect = el.getBoundingClientRect();
      const px = e.clientX - rect.left;
      const py = e.clientY - rect.top;
      const v = scrollNode(vref);
      const h = scrollNode(href);
      const cx = ((h?.scrollLeft ?? 0) + px) * (next / prev);
      const cy = ((v?.scrollTop ?? 0) + py) * (next / prev);
      setZoom(next);
      // Keep the point that was under the pointer in place after the zoom.
      requestAnimationFrame(() => {
        if (h) h.scrollLeft = cx - px;
        if (v) v.scrollTop = cy - py;
      });
    };
    el.addEventListener("wheel", onWheel, { passive: false });
    return () => el.removeEventListener("wheel", onWheel);
  }, [ready]);

  return (
    <View
      ref={outer}
      style={[st.canvas, Platform.OS === "web" && (st.dots as any)]}
      onLayout={(e) => setBox({ w: e.nativeEvent.layout.width, h: e.nativeEvent.layout.height })}
    >
      {ready ? (
        <ScrollView
          ref={vref}
          style={st.pan}
          contentContainerStyle={{ flexGrow: 1 }}
          directionalLockEnabled
          nestedScrollEnabled
        >
          <ScrollView
            ref={href}
            horizontal
            nestedScrollEnabled
            contentContainerStyle={[st.panInner, { minWidth: box.w, minHeight: box.h }]}
          >
            <View style={[st.devices, { gap, padding: pad }]}>
              {devices.map((d) => (
                <View key={d} style={[st.sheet, { width: SIZES[d].w * scale, height: SIZES[d].h * scale }]}>
                  <Frame url={url} width={SIZES[d].w} height={SIZES[d].h} scale={scale} version={version} />
                  {/* A preview: the cover takes scrolls and drags for the canvas,
                      so panning and zooming work over the design, not in it. */}
                  <View style={StyleSheet.absoluteFill} />
                </View>
              ))}
            </View>
          </ScrollView>
        </ScrollView>
      ) : null}
      {ready ? (
        <View style={st.zoomBar}>
          <Tap onPress={() => step(-1)} style={st.zoomKey} aria-label="Zoom out" id="canvas-zoom-out">
            <Text style={st.zoomKeyText}>−</Text>
          </Tap>
          <Tap
            onPress={() => setZoom(zoom === 1 ? null : 1)}
            style={st.zoomPct}
            aria-label={zoom === 1 ? "Fit" : "Actual size"}
            id="canvas-zoom-reset"
          >
            <Text style={st.zoomPctText}>{Math.round(scale * 100)}%</Text>
          </Tap>
          <Tap onPress={() => step(1)} style={st.zoomKey} aria-label="Zoom in" id="canvas-zoom-in">
            <Text style={st.zoomKeyText}>+</Text>
          </Tap>
          <View style={st.zoomSep} />
          <Tap
            onPress={() => setZoom(null)}
            disabled={zoom == null}
            style={st.zoomFit}
            aria-label="Fit to canvas"
            id="canvas-zoom-fit"
          >
            <Text style={[st.zoomFitText, zoom == null && { color: color.faint }]}>Fit</Text>
          </Tap>
        </View>
      ) : null}
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

type Source = {
  name: string;
  table: string;
  fetched_at: string | null;
  stale: boolean;
  // Connector sources (synced by Peon: GitHub Projects, Front).
  connector?: string;
  connector_name?: string;
  short?: string;
  title?: string | null;
  error?: string | null;
  rows?: number | null;
  waiting?: number;
  posting?: number;
  failed?: number;
};

/**
 * A dataset's sources (sources.json): where a table's data comes from, how old
 * it is, and ↻ to run its script again. Stale ones refresh once when shown.
 */
function Sources({
  call,
  sources,
  canRefresh,
  onDone,
}: {
  call: Call;
  sources: Source[];
  canRefresh: boolean;
  onDone: () => void;
}) {
  const [busy, setBusy] = useState<string | null>(null);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const tried = useRef(new Set<string>());

  const refresh = async (name: string) => {
    tried.current.add(name);
    setBusy(name);
    try {
      await call("refresh_source", { name }, 660000);
      setErrors(({ [name]: _, ...rest }) => rest);
      onDone();
    } catch (e: any) {
      setErrors((m) => ({ ...m, [name]: e.message }));
    } finally {
      setBusy(null);
    }
  };

  // One at a time (the server runs one per folder), and only once per source.
  useEffect(() => {
    if (!canRefresh || busy) return;
    // Synced services pull on their own every few minutes.
    const next = sources.find((s) => !s.connector && s.stale && !tried.current.has(s.name));
    if (next) refresh(next.name);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sources, canRefresh, busy]);

  return (
    <View style={st.sources}>
      {sources.map((s) => {
        const on = busy === s.name;
        return (
          <View key={s.name} style={st.source} testID={`source-${s.name}`}>
            {s.short ? (
              <SourceBadge short={s.short} />
            ) : (
              <View style={[st.sourceDot, s.stale && !on && { backgroundColor: color.needs }]} />
            )}
            <Text style={st.sourceText} numberOfLines={1}>
              {s.connector ? s.title || s.connector_name : s.name}{" "}
              <Text style={{ color: color.faint }}>→ {s.table}</Text>
            </Text>
            {s.waiting ? (
              <Text style={[st.sourceAge, { color: color.needs }]}>{s.waiting} waiting for you</Text>
            ) : s.posting ? (
              <Text style={[st.sourceAge, { color: color.accentText }]}>
                Posting {s.posting} change{s.posting > 1 ? "s" : ""}
              </Text>
            ) : null}
            <Text style={st.sourceAge}>
              {on
                ? s.connector
                  ? "Syncing…"
                  : "Refreshing…"
                : s.fetched_at
                  ? `${s.connector ? "Synced " : ""}${ago(s.fetched_at, true)}`
                  : s.connector
                    ? "not synced yet"
                    : "never fetched"}
            </Text>
            {canRefresh ? (
              <Tap
                onPress={() => refresh(s.name)}
                disabled={busy != null}
                haptic
                style={st.sourceKey}
                accessibilityLabel={`Refresh ${s.name}`}
              >
                <Text style={[st.sourceKeyText, on && { color: color.accentText }]}>↻</Text>
              </Tap>
            ) : null}
            {errors[s.name] || s.error ? (
              <Text style={st.sourceError} numberOfLines={2}>
                {errors[s.name] || s.error}
              </Text>
            ) : null}
          </View>
        );
      })}
    </View>
  );
}

/** Rows of a SQLite table (read on the server) or a CSV, view only. */
export function Table({ call, path, text }: { call: Call; path: string; text: string | null }) {
  const csv = path.toLowerCase().endsWith(".csv");
  const [table, setTable] = useState<string | null>(null);
  const [filter, setFilter] = useState("");
  const [sort, setSort] = useState<[string, 1 | -1] | null>(null);
  const { data, error, reload } = useLoad(async (): Promise<{
    tables: { name: string; rows: number | null }[];
    columns: string[];
    rows: any[];
    table: string | null;
    sources?: Source[];
    local?: string[];
    can_refresh?: boolean;
  }> => {
    if (!csv) return call("table", { path, table: table === OUTBOX ? null : table }, 60000);
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
  // Peon's own tables (_sources, _fields, _outbox) stay out of the tabs; the
  // Outbox gets its own tab when a service is synced here.
  const tables = data.tables.filter((t) => !t.name.startsWith("_") && !t.name.startsWith("sqlite_"));
  const synced = (data.sources ?? []).filter((x) => x.connector);
  const waiting = synced.reduce((n, x) => n + (x.waiting ?? 0) + (x.failed ?? 0), 0);
  const showOutbox = table === OUTBOX && synced.length > 0;
  const local = new Set(data.local ?? []);
  const columns = data.columns.filter((c) => !c.startsWith("_"));
  return (
    <ScrollView contentContainerStyle={st.table}>
      {data.sources?.length ? (
        <Sources call={call} sources={data.sources} canRefresh={!!data.can_refresh} onDone={reload} />
      ) : null}
      {tables.length > 1 || synced.length ? (
        <View style={st.seg}>
          {tables.map((t) => {
            const on = !showOutbox && t.name === data.table;
            return (
              <Tap key={t.name} onPress={() => setTable(t.name)} style={[st.segItem, on && st.segOn]}>
                <Text style={[st.segText, on && { color: color.textStrong }]}>
                  {t.name} <Text style={{ color: color.faint }}>{t.rows ?? ""}</Text>
                </Text>
              </Tap>
            );
          })}
          {synced.length ? (
            <Tap
              testID="outbox-tab"
              onPress={() => setTable(OUTBOX)}
              style={[st.segItem, showOutbox && st.segOn]}
            >
              <Text style={[st.segText, showOutbox && { color: color.textStrong }]}>
                Outbox <Text style={{ color: waiting ? color.needs : color.faint }}>{waiting || ""}</Text>
              </Text>
            </Tap>
          ) : null}
        </View>
      ) : null}
      {showOutbox ? <Outbox call={call} onChange={reload} /> : null}
      {showOutbox ? null : (
        <>
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
                {columns.map((c) => (
                  <Tap
                    key={c}
                    onPress={() => setSort(sort?.[0] === c ? (sort[1] === 1 ? [c, -1] : null) : [c, 1])}
                    style={[st.cell, { width: W }]}
                  >
                    <Text style={st.headText} numberOfLines={1}>
                      {c}
                      {local.has(c) ? <Text style={st.localMark}> · local</Text> : null}{" "}
                      {sort?.[0] === c ? (sort[1] === 1 ? "↑" : "↓") : ""}
                    </Text>
                  </Tap>
                ))}
              </View>
              {rows.map((r, i) => (
                <View key={i} style={[st.gridRow, r._pending ? { opacity: 0.55 } : null]}>
                  {columns.map((c) => (
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
          <Text style={st.faintSmall}>
            {synced.some((x) => x.table === data.table)
              ? "Synced. Change rows from a view or the chat; the Outbox shows what's posted back."
              : "View only. Ask in a chat to add or change rows."}
          </Text>
        </>
      )}
    </ScrollView>
  );
}

// The Outbox's place among the table tabs.
const OUTBOX = "\u0000outbox";

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

// Lines per Text: a few big Texts draw much faster than a row per line.
const CODE_CHUNK = 400;

export function Code({ text }: { text: string }) {
  const chunks = useMemo(() => {
    const lines = text.split("\n");
    const out: { first: number; numbers: string; body: string }[] = [];
    for (let i = 0; i < lines.length; i += CODE_CHUNK) {
      const part = lines.slice(i, i + CODE_CHUNK);
      out.push({
        first: i,
        numbers: part.map((_, j) => i + j + 1).join("\n"),
        body: part.join("\n"),
      });
    }
    return out;
  }, [text]);
  return (
    <ScrollView>
      <ScrollView horizontal contentContainerStyle={st.code}>
        <View>
          {chunks.map((c) => (
            <View key={c.first} style={st.codeLine}>
              <Text style={st.codeN}>{c.numbers}</Text>
              <Text style={st.codeText}>{c.body}</Text>
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
  canvas: { flex: 1, backgroundColor: "#0c0c0f" },
  pan: { flex: 1 },
  panInner: { flexGrow: 1, alignItems: "center", justifyContent: "center" },
  zoomBar: {
    position: "absolute",
    right: 12,
    bottom: 12,
    flexDirection: "row",
    alignItems: "center",
    padding: 3,
    borderRadius: 10,
    backgroundColor: color.card,
    borderWidth: 1,
    borderColor: color.border,
  },
  zoomKey: { width: 30, height: 28, alignItems: "center", justifyContent: "center", borderRadius: 7 },
  zoomKeyText: { fontSize: 17, lineHeight: 20, color: color.textSoft },
  zoomPct: { minWidth: 50, height: 28, alignItems: "center", justifyContent: "center", borderRadius: 7 },
  zoomPctText: { fontSize: 12, fontVariant: ["tabular-nums"], color: color.text },
  zoomSep: { width: 1, height: 16, marginHorizontal: 3, backgroundColor: color.divider },
  zoomFit: {
    height: 28,
    paddingHorizontal: 9,
    alignItems: "center",
    justifyContent: "center",
    borderRadius: 7,
  },
  zoomFitText: { fontSize: 12, color: color.textSoft },
  devices: { flexDirection: "row", alignItems: "center" },
  dots: { backgroundImage: "radial-gradient(#202027 1px, transparent 1px)", backgroundSize: "18px 18px" },
  sheet: {
    borderRadius: 12,
    borderWidth: 1,
    borderColor: "#2c2c34",
    overflow: "hidden",
    backgroundColor: "#fff",
  },
  table: { padding: 16, paddingBottom: 30, gap: 10 },
  sources: {
    borderWidth: 1,
    borderColor: color.border,
    borderRadius: 10,
    backgroundColor: color.card,
    paddingVertical: 4,
  },
  source: {
    flexDirection: "row",
    flexWrap: "wrap",
    alignItems: "center",
    gap: 10,
    paddingLeft: 12,
    paddingRight: 4,
    minHeight: 40,
  },
  sourceDot: { width: 7, height: 7, borderRadius: 4, backgroundColor: color.accent },
  sourceText: { flex: 1, fontSize: 14, color: color.text },
  sourceAge: { fontSize: 12, color: color.muted, fontVariant: ["tabular-nums"] },
  sourceKey: { width: 34, height: 34, alignItems: "center", justifyContent: "center", borderRadius: 8 },
  sourceKeyText: { fontSize: 18, lineHeight: 20, color: color.textSoft },
  sourceError: { width: "100%", paddingLeft: 17, paddingBottom: 8, fontSize: 12, color: color.red },
  localMark: { fontWeight: "400", color: color.faint },
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
    minWidth: 28,
    textAlign: "right",
    fontSize: 12,
    lineHeight: 20,
    fontFamily: font.mono,
    color: "#4a4a52",
  },
  codeText: { fontSize: 12, lineHeight: 20, fontFamily: font.mono, color: color.textSoft },
});
