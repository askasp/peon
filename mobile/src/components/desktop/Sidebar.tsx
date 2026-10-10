import { ReactNode } from "react";
import { Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { router, usePathname } from "expo-router";
import { Icon } from "../Icon";
import { Dot, kbProps } from "../ui";
import { signOut, usePeon } from "@/lib/peon";
import { color, tileColors } from "@/lib/theme";
import type { Project } from "@/lib/types";

/** A sidebar row: highlights when hovered or current. */
export function NavRow({
  label,
  href,
  active,
  left,
  right,
  testID,
}: {
  label: string;
  href: string;
  active: boolean;
  left?: ReactNode;
  right?: ReactNode;
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

function Section({ title, onAdd }: { title: string; onAdd?: () => void }) {
  return (
    <View style={st.sectionRow}>
      <Text style={st.section}>{title}</Text>
      {onAdd ? (
        <Pressable
          onPress={onAdd}
          hitSlop={8}
          style={(s: any) => [st.add, s.hovered && { color: color.text }]}
        >
          <Text style={st.addText}>+</Text>
        </Pressable>
      ) : null}
    </View>
  );
}

const host = typeof window !== "undefined" ? window.location.hostname : "connected";

// Projects and routines, then the app's places, like the web app's sidebar.
export function Sidebar() {
  const path = usePathname();
  const projects = usePeon((s) => s.projects);
  const running = usePeon((s) => s.running);
  const inbox = usePeon((s) => s.inbox.length);
  const user = usePeon((s) => s.user);
  const connected = usePeon((s) => s.connected);
  // Per project: "waiting" if any session needs you, else "running".
  const busy = new Map<number, string>();
  for (const r of running)
    if (busy.get(r.project.id) !== "waiting")
      busy.set(r.project.id, r.status === "waiting" ? "waiting" : "running");

  // A row's right side: a dot while it works (cream when it needs you), a lock if private, its schedule.
  const meta = (p: Project, label: string) => (
    <View style={st.metaRow}>
      {busy.has(p.id) ? (
        <Dot size={7} tint={busy.get(p.id) === "waiting" ? color.needs : color.accent} />
      ) : null}
      {p.scope === "private" ? <Icon name="lock" size={11} color={color.faint} /> : null}
      <Text style={st.meta} numberOfLines={1}>
        {label}
      </Text>
    </View>
  );

  const places = projects.filter((p) => p.kind === "code" || p.kind === "chat");
  const routines = projects.filter((p) => p.kind === "routine" || p.kind === "system");

  const projectRow = (p: Project, href: string, right: ReactNode) => (
    <NavRow
      key={p.id}
      testID={`side-${p.name}`}
      label={p.name}
      href={href}
      active={path === href || path.startsWith(`${href}/`)}
      left={<Letter name={p.name} system={p.kind === "system"} />}
      right={right}
    />
  );

  return (
    <View style={st.side}>
      <ScrollView style={{ flex: 1 }} contentContainerStyle={{ paddingTop: 10, paddingBottom: 16 }}>
        <Section title="Projects" onAdd={user ? () => router.navigate("/new" as any) : undefined} />
        {places.map((p) => projectRow(p, `/project/${p.id}`, meta(p, p.schedule ?? p.kind)))}
        <Section
          title="Routines"
          onAdd={
            user ? () => router.navigate({ pathname: "/new", params: { kind: "routine" } } as any) : undefined
          }
        />
        {routines.map((p) =>
          projectRow(
            p,
            p.kind === "system" ? `/project/${p.id}` : `/routine/${p.id}`,
            meta(p, p.kind === "system" ? "system" : (p.schedule ?? "")),
          ),
        )}

        <View style={{ height: 18 }} />
        <NavRow
          label="Inbox"
          href="/"
          active={path === "/"}
          right={inbox ? <Text style={st.count}>{inbox}</Text> : null}
          testID="side-inbox"
        />
        <NavRow label="Schedules" href="/schedules" active={path === "/schedules"} />
        {user?.admin ? (
          <>
            <NavRow label="Connectors" href="/connectors" active={path === "/connectors"} />
            <NavRow label="Models" href="/models" active={path === "/models"} />
            <NavRow label="Users" href="/users" active={path === "/users"} />
          </>
        ) : null}
        <NavRow label="Settings" href="/settings" active={path === "/settings"} />
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
    </View>
  );
}

const st = StyleSheet.create({
  side: { width: 240, borderRightWidth: 1, borderRightColor: color.hairline, backgroundColor: color.bar },
  sectionRow: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    paddingHorizontal: 18,
    paddingTop: 14,
    paddingBottom: 6,
  },
  section: { fontSize: 12, color: color.muted },
  add: { paddingHorizontal: 4 },
  addText: { fontSize: 16, color: color.muted },
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
