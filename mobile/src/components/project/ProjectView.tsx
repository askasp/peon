import { useCallback, useState } from "react";
import { Platform, StyleSheet, Text, View } from "react-native";
import { router } from "expo-router";
import { BackHeader, ErrorLine, Loading, Screen, Segmented, Tap, Toggle, UnderlineTabs } from "../ui";
import { notify } from "@/lib/notice";
import { Icon } from "../Icon";
import { Letter } from "../desktop/Sidebar";
import { FilesTab } from "./FilesTab";
import { ApiCallsTab } from "./ApiCallsTab";
import { ProceduresTab } from "./ProceduresTab";
import { SchedulesTab } from "./SchedulesTab";
import { SessionsTab } from "./SessionsTab";
import { SettingsTab } from "./SettingsTab";
import { SessionChat } from "../session/SessionChat";
import { SkillsTab } from "./SkillsTab";
import { TasksTab } from "./TasksTab";
import { QueueTab } from "./QueueTab";
import { OpsView } from "./OpsView";
import { FolderPane } from "./FolderPane";
import type { ProjectCtx } from "./types";
import type { Procedure } from "@/lib/procedures";
import { usePeon } from "@/lib/peon";
import { useChannel } from "@/lib/useChannel";
import { useCurrent } from "@/lib/current";
import { useWide } from "@/lib/useWide";
import { firstTab, homeLabel, opensWith, singleChat, templateName } from "@/lib/folders";
import { attachToChat, useAttached } from "@/lib/attach";
import { useLoad } from "@/lib/useLoad";
import { color, font } from "@/lib/theme";
import type { Project, SessionSummary } from "@/lib/types";

type Tab = "chat" | "chats" | "files" | "procedures" | "api" | "queue" | "tasks" | "settings" | "home";
type Section = "general" | "skills" | "schedules";

// Old links (?tab=skills) land on the tab that has them now.
const legacy: Record<string, [Tab, Section?]> = {
  sessions: ["chats"],
  runs: ["procedures"],
  skills: ["settings", "skills"],
  schedules: ["settings", "schedules"],
};

/** A Project: the same four tabs whatever template it was made from. */
export function ProjectView({
  id,
  initialTab,
  tree,
  chat: opsChat,
  run,
}: {
  id: string;
  back?: string;
  initialTab?: string;
  /** Files tab: a chat id to show that chat's worktree. */
  tree?: string;
  /** An Operations Project: a procedure chat or a run to open (see OpsView). */
  chat?: string;
  run?: string;
}) {
  const wide = useWide();
  const [changed, setChanged] = useState(0);
  const [project, setProject] = useState<Project | null>(null);
  const stored = usePeon((s) => s.projects.find((p) => String(p.id) === id) ?? null);
  const ch = useChannel<{
    project: Project;
    can_edit: boolean;
    admin: boolean;
    procedures: Procedure[];
    procedures_error: string | null;
    api_calls?: number;
  }>(`project:${id}`, {
    changed: () => setChanged((n) => n + 1),
    project: ({ project }) => setProject(project),
  });

  const p = (project?.id === Number(id) ? project : null) ?? ch.reply?.project ?? stored;
  useCurrent(p?.id);
  const routine = p?.kind === "routine";
  // Design, Document, Dataset and Operations Projects are one chat beside their files.
  const single = p ? singleChat(p.kind) : false;
  // A single-chat Project opens on its chat, or the View it's set to show ("home").
  const home = p ? opensWith(p.kind, p.home_view) : "chat";
  const homeTab = single && home !== "chat";
  // Where its header buttons go back to: the home View, or the chat.
  const main: Tab = homeTab ? "home" : "chat";
  const mainLabel = homeTab ? homeLabel[home] : "Chat";
  // The procedures it can run, as joined and when the chat may have added one.
  const [reloaded, setProcedures] = useState<{ list: Procedure[]; error: string | null } | null>(null);
  const procedures = reloaded?.list ?? ch.reply?.procedures ?? [];
  const proceduresError = reloaded ? reloaded.error : (ch.reply?.procedures_error ?? null);
  const call = ch.call;
  const reloadProcedures = useCallback(() => {
    call<{ procedures: Procedure[]; error: string | null }>("procedures", { fresh: true }, 30000)
      .then((r) => setProcedures({ list: r.procedures, error: r.error }))
      .catch(() => {});
  }, [call]);
  // Operations and Code Projects always have the tab; others once they have their own procedure.
  const proceduresTab =
    routine || p?.kind === "code" || procedures.some((x) => x.source === "folder")
      ? [{ value: "procedures" as Tab, label: "Procedures" }]
      : [];
  const [from, fromSection] = legacy[initialTab ?? ""] ?? [initialTab as Tab | undefined];
  const [picked, setTab] = useState<Tab | null>(from ?? null);
  // Operations, Code and Dataset Projects always have API calls; others once
  // they have one, or while it's open (from Settings).
  const apiTab =
    routine ||
    p?.kind === "code" ||
    p?.kind === "dataset" ||
    (ch.reply?.api_calls ?? 0) > 0 ||
    picked === "api"
      ? [{ value: "api" as Tab, label: "API calls" }]
      : [];
  // Other schedules are under Settings.
  const tabs: { value: Tab; label: string }[] = single
    ? [
        ...(homeTab ? [{ value: "home" as Tab, label: homeLabel[home] }] : []),
        { value: "chat", label: "Chat" },
        ...proceduresTab,
        ...apiTab,
        { value: "files", label: "Files" },
        { value: "settings", label: "Settings" },
      ]
    : [
        { value: "chats", label: "Chats" },
        { value: "files", label: "Files" },
        // Code Projects queue tasks by worktree; the others keep one list.
        p?.kind === "code" ? { value: "queue", label: "Queue" } : { value: "tasks", label: "Tasks" },
        ...proceduresTab,
        ...apiTab,
        { value: "settings", label: "Settings" },
      ];
  const [section, setSection] = useState<Section>(fromSection ?? "general");
  const tab =
    picked && tabs.some((t) => t.value === picked) ? picked : p ? (firstTab(p.kind, p.home_view) as Tab) : "chats";

  // The one chat (made the first time), and the chats the Project had before.
  const { data: chat, error: chatError } = useLoad(
    () =>
      single
        ? ch.call<{ session_id: string; earlier: SessionSummary[] }>("folder_chat", {}, 60000)
        : Promise.resolve(null),
    [id, single],
  );
  // "Chat about this" from Files (or the phone's View) lands in the chat.
  const attached = useAttached(id);
  const [seen, setSeen] = useState(attached);
  if (attached !== seen) {
    setSeen(attached);
    if (attached) setTab("chat");
  }

  const [worktreeOverride, setWorktree] = useState<boolean | null>(null);
  const worktree = worktreeOverride ?? p?.always_worktree ?? false;
  // The file a single-chat Project's "home" View shows (its chat is a tab).
  const [homeFile, setHomeFile] = useState<string | null>(null);
  const newChat = () => p && router.push({ pathname: "/compose", params: { folder: String(p.id) } });
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
          procedures,
          proceduresError,
          reloadProcedures,
          tree,
          changed,
          call: ch.call,
        }
      : null;

  const name = p?.kind === "home" ? "Home" : (p?.name ?? "Project");
  const sub = p
    ? [
        routine
          ? `${procedures.length} procedure${procedures.length === 1 ? "" : "s"}`
          : p.kind === "home"
            ? null
            : `${templateName[p.kind]} template`,
        p.scope === "private" ? "only you" : "Team",
        routine ? p.schedule : p.default_branch,
      ]
        .filter(Boolean)
        .join(" · ")
    : "";

  const tabProps = Platform.OS === "web" ? ({ dataSet: { kbTabs: "project" } } as object) : {};

  const settingsView = (c: ProjectCtx) => (
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
        <SkillsTab ctx={c} />
      ) : section === "schedules" ? (
        <SchedulesTab ctx={c} />
      ) : (
        <SettingsTab ctx={c} onSection={setSection} onApi={() => setTab("api")} />
      )}
    </View>
  );

  // An Operations Project: Procedures and Runs, each with its own chats.
  if (routine && p)
    return (
      <Screen full>
        <OpsView
          project={p}
          ctx={ctx}
          error={ch.error}
          name={name}
          sub={sub}
          initialTab={initialTab}
          chat={opsChat}
          run={run}
          settings={settingsView}
        />
      </Screen>
    );

  // A single-chat Project opens as its chat: beside its files on the desktop
  // (Settings is a button), Chat · Files · Settings on the phone.
  if (single && p) {
    const settings = tab === "settings";
    const error = ch.error ?? chatError;
    return (
      <Screen full>
        {wide ? (
          <View style={st.singleHead}>
            <Letter name={name} size={32} />
            <View style={{ gap: 1, minWidth: 0, flexShrink: 1 }}>
              <Text style={st.crumb}>Projects › {templateName[p.kind]}</Text>
              <Text style={st.singleTitle} numberOfLines={1}>
                {name}
              </Text>
            </View>
            <Text style={st.singleSub} numberOfLines={1}>
              {sub}
            </Text>
            <View style={{ flex: 1 }} />
            {homeTab ? (
              <Tap
                onPress={() => setTab(tab === "home" ? "chat" : "home")}
                style={st.settingsButton}
                testID="folder-home"
              >
                <Text style={st.settingsText}>{tab === "home" ? "Chat" : homeLabel[home]}</Text>
              </Tap>
            ) : null}
            {proceduresTab.length ? (
              <Tap
                onPress={() => setTab(tab === "procedures" ? main : "procedures")}
                style={st.settingsButton}
                testID="folder-procedures"
              >
                <Text style={st.settingsText}>{tab === "procedures" ? mainLabel : "Procedures"}</Text>
              </Tap>
            ) : null}
            {apiTab.length ? (
              <Tap
                onPress={() => setTab(tab === "api" ? main : "api")}
                style={st.settingsButton}
                testID="folder-api"
              >
                <Text style={st.settingsText}>{tab === "api" ? mainLabel : "API calls"}</Text>
              </Tap>
            ) : null}
            <Tap
              onPress={() => setTab(settings ? main : "settings")}
              style={st.settingsButton}
              testID="folder-settings"
            >
              <Icon
                name={settings ? "back" : "gear"}
                size={14}
                color={color.textSoft}
                strokeWidth={settings ? 2.4 : undefined}
              />
              <Text style={st.settingsText}>{settings ? mainLabel : "Settings"}</Text>
            </Tap>
          </View>
        ) : (
          <>
            <BackHeader label="Projects" />
            <View style={st.head}>
              <View style={st.titleRow}>
                <Letter name={name} size={44} />
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
        {error ? (
          <View style={{ padding: 18 }}>
            <ErrorLine message={error} />
          </View>
        ) : !ctx ? (
          <Loading />
        ) : settings ? (
          settingsView(ctx)
        ) : tab === "procedures" ? (
          <ProceduresTab ctx={ctx} onRan={() => setTab(main)} />
        ) : tab === "api" ? (
          <ApiCallsTab ctx={ctx} onRan={() => setTab(main)} />
        ) : tab === "files" && !wide ? (
          <FilesTab ctx={ctx} />
        ) : tab === "home" ? (
          <FolderPane
            ctx={ctx}
            file={homeFile}
            homeView={home}
            onFile={setHomeFile}
            onShown={() => {}}
          />
        ) : !chat ? (
          <Loading />
        ) : (
          <SessionChat
            id={chat.session_id}
            folder={{
              ctx,
              earlier: chat.earlier,
              attached,
              onAttach: (file) => attachToChat(id, file),
            }}
          />
        )}
      </Screen>
    );
  }

  return (
    <Screen full={wide && (tab === "files" || tab === "settings")}>
      {wide ? (
        <View style={st.wideHead}>
          <View style={st.headTop}>
            <View style={{ flex: 1, gap: 4, minWidth: 0 }}>
              <Text style={st.crumb}>Projects › {p ? templateName[p.kind] : ""}</Text>
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
                <Tap haptic onPress={newChat} style={st.primary} testID="folder-primary">
                  <Text style={st.primaryText}>New chat</Text>
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
          <BackHeader label="Projects" />
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
      ) : tab === "queue" ? (
        <QueueTab ctx={ctx} />
      ) : tab === "tasks" ? (
        <TasksTab ctx={ctx} />
      ) : tab === "procedures" ? (
        <ProceduresTab ctx={ctx} />
      ) : tab === "api" ? (
        <ApiCallsTab ctx={ctx} />
      ) : (
        settingsView(ctx)
      )}
      {/* Phone: a new chat in this Project, over the list (or the empty Files tab). */}
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
  singleHead: {
    flexDirection: "row",
    alignItems: "center",
    gap: 12,
    paddingHorizontal: 20,
    paddingVertical: 12,
    borderBottomWidth: 1,
    borderBottomColor: color.hairline,
  },
  singleTitle: { fontSize: 20, fontWeight: "700", letterSpacing: -0.4, color: color.text },
  singleSub: { alignSelf: "flex-end", paddingBottom: 3, flexShrink: 1, fontSize: 13, color: color.muted },
  settingsButton: {
    flexDirection: "row",
    alignItems: "center",
    gap: 6,
    paddingHorizontal: 12,
    paddingVertical: 6,
    borderRadius: 7,
    borderWidth: 1,
    borderColor: "#2c2c34",
  },
  settingsText: { fontSize: 13, color: color.textSoft },
});
