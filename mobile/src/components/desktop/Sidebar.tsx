import { ReactNode } from "react";
import { Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { router, usePathname } from "expo-router";
import { Icon, Mark } from "../Icon";
import { Dot, kbProps } from "../ui";
import { signOut, usePeon } from "@/lib/peon";
import { color, font } from "@/lib/theme";
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

function Letter({ name }: { name: string }) {
  return (
    <View style={st.letter}>
      <Text style={st.letterText}>{name.slice(0, 1).toUpperCase()}</Text>
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
        <Dot size={7} tint={busy.get(p.id) === "waiting" ? color.cream : color.accent} />
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
      left={<Letter name={p.name} />}
      right={right}
    />
  );

  return (
    <View style={st.side}>
      <View style={st.brand}>
        <Mark size={26} />
        <Text style={st.word}>peon</Text>
        <Text style={st.tag}>work work.</Text>
      </View>
      <ScrollView style={{ flex: 1 }} contentContainerStyle={{ paddingBottom: 16 }}>
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
        <Text style={[st.footText, { color: connected ? color.muted : color.red }]}>
          {connected ? "connected" : "reconnecting…"}
        </Text>
        <Pressable onPress={signOut} style={(s: any) => [s.hovered && { opacity: 0.7 }]}>
          <Text style={st.footText}>Log out</Text>
        </Pressable>
      </View>
    </View>
  );
}

const st = StyleSheet.create({
  side: { width: 248, borderRightWidth: 1, borderRightColor: color.hairline, backgroundColor: color.bar },
  brand: { flexDirection: "row", alignItems: "center", gap: 8, paddingHorizontal: 18, paddingVertical: 16 },
  word: { fontFamily: font.brand, fontSize: 22, letterSpacing: -0.8, color: color.text },
  tag: { fontSize: 11, color: color.accentText, fontFamily: font.mono, marginTop: 4 },
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
  letter: {
    width: 20,
    height: 20,
    borderRadius: 5,
    borderWidth: 1,
    borderColor: color.outline,
    alignItems: "center",
    justifyContent: "center",
  },
  letterText: { fontSize: 11, fontWeight: "600", color: color.text },
  meta: { fontSize: 11, color: color.faint, maxWidth: 96 },
  metaRow: { flexDirection: "row", alignItems: "center", gap: 4 },
  count: {
    fontSize: 11,
    color: color.accentInk,
    backgroundColor: color.accent,
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
});
