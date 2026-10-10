import { useState } from "react";
import { Platform, ScrollView, StyleSheet, Text, View } from "react-native";
import { BackHeader, ErrorLine, Loading, Screen, Segmented, UnderlineTabs } from "../ui";
import { Letter } from "../desktop/Sidebar";
import { RunsTab } from "./RunsTab";
import { SchedulesTab } from "./SchedulesTab";
import { SessionsTab } from "./SessionsTab";
import { SettingsTab } from "./SettingsTab";
import { SkillsTab } from "./SkillsTab";
import type { ProjectCtx, RoutineInput } from "./types";
import { usePeon } from "@/lib/peon";
import { useChannel } from "@/lib/useChannel";
import { useCurrent } from "@/lib/current";
import { useWide } from "@/lib/useWide";
import { color, font } from "@/lib/theme";
import type { Project } from "@/lib/types";

type Tab = "sessions" | "runs" | "chats" | "skills" | "schedules" | "settings";

const kindLabel: Record<Project["kind"], string> = {
  code: "Code",
  chat: "Chat",
  routine: "Routine",
  system: "System",
};

/** A project (or routine) with its tabs, as on the web: one place to run and change it. */
export function ProjectView({ id, back, initialTab }: { id: string; back: string; initialTab?: string }) {
  const wide = useWide();
  const [changed, setChanged] = useState(0);
  const [project, setProject] = useState<Project | null>(null);
  const stored = usePeon((s) => s.projects.find((p) => String(p.id) === id) ?? null);
  const ch = useChannel<{
    project: Project;
    can_edit: boolean;
    admin: boolean;
    inputs: RoutineInput[];
    routine: { run: string; error: string | null } | null;
  }>(`project:${id}`, {
    changed: () => setChanged((n) => n + 1),
    project: ({ project }) => setProject(project),
  });

  const p = (project?.id === Number(id) ? project : null) ?? ch.reply?.project ?? stored;
  useCurrent(p?.id);
  const routine = p?.kind === "routine";
  const tabs: { value: Tab; label: string }[] = routine
    ? [
        { value: "runs", label: "Runs" },
        { value: "chats", label: "Chats" },
        { value: "skills", label: "Skills" },
        { value: "schedules", label: "Schedules" },
        { value: "settings", label: "Settings" },
      ]
    : [
        { value: "sessions", label: p?.kind === "chat" ? "Chats" : "Sessions" },
        { value: "skills", label: "Skills" },
        { value: "schedules", label: "Schedules" },
        { value: "settings", label: "Settings" },
      ];
  const [picked, setTab] = useState<Tab | null>((initialTab as Tab) ?? null);
  const tab = picked && tabs.some((t) => t.value === picked) ? picked : tabs[0].value;

  const ctx: ProjectCtx | null =
    p && ch.reply
      ? {
          project: p,
          canEdit: ch.reply.can_edit,
          admin: ch.reply.admin,
          inputs: ch.reply.inputs,
          changed,
          call: ch.call,
        }
      : null;

  const sub = p
    ? [
        kindLabel[p.kind],
        p.scope === "private" ? "only you" : "team",
        routine ? p.schedule || "on demand" : p.default_branch,
      ]
        .filter(Boolean)
        .join(" · ")
    : "";

  const routineLine = ch.reply?.routine ? (
    <>
      <Text style={st.run} numberOfLines={1} selectable>
        {ch.reply.routine.run}
      </Text>
      <ErrorLine message={ch.reply.routine.error} />
    </>
  ) : null;

  return (
    <Screen full={wide && tab === "skills"}>
      {wide ? (
        // Desktop: crumb, tile and name, then tabs on the header's bottom line.
        <View style={st.wideHead}>
          <Text style={st.crumb}>{back}</Text>
          <View style={st.titleRow}>
            {p ? <Letter name={p.name} system={p.kind === "system"} size={34} /> : null}
            <Text style={st.wideTitle} numberOfLines={1}>
              {p?.name ?? "Project"}
            </Text>
          </View>
          <Text style={st.wideSub}>{sub}</Text>
          {routineLine}
          <View
            style={{ marginTop: 6 }}
            {...(Platform.OS === "web" ? ({ dataSet: { kbTabs: "project" } } as object) : {})}
          >
            <UnderlineTabs options={tabs} value={tab} onChange={setTab} />
          </View>
        </View>
      ) : (
        <>
          <BackHeader label={back} />
          <View style={st.head}>
            <Text style={st.title} numberOfLines={1}>
              {p?.name ?? "Project"}
            </Text>
            <Text style={st.sub}>{sub}</Text>
            {routineLine}
            <ScrollView horizontal showsHorizontalScrollIndicator={false}>
              <View
                style={{ minWidth: tabs.length * 92, flex: 1 }}
                {...(Platform.OS === "web" ? ({ dataSet: { kbTabs: "project" } } as object) : {})}
              >
                <Segmented options={tabs} value={tab} onChange={setTab} />
              </View>
            </ScrollView>
          </View>
        </>
      )}
      {ch.error ? (
        <View style={{ padding: 18 }}>
          <ErrorLine message={ch.error} />
        </View>
      ) : !ctx ? (
        <Loading />
      ) : tab === "sessions" || tab === "chats" ? (
        <SessionsTab ctx={ctx} />
      ) : tab === "runs" ? (
        <RunsTab ctx={ctx} />
      ) : tab === "skills" ? (
        <SkillsTab ctx={ctx} />
      ) : tab === "schedules" ? (
        <SchedulesTab ctx={ctx} />
      ) : (
        <SettingsTab ctx={ctx} />
      )}
    </Screen>
  );
}

const st = StyleSheet.create({
  head: { paddingHorizontal: 18, paddingTop: 4, gap: 12, paddingBottom: 10 },
  title: { fontSize: 28, fontWeight: "700", letterSpacing: -0.5, color: color.text },
  sub: { fontSize: 14, color: color.muted, marginTop: -8 },
  wideHead: {
    paddingHorizontal: 32,
    paddingTop: 18,
    gap: 4,
    borderBottomWidth: 1,
    borderBottomColor: color.hairline,
    marginBottom: 8,
  },
  crumb: { fontSize: 12, color: color.muted },
  titleRow: { flexDirection: "row", alignItems: "center", gap: 12, minWidth: 0 },
  wideTitle: { flexShrink: 1, fontFamily: font.brand, fontSize: 28, letterSpacing: -0.8, color: color.text },
  wideSub: { fontSize: 13, color: color.muted },
  run: { fontSize: 12, fontFamily: font.mono, color: color.muted, marginTop: -6 },
});
