import { useEffect, useState, type RefObject } from "react";
import {
  Pressable,
  StyleSheet,
  Text,
  View,
  type StyleProp,
  type TextInput,
  type ViewStyle,
} from "react-native";
import { color, font } from "@/lib/theme";
import type { SessionOptions } from "@/lib/types";

export type Completion = {
  key: string;
  label: string;
  /** A procedure's inputs, after its name ("name amount"). */
  hint?: string | null;
  detail?: string | null;
  insert: string;
};

// What the cursor is completing: "/name" at the start, or the "@path" being typed.
function completing(draft: string): { kind: "slash" | "file"; query: string } | null {
  const slash = /^\/([\w.-]*)$/.exec(draft);
  if (slash) return { kind: "slash", query: slash[1] };
  const at = /(^|\s)@([^\s]*)$/.exec(draft);
  if (at) return { kind: "file", query: at[2] };
  return null;
}

/**
 * `/` completes from a folder's skills and commands, `@` from its files (when
 * `findFiles` is given). Arrows move through the list, Tab or Enter completes.
 */
export function useCompletions(o: {
  draft: string;
  setDraft: (text: string) => void;
  slash: SessionOptions["slash"] | null | undefined;
  findFiles?: (query: string) => Promise<{ items: { path: string; type?: string }[] }>;
  input: RefObject<TextInput | null>;
  /** No list while this is true (voice typing). */
  off?: boolean;
}) {
  const [found, setFound] = useState<Completion[]>([]);
  const [pick, setPick] = useState(0);
  const what = o.off ? null : completing(o.draft);

  const slash: Completion[] =
    what?.kind === "slash"
      ? (o.slash ?? [])
          .filter((i) => i.name.toLowerCase().startsWith(what.query.toLowerCase()))
          .slice(0, 8)
          .map((i) => ({
            key: i.name,
            label: `/${i.name}`,
            hint: i.inputs?.length ? i.inputs.join(" ") : null,
            detail: i.description || (i.kind === "procedure" ? null : i.kind),
            insert: `/${i.name} `,
          }))
      : [];
  const fileQuery = what?.kind === "file" && o.findFiles ? what.query : null;
  useEffect(() => {
    if (fileQuery == null || !o.findFiles) return;
    const t = setTimeout(() => {
      o.findFiles!(fileQuery)
        .then((r) =>
          setFound(
            r.items.slice(0, 8).map((i) => ({
              key: i.path,
              label: i.path,
              detail: i.type === "directory" ? "folder" : null,
              insert: `@${i.path}${i.type === "directory" ? "/" : " "}`,
            })),
          ),
        )
        .catch(() => setFound([]));
    }, 150);
    return () => clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [fileQuery]);
  const items = what?.kind === "slash" ? slash : fileQuery != null ? found : [];

  function complete(c: Completion) {
    o.setDraft(what?.kind === "file" ? o.draft.replace(/@[^\s]*$/, c.insert) : c.insert);
    setPick(0);
    o.input.current?.focus();
  }

  /** For a TextInput's onKeyPress: true when the key moved or completed. */
  function onKey(e: any): boolean {
    const k = e.nativeEvent.key;
    if (items.length && (k === "ArrowDown" || k === "ArrowUp")) {
      e.preventDefault?.();
      setPick((i) => (i + (k === "ArrowDown" ? 1 : items.length - 1)) % items.length);
      return true;
    }
    if (items.length && (k === "Tab" || (k === "Enter" && !e.nativeEvent.shiftKey))) {
      e.preventDefault?.();
      complete(items[pick] ?? items[0]);
      return true;
    }
    return false;
  }

  return { items, pick, setPick, complete, onKey };
}

/** The list over (or under) a text box; `style` places it. */
export function Completions({
  items,
  pick,
  onPick,
  style,
}: {
  items: Completion[];
  pick: number;
  onPick: (c: Completion) => void;
  style?: StyleProp<ViewStyle>;
}) {
  if (!items.length) return null;
  return (
    <View style={[st.popover, style]} testID="completions">
      {items.map((c, i) => (
        <Pressable
          key={c.key}
          onPress={() => onPick(c)}
          style={(s: any) => [st.option, (i === pick || s.hovered) && { backgroundColor: color.raised }]}
        >
          <Text style={st.optionLabel} numberOfLines={1}>
            {c.label}
            {c.hint ? <Text style={st.optionHint}> {c.hint}</Text> : null}
          </Text>
          {c.detail ? (
            <Text style={st.optionDetail} numberOfLines={1}>
              {c.detail}
            </Text>
          ) : null}
        </Pressable>
      ))}
    </View>
  );
}

const st = StyleSheet.create({
  popover: {
    position: "absolute",
    borderRadius: 12,
    borderWidth: 1,
    borderColor: color.border,
    backgroundColor: color.card,
    padding: 4,
    zIndex: 20,
  },
  option: {
    flexDirection: "row",
    gap: 10,
    alignItems: "center",
    paddingHorizontal: 10,
    paddingVertical: 8,
    borderRadius: 8,
  },
  optionLabel: { fontSize: 13.5, color: color.text, fontFamily: font.mono, flexShrink: 1 },
  optionHint: { fontSize: 12, color: color.faint },
  optionDetail: { fontSize: 12, color: color.muted, flex: 1 },
});
