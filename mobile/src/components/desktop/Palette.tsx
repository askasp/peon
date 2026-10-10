import { useEffect, useMemo, useRef, useState } from "react";
import { Pressable, ScrollView, StyleSheet, Text, TextInput, View } from "react-native";
import { router } from "expo-router";
import { currentPayload, getCurrent } from "@/lib/current";
import { notePaletteOpen, setHelp, sidebarItems, toast, toggleZoom } from "@/lib/keys";
import { closePalette, usePalette, type PaletteMode } from "@/lib/palette";
import { ask, signOut, usePeon } from "@/lib/peon";
import { setVoiceSettings, useVoiceSettings } from "@/lib/voice";
import { color, font } from "@/lib/theme";
import type { ComposeResult } from "@/lib/types";

export type Item = {
  key: string;
  group: string;
  label: string;
  detail?: string;
  run: () => void | Promise<void>;
};

const go = (href: string) => router.navigate(href as any);

async function newSessionIn(projectId: number) {
  try {
    const { session_id } = await ask<{ session_id: string }>("new_session", { project_id: projectId }, 60000);
    go(`/session/${session_id}`);
  } catch (e: any) {
    toast(e.message);
  }
}

// Anything the palette doesn't list goes to the composer.
async function compose(text: string) {
  try {
    const r = await ask<{ plan?: { summary: string | null }; result?: ComposeResult }>(
      "compose:submit",
      { text, current: currentPayload() },
      60000,
    );
    if (r.result?.kind === "navigate") go(`/session/${r.result.session_id}`);
    else if (r.result?.kind === "answer") toast(r.result.text);
    else if (r.result?.kind === "done") toast(r.result.message);
    else if (r.plan) toast(`${r.plan.summary ?? "Needs confirming"}: use the composer to confirm.`);
  } catch (e: any) {
    toast(e.message);
  }
}

/** What the palette (and the top bar's "> commands") lists for `mode`. */
export function usePaletteItems(mode: PaletteMode | null): Item[] {
  const projects = usePeon((s) => s.projects);
  const running = usePeon((s) => s.running);
  const user = usePeon((s) => s.user);
  const voice = useVoiceSettings();
  return useMemo(() => {
    if (!mode) return [];
    const places = sidebarItems(projects).map(({ project, href }, i) => ({
      key: `place-${project.id}`,
      group: "Go to",
      label: project.name,
      detail: i < 9 ? `${i + 1} · ${project.kind}` : project.kind,
      run: () => go(href),
    }));
    if (mode === "new")
      return projects
        .filter((p) => p.kind !== "system")
        .map((p) => ({
          key: `new-${p.id}`,
          group: "New session in",
          label: p.name,
          detail: p.kind,
          run: () => newSessionIn(p.id),
        }));

    const sessions = running.map((r) => ({
      key: `run-${r.id}`,
      group: "Running",
      label: r.title,
      detail: r.status === "waiting" ? "needs you" : r.project.name,
      run: () => go(`/session/${r.id}`),
    }));
    const pages = [
      { key: "inbox", group: "Go to", label: "Inbox", run: () => go("/") },
      { key: "schedules", group: "Go to", label: "Schedules", run: () => go("/schedules") },
      { key: "settings", group: "Go to", label: "Settings", run: () => go("/settings") },
      ...(user?.admin
        ? [
            { key: "connectors", group: "Go to", label: "Connectors", run: () => go("/connectors") },
            { key: "models", group: "Go to", label: "Models", run: () => go("/models") },
            { key: "users", group: "Go to", label: "Users", run: () => go("/users") },
          ]
        : []),
    ];
    if (mode === "switch") return [...places, ...sessions, ...pages];

    const here = getCurrent().projectId;
    const hereName = projects.find((p) => p.id === here)?.name;
    const commands: Item[] = [
      ...(here != null
        ? [
            {
              key: "new-here",
              group: "Do",
              label: `New session in ${hereName}`,
              run: () => newSessionIn(here),
            },
          ]
        : []),
      ...projects
        .filter((p) => p.kind !== "system" && p.id !== here)
        .map((p) => ({
          key: `new-${p.id}`,
          group: "Do",
          label: `New session in ${p.name}`,
          run: () => newSessionIn(p.id),
        })),
      ...projects
        .filter((p) => p.kind === "routine")
        .map((p) => ({
          key: `run-${p.id}`,
          group: "Do",
          label: `Run ${p.name}`,
          detail: p.schedule ?? "routine",
          run: async () => {
            try {
              const { session_id } = await ask<{ session_id: string }>(
                "run_routine",
                { project_id: p.id },
                60000,
              );
              go(`/session/${session_id}`);
            } catch (e: any) {
              toast(e.message);
            }
          },
        })),
      { key: "new-project", group: "Do", label: "New project", run: () => go("/new") },
      {
        key: "voice",
        group: "Do",
        label: voice.reply ? "Turn spoken replies off" : "Turn spoken replies on",
        run: () => setVoiceSettings({ reply: !voice.reply }),
      },
      { key: "zoom", group: "Do", label: "Toggle sidebar", detail: "mod+\\", run: toggleZoom },
      { key: "help", group: "Do", label: "Keyboard shortcuts", detail: "?", run: () => setHelp(true) },
      { key: "logout", group: "Do", label: "Log out", run: signOut },
    ];
    return [...places, ...sessions, ...pages, ...commands];
  }, [mode, projects, running, user, voice.reply]);
}

// ^B w / ^B c (and mod+K where there is no top bar): a modal list to jump or start in.
// Typing filters; Enter runs the first match.
export function Palette() {
  const mode = usePalette();
  const items = usePaletteItems(mode);
  const [query, setQuery] = useState("");
  const [index, setIndex] = useState(0);
  const input = useRef<TextInput>(null);

  useEffect(() => {
    notePaletteOpen(mode != null);
    if (mode) setTimeout(() => input.current?.focus(), 30);
  }, [mode]);

  const q = query.trim().toLowerCase();
  const shown = q
    ? items.filter((i) => `${i.label} ${i.detail ?? ""} ${i.group}`.toLowerCase().includes(q))
    : items;
  const list: Item[] =
    q && mode === "all"
      ? [
          ...shown,
          {
            key: "compose",
            group: "Start",
            label: `Start: ${query.trim()}`,
            detail: "through the composer",
            run: () => compose(query.trim()),
          },
        ]
      : shown;

  function close() {
    setQuery("");
    setIndex(0);
    closePalette();
  }

  function pick(item: Item | undefined) {
    if (!item) return;
    close();
    item.run();
  }

  if (!mode) return null;

  // A group's name shows above its first item.
  const rows = list.map((item, i) => ({
    item,
    header: i === 0 || list[i - 1].group !== item.group ? item.group : null,
  }));

  return (
    <View style={st.backdrop}>
      <Pressable style={StyleSheet.absoluteFill} onPress={close} />
      <View style={st.panel} testID="palette">
        <TextInput
          ref={input}
          // Focus on mount, so keys typed right after mod+K land here.
          autoFocus
          value={query}
          onChangeText={(v) => {
            setQuery(v);
            setIndex(0);
          }}
          placeholder={
            mode === "new" ? "New session in…" : mode === "switch" ? "Switch to…" : "Search or run a command"
          }
          placeholderTextColor={color.faint}
          style={st.input}
          onKeyPress={(e: any) => {
            const k = e.nativeEvent.key;
            if (k === "ArrowDown" || k === "ArrowUp") {
              e.preventDefault?.();
              setIndex((i) => (i + (k === "ArrowDown" ? 1 : list.length - 1)) % Math.max(list.length, 1));
            } else if (k === "Enter") {
              e.preventDefault?.();
              pick(list[index]);
            } else if (k === "Escape") {
              e.preventDefault?.();
              close();
            }
          }}
        />
        <ScrollView style={{ maxHeight: 420 }} keyboardShouldPersistTaps="handled">
          {rows.map(({ item, header }, i) => {
            return (
              <View key={item.key}>
                {header ? <Text style={st.group}>{header}</Text> : null}
                <Pressable
                  onPress={() => pick(item)}
                  onHoverIn={() => setIndex(i)}
                  style={[st.item, i === index && st.itemOn]}
                >
                  <Text style={st.label} numberOfLines={1}>
                    {item.label}
                  </Text>
                  {item.detail ? <Text style={st.detail}>{item.detail}</Text> : null}
                </Pressable>
              </View>
            );
          })}
          {list.length === 0 ? <Text style={[st.detail, { padding: 14 }]}>Nothing matches.</Text> : null}
        </ScrollView>
      </View>
    </View>
  );
}

const st = StyleSheet.create({
  backdrop: {
    position: "absolute",
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    backgroundColor: "rgba(5,5,7,0.55)",
    alignItems: "center",
    paddingTop: 90,
    zIndex: 100,
  },
  panel: {
    width: 620,
    maxWidth: "92%",
    borderRadius: 14,
    borderWidth: 1,
    borderColor: color.border,
    backgroundColor: color.card,
    overflow: "hidden",
    shadowColor: "#000",
    shadowOpacity: 0.5,
    shadowRadius: 30,
    shadowOffset: { width: 0, height: 16 },
  },
  input: {
    height: 52,
    paddingHorizontal: 16,
    fontSize: 16,
    color: color.text,
    borderBottomWidth: 1,
    borderBottomColor: color.divider,
    outlineStyle: "none",
  } as any,
  group: {
    fontSize: 11,
    color: color.faint,
    paddingHorizontal: 16,
    paddingTop: 10,
    paddingBottom: 4,
    textTransform: "uppercase",
    letterSpacing: 0.6,
  },
  item: { flexDirection: "row", alignItems: "center", gap: 10, paddingHorizontal: 16, paddingVertical: 9 },
  itemOn: { backgroundColor: color.raised },
  label: { flex: 1, fontSize: 14, color: color.text },
  detail: { fontSize: 12, color: color.muted, fontFamily: font.mono },
});
