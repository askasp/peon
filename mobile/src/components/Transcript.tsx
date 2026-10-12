import { useState } from "react";
import { Image, Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { Markdown } from "./Markdown";
import { viewFor, viewInfo, type ViewKind } from "@/lib/folders";

import { Icon } from "./Icon";
import { Tap } from "./ui";
import { color, font } from "@/lib/theme";
import type { Message } from "@/lib/types";

const opensAs: Record<ViewKind, string> = {
  doc: "Markdown · opens as a document",
  canvas: "HTML · opens in the canvas",
  app: "HTML · opens as an app",
  table: "Data · opens as a table",
  image: "Image",
  code: "Code",
  diff: "Diff",
};

// The session's messages: your messages as bubbles, replies as text, the
// model's thinking folded away, and tool calls folded into one "Ran N steps"
// row between them that opens to each call's input and output.

/** A pasted image: inline (`uri`), or too big to come along and loaded on tap. */
export type Img = { uri: string | null; messageId: string; index: number };

export type Tool = { name: string; label: string; status?: string; input: string; output: string };

export type Block =
  | { kind: "user"; key: string; text: string; skills: string[]; images: Img[] }
  | { kind: "text"; key: string; text: string; streaming: boolean }
  | { kind: "thinking"; key: string; text: string }
  | { kind: "steps"; key: string; tools: Tool[]; from?: number; to?: number }
  | { kind: "shell"; key: string; command: string; output: string }
  | { kind: "note"; key: string; text: string; tint?: string }
  /** The agent summarised everything above to free up context (`messages` of them). */
  | { kind: "compaction"; key: string; auto: boolean; summary: string; time?: number; messages: number }
  /** A file the agent wrote or edited, once per message. */
  | { kind: "file"; key: string; path: string; verb: "Wrote" | "Edited" };

const base = (p?: string) => (p ? p.split("/").pop() : "");

/** A tool call in a few words, like the web: "Read sessions.ex", "Shell `ls -la`", "front · get_conversation". */
export function shortTool(name: string, input: any): string {
  const i = input && typeof input === "object" ? input : {};
  switch (name) {
    case "read":
      return `Read ${base(i.path ?? i.filePath)}`;
    case "shell":
    case "bash":
      return `Shell \`${String(i.command ?? "").slice(0, 40)}\``;
    case "edit":
    case "write":
    case "apply_patch":
    case "patch":
      return `Edit ${base(i.path ?? i.filePath)}`;
    case "grep":
      return `Grep “${i.pattern ?? ""}”`;
    case "glob":
      return `Glob ${i.pattern ?? ""}`;
    case "webfetch":
      return `Fetch ${i.url ?? ""}`;
    case "execute": {
      const calls = [...String(i.code ?? "").matchAll(/tools\.(\w+)\.(\w+)/g)].map((m) => m[2]);
      return calls.length ? [...new Set(calls)].join(", ") : "Run code";
    }
    default:
      return name.startsWith("gateway_") ? name.slice(8).replace("_", " · ") : name;
  }
}

// What a call returned (or its error), as text; long output is cut like on the web.
function toolOutput(state: any): string {
  if (!state) return "";
  if (state.error) return String(state.error.message ?? JSON.stringify(state.error)).slice(0, 8000);
  const content = (state.content ?? [])
    .map((c: any) =>
      c.type === "text" ? c.text : c.type === "file" ? `[file ${c.name ?? c.uri}]` : JSON.stringify(c),
    )
    .join("\n");
  return String(content).slice(0, 8000);
}

export function toBlocks(items: Message[]): Block[] {
  const out: Block[] = [];
  const steps = (m: Message): Block & { kind: "steps" } => {
    const last = out[out.length - 1];
    if (last?.kind === "steps") return last;
    const b: Block & { kind: "steps" } = {
      kind: "steps",
      key: `steps-${m.id}-${out.length}`,
      tools: [],
      from: m.time?.created,
    };
    out.push(b);
    return b;
  };

  for (const m of items) {
    switch (m.type) {
      case "user":
        out.push({
          kind: "user",
          key: m.id,
          text: m.text ?? "",
          skills: (m.skills ?? []).map((s) => s.name),
          images: (m.files ?? []).flatMap((f, index) =>
            f.mime?.startsWith("image/")
              ? [{ uri: f.data ? `data:${f.mime};base64,${f.data}` : null, messageId: m.id, index }]
              : [],
          ),
        });
        break;
      case "assistant": {
        const files = new Map<string, "Wrote" | "Edited">();
        (m.content ?? []).forEach((p: any, i) => {
          if (p.type === "reasoning" && p.text?.trim()) {
            out.push({ kind: "thinking", key: `${m.id}-r${i}`, text: p.text });
          } else if (p.type === "text" && p.text.trim()) {
            out.push({ kind: "text", key: `${m.id}-${i}`, text: p.text, streaming: !!p.streaming });
          } else if (p.type === "tool") {
            const b = steps(m);
            const input = p.state?.input;
            b.tools.push({
              name: p.name,
              label: shortTool(p.name, input),
              status: p.state?.status,
              input: typeof input === "string" ? input : JSON.stringify(input ?? {}),
              output: toolOutput(p.state),
            });
            b.to = m.time?.completed ?? b.to;
            const path = input?.filePath ?? input?.path;
            if (p.state?.status === "completed" && typeof path === "string" && /^(write|edit)$/.test(p.name))
              files.set(path, files.get(path) ?? (p.name === "write" ? "Wrote" : "Edited"));
          }
        });
        for (const [path, verb] of files) out.push({ kind: "file", key: `${m.id}-f-${path}`, path, verb });
        if (m.error?.message)
          out.push({ kind: "note", key: `${m.id}-err`, text: m.error.message, tint: color.red });
        break;
      }
      case "shell":
        out.push({
          kind: "shell",
          key: m.id,
          command: m.command ?? "",
          output: String((m as any).output?.output ?? ""),
        });
        break;
      case "model-switched":
        out.push({ kind: "note", key: m.id, text: `→ model ${m.model?.id ?? m.model ?? ""}` });
        break;
      case "agent-switched":
        out.push({ kind: "note", key: m.id, text: `→ agent ${m.agent ?? ""}` });
        break;
      case "location-switched":
        out.push({ kind: "note", key: m.id, text: "→ moved" });
        break;
      case "skill":
        out.push({ kind: "note", key: m.id, text: `ran skill /${m.name ?? ""}` });
        break;
      case "compaction":
        out.push({
          kind: "compaction",
          key: m.id,
          auto: m.reason !== "manual",
          summary: m.summary ?? "",
          time: m.time?.created,
          messages: out.filter((b) => b.kind === "user" || b.kind === "text").length,
        });
        break;
      case "idle":
        if (m.outcome === "failed")
          out.push({ kind: "note", key: m.id, text: "That failed.", tint: color.red });
        else if (m.outcome === "interrupted") out.push({ kind: "note", key: m.id, text: "Stopped." });
        else if (m.outcome && m.outcome !== "succeeded")
          out.push({ kind: "note", key: m.id, text: `Ended: ${m.outcome}.` });
        break;
    }
  }
  return out;
}

function span(from?: number, to?: number) {
  if (!from || !to || to < from) return "";
  const s = Math.round((to - from) / 1000);
  return s < 60 ? ` · ${s}s` : ` · ${Math.floor(s / 60)}m ${String(s % 60).padStart(2, "0")}s`;
}

const statusTint = (s?: string) =>
  s === "completed" ? color.teal : s === "error" ? color.red : color.accentText;

export function BlockView({
  block,
  onImage,
  loadImage,
  onFile,
  viewing,
  rel = (p) => p,
}: {
  block: Block;
  /** Opens a file card's file; `viewing` is the one open now (as `rel` shows it). */
  onFile?: (path: string) => void;
  viewing?: string | null;
  /** A file's path as shown (relative to the folder). */
  rel?: (path: string) => string;
  onImage?: (uri: string) => void;
  /** Fetches a big image's data URI (see `Img`). */
  loadImage?: (img: Img) => Promise<string>;
}) {
  const [open, setOpen] = useState(false);
  const [loading, setLoading] = useState<number | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);

  async function openBig(img: Img) {
    if (!loadImage) return;
    setLoading(img.index);
    setLoadError(null);
    try {
      onImage?.(await loadImage(img));
    } catch (e: any) {
      setLoadError(e.message);
    }
    setLoading(null);
  }

  switch (block.kind) {
    case "file": {
      const on = viewing != null && rel(block.path) === viewing;
      const kind = viewFor(rel(block.path));
      return (
        <Tap onPress={() => onFile?.(block.path)} style={[st.fileCard, on && st.fileCardOn]} kb="row">
          <View style={[st.fileGlyph, on && { backgroundColor: color.accentWash }]}>
            <Text style={[st.fileGlyphText, on && { color: color.accentText }]}>{viewInfo[kind][1]}</Text>
          </View>
          <View style={{ flex: 1, gap: 2 }}>
            <Text style={st.fileText} numberOfLines={1}>
              {block.verb} {rel(block.path)}
            </Text>
            <Text style={st.fileSub} numberOfLines={1}>
              {opensAs[kind]}
            </Text>
          </View>
          {on ? <Text style={st.fileOn}>In view</Text> : <Text style={st.fileChev}>›</Text>}
        </Tap>
      );
    }
    case "user":
      return (
        <View style={st.userWrap}>
          <View style={st.user}>
            {block.skills.length ? <Text style={st.skill}>/{block.skills.join(" /")}</Text> : null}
            {block.text ? (
              <Text style={st.userText} selectable>
                {block.text}
              </Text>
            ) : null}
            {block.images.length ? (
              <View style={st.images}>
                {block.images.map((img) =>
                  img.uri ? (
                    <Pressable key={img.index} onPress={() => onImage?.(img.uri!)}>
                      <Image source={{ uri: img.uri }} style={st.image} resizeMode="cover" />
                    </Pressable>
                  ) : (
                    <Tap key={img.index} style={[st.image, st.bigImage]} onPress={() => openBig(img)}>
                      <Text style={st.files}>
                        {loading === img.index ? "Loading…" : "Large image\nTap to view"}
                      </Text>
                    </Tap>
                  ),
                )}
              </View>
            ) : null}
            {loadError ? <Text style={[st.files, { color: color.red }]}>{loadError}</Text> : null}
          </View>
        </View>
      );
    case "text":
      return <Markdown text={block.text} streaming={block.streaming} />;
    case "thinking":
      return (
        <Tap onPress={() => setOpen(!open)} style={{ gap: 4 }}>
          <Text style={st.thinkingHead}>{open ? "⌄" : "›"} Thinking</Text>
          {open ? (
            <Text style={st.thinking} selectable>
              {block.text}
            </Text>
          ) : null}
        </Tap>
      );
    case "steps": {
      const failed = block.tools.some((t) => t.status === "error");
      const live = block.tools.some((t) => t.status === "running" || t.status === "pending" || !t.status);
      const names = [...new Set(block.tools.map((t) => t.label))].slice(0, 4).join(", ");
      return (
        <View style={st.steps}>
          <Tap onPress={() => setOpen(!open)} style={st.stepsHead}>
            <Text style={st.stepsText} numberOfLines={1}>
              {live ? "Running" : "Ran"} {block.tools.length} step{block.tools.length === 1 ? "" : "s"}
              {span(block.from, block.to)}
              {failed ? " · some failed" : ""} · {names}
            </Text>
            <Text style={st.stepsText}>{open ? "⌄" : "›"}</Text>
          </Tap>
          {open
            ? block.tools.map((t, i) => (
                <View key={i} style={st.tool}>
                  <View style={st.toolHead}>
                    <Text style={st.toolLabel} numberOfLines={1}>
                      {t.name} {t.input.slice(0, 200)}
                    </Text>
                    <Text style={[st.toolStatus, { color: statusTint(t.status) }]}>
                      {t.status ?? "running"}
                    </Text>
                  </View>
                  {t.output ? (
                    <ScrollView style={st.toolOut} nestedScrollEnabled>
                      <Text style={st.toolOutText} selectable>
                        {t.output}
                      </Text>
                    </ScrollView>
                  ) : null}
                </View>
              ))
            : null}
        </View>
      );
    }
    case "shell":
      return (
        <View style={st.tool}>
          <View style={st.toolHead}>
            <Text style={st.toolLabel} selectable>
              $ {block.command}
            </Text>
          </View>
          {block.output ? (
            <ScrollView style={st.toolOut} nestedScrollEnabled>
              <Text style={st.toolOutText} selectable>
                {block.output}
              </Text>
            </ScrollView>
          ) : null}
        </View>
      );
    case "note":
      return <Text style={[st.note, block.tint ? { color: block.tint } : null]}>{block.text}</Text>;
    case "compaction":
      return (
        <View style={st.compaction}>
          <View style={st.compactionHead}>
            <Icon name="compact" size={14} color={color.textDim} />
            <Text style={st.compactionTitle}>{block.auto ? "Compacted automatically" : "Compacted"}</Text>
            {block.time ? <Text style={st.compactionTime}>{clock(block.time)}</Text> : null}
            <View style={{ flex: 1 }} />
            {block.summary ? (
              <Tap onPress={() => setOpen(!open)} hitSlop={6}>
                <Text style={st.compactionLink}>{open ? "Hide summary" : "View summary"}</Text>
              </Tap>
            ) : null}
          </View>
          <Text style={st.compactionText}>
            The agent now works from a summary of the {block.messages} message
            {block.messages === 1 ? "" : "s"} above, plus the files and AGENTS.md.
          </Text>
          {open ? <Markdown text={block.summary} /> : null}
        </View>
      );
  }
}

const clock = (t: number) => new Date(t).toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" });

const st = StyleSheet.create({
  fileCard: {
    flexDirection: "row",
    alignItems: "center",
    gap: 10,
    paddingHorizontal: 12,
    paddingVertical: 10,
    borderRadius: 10,
    borderWidth: 1,
    borderColor: color.border,
    backgroundColor: color.card,
  },
  fileCardOn: { borderColor: color.accentBorder, backgroundColor: color.accentCard },
  fileGlyph: {
    width: 30,
    height: 30,
    borderRadius: 8,
    backgroundColor: color.divider,
    alignItems: "center",
    justifyContent: "center",
  },
  fileGlyphText: { fontSize: 13, color: color.textDim },
  fileText: { fontSize: 14, color: color.text },
  fileSub: { fontSize: 12, color: color.muted },
  fileChev: { fontSize: 18, color: "#5d5d66" },
  fileOn: { fontSize: 12, color: color.accentText },
  userWrap: { alignItems: "flex-end" },
  user: {
    maxWidth: "82%",
    paddingVertical: 10,
    paddingHorizontal: 14,
    borderRadius: 18,
    borderBottomRightRadius: 4,
    backgroundColor: color.raised,
    gap: 4,
  },
  userText: { fontSize: 15, lineHeight: 21, color: color.text },
  skill: { fontSize: 13, color: color.accentText, fontFamily: font.mono },
  files: { fontSize: 12, color: color.muted, textAlign: "center" },
  images: { flexDirection: "row", flexWrap: "wrap", gap: 6 },
  image: { width: 120, height: 90, borderRadius: 8, backgroundColor: color.field },
  bigImage: { alignItems: "center", justifyContent: "center", padding: 6 },
  thinkingHead: { fontSize: 12.5, color: color.faint },
  thinking: {
    fontSize: 12.5,
    lineHeight: 18,
    color: color.faint,
    paddingLeft: 10,
    borderLeftWidth: 1,
    borderLeftColor: color.divider,
  },
  steps: {
    borderRadius: 12,
    borderWidth: 1,
    borderColor: color.divider,
    paddingVertical: 10,
    paddingHorizontal: 12,
    gap: 8,
  },
  stepsHead: { flexDirection: "row", justifyContent: "space-between", gap: 8 },
  stepsText: { fontSize: 13, color: color.textDim, flexShrink: 1 },
  tool: {
    borderRadius: 10,
    borderWidth: 1,
    borderColor: color.border,
    backgroundColor: color.bgDeep,
    overflow: "hidden",
  },
  toolHead: {
    flexDirection: "row",
    gap: 8,
    paddingHorizontal: 10,
    paddingVertical: 6,
    borderBottomWidth: 1,
    borderBottomColor: color.divider,
  },
  toolLabel: { flex: 1, fontSize: 12, fontFamily: font.mono, color: color.textSoft },
  toolStatus: { fontSize: 12, fontFamily: font.mono },
  toolOut: { maxHeight: 256 },
  toolOutText: { fontSize: 11.5, lineHeight: 17, fontFamily: font.mono, color: color.muted, padding: 10 },
  note: { fontSize: 12, color: color.muted, textAlign: "center" },
  compaction: {
    gap: 6,
    paddingHorizontal: 14,
    paddingVertical: 12,
    marginVertical: 6,
    borderRadius: 12,
    borderWidth: 1,
    borderColor: color.raised,
    backgroundColor: "#17171b",
  },
  compactionHead: { flexDirection: "row", alignItems: "center", gap: 8 },
  compactionTitle: { fontSize: 13, fontWeight: "600", color: color.text },
  compactionTime: { fontSize: 13, color: color.faint },
  compactionLink: { fontSize: 12, color: color.accentText },
  compactionText: { fontSize: 12, lineHeight: 18, color: color.muted },
});
