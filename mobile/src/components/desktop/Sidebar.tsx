import { ReactNode, useRef, useState } from "react";
import { Modal, Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { router, usePathname } from "expo-router";
import { Icon } from "../Icon";
import { Dot, kbProps } from "../ui";
import { appPath, sidebarItems, useKb } from "@/lib/keys";
import { signOut, usePeon } from "@/lib/peon";
import { filters, folderHref, kindLabel, sortFolders, templates } from "@/lib/folders";
import { color, font, tileColors } from "@/lib/theme";
import type { Project } from "@/lib/types";

/** A sidebar row: highlights when hovered or current; `gkey` shows its key while a chord is armed. */
export function NavRow({
  label,
  href,
  active,
  left,
  right,
  gkey,
  testID,
}: {
  label: string;
  href: string;
  active: boolean;
  left?: ReactNode;
  right?: ReactNode;
  gkey?: string | null;
  testID?: string;
}) {
  return (
    <Pressable
      testID={testID}
      {...kbProps("item", active)}
      onPress={() => router.navigate(href as any)}
      style={(state: any) => [st.row, active ? st.rowActive : state.hovered ? st.rowHover : null]}
    >
      {left}
      <Text style={[st.rowLabel, active && { color: color.textStrong }]} numberOfLines={1}>
        {label}
      </Text>
      {right}
      {gkey ? <Text style={st.gkey}>{gkey}</Text> : null}
    </Pressable>
  );
}

/** A project's letter on its own tint. */
export function Letter({
  name,
  system = false,
  size = 22,
}: {
  name: string;
  system?: boolean;
  size?: number;
}) {
  const tint = tileColors(name, system);
  return (
    <View
      style={[st.letter, { width: size, height: size, borderRadius: size * 0.27, backgroundColor: tint.bg }]}
    >
      <Text style={[st.letterText, { color: tint.fg, fontSize: size * 0.48 }]}>
        {name.slice(0, 1).toUpperCase()}
      </Text>
    </View>
  );
}

/** The prefix + number that opens a sidebar item, in place of its letter while the prefix is armed. */
function Num({ n }: { n: number }) {
  return (
    <View style={[st.letter, st.num]}>
      <Text style={st.numText}>{n}</Text>
    </View>
  );
}

// React Native has a `window` but no `location`, so check for it.
const host = (typeof window !== "undefined" && window.location?.hostname) || "connected";

/** The templates a new Project can start from, floating next to the sidebar. */
export function TemplateMenu({ at, onClose }: { at: { x: number; y: number } | null; onClose: () => void }) {
  return (
    <Modal transparent visible={at != null} animationType="fade" onRequestClose={onClose}>
      <Pressable style={StyleSheet.absoluteFill} onPress={onClose} />
      {at ? (
        <View style={[st.menu, { left: at.x, top: Math.max(12, at.y - 140) }]}>
          <Text style={st.menuTitle}>New Project</Text>
          {templates.map((t) => (
            <Pressable
              key={t.kind}
              testID={`template-${t.kind}`}
              onPress={() => {
                onClose();
                router.navigate({ pathname: "/new-folder", params: { kind: t.kind } } as any);
              }}
              style={(s: any) => [st.menuRow, s.hovered && { backgroundColor: color.raised }]}
            >
              <View style={{ flex: 1, gap: 2 }}>
                <Text style={st.menuLabel}>{t.label}</Text>
                <Text style={st.menuDetail}>{t.detail}</Text>
              </View>
              <Text style={st.menuOpens}>opens {t.opens}</Text>
            </Pressable>
          ))}
        </View>
      ) : null}
    </Modal>
  );
}

// Projects (Home first, filtered by template), then the app's places.
export function Sidebar() {
  const path = usePathname();
  const projects = usePeon((s) => s.projects);
  const running = usePeon((s) => s.running);
  const inbox = usePeon((s) => s.inbox.length);
  const user = usePeon((s) => s.user);
  const connected = usePeon((s) => s.connected);
  const keys = usePeon((s) => s.keys);
  const { mode } = useKb();
  const [filter, setFilter] = useState("all");
  const [menu, setMenu] = useState<{ x: number; y: number } | null>(null);
  const newRow = useRef<View>(null);
  // Per project: "waiting" if any session needs you, else "running".
  const busy = new Map<number, string>();
  for (const r of running)
    if (busy.get(r.project.id) !== "waiting")
      busy.set(r.project.id, r.status === "waiting" ? "waiting" : "running");

  // A row's right side: a dot while it works (amber when it needs you), a lock if private, its template.
  const meta = (p: Project) => (
    <View style={st.metaRow}>
      {busy.has(p.id) ? (
        <Dot size={7} tint={busy.get(p.id) === "waiting" ? color.needs : color.accent} />
      ) : null}
      {p.scope === "private" && p.kind !== "home" ? <Icon name="lock" size={11} color={color.faint} /> : null}
      <Text style={st.meta} numberOfLines={1}>
        {kindLabel[p.kind]}
      </Text>
    </View>
  );

  const { home, folders } = sortFolders(projects, filter);

  // While the prefix is armed, numbers replace the letters (by the unfiltered order the
  // keys use); in `g` mode each page shows its key, and Inbox its prefix key.
  const nums = new Map(
    sidebarItems(projects)
      .slice(0, 9)
      .map(({ project }, i) => [project.id, i + 1]),
  );
  const gkey = (href: string) =>
    mode === "g"
      ? keys?.globals.find((g) => appPath(g.path) === href)?.key
      : mode === "prefix" && href === "/" && keys?.prefs.keymap === "tmux"
        ? "i"
        : null;

  const folderRow = (p: Project, label = p.name) => {
    const href = folderHref(p);
    return (
      <NavRow
        key={p.id}
        testID={`side-${p.name}`}
        label={label}
        href={href}
        active={path === href || path.startsWith(`${href}/`)}
        left={
          mode === "prefix" && nums.has(p.id) ? (
            <Num n={nums.get(p.id)!} />
          ) : (
            <Letter name={label} system={p.kind === "system" || p.kind === "home"} />
          )
        }
        right={meta(p)}
      />
    );
  };

  const openMenu = () => newRow.current?.measureInWindow((x, y, w) => setMenu({ x: x + w - 24, y }));

  return (
    <View style={st.side}>
      <ScrollView style={{ flex: 1 }} contentContainerStyle={{ paddingTop: 10, paddingBottom: 16 }}>
        <Text style={st.section}>Projects</Text>
        <View style={st.chips}>
          {filters.map((f) => (
            <Pressable
              key={f.key}
              onPress={() => setFilter(f.key)}
              style={(s: any) => [st.chip, filter === f.key ? st.chipOn : s.hovered && st.chipHover]}
            >
              <Text style={[st.chipText, filter === f.key && { color: color.textStrong }]}>{f.label}</Text>
            </Pressable>
          ))}
        </View>
        {home ? folderRow(home, "Home") : null}
        {home ? <View style={st.rule} /> : null}
        {folders.map((p) => folderRow(p))}
        {user ? (
          <View ref={newRow} collapsable={false}>
            <Pressable
              testID="side-new-folder"
              onPress={openMenu}
              style={(s: any) => [st.row, s.hovered && st.rowHover]}
            >
              <View style={st.plus}>
                <Text style={st.plusText}>+</Text>
              </View>
              <Text style={[st.rowLabel, { color: color.muted }]}>New Project</Text>
            </Pressable>
          </View>
        ) : null}

        <View style={{ height: 18 }} />
        <NavRow
          label="Inbox"
          href="/"
          active={path === "/"}
          right={inbox ? <Text style={st.count}>{inbox}</Text> : null}
          gkey={gkey("/")}
          testID="side-inbox"
        />
        <NavRow
          label="Schedules"
          href="/schedules"
          active={path === "/schedules"}
          gkey={gkey("/schedules")}
        />
        {user?.admin ? (
          <NavRow
            label="Secrets"
            href="/connectors"
            active={path === "/connectors"}
            gkey={gkey("/connectors")}
          />
        ) : null}
        <NavRow label="Settings" href="/settings" active={path === "/settings"} gkey={gkey("/settings")} />
      </ScrollView>
      <View style={st.foot}>
        <View style={st.host}>
          <Dot size={6} tint={connected ? color.teal : color.red} />
          <Text style={[st.footText, { color: connected ? color.muted : color.red }]} numberOfLines={1}>
            {connected ? host : "reconnecting…"}
          </Text>
        </View>
        <Pressable onPress={signOut} style={(s: any) => [s.hovered && { opacity: 0.7 }]}>
          <Text style={st.footText}>Log out</Text>
        </Pressable>
      </View>
      <TemplateMenu at={menu} onClose={() => setMenu(null)} />
    </View>
  );
}

const st = StyleSheet.create({
  side: { width: 240, borderRightWidth: 1, borderRightColor: color.hairline, backgroundColor: color.bar },
  section: { fontSize: 12, color: color.muted, paddingHorizontal: 18, paddingTop: 14, paddingBottom: 8 },
  chips: { flexDirection: "row", flexWrap: "wrap", gap: 4, paddingHorizontal: 14, paddingBottom: 10 },
  chip: { paddingHorizontal: 7, paddingVertical: 2, borderRadius: 6 },
  chipOn: { backgroundColor: color.raised },
  chipHover: { backgroundColor: color.card },
  chipText: { fontSize: 11.5, color: color.muted },
  rule: { height: 1, backgroundColor: color.hairline, marginHorizontal: 18, marginVertical: 8 },
  plus: {
    width: 22,
    height: 22,
    borderRadius: 6,
    borderWidth: 1,
    borderStyle: "dashed",
    borderColor: color.ghost,
    alignItems: "center",
    justifyContent: "center",
  },
  plusText: { fontSize: 14, color: color.muted, marginTop: -1 },
  menu: {
    position: "absolute",
    width: 340,
    padding: 6,
    borderRadius: 12,
    borderWidth: 1,
    borderColor: color.border,
    backgroundColor: color.card,
    shadowColor: "#000",
    shadowOpacity: 0.5,
    shadowRadius: 30,
    shadowOffset: { width: 0, height: 12 },
  },
  menuTitle: {
    fontSize: 11,
    color: color.faint,
    letterSpacing: 0.6,
    textTransform: "uppercase",
    padding: 10,
  },
  menuRow: {
    flexDirection: "row",
    alignItems: "center",
    gap: 10,
    paddingHorizontal: 10,
    paddingVertical: 8,
    borderRadius: 8,
  },
  menuLabel: { fontSize: 14, color: color.text },
  menuDetail: { fontSize: 12, color: color.muted },
  menuOpens: { fontSize: 11, color: color.faint },
  row: {
    flexDirection: "row",
    alignItems: "center",
    gap: 10,
    marginHorizontal: 8,
    paddingHorizontal: 10,
    height: 32,
    borderRadius: 8,
  },
  rowHover: { backgroundColor: color.card },
  rowActive: { backgroundColor: color.raised },
  rowLabel: { flex: 1, fontSize: 14, color: color.textSoft },
  letter: { alignItems: "center", justifyContent: "center" },
  letterText: { fontWeight: "700" },
  num: { width: 22, height: 22, borderRadius: 6, backgroundColor: color.accent },
  numText: { fontSize: 11, fontWeight: "700", color: color.accentInk },
  gkey: {
    fontSize: 11,
    fontWeight: "600",
    fontFamily: font.mono,
    color: color.accentInk,
    backgroundColor: color.accent,
    borderRadius: 4,
    paddingHorizontal: 6,
    overflow: "hidden",
  },
  meta: { fontSize: 11, color: color.faint, maxWidth: 96 },
  metaRow: { flexDirection: "row", alignItems: "center", gap: 4 },
  count: {
    fontSize: 11,
    fontWeight: "700",
    color: "#1e140b",
    backgroundColor: color.needs,
    borderRadius: 8,
    paddingHorizontal: 6,
    overflow: "hidden",
  },
  foot: {
    flexDirection: "row",
    justifyContent: "space-between",
    paddingHorizontal: 18,
    paddingVertical: 12,
    borderTopWidth: 1,
    borderTopColor: color.hairline,
  },
  footText: { fontSize: 12, color: color.muted },
  host: { flexDirection: "row", alignItems: "center", gap: 6, flexShrink: 1 },
});
