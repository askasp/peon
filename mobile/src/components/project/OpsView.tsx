// An Operations Project (O1–O6). No Chat tab: work here is always about one
// procedure or one run, so each has its own chat. It opens on Procedures, with
// Runs beside it; a procedure opens its chat beside the file, a run its chat
// beside what it did. On the phone each chat is its own screen, with the file
// or the run a tab away.

import { useCallback, useEffect, useState, type ReactNode } from "react";
import { Platform, StyleSheet, Text, View } from "react-native";
import { router } from "expo-router";
import { BackHeader, Badge, ErrorLine, Loading, Segmented, Tap } from "../ui";
import { Icon } from "../Icon";
import { Letter } from "../desktop/Sidebar";
import { ApiCallsTab } from "./ApiCallsTab";
import { ProceduresTab } from "./ProceduresTab";
import { ProcedurePane, type ProcedureChatInfo } from "./ProcedurePane";
import { RunPane } from "./RunPane";
import { RunsTab } from "./RunsTab";
import { SessionChat, type OpsChat } from "../session/SessionChat";
import { attachToChat, useAttached, type Attached } from "@/lib/attach";
import { useLoad } from "@/lib/useLoad";
import { useWide } from "@/lib/useWide";
import { usePeon } from "@/lib/peon";
import { clock, runState } from "@/lib/runs";
import { duration } from "@/lib/time";
import { color, font } from "@/lib/theme";
import type { Project, Run } from "@/lib/types";
import type { ProjectCtx } from "./types";

type Tab = "procedures" | "runs" | "api" | "settings";

export function OpsView({
  project: p,
  ctx,
  error,
  name,
  sub,
  initialTab,
  chat,
  run,
  settings,
}: {
  project: Project;
  ctx: ProjectCtx | null;
  error: string | null;
  name: string;
  sub: string;
  initialTab?: string;
  /** A procedure chat to open (a session id), or a run (its id). */
  chat?: string;
  run?: string;
  settings: (ctx: ProjectCtx) => ReactNode;
}) {
  const wide = useWide();
  const [tab, setTab] = useState<Tab>(
    initialTab === "runs" || initialTab === "api" || initialTab === "settings" ? initialTab : "procedures",
  );
  // What's open over the lists: a procedure's chat or a run's. Links (and the
  // phone, where each is its own screen) set it through the route.
  const [open, setOpen] = useState<{ chat?: string; run?: number }>(() =>
    chat ? { chat } : run && Number(run) ? { run: Number(run) } : {},
  );
  const route = `${chat ?? ""}|${run ?? ""}`;
  const [routed, setRouted] = useState(route);
  if (route !== routed) {
    setRouted(route);
    if (chat) setOpen({ chat });
    else if (run && Number(run)) setOpen({ run: Number(run) });
  }

  const go = useCallback(
    (to: { chat?: string; run?: number }) => {
      if (wide) {
        setOpen(to);
        if (to.chat) setTab("procedures");
        if (to.run) setTab("runs");
      } else
        router.push({
          pathname: "/routine/[id]",
          params: { id: String(p.id), ...(to.chat ? { chat: to.chat } : { run: String(to.run) }) },
        } as any);
    },
    [wide, p.id],
  );
  const back = () => {
    if (wide) setOpen({});
    else if (router.canGoBack()) router.back();
    else router.replace({ pathname: "/routine/[id]", params: { id: String(p.id) } } as any);
  };

  // A procedure's chat by name (made the first time), or a new procedure's;
  // `attach` lands in its composer ("Edit refund-asks" from a run).
  const [opening, setOpening] = useState<string | null>(null);
  const openProcedure = async (procedure: string | null, attach?: Attached) => {
    if (!ctx) return;
    setOpening(null);
    try {
      const r = await ctx.call<{ session_id: string }>(
        "procedure_chat",
        procedure ? { name: procedure } : {},
        60000,
      );
      if (attach) attachToChat(`${p.id}:${r.session_id}`, attach);
      go({ chat: r.session_id });
    } catch (e: any) {
      setOpening(e.message);
    }
  };
  const openRun = (r: Pick<Run, "id">) => go({ run: r.id });

  const showing = open.chat ? "chat" : open.run ? "run" : null;
  // The phone shows a chat as its own screen; the lists live on the Project's.
  const phoneChat = !wide && (chat || run);
  const tabs: { value: Tab; label: string }[] = [
    { value: "procedures", label: "Procedures" },
    { value: "runs", label: "Runs" },
    { value: "api", label: "API calls" },
    { value: "settings", label: "Settings" },
  ];
  const tabProps = Platform.OS === "web" ? ({ dataSet: { kbTabs: "project" } } as object) : {};
  const pick = (t: Tab) => {
    setOpen({});
    setTab(t);
  };

  const body = error ? (
    <View style={{ padding: 18 }}>
      <ErrorLine message={error} />
    </View>
  ) : !ctx ? (
    <Loading />
  ) : showing === "chat" ? (
    <ProcedureChat
      key={open.chat}
      ctx={ctx}
      sid={open.chat!}
      onBack={back}
      onOpenRun={openRun}
      onOpenProcedure={(n) => openProcedure(n)}
    />
  ) : showing === "run" ? (
    <RunChat
      key={open.run}
      ctx={ctx}
      runId={open.run!}
      onBack={back}
      onOpenRun={openRun}
      onOpenProcedure={openProcedure}
    />
  ) : tab === "runs" ? (
    <RunsTab ctx={ctx} onOpen={openRun} />
  ) : tab === "api" ? (
    <ApiCallsTab ctx={ctx} />
  ) : tab === "settings" ? (
    settings(ctx)
  ) : (
    <ProceduresTab ctx={ctx} onOpenChat={openProcedure} />
  );

  if (phoneChat) return body;

  return (
    <>
      {wide ? (
        <View style={st.head}>
          <Letter name={name} size={32} />
          <View style={{ gap: 1, minWidth: 0, flexShrink: 1 }}>
            <Text style={st.crumb}>Projects › Operations</Text>
            <Text style={st.title} numberOfLines={1}>
              {name}
            </Text>
          </View>
          <Text style={st.sub} numberOfLines={1}>
            {sub}
          </Text>
          <View style={{ flex: 1 }} />
          <View style={st.toggle} {...tabProps}>
            {(["procedures", "runs"] as const).map((t) => (
              <Tap
                key={t}
                onPress={() => pick(t)}
                style={[st.toggleItem, tab === t && st.toggleOn]}
                testID={`folder-${t}`}
              >
                <Text style={[st.toggleText, tab === t && { color: color.textStrong }]}>
                  {t === "procedures" ? "Procedures" : "Runs"}
                </Text>
              </Tap>
            ))}
          </View>
          <Tap
            onPress={() => pick(tab === "api" ? "procedures" : "api")}
            style={[st.button, tab === "api" && st.buttonOn]}
            testID="folder-api"
          >
            <Text style={st.buttonText}>API calls</Text>
          </Tap>
          <Tap
            onPress={() => pick(tab === "settings" ? "procedures" : "settings")}
            style={[st.button, tab === "settings" && st.buttonOn]}
            testID="folder-settings"
          >
            <Icon name="gear" size={14} color={color.textSoft} />
            <Text style={st.buttonText}>Settings</Text>
          </Tap>
        </View>
      ) : (
        <>
          <BackHeader label="Projects" />
          <View style={st.phoneHead}>
            <View style={st.titleRow}>
              <Letter name={name} size={44} />
              <View style={{ flex: 1, gap: 2 }}>
                <Text style={st.phoneTitle} numberOfLines={1}>
                  {name}
                </Text>
                <Text style={st.sub}>{sub}</Text>
              </View>
            </View>
            <View {...tabProps}>
              <Segmented options={tabs} value={tab} onChange={pick} />
            </View>
          </View>
        </>
      )}
      <ErrorLine message={opening} />
      {body}
    </>
  );
}

/** "‹ Procedures / refund-asks": back to the list, and what the chat is about. */
function Crumb({
  back,
  title,
  extra,
  onBack,
}: {
  back: string;
  title: string;
  extra?: string;
  onBack: () => void;
}) {
  return (
    <View style={st.crumbRow}>
      <Tap onPress={onBack} hitSlop={8} style={st.crumbBack} testID="ops-back">
        <Icon name="back" size={13} color={color.muted} strokeWidth={2.4} />
        <Text style={st.crumbBackText}>{back}</Text>
      </Tap>
      <Text style={st.crumbSlash}>/</Text>
      <Text style={st.crumbTitle} numberOfLines={1}>
        {title}
      </Text>
      {extra ? <Text style={st.crumbExtra}>{extra}</Text> : null}
    </View>
  );
}

/**
 * The chat a phone shows on its own screen: back, what it's about, and Chat or
 * the pane beside it on the desktop.
 */
function PhoneChat({
  back,
  title,
  extra,
  onBack,
  paneLabel,
  chat,
  pane,
}: {
  back: string;
  title: string;
  extra?: string;
  onBack: () => void;
  paneLabel: string;
  chat: ReactNode;
  pane: ReactNode;
}) {
  const [shown, setShown] = useState<"chat" | "pane">("chat");
  return (
    <>
      <View style={st.phoneChatHead}>
        <Crumb back={back} title={title} extra={extra} onBack={onBack} />
        <Segmented
          options={[
            { value: "chat" as const, label: "Chat" },
            { value: "pane" as const, label: paneLabel },
          ]}
          value={shown}
          onChange={setShown}
        />
      </View>
      {shown === "chat" ? chat : pane}
    </>
  );
}

/** A procedure's chat (O2, O3), beside the procedure it builds and edits. */
function ProcedureChat({
  ctx,
  sid,
  onBack,
  onOpenRun,
  onOpenProcedure,
}: {
  ctx: ProjectCtx;
  sid: string;
  onBack: () => void;
  onOpenRun: (run: Run) => void;
  onOpenProcedure: (name: string) => void;
}) {
  const wide = useWide();
  const [info, setInfo] = useState<ProcedureChatInfo | null>(null);
  const [error, setError] = useState<string | null>(null);
  const call = ctx.call;
  const load = useCallback(() => {
    call<ProcedureChatInfo>("procedure_chat_info", { session_id: sid }, 30000)
      .then(setInfo)
      .catch((e) => setError(e.message));
  }, [call, sid]);
  // Again when the procedures are read again: a turn ended, or Undo.
  useEffect(load, [load, ctx.procedures]);
  const key = `${ctx.project.id}:${sid}`;
  const attached = useAttached(key);
  const title = info?.procedure ?? "New procedure";

  const pane = (
    <ProcedurePane
      ctx={ctx}
      sessionId={sid}
      info={info}
      onChanged={() => {
        ctx.reloadProcedures();
        load();
      }}
      onRan={onOpenRun}
      onOpen={onOpenProcedure}
    />
  );
  const chat = (side: ReactNode | null, bar: ReactNode) => (
    <SessionChat
      id={sid}
      folder={{
        ctx,
        earlier: [],
        attached,
        onAttach: (f) => attachToChat(key, f),
        ops: { bar, side, hint: "Message" } satisfies OpsChat,
      }}
    />
  );
  if (error) return <ErrorLine message={error} />;
  if (wide) return chat(pane, <Crumb back="Procedures" title={title} onBack={onBack} />);
  return (
    <PhoneChat
      back="Procedures"
      title={title}
      onBack={onBack}
      paneLabel="Procedure"
      chat={chat(null, null)}
      pane={pane}
    />
  );
}

/** A run's chat (O5, O6): its result first, what it did beside it. */
function RunChat({
  ctx,
  runId,
  onBack,
  onOpenRun,
  onOpenProcedure,
}: {
  ctx: ProjectCtx;
  runId: number;
  onBack: () => void;
  onOpenRun: (run: Run) => void;
  onOpenProcedure: (name: string, attach?: Attached) => void;
}) {
  const wide = useWide();
  const me = usePeon((s) => s.user?.id);
  const { data: sid, error } = useLoad(
    () => ctx.call<{ session_id: string }>("run_chat", { id: runId }, 60000).then((r) => r.session_id),
    [runId],
  );
  const { data: detail } = useLoad(
    () => ctx.call<{ run: Run }>("run_detail", { id: runId }, 30000),
    [runId, ctx.changed],
  );
  const key = `${ctx.project.id}:${sid}`;
  const attached = useAttached(key);
  if (error) return <ErrorLine message={error} />;
  if (!sid || !detail) return <Loading />;
  const r = detail.run;
  const title = r.procedure ?? "Run";
  const when = clock(r.started);

  const pane = (
    <RunPane
      ctx={ctx}
      runId={runId}
      onOpenRun={onOpenRun}
      onOpenProcedure={(n) => onOpenProcedure(n)}
      onAttach={(a) => attachToChat(key, a)}
    />
  );
  const ops = (side: ReactNode | null, bar: ReactNode): OpsChat => ({
    bar,
    side,
    hint: "Ask about this run",
    header: <RunResult run={r} me={me} />,
    onEdit: (procedure, reply) =>
      onOpenProcedure(procedure, { path: `From run ${title} ${when}`, view: null, text: reply }),
  });
  const chat = (side: ReactNode | null, bar: ReactNode) => (
    <SessionChat
      id={sid}
      folder={{
        ctx,
        earlier: [],
        attached,
        onAttach: (f) => attachToChat(key, f),
        ops: ops(side, bar),
      }}
    />
  );
  if (wide) return chat(pane, <Crumb back="Runs" title={title} extra={when} onBack={onBack} />);
  return (
    <PhoneChat
      back="Runs"
      title={title}
      extra={when}
      onBack={onBack}
      paneLabel="Run"
      chat={chat(null, null)}
      pane={pane}
    />
  );
}

/** The run's result, first in its chat: how it started, how long, what it came to. */
function RunResult({ run: r, me }: { run: Run; me: number | undefined }) {
  const state = runState(r);
  const who = r.trigger === "chain" ? "chain" : r.owner_id === me ? "you" : (r.owner ?? "");
  return (
    <View style={st.result} testID="run-result">
      <View style={st.resultHead}>
        {r.trigger === "schedule" ? <Badge label="Scheduled" tint="teal" /> : null}
        <Text style={st.resultName}>{r.trigger === "slash" ? `/${r.procedure}` : r.procedure}</Text>
        <Text style={st.resultMeta}>
          {[r.trigger === "schedule" ? null : who, r.finished ? duration(r.started, r.finished) : null]
            .filter(Boolean)
            .join(" · ")}
        </Text>
      </View>
      <View style={st.resultBody}>
        <Text style={st.resultText}>
          {r.status === "done" ? (r.summary ?? "Done") : r.status === "failed" ? "Failed" : state.text}
        </Text>
      </View>
    </View>
  );
}

const st = StyleSheet.create({
  head: {
    flexDirection: "row",
    alignItems: "center",
    gap: 12,
    paddingHorizontal: 20,
    paddingVertical: 12,
    borderBottomWidth: 1,
    borderBottomColor: color.hairline,
  },
  crumb: { fontSize: 12, color: color.muted },
  title: { fontSize: 20, fontWeight: "700", letterSpacing: -0.4, color: color.text },
  sub: { alignSelf: "flex-end", paddingBottom: 3, flexShrink: 1, fontSize: 13, color: color.muted },
  toggle: { flexDirection: "row", padding: 3, borderRadius: 9, backgroundColor: color.card },
  toggleItem: { paddingHorizontal: 12, paddingVertical: 5, borderRadius: 7 },
  toggleOn: { backgroundColor: color.raised },
  toggleText: { fontSize: 13, color: color.muted },
  button: {
    flexDirection: "row",
    alignItems: "center",
    gap: 6,
    paddingHorizontal: 12,
    paddingVertical: 6,
    borderRadius: 7,
    borderWidth: 1,
    borderColor: "#2c2c34",
  },
  buttonOn: { backgroundColor: color.raised },
  buttonText: { fontSize: 13, color: color.textSoft },
  phoneHead: { paddingHorizontal: 18, paddingTop: 2, gap: 14, paddingBottom: 10 },
  titleRow: { flexDirection: "row", alignItems: "center", gap: 12, minWidth: 0 },
  phoneTitle: { fontSize: 24, fontWeight: "700", letterSpacing: -0.5, color: color.text },
  phoneChatHead: {
    paddingHorizontal: 16,
    paddingTop: 6,
    paddingBottom: 10,
    gap: 10,
    borderBottomWidth: 1,
    borderBottomColor: color.hairline,
  },
  crumbRow: { flexDirection: "row", alignItems: "center", gap: 7, minWidth: 0, flexShrink: 1 },
  crumbBack: { flexDirection: "row", alignItems: "center", gap: 3 },
  crumbBackText: { fontSize: 13, color: color.muted },
  crumbSlash: { fontSize: 13, color: color.ghost },
  crumbTitle: { flexShrink: 1, fontSize: 13, fontWeight: "700", fontFamily: font.mono, color: color.text },
  crumbExtra: { fontSize: 13, color: color.muted },
  result: {
    borderRadius: 12,
    borderWidth: 1,
    borderColor: color.border,
    overflow: "hidden",
    marginBottom: 6,
  },
  resultHead: {
    flexDirection: "row",
    alignItems: "center",
    gap: 8,
    paddingHorizontal: 14,
    paddingVertical: 9,
    borderBottomWidth: 1,
    borderBottomColor: color.border,
  },
  resultName: { fontFamily: font.mono, fontSize: 12.5, color: color.textSoft },
  resultMeta: { fontSize: 12.5, color: color.muted },
  resultBody: { paddingHorizontal: 14, paddingVertical: 12, gap: 4 },
  resultText: { fontSize: 15, fontWeight: "600", color: color.textStrong },
});
