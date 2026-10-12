import { useState } from "react";
import { Platform, StyleSheet, Text, View } from "react-native";
import { router } from "expo-router";
import { BackHeader, ErrorLine, Loading, Screen, Segmented, Tap, Toggle, UnderlineTabs } from "../ui";
import { notify } from "@/lib/notice";
import { Icon } from "../Icon";
import { Letter } from "../desktop/Sidebar";
import { FilesTab } from "./FilesTab";
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
import { firstTab, templateName } from "@/lib/folders";
import { color, font } from "@/lib/theme";
import type { Project } from "@/lib/types";

type Tab = "chats" | "files" | "runs" | "settings";
type Section = "general" | "skills" | "schedules";

// Old links (?tab=skills) land on the tab that has them now.
const legacy: Record<string, [Tab, Section?]> = {
  sessions: ["chats"],
  skills: ["settings", "skills"],
  schedules: ["settings", "schedules"],
};

/** A Folder: the same four tabs whatever template it was made from. */
export function ProjectView({
  id,
  initialTab,
  tree,
}: {
  id: string;
  back?: string;
  initialTab?: string;
  /** Files tab: a chat id to show that chat's worktree. */
  tree?: string;
}) {
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
  // Runs only when the Folder has a routine; other schedules are under Settings.
  const tabs: { value: Tab; label: string }[] = [
    { value: "chats", label: "Chats" },
    { value: "files", label: "Files" },
    ...(routine ? [{ value: "runs" as Tab, label: "Runs" }] : []),
    { value: "settings", label: "Settings" },
  ];
  const [from, fromSection] = legacy[initialTab ?? ""] ?? [initialTab as Tab | undefined];
  const [picked, setTab] = useState<Tab | null>(from ?? null);
  const [section, setSection] = useState<Section>(fromSection ?? "general");
  const tab =
    picked && tabs.some((t) => t.value === picked) ? picked : p ? (firstTab(p.kind) as Tab) : "chats";

  // The header's primary action: a new chat here, or run the routine.
  const [running, setRunning] = useState(false);
  const [worktreeOverride, setWorktree] = useState<boolean | null>(null);
  const worktree = worktreeOverride ?? p?.always_worktree ?? false;
  const newChat = () => p && router.push({ pathname: "/compose", params: { folder: String(p.id) } });
  async function runNow() {
    setRunning(true);
    try {
      const { session_id } = await ch.call<{ session_id: string }>("run", {}, 60000);
      router.push(`/session/${session_id}`);
    } catch (e: any) {
      notify(e.message);
    }
    setRunning(false);
  }
  async function saveWorktree(v: boolean) {
    setWorktree(v);
    try {
      await ch.call("save_settings", { params: { always_worktree: String(v) } }, 30000);
    } catch (e: any) {
      setWorktree(!v);
      notify(e.message);
    }
  }

  const ctx: ProjectCtx | null =
    p && ch.reply
      ? {
          project: p,
          canEdit: ch.reply.can_edit,
          admin: ch.reply.admin,
          inputs: ch.reply.inputs,
          routine: ch.reply.routine,
          tree,
          changed,
          call: ch.call,
        }
      : null;

  const name = p?.kind === "home" ? "Home" : (p?.name ?? "Folder");
  const sub = p
    ? [
        p.kind === "home" ? null : `${templateName[p.kind]} template`,
        p.scope === "private" ? "only you" : "Team",
        routine ? p.schedule || "on demand" : p.default_branch,
      ]
        .filter(Boolean)
        .join(" · ")
    : "";

  const tabProps = Platform.OS === "web" ? ({ dataSet: { kbTabs: "project" } } as object) : {};

  return (
    <Screen full={wide && (tab === "files" || tab === "settings")}>
      {wide ? (
        <View style={st.wideHead}>
          <View style={st.headTop}>
            <View style={{ flex: 1, gap: 4, minWidth: 0 }}>
              <Text style={st.crumb}>Folders › {p ? templateName[p.kind] : ""}</Text>
              <View style={st.titleRow}>
                {p ? (
                  <Letter name={name} system={p.kind === "system" || p.kind === "home"} size={34} />
                ) : null}
                <Text style={st.wideTitle} numberOfLines={1}>
                  {name}
                </Text>
              </View>
              <Text style={st.wideSub}>{sub}</Text>
            </View>
            {ctx ? (
              <View style={st.headActions}>
                {p?.kind === "code" ? (
                  <View style={st.wt}>
                    <Toggle label="New worktree" value={worktree} onChange={saveWorktree} />
                    <Text style={st.wtText}>New worktree</Text>
                  </View>
                ) : null}
                <Tap haptic onPress={routine ? runNow : newChat} style={st.primary} testID="folder-primary">
                  <Text style={st.primaryText}>{routine ? (running ? "Starting…" : "Run") : "New chat"}</Text>
                </Tap>
              </View>
            ) : null}
          </View>
          <View style={{ marginTop: 6 }} {...tabProps}>
            <UnderlineTabs options={tabs} value={tab} onChange={setTab} />
          </View>
        </View>
      ) : (
        <>
          <BackHeader label="Folders" />
          <View style={st.head}>
            <View style={st.titleRow}>
              {p ? <Letter name={name} system={p.kind === "system" || p.kind === "home"} size={44} /> : null}
              <View style={{ flex: 1, gap: 2 }}>
                <Text style={st.title} numberOfLines={1}>
                  {name}
                </Text>
                <Text style={st.sub}>{sub}</Text>
              </View>
            </View>
            <View {...tabProps}>
              <Segmented options={tabs} value={tab} onChange={setTab} />
            </View>
          </View>
        </>
      )}
      {ch.error ? (
        <View style={{ padding: 18 }}>
          <ErrorLine message={ch.error} />
        </View>
      ) : !ctx ? (
        <Loading />
      ) : tab === "chats" ? (
        <SessionsTab ctx={ctx} />
      ) : tab === "files" ? (
        <FilesTab ctx={ctx} />
      ) : tab === "runs" ? (
        <RunsTab ctx={ctx} />
      ) : (
        <View style={{ flex: 1, minHeight: 0 }}>
          {section !== "general" ? (
            <Tap
              testID="settings-up"
              onPress={() => setSection("general")}
              style={[st.up, wide && { paddingHorizontal: 32 }]}
            >
              <Icon name="back" size={16} color={color.accentText} strokeWidth={2.4} />
              <Text style={st.upText}>Settings</Text>
            </Tap>
          ) : null}
          {section === "skills" ? (
            <SkillsTab ctx={ctx} />
          ) : section === "schedules" ? (
            <SchedulesTab ctx={ctx} />
          ) : (
            <SettingsTab ctx={ctx} onSection={setSection} />
          )}
        </View>
      )}
      {/* Phone: a new chat in this Folder, over the list (or the empty Files tab). */}
      {!wide && ctx && (tab === "chats" || tab === "files") ? (
        <Tap
          testID="new-session"
          haptic
          onPress={() => router.push({ pathname: "/compose", params: { folder: String(ctx.project.id) } })}
          style={st.fab}
        >
          <Text style={st.fabText}>+ New chat</Text>
        </Tap>
      ) : null}
    </Screen>
  );
}

const st = StyleSheet.create({
  head: { paddingHorizontal: 18, paddingTop: 2, gap: 14, paddingBottom: 10 },
  title: { fontSize: 24, fontWeight: "700", letterSpacing: -0.5, color: color.text },
  sub: { fontSize: 13, color: color.muted },
  up: { flexDirection: "row", alignItems: "center", gap: 4, paddingHorizontal: 18, minHeight: 32 },
  upText: { fontSize: 15, color: color.accentText },
  fab: {
    position: "absolute",
    right: 18,
    bottom: 24,
    height: 50,
    paddingHorizontal: 20,
    borderRadius: 25,
    backgroundColor: color.textStrong,
    justifyContent: "center",
    shadowColor: "#000",
    shadowOpacity: 0.45,
    shadowRadius: 24,
    shadowOffset: { width: 0, height: 8 },
    elevation: 8,
  },
  fabText: { color: color.bg, fontWeight: "600", fontSize: 15 },
  headTop: { flexDirection: "row", alignItems: "flex-start", gap: 16 },
  headActions: { flexDirection: "row", alignItems: "center", gap: 14, paddingTop: 14 },
  wt: { flexDirection: "row", alignItems: "center", gap: 8 },
  wtText: { fontSize: 13, color: color.textDim },
  primary: { paddingHorizontal: 14, paddingVertical: 8, borderRadius: 8, backgroundColor: color.textStrong },
  primaryText: { fontSize: 14, fontWeight: "600", color: color.bg },
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
