import { useState } from "react";
import { StyleSheet, Text, View } from "react-native";
import * as Clipboard from "expo-clipboard";
import { Markdown } from "../Markdown";
import { shortTool } from "../Transcript";
import { Tap } from "../ui";
import { color } from "@/lib/theme";
import type { Message, Status } from "@/lib/types";

type Step = { label: string; count: number; state: "done" | "current" | "failed" | "pending" };

// A run's first turn: its prompt and the work up to the result.
function firstTurn(items: Message[]): Message[] {
  const users = items.map((m, i) => (m.type === "user" ? i : -1)).filter((i) => i >= 0);
  if (!users.length) return [];
  return items.slice(users[0], users[1] ?? items.length);
}

/** The run's result text: the last text it wrote in its first turn. */
export function runResult(items: Message[]): string {
  const texts = firstTurn(items)
    .filter((m) => m.type === "assistant")
    .flatMap((m) =>
      (m.content ?? []).filter((p: any) => p.type === "text" && p.text).map((p: any) => p.text as string),
    );
  return texts[texts.length - 1] ?? "";
}

// Progress like the web: tool calls grouped ("front · get_conversation ×6"), then writing the result.
function runSteps(items: Message[], result: string): Step[] {
  const tools = firstTurn(items)
    .flatMap((m) => m.content ?? [])
    .filter((p: any) => p.type === "tool") as any[];
  const steps: Step[] = [];
  for (const t of tools) {
    const label = shortTool(t.name, t.state?.input);
    const status = t.state?.status;
    const last = steps[steps.length - 1];
    const state: Step["state"] = status === "completed" ? "done" : status === "error" ? "failed" : "current";
    if (last && last.label === label) {
      last.count += 1;
      if (state === "current") last.state = "current";
      else if (last.state !== "current" && state === "done") last.state = "done";
    } else {
      steps.push({ label, count: 1, state });
    }
  }
  const busy = steps.some((s) => s.state === "current");
  steps.push({ label: "Write the result", count: 1, state: busy || !result ? "pending" : "current" });
  return steps;
}

const dot: Record<Step["state"], { char: string; tint: string }> = {
  done: { char: "✓", tint: color.teal },
  current: { char: "●", tint: color.accentText },
  failed: { char: "✕", tint: color.red },
  pending: { char: "○", tint: color.faint },
};

/** While a run works: its steps, a permission wait, and the result so far. */
export function RunProgress({ items, status }: { items: Message[]; status: Status }) {
  const result = runResult(items);
  const steps = runSteps(items, result);
  return (
    <View style={{ gap: 14 }}>
      <View style={{ gap: 2 }}>
        {steps.map((s, i) => (
          <View key={i} style={st.step}>
            <Text style={[st.dot, { color: dot[s.state].tint }]}>{dot[s.state].char}</Text>
            <Text style={[st.label, s.state === "pending" && { color: color.muted }]}>
              {s.label}
              {s.count > 1 ? <Text style={{ color: color.muted }}> ×{s.count}</Text> : null}
            </Text>
          </View>
        ))}
        {status === "waiting" ? (
          <View style={st.step}>
            <Text style={[st.dot, { color: color.cream }]}>○</Text>
            <Text style={[st.label, { color: color.cream }]}>Waiting for your permission below</Text>
          </View>
        ) : null}
      </View>
      {result ? (
        <View style={st.result}>
          <Text style={st.resultLabel}>Result so far</Text>
          <Markdown text={result} streaming />
        </View>
      ) : null}
    </View>
  );
}

/** "Copy" for a finished run's result. */
export function CopyResult({ items }: { items: Message[] }) {
  const [done, setDone] = useState(false);
  const result = runResult(items);
  if (!result) return null;
  return (
    <Tap
      onPress={async () => {
        await Clipboard.setStringAsync(result);
        setDone(true);
        setTimeout(() => setDone(false), 1500);
      }}
    >
      <Text style={{ color: color.accentText, fontSize: 13 }}>{done ? "Copied" : "Copy result"}</Text>
    </Tap>
  );
}

const st = StyleSheet.create({
  step: { flexDirection: "row", alignItems: "flex-start", gap: 10, paddingVertical: 5 },
  dot: { width: 16, fontSize: 13, textAlign: "center", marginTop: 1 },
  label: { flex: 1, fontSize: 14, color: color.text },
  result: { gap: 8, paddingTop: 14, borderTopWidth: 1, borderTopColor: color.hairline },
  resultLabel: { fontSize: 12.5, color: color.muted },
});
