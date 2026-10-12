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

// Web: the canvas is panned, not scrolled, so its scrollbars stay out of sight.
let scrollbarsHidden = false;
function hideScrollbars() {
  if (scrollbarsHidden || typeof document === "undefined") return;
  scrollbarsHidden = true;
  const tag = document.createElement("style");
  tag.textContent = ".peon-canvas::-webkit-scrollbar{width:0;height:0;display:none}";
  document.head.appendChild(tag);
}

/**
 * A design on a pannable canvas: the phone and the desktop layout side by side,
 * with no device chrome, so the design fills the pane. It opens fitted to the
 * pane's height.
 *
 * On the web it works like Figma: drag anywhere to pan, scroll (or a trackpad
 * pinch, or ctrl/⌘ + scroll) to zoom in on the point under the pointer, shift +
 * scroll to move sideways, and − / + / Fit (or +, −, shift+0, shift+1) to change
 * the zoom. On a phone the same canvas pans with a finger.
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
  // dragging (or shifting the wheel) swings between the phone and the desktop.
  const base = box.h > 0 ? Math.min(1.5, (box.h - pad * 2) / tallest) : 1;
  const scale = zoom ?? base;

  const vref = useRef<ScrollView>(null);
  const href = useRef<ScrollView>(null);
  const scaleRef = useRef(scale);
  useEffect(() => {
    scaleRef.current = scale;
  }, [scale]);
  const ready = box.w > 0;

  const node = (r: typeof vref) =>
    (r.current as unknown as { getScrollableNode?: () => HTMLElement })?.getScrollableNode?.();

  // The drawn content's size at a zoom (the sheets scaled, plus their padding).
  const contentAt = (z: number) => ({
    w: pad * 2 + devices.reduce((s, d) => s + SIZES[d].w * z, 0) + gap * (devices.length - 1),
    h: pad * 2 + tallest * z,
  });

  // Zoom to `z`, keeping the point under (clientX, clientY) still — the pointer
  // for a wheel or a pinch, the pane's centre for the − / + buttons.
  const zoomTo = (z: number, clientX?: number, clientY?: number) => {
    const next = Math.min(3, Math.max(0.1, z));
    const prev = scaleRef.current;
    scaleRef.current = next;
    const v = node(vref);
    const h = node(href);
    if (next === prev || !v || typeof v.getBoundingClientRect !== "function") {
      setZoom(next);
      return;
    }
    const rect = v.getBoundingClientRect();
    const px = (clientX ?? rect.left + rect.width / 2) - rect.left;
    const py = (clientY ?? rect.top + rect.height / 2) - rect.top;
    const vw = box.w || rect.width;
    const vh = box.h || rect.height;
    // Until the content overflows the pane it is centred; allow for that so the
    // anchored point doesn't drift at small zooms.
    const before = contentAt(prev);
    const after = contentAt(next);
    const offX = Math.max(0, (vw - before.w) / 2);
    const offY = Math.max(0, (vh - before.h) / 2);
    const offX2 = Math.max(0, (vw - after.w) / 2);
    const offY2 = Math.max(0, (vh - after.h) / 2);
    const cx = (px + (h?.scrollLeft ?? 0) - offX) / prev;
    const cy = (py + v.scrollTop - offY) / prev;
    setZoom(next);
    requestAnimationFrame(() => {
      if (h) h.scrollLeft = cx * next + offX2 - px;
      v.scrollTop = cy * next + offY2 - py;
    });
  };

  const fit = () => {
    setZoom(null);
    if (Platform.OS !== "web") return;
    requestAnimationFrame(() => {
      const v = node(vref);
      const h = node(href);
      if (h) h.scrollLeft = 0;
      if (v) v.scrollTop = 0;
    });
  };

  const step = (dir: 1 | -1) => {
    const cur = scaleRef.current;
    const next =
      dir > 0 ? ZOOMS.find((z) => z > cur + 0.001) : [...ZOOMS].reverse().find((z) => z < cur - 0.001);
    zoomTo(next ?? (dir > 0 ? ZOOMS[ZOOMS.length - 1] : ZOOMS[0]));
  };

  // Web: a Figma-style canvas. Drag pans it, the wheel (or a pinch) zooms it on
  // the point under the pointer, and +, −, shift+0 and shift+1 set the zoom.
  useEffect(() => {
    if (Platform.OS !== "web" || !ready) return;
    const v = node(vref);
    if (!v || typeof v.getBoundingClientRect !== "function") return;
    const h = node(href);
    // Panning, not scrolling: no scrollbars over the design.
    v.classList.add("peon-canvas");
    (v.style as any).scrollbarWidth = "none";
    if (h) {
      h.classList.add("peon-canvas");
      (h.style as any).scrollbarWidth = "none";
    }
    hideScrollbars();
    v.style.cursor = "grab";

    let drag: { id: number; x: number; y: number; top: number; left: number } | null = null;
    let over = false;

    const down = (e: PointerEvent) => {
      if (e.button !== 0 && e.button !== 1) return;
      drag = { id: e.pointerId, x: e.clientX, y: e.clientY, top: v.scrollTop, left: h?.scrollLeft ?? 0 };
      try {
        v.setPointerCapture(e.pointerId);
      } catch {
        // Not capturable; the drag still works while the pointer stays inside.
      }
      v.style.cursor = "grabbing";
      v.style.userSelect = "none";
      e.preventDefault();
    };
    const move = (e: PointerEvent) => {
      if (!drag || e.pointerId !== drag.id) return;
      v.scrollTop = drag.top - (e.clientY - drag.y);
      if (h) h.scrollLeft = drag.left - (e.clientX - drag.x);
      e.preventDefault();
    };
    const up = (e: PointerEvent) => {
      if (!drag || e.pointerId !== drag.id) return;
      drag = null;
      try {
        v.releasePointerCapture(e.pointerId);
      } catch {
        // It was never captured.
      }
      v.style.cursor = over ? "grab" : "";
      v.style.userSelect = "";
    };
    const wheel = (e: WheelEvent) => {
      // A trackpad's sideways swipe, or shift + the wheel, moves the canvas.
      if (e.shiftKey || Math.abs(e.deltaX) > Math.abs(e.deltaY) + 0.5) {
        e.preventDefault();
        if (h) h.scrollLeft += e.deltaX || e.deltaY;
        else v.scrollTop += e.deltaY;
        return;
      }
      // Otherwise zoom, on the point under the pointer. A pinch arrives as
      // ctrl + wheel and steps faster than the wheel does.
      e.preventDefault();
      const lines = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? 100 : 1;
      const k = e.ctrlKey || e.metaKey ? 0.02 : 0.0018;
      zoomTo(scaleRef.current * Math.exp(-e.deltaY * lines * k), e.clientX, e.clientY);
    };
    const enter = () => {
      over = true;
      if (!drag) v.style.cursor = "grab";
    };
    const leave = () => {
      over = false;
      if (!drag) v.style.cursor = "";
    };
    // Figma's zoom keys, while the pointer is over the canvas.
    const key = (e: KeyboardEvent) => {
      if (!over || e.altKey) return;
      const t = e.target as HTMLElement | null;
      if (t && (/^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName) || t.isContentEditable)) return;
      const mod = e.metaKey || e.ctrlKey;
      const zero = e.code === "Digit0" || e.code === "Numpad0" || e.key === "0";
      const one = e.code === "Digit1" || e.code === "Numpad1" || e.key === "1";
      if (zero && (mod || e.shiftKey)) zoomTo(1);
      else if (one && (mod || e.shiftKey)) fit();
      else if ((e.key === "+" || e.key === "=" || e.code === "NumpadAdd") && (mod || e.shiftKey))
        zoomTo(scaleRef.current * 1.25);
      else if ((e.key === "-" || e.key === "_" || e.code === "NumpadSubtract") && (mod || e.shiftKey))
        zoomTo(scaleRef.current / 1.25);
      else return;
      e.preventDefault();
    };

    v.addEventListener("pointerdown", down);
    v.addEventListener("pointermove", move);
    v.addEventListener("pointerup", up);
    v.addEventListener("pointercancel", up);
    v.addEventListener("wheel", wheel, { passive: false });
    v.addEventListener("pointerenter", enter);
    v.addEventListener("pointerleave", leave);
    window.addEventListener("keydown", key);
    return () => {
      v.removeEventListener("pointerdown", down);
      v.removeEventListener("pointermove", move);
      v.removeEventListener("pointerup", up);
      v.removeEventListener("pointercancel", up);
      v.removeEventListener("wheel", wheel);
      v.removeEventListener("pointerenter", enter);
      v.removeEventListener("pointerleave", leave);
      window.removeEventListener("keydown", key);
    };
    // Re-subscribes only when the pane resizes; the handlers read the zoom from
    // `scaleRef`, so a burst of wheel events never falls behind.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ready, box.w, box.h]);

  return (
    <View
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
                  {/* A preview: the cover takes drags and scrolls for the canvas,
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
            onPress={() => (zoom === 1 ? fit() : zoomTo(1))}
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
            onPress={fit}
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
