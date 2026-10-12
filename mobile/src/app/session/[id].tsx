import { setViewing, usePeon } from "@/lib/peon";
import { useEffect, useMemo, useRef, useState } from "react";
import {
  ActivityIndicator,
  FlatList,
  Image,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from "react-native";
import { router, useLocalSearchParams } from "expo-router";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { Icon } from "@/components/Icon";
import { PickSheet, Sheet } from "@/components/Sheet";
import { BlockView, toBlocks, type Block } from "@/components/Transcript";
import { DiffView } from "@/components/session/DiffView";
import { FileView, treeCall } from "@/components/project/FilesTab";
import { Letter } from "@/components/desktop/Sidebar";
import { PermResources } from "@/components/PermResources";
import { FormCard } from "@/components/session/FormCard";
import { SessionComposer } from "@/components/session/SessionComposer";
import { Badge, Button, Card, ErrorLine, Loading, Screen, Tap, UnderlineTabs } from "@/components/ui";
import { CopyResult, RunProgress } from "@/components/session/RunProgress";
import { useKeyboardHeight } from "@/lib/useKeyboard";
import { useSession } from "@/lib/useSession";
import { useCommand } from "@/lib/commands";
import { useCurrent } from "@/lib/current";
import { useWide } from "@/lib/useWide";
import { useChannel } from "@/lib/useChannel";
import { folderHref } from "@/lib/folders";
import { setViewDiff } from "@/lib/viewStore";
import { inputsLabel, runLine, runWho } from "@/lib/runs";
import { say, stopSpeaking } from "@/lib/voice";
import { color, font } from "@/lib/theme";
import type { SessionOptions } from "@/lib/types";

const modelValue = (m: any): string | null =>
  m && typeof m === "object" && m.id ? `${m.providerID}/${m.id}` : typeof m === "string" ? m : null;

// 05 · Session: the conversation, live; reply by typing or talking.
export default function SessionScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const s = useSession(id, (text) => say(text));
  const me = usePeon((p) => p.user);
  const title = s.session?.title;
  useEffect(() => {
    if (title) setViewing({ id, title });
  }, [id, title]);
  useEffect(() => () => setViewing(null), [id]);
  const insets = useSafeAreaInsets();
  const keyboard = useKeyboardHeight();
  const wide = useWide();
  const list = useRef<FlatList>(null);
  const atEnd = useRef(true);
  // Opening a session lands on its end: the list renders in pieces, so for a
  // moment every growth jumps to the bottom, whatever the scroll events say.
  const pinUntil = useRef(0);
  useEffect(() => {
    if (!s.joined) return;
    atEnd.current = true;
    pinUntil.current = Date.now() + 2500;
  }, [id, s.joined]);
  const [error, setError] = useState<string | null>(null);
  const [options, setOptions] = useState<SessionOptions | null>(null);
  const [menu, setMenu] = useState(false);
  const [renaming, setRenaming] = useState<string | null>(null);
  // The View beside the chat (desktop): "diff" or a file the agent wrote.
  const [view, setView] = useState<string | null>(null);
  const [opened, setOpened] = useState<string[]>([]);
  const [paneHidden, setPaneHidden] = useState(false);

  const all = useMemo(() => toBlocks(s.items), [s.items]);
  const [full, setFull] = useState(false);
  // A routine run reads as its result: the steps fold into one "Run transcript" row.
  // While a run works it shows its progress instead (RunProgress); after, the result.
  const runWorking = s.run?.status === "running" && (s.status === "running" || s.status === "waiting");
  const blocks = useMemo(
    () => (s.run && !full ? (runWorking ? [] : foldRun(all)) : all),
    [all, s.run, full, runWorking],
  );
  const [image, setImage] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const [, tick] = useState(0);
  useEffect(() => {
    if (s.run?.status !== "running") return;
    const t = setInterval(() => tick((n) => n + 1), 1000);
    return () => clearInterval(t);
  }, [s.run?.status]);
  const call = s.call;
  // Files open through the Folder's channel.
  const folder = useChannel(s.project ? `project:${s.project.id}` : null);
  const dir = s.session?.directory ?? null;
  // A chat in its own worktree: its files come from there, not the Folder's main.
  const tree = s.session?.worktree ? id : "main";
  const folderCall = useMemo(() => treeCall(folder.call, tree), [folder.call, tree]);
  const openInFiles = () =>
    s.project &&
    router.push({
      pathname: `/project/${s.project.id}` as any,
      params: { tab: "files", ...(tree !== "main" ? { tree } : {}) },
    });
  const rel = (path: string) => (dir && path.startsWith(`${dir}/`) ? path.slice(dir.length + 1) : path);
  const openFile = (path: string) => {
    const r = rel(path);
    if (!wide)
      return (
        s.project &&
        router.push({
          pathname: "/view" as any,
          params: {
            project: String(s.project.id),
            path: r,
            from: "chat",
            ...(tree !== "main" ? { tree } : {}),
          },
        })
      );
    setOpened((o) => (o.includes(r) ? o : [...o, r]));
    setView(r);
    setPaneHidden(false);
  };
  const offset = useRef(0);
  const height = useRef(600);
  useCurrent(s.project?.id, id);

  // Agents, models and `/` items for the composer, once joined.
  useEffect(() => {
    if (!s.joined) return;
    call<SessionOptions>("options", {}, 60000)
      .then(setOptions)
      .catch(() => {});
  }, [s.joined, call]);

  // Stop talking when leaving the session.
  useEffect(
    () => () => {
      stopSpeaking();
    },
    [],
  );

  const act = (event: string, payload: object = {}) => call(event, payload).catch((e) => setError(e.message));

  async function rename() {
    const title = renaming?.trim();
    setRenaming(null);
    if (title && title !== s.session?.title) await act("rename", { title });
  }

  async function runAgain() {
    try {
      const { session_id } = await call<{ session_id: string }>("run_again", {}, 60000);
      router.replace(`/session/${session_id}`);
    } catch (e: any) {
      setError(e.message);
    }
  }

  const busy = s.status === "running" || s.status === "waiting";

  // Keyboard shortcuts for this session (see lib/keys).
  useCommand("session:interrupt", () => {
    if (busy) s.interrupt().catch((e) => setError(e.message));
  });
  const compact = () => {
    setNote("Compacting…");
    act("compact").then(() => setTimeout(() => setNote(null), 4000));
  };
  useCommand("session:compact", compact);
  useCommand("session:rename", () => setRenaming(s.session?.title ?? ""));
  useCommand("session:run-again", () => (s.run ? runAgain() : undefined));
  useCommand("session:first", () => list.current?.scrollToOffset({ offset: 0, animated: true }));
  useCommand("session:last", () => list.current?.scrollToEnd({ animated: true }));
  useCommand("session:page-up", () =>
    list.current?.scrollToOffset({
      offset: Math.max(0, offset.current - height.current * 0.9),
      animated: true,
    }),
  );
  useCommand("session:page-down", () =>
    list.current?.scrollToOffset({ offset: offset.current + height.current * 0.9, animated: true }),
  );

  const subtitle = [
    s.project?.name,
    s.session?.worktree,
    s.session?.started_by,
    s.session?.scope === "private" ? "only you" : null,
    s.session?.agent,
  ]
    .filter(Boolean)
    .join(" · ");
  const changed = s.diff.length;
  const added = s.diff.reduce((n, f) => n + (f.additions ?? 0), 0);
  const removed = s.diff.reduce((n, f) => n + (f.deletions ?? 0), 0);
  const openDiff = () => {
    if (wide) {
      setView("diff");
      setPaneHidden(false);
    } else if (s.project) {
      setViewDiff(s.diff);
      router.push({
        pathname: "/view" as any,
        params: { project: String(s.project.id), diff: s.session?.branch ?? "changes" },
      });
    }
  };
  const run = runLine(s.run);
  const current =
    view && (view === "diff" ? changed > 0 : opened.includes(view)) ? view : changed ? "diff" : opened[0];
  const pane = wide && !paneHidden && current != null;
  const folderName = s.project?.kind === "home" ? "Home" : s.project?.name;
  const goFolder = (tab: string) =>
    s.project && router.navigate({ pathname: folderHref(s.project), params: { tab } } as any);

  const transcript = s.error ? (
    <View style={{ padding: 18 }}>
      <ErrorLine message={s.error} />
    </View>
  ) : !s.joined ? (
    <Loading />
  ) : (
    <FlatList
      ref={list}
      data={blocks}
      // File cards show which file is in the View.
      extraData={pane ? current : null}
      keyExtractor={(b) => b.key}
      renderItem={({ item }) =>
        item.kind === "note" && item.key === FOLD ? (
          <Tap onPress={() => setFull(true)} style={st.changed} kb="row">
            <Text style={st.changedText} numberOfLines={1}>
              {item.text}
            </Text>
            <Icon name="chevron" size={16} color={color.muted} />
          </Tap>
        ) : (
          <BlockView
            block={item}
            onFile={openFile}
            viewing={pane && current !== "diff" ? current : null}
            rel={rel}
            onImage={setImage}
            loadImage={(img) =>
              call<{ mime: string; data: string }>(
                "image",
                { message_id: img.messageId, index: img.index },
                60000,
              ).then((r) => `data:${r.mime};base64,${r.data}`)
            }
          />
        )
      }
      contentContainerStyle={st.transcript}
      onScroll={(e) => {
        const { contentOffset, contentSize, layoutMeasurement } = e.nativeEvent;
        offset.current = contentOffset.y;
        height.current = layoutMeasurement.height;
        if (Date.now() < pinUntil.current) return;
        atEnd.current = contentOffset.y + layoutMeasurement.height >= contentSize.height - 80;
      }}
      scrollEventThrottle={100}
      onContentSizeChange={() => {
        if (Date.now() < pinUntil.current) list.current?.scrollToEnd({ animated: false });
        else if (atEnd.current) list.current?.scrollToEnd({ animated: true });
      }}
      ListHeaderComponent={
        s.run && run ? (
          <Card style={{ marginBottom: 6 }}>
            <View style={st.runHead}>
              <Text style={st.runTitle}>
                Run · {s.run.schedule_key === "manual" ? "manual" : s.run.schedule_key}
              </Text>
              <Text style={{ color: run.tint, fontSize: 13 }}>{run.text}</Text>
            </View>
            <Text style={st.runMeta} numberOfLines={2}>
              {[runWho(s.run, me?.id), inputsLabel(s.run.inputs)].filter(Boolean).join(" · ")}
            </Text>
            <View style={st.runActions}>
              <Tap onPress={() => setFull(!full)} hitSlop={6}>
                <Text style={{ color: color.accentText, fontSize: 13 }}>
                  {full ? (runWorking ? "Hide transcript" : "Show the result only") : "Full transcript"}
                </Text>
              </Tap>
              {!runWorking ? <CopyResult items={s.items} /> : null}
            </View>
            {runWorking && !full ? <RunProgress items={s.items} status={s.status} /> : null}
            {s.run.status !== "running" ? (
              <Button label="Run again" kind="secondary" height={34} onPress={runAgain} />
            ) : null}
          </Card>
        ) : null
      }
      ListFooterComponent={
        <View style={{ gap: 12 }}>
          {changed ? (
            <Tap
              onPress={openDiff}
              style={[st.diffCard, pane && current === "diff" && st.diffCardOn]}
              kb="row"
            >
              <View style={st.diffTop}>
                <Text style={st.diffBranch} numberOfLines={1}>
                  {s.session?.branch ?? s.session?.worktree ?? "changes"}
                </Text>
                <Text style={st.diffCounts}>
                  <Text style={{ color: color.teal }}>+{added}</Text>{" "}
                  <Text style={{ color: color.red }}>−{removed}</Text>
                </Text>
              </View>
              <Text style={st.diffSub}>
                {changed} file{changed === 1 ? "" : "s"} · tap to see the diff
              </Text>
            </Tap>
          ) : null}
          {s.perms.map((p) => (
            <PermCard
              key={p.id}
              title={p.title}
              resources={p.resources}
              onAnswer={(d) => s.answer(p.id, d)}
            />
          ))}
          {s.forms.map((f) => (
            <FormCard
              key={f.id}
              form={f}
              onSend={(answer) => s.reply(f.id, answer)}
              onSkip={() => s.skip(f.id)}
            />
          ))}
          {s.status === "running" && s.forms.length === 0 ? (
            <View style={st.working}>
              <ActivityIndicator size="small" color={color.accent} />
              <Text style={st.workingText}>Working…</Text>
              <Tap
                onPress={() => s.interrupt().catch((e) => setError(e.message))}
                style={st.stop}
                testID="stop"
              >
                <Icon name="stop" size={12} color={color.text} />
                <Text style={st.stopText}>Stop</Text>
              </Tap>
            </View>
          ) : null}
        </View>
      }
    />
  );

  return (
    <Screen full>
      <View style={st.header}>
        <Tap onPress={() => (router.canGoBack() ? router.back() : router.replace("/"))} hitSlop={12}>
          <Icon name="back" size={22} color={color.accentText} />
        </Tap>
        <View style={st.headerMid}>
          {renaming != null ? (
            <TextInput
              value={renaming}
              onChangeText={setRenaming}
              onSubmitEditing={rename}
              onBlur={rename}
              autoFocus
              selectTextOnFocus
              style={[st.headerTitle, st.renameInput]}
            />
          ) : (
            <Text
              style={st.headerTitle}
              numberOfLines={1}
              onPress={() => setRenaming(s.session?.title ?? "")}
            >
              {s.session?.title ?? " "}
            </Text>
          )}
          {wide && folderName ? (
            <Text style={st.crumb} onPress={() => goFolder("chats")}>
              {folderName} › Chats
            </Text>
          ) : null}
          {wide ? (
            <Text style={st.headerSub} numberOfLines={1}>
              {subtitle}
            </Text>
          ) : s.project ? (
            // Phone: which Folder (and worktree) this chat is in.
            <View style={st.subRow}>
              <Letter name={folderName ?? ""} system={s.project.kind === "home"} size={13} />
              <Text style={st.headerSub} numberOfLines={1}>
                {[folderName, s.session?.worktree].filter(Boolean).join(" · ")}
              </Text>
            </View>
          ) : null}
        </View>
        {wide && s.status === "waiting" ? <Badge label="Needs you" tint="needs" /> : null}
        {wide && s.status === "running" ? <Badge label="Working" /> : null}
        <Tap testID="session-menu" hitSlop={12} onPress={() => setMenu(true)} style={st.menuButton}>
          <Text style={st.menuDots}>⋯</Text>
        </Tap>
      </View>
      {wide && s.project ? (
        <View style={st.folderTabs}>
          <UnderlineTabs
            options={[
              { value: "chats", label: "Chats" },
              { value: "files", label: "Files" },
              ...(s.project.kind === "routine" || s.project.schedule
                ? [{ value: "runs", label: "Runs" }]
                : []),
              { value: "settings", label: "Settings" },
            ]}
            value="chats"
            onChange={goFolder}
          />
        </View>
      ) : null}

      <View style={{ flex: 1, flexDirection: "row", minHeight: 0 }}>
        <View style={[{ flex: 1, paddingBottom: keyboard, minWidth: 0 }, pane && st.chatColumn]}>
          {transcript}
          <ErrorLine message={error} />
          {note ? <Text style={st.note}>{note}</Text> : null}
          {s.run?.status === "running" ? (
            <Text style={st.note}>Anything you send now is queued until the run is done.</Text>
          ) : null}
          <SessionComposer
            queued={s.run?.status === "running"}
            busy={busy}
            options={options}
            agent={s.session?.agent ?? null}
            model={modelValue(s.session?.model)}
            variant={s.session?.model?.variant ?? null}
            bottomPad={keyboard > 0 ? 10 : Math.max(insets.bottom, 10) + 4}
            send={(text, files) => {
              atEnd.current = true;
              return s.send(text, files);
            }}
            findFiles={(query) => call("find_files", { query })}
            setAgent={(agent) => call("set_agent", { agent })}
            setModel={(model, variant) => call("set_model", { model, ...(variant ? { variant } : {}) })}
            onError={setError}
          />
        </View>
        {/* Desktop: the View beside the conversation, the diff or a file the agent wrote. */}
        {pane ? (
          <View style={st.side}>
            {(changed ? 1 : 0) + opened.length > 1 ? (
              <View style={st.paneTabs}>
                <ScrollView
                  horizontal
                  showsHorizontalScrollIndicator={false}
                  contentContainerStyle={{ gap: 4 }}
                >
                  {changed ? (
                    <Tap
                      onPress={() => setView("diff")}
                      style={[st.paneTab, current === "diff" && st.paneTabOn]}
                    >
                      <Text style={[st.paneTabText, current === "diff" && { color: color.textStrong }]}>
                        Diff · {changed} file{changed === 1 ? "" : "s"}
                      </Text>
                    </Tap>
                  ) : null}
                  {opened.map((f) => (
                    <Tap
                      key={f}
                      onPress={() => setView(f)}
                      style={[st.paneTab, current === f && st.paneTabOn]}
                    >
                      <Text style={[st.paneTabText, current === f && { color: color.textStrong }]}>
                        {f.split("/").pop()}
                      </Text>
                    </Tap>
                  ))}
                </ScrollView>
              </View>
            ) : null}
            {current === "diff" ? (
              <View style={st.diffPane}>
                <View style={st.diffHead}>
                  <View style={st.kindChip}>
                    <Text style={st.kindText}>Diff</Text>
                  </View>
                  <Text style={st.diffName} numberOfLines={1}>
                    {s.session?.branch ?? s.session?.worktree ?? "changes"}
                  </Text>
                  <View style={{ flex: 1 }} />
                  <Tap onPress={() => setPaneHidden(true)} style={st.closeBox} aria-label="Close the view">
                    <Icon name="close" size={14} color={color.muted} />
                  </Tap>
                </View>
                <ScrollView>
                  <DiffView files={s.diff} />
                </ScrollView>
              </View>
            ) : folder.joined ? (
              <FileView
                key={current}
                call={folderCall}
                path={current!}
                version={all.length}
                readOnly={s.project?.kind === "code" && tree === "main"}
                onOpenInFiles={openInFiles}
                onClose={() => setPaneHidden(true)}
              />
            ) : (
              <Loading />
            )}
          </View>
        ) : null}
      </View>

      <Sheet visible={image != null} onClose={() => setImage(null)} width={900}>
        {image ? <Image source={{ uri: image }} style={st.full} resizeMode="contain" /> : null}
      </Sheet>

      <PickSheet
        visible={menu}
        title={s.session?.title ?? "Session"}
        onClose={() => setMenu(false)}
        items={[
          { key: "rename", label: "Rename" },
          {
            key: "diff",
            label: "Changed files",
            detail: changed ? `${changed} file${changed === 1 ? "" : "s"}` : "none yet",
          },
          {
            key: "files",
            label: "Open in Files",
            detail: tree !== "main" ? "This chat's worktree" : "The Folder's files",
          },
          { key: "compact", label: "Compact the conversation", detail: "Summarize it to free up context" },
          { key: "handsfree", label: "Hands-free", detail: "Talk to this session" },
          ...(busy ? [{ key: "stop", label: "Stop", danger: true }] : []),
        ]}
        onPick={(key) => {
          setMenu(false);
          if (key === "rename") setRenaming(s.session?.title ?? "");
          else if (key === "diff") openDiff();
          else if (key === "files") openInFiles();
          else if (key === "compact") compact();
          else if (key === "handsfree") router.push({ pathname: "/handsfree", params: { session: id } });
          else if (key === "stop") s.interrupt().catch((e) => setError(e.message));
        }}
      />
    </Screen>
  );
}

const FOLD = "run-transcript";

// Everything up to the reply after the last steps folds into one row:
// "Run transcript · <prompt> · N tool calls".
function foldRun(blocks: Block[]): Block[] {
  const lastSteps = blocks.map((b) => b.kind).lastIndexOf("steps");
  if (lastSteps < 0) return blocks;
  const folded = blocks.slice(0, lastSteps + 1);
  const tools = folded.reduce((n, b) => n + (b.kind === "steps" ? b.tools.length : 0), 0);
  const prompt = folded.find((b) => b.kind === "user");
  const what = prompt && prompt.kind === "user" ? prompt.text.split("\n")[0].slice(0, 60) : "the run";
  return [
    {
      kind: "note",
      key: FOLD,
      text: `Run transcript · ${what} · ${tools} tool call${tools === 1 ? "" : "s"}`,
    },
    ...blocks.slice(lastSteps + 1),
  ];
}

function PermCard({
  title,
  resources,
  onAnswer,
}: {
  title: string;
  resources: string[];
  onAnswer: (d: "once" | "always" | "reject") => Promise<unknown>;
}) {
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const answer = async (d: "once" | "always" | "reject") => {
    setBusy(d);
    try {
      await onAnswer(d);
    } catch (e: any) {
      setError(e.message);
      setBusy(null);
    }
  };
  return (
    <Card needs>
      <Text style={{ fontSize: 15, color: color.text }}>Needs your OK: {title}</Text>
      <PermResources resources={resources} />
      <ErrorLine message={error} />
      <View style={{ flexDirection: "row", gap: 8 }}>
        <Button
          label="Allow once"
          style={{ flex: 1 }}
          busy={busy === "once"}
          onPress={() => answer("once")}
          testID="allow-once"
        />
        <Button
          label="Always"
          kind="secondary"
          style={{ flex: 1 }}
          busy={busy === "always"}
          onPress={() => answer("always")}
        />
        <Button
          label="Deny"
          kind="danger"
          style={{ flex: 1 }}
          busy={busy === "reject"}
          onPress={() => answer("reject")}
        />
      </View>
    </Card>
  );
}

const st = StyleSheet.create({
  header: {
    flexDirection: "row",
    alignItems: "center",
    gap: 12,
    paddingHorizontal: 14,
    paddingTop: 6,
    paddingBottom: 12,
    borderBottomWidth: 1,
    borderBottomColor: color.hairline,
  },
  headerMid: { flex: 1, alignItems: "center", minWidth: 0 },
  headerTitle: { fontSize: 16, fontWeight: "600", color: color.text },
  renameInput: {
    minWidth: 240,
    textAlign: "center",
    borderBottomWidth: 1,
    borderBottomColor: color.accent,
    paddingVertical: 2,
    outlineStyle: "none",
  } as any,
  headerSub: { fontSize: 12, color: color.muted },
  subRow: { flexDirection: "row", alignItems: "center", gap: 5, maxWidth: "100%" },
  menuButton: { paddingHorizontal: 4 },
  menuDots: { fontSize: 22, color: color.text, marginTop: -6 },
  transcript: { padding: 16, gap: 14 },
  runMeta: { fontSize: 12.5, color: color.muted },
  runHead: { flexDirection: "row", justifyContent: "space-between", gap: 10 },
  runTitle: { fontSize: 14, fontWeight: "600", color: color.text },
  changed: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    paddingHorizontal: 12,
    paddingVertical: 10,
    borderRadius: 12,
    borderWidth: 1,
    borderColor: color.divider,
  },
  changedText: { fontSize: 13, color: color.textDim },
  working: { flexDirection: "row", alignItems: "center", gap: 10, paddingVertical: 4 },
  workingText: { flex: 1, fontSize: 14, color: color.textDim },
  stop: {
    flexDirection: "row",
    alignItems: "center",
    gap: 6,
    paddingHorizontal: 12,
    height: 32,
    borderRadius: 16,
    borderWidth: 1,
    borderColor: color.outline,
  },
  stopText: { fontSize: 13, color: color.text },
  side: {
    flex: 1,
    minHeight: 0,
    minWidth: 0,
    overflow: "hidden",
    borderLeftWidth: 1,
    borderLeftColor: color.hairline,
  },
  chatColumn: { flexGrow: 0, flexShrink: 0, flexBasis: 540, width: 540 },
  diffPane: { flex: 1, minHeight: 0, backgroundColor: "#0f0f12" },
  diffHead: {
    height: 46,
    flexDirection: "row",
    alignItems: "center",
    gap: 10,
    paddingLeft: 16,
    paddingRight: 12,
    borderBottomWidth: 1,
    borderBottomColor: "#222228",
  },
  kindChip: { paddingHorizontal: 7, paddingVertical: 2, borderRadius: 5, backgroundColor: color.field },
  kindText: { fontSize: 11, color: color.textDim },
  diffName: { flexShrink: 1, fontSize: 13, color: color.text },
  closeBox: { width: 26, height: 26, borderRadius: 6, alignItems: "center", justifyContent: "center" },
  paneTabs: {
    flexDirection: "row",
    alignItems: "center",
    gap: 10,
    paddingHorizontal: 12,
    paddingVertical: 8,
    borderBottomWidth: 1,
    borderBottomColor: color.hairline,
  },
  paneTab: { paddingHorizontal: 10, paddingVertical: 5, borderRadius: 7 },
  paneTabOn: { backgroundColor: color.raised },
  paneTabText: { fontSize: 12.5, color: color.muted },
  crumb: { fontSize: 12, color: color.muted, marginTop: 2 },
  diffCard: {
    gap: 6,
    paddingHorizontal: 14,
    paddingVertical: 12,
    borderRadius: 12,
    borderWidth: 1,
    borderColor: color.border,
    backgroundColor: color.card,
  },
  diffCardOn: { borderColor: color.accentBorder, backgroundColor: color.accentCard },
  diffTop: { flexDirection: "row", justifyContent: "space-between", gap: 8 },
  diffBranch: { flex: 1, fontSize: 14, fontFamily: font.mono, color: color.text },
  diffCounts: { fontSize: 14 },
  diffSub: { fontSize: 13, color: color.muted },
  folderTabs: { paddingHorizontal: 24, borderBottomWidth: 1, borderBottomColor: color.hairline },
  runActions: { flexDirection: "row", gap: 16 },
  note: { fontSize: 12.5, color: color.muted, paddingHorizontal: 16, paddingBottom: 4 },
  full: { width: "100%", height: 560 },
});
