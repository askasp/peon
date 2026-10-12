import { Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { usePathname } from "expo-router";
import { prefixLabel, setHelp, sidebarItems, useKb } from "@/lib/keys";
import { usePeon } from "@/lib/peon";
import { color, font } from "@/lib/theme";

// What the prefix can do next (the server's which-key groups).
const WHICH: [string, [string, string][]][] = [
  [
    "Navigate",
    [
      ["1–9", "Sidebar item"],
      ["a–z", "Lettered row, tab or box"],
      ["n p", "Next / previous ↻"],
      ["l", "Last place"],
      ["w", "Switch to…"],
      ["i", "Inbox"],
      ["g", "Go to…"],
    ],
  ],
  [
    "Act",
    [
      ["c", "New chat"],
      ["r", "Run procedure"],
      [",", "Rename session"],
    ],
  ],
  [
    "View",
    [
      ["[ ]", "Previous / next tab ↻"],
      ["z", "Zoom"],
      ["/", "Search"],
      [":", "Command"],
      ["?", "All shortcuts"],
    ],
  ],
];

function Kbd({ k }: { k: string }) {
  return <Text style={st.kbd}>{k}</Text>;
}

/** Which-key after the prefix, the full shortcut list, toasts, and the status line. */
export function KeyOverlays() {
  const kb = useKb();
  const keys = usePeon((s) => s.keys);
  const projects = usePeon((s) => s.projects);
  const path = usePathname();
  if (!keys) return null;
  const prefix = prefixLabel(keys.prefs.prefix);

  return (
    <>
      {kb.mode === "prefix"
        ? kb.hints.map((h) =>
            h.label.startsWith(kb.typed) ? (
              <View key={h.label} style={[st.badge, { left: h.x, top: h.y }]} pointerEvents="none">
                <Text style={st.badgeText}>
                  <Text style={{ opacity: 0.45 }}>{kb.typed}</Text>
                  {h.label.slice(kb.typed.length)}
                </Text>
              </View>
            ) : null,
          )
        : null}

      {kb.which && kb.mode === "prefix" ? (
        <View style={st.which} pointerEvents="none">
          {WHICH.map(([title, rows]) => (
            <View key={title} style={{ gap: 4, minWidth: 180 }}>
              <Text style={st.whichTitle}>{title}</Text>
              {rows.map(([k, label]) => (
                <View key={k} style={st.whichRow}>
                  <Kbd k={k} />
                  <Text style={st.whichLabel}>{label}</Text>
                </View>
              ))}
            </View>
          ))}
        </View>
      ) : null}

      {kb.mode === "g" ? (
        <View style={st.which} pointerEvents="none">
          <View style={{ gap: 4 }}>
            <Text style={st.whichTitle}>Go to</Text>
            {keys.globals.map((g) => (
              <View key={g.id} style={st.whichRow}>
                <Kbd k={g.key} />
                <Text style={st.whichLabel}>{g.name}</Text>
              </View>
            ))}
          </View>
        </View>
      ) : null}

      {kb.help ? (
        <View style={st.helpBackdrop}>
          <Pressable style={StyleSheet.absoluteFill} onPress={() => setHelp(false)} />
          <View style={st.help}>
            <Text style={st.helpTitle}>Keyboard shortcuts</Text>
            <ScrollView style={{ maxHeight: 560 }} contentContainerStyle={st.helpGrid}>
              {keys.help.map((section) => (
                <View key={section.title} style={st.helpSection}>
                  <Text style={st.whichTitle}>{section.title}</Text>
                  {section.rows.map((r) => (
                    <View key={r.label} style={st.whichRow}>
                      <View style={{ flexDirection: "row", gap: 3, minWidth: 110 }}>
                        {r.keys.map((k, i) => (
                          <Kbd key={i} k={k} />
                        ))}
                      </View>
                      <Text style={st.whichLabel}>{r.label}</Text>
                    </View>
                  ))}
                </View>
              ))}
            </ScrollView>
            <Text style={st.hint}>Change the keymap and session shortcuts in Settings. Esc closes.</Text>
          </View>
        </View>
      ) : null}

      {keys.prefs.keycast && kb.cast.length ? (
        <View style={st.cast} pointerEvents="none">
          {kb.cast.map((k, i) => (
            <Kbd key={i} k={k} />
          ))}
        </View>
      ) : null}

      {kb.toast ? (
        <View style={st.toast} pointerEvents="none">
          <Text style={st.toastText}>{kb.toast}</Text>
        </View>
      ) : null}

      {keys.prefs.status_line ? (
        <View style={st.status}>
          <Text style={[st.statusText, kb.mode ? st.armed : null]}>
            {kb.mode === "g"
              ? "g …"
              : kb.mode
                ? `${prefix} …`
                : keys.prefs.keymap === "tmux"
                  ? prefix
                  : "alt"}
          </Text>
          <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{ gap: 12 }}>
            {sidebarItems(projects)
              .slice(0, 9)
              .map(({ project, href }, i) => {
                const on = path === href || path.startsWith(`${href}/`);
                return (
                  <Text key={project.id} style={[st.statusText, on && { color: color.textStrong }]}>
                    {i + 1}:{project.name}
                    {on ? "*" : ""}
                  </Text>
                );
              })}
          </ScrollView>
          <Text style={st.statusText}>{keys.prefs.keymap === "tmux" ? `${prefix} ?` : "?"} shortcuts</Text>
        </View>
      ) : null}
    </>
  );
}

const st = StyleSheet.create({
  kbd: {
    fontSize: 11,
    fontFamily: font.mono,
    color: color.text,
    borderWidth: 1,
    borderColor: color.outline,
    borderRadius: 4,
    paddingHorizontal: 5,
    paddingVertical: 1,
    backgroundColor: color.raised,
  },
  which: {
    position: "absolute",
    bottom: 40,
    alignSelf: "center",
    left: "50%",
    transform: [{ translateX: -320 }],
    width: 640,
    flexDirection: "row",
    gap: 24,
    padding: 16,
    borderRadius: 12,
    borderWidth: 1,
    borderColor: color.border,
    backgroundColor: color.card,
    zIndex: 90,
  },
  badge: {
    position: "absolute",
    zIndex: 95,
    paddingHorizontal: 5,
    borderRadius: 4,
    backgroundColor: color.accent,
    shadowColor: "#000",
    shadowOpacity: 0.4,
    shadowRadius: 4,
  },
  badgeText: { fontSize: 11, fontWeight: "700", fontFamily: font.mono, color: color.accentInk },
  whichTitle: {
    fontSize: 11,
    color: color.faint,
    textTransform: "uppercase",
    letterSpacing: 0.6,
    marginBottom: 2,
  },
  whichRow: { flexDirection: "row", alignItems: "center", gap: 8 },
  whichLabel: { fontSize: 13, color: color.textSoft },
  helpBackdrop: {
    position: "absolute",
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    backgroundColor: "rgba(5,5,7,0.6)",
    alignItems: "center",
    justifyContent: "center",
    zIndex: 100,
  },
  help: {
    width: 860,
    maxWidth: "94%",
    padding: 20,
    gap: 12,
    borderRadius: 16,
    borderWidth: 1,
    borderColor: color.border,
    backgroundColor: color.card,
  },
  helpTitle: { fontSize: 18, fontWeight: "600", color: color.text },
  helpGrid: { flexDirection: "row", flexWrap: "wrap", gap: 24 },
  helpSection: { gap: 6, width: 380 },
  hint: { fontSize: 12, color: color.muted },
  cast: { position: "absolute", right: 16, bottom: 36, flexDirection: "row", gap: 4, zIndex: 110 },
  toast: {
    position: "absolute",
    bottom: 44,
    alignSelf: "center",
    left: 0,
    right: 0,
    alignItems: "center",
    zIndex: 110,
  },
  toastText: {
    fontSize: 13,
    color: color.text,
    backgroundColor: color.raised,
    borderRadius: 8,
    paddingHorizontal: 12,
    paddingVertical: 7,
    overflow: "hidden",
    maxWidth: 560,
  },
  status: {
    height: 24,
    flexDirection: "row",
    alignItems: "center",
    gap: 14,
    paddingHorizontal: 10,
    borderTopWidth: 1,
    borderTopColor: color.hairline,
    backgroundColor: color.bar,
  },
  statusText: { fontSize: 11, fontFamily: font.mono, color: color.faint },
  armed: { color: color.accentInk, backgroundColor: color.accent, paddingHorizontal: 4, borderRadius: 3 },
});
