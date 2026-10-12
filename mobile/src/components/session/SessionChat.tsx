import { setViewing, usePeon } from "@/lib/peon";
import { useEffect, useMemo, useRef, useState } from "react";
import {
  ActivityIndicator,
  FlatList,
  Image,
  Platform,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from "react-native";
import { router } from "expo-router";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { Icon } from "@/components/Icon";
import { PickSheet, Sheet } from "@/components/Sheet";
import { BlockView, toBlocks, type Block } from "@/components/Transcript";
import { DiffView } from "@/components/session/DiffView";
import { FileView, treeCall } from "@/components/project/FilesTab";
import { FolderPane } from "@/components/project/FolderPane";
import type { ProjectCtx } from "@/components/project/types";
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
import { folderHref, singleChat } from "@/lib/folders";
import { setViewDiff } from "@/lib/viewStore";
import { inputsLabel, runLine, runWho } from "@/lib/runs";
import { say, stopSpeaking } from "@/lib/voice";
import { color, font } from "@/lib/theme";
import type { Attached } from "@/lib/attach";
import type { Message, SessionOptions, SessionSummary } from "@/lib/types";

const modelValue = (m: any): string | null =>
  m && typeof m === "object" && m.id ? `${m.providerID}/${m.id}` : typeof m === "string" ? m : null;

/**
 * A single-chat Folder's chat (see `singleChat`): its screen has the header, the
 * pane shows the Folder's files, and the chats it had before sit above.
 */
export type FolderChat = {
  /** The Folder's channel, joined by its screen, and what it says changed. */
  ctx: Pick<ProjectCtx, "call" | "changed" | "project">;
  earlier: SessionSummary[];
  /** "Chat about this": the file in the composer. */
  attached: Attached | null;
  onAttach: (file: Attached | null) => void;
};

// 05 · Session: the conversation, live; reply by typing or talking.
export function SessionChat({ id, folder: inFolder }: { id: string; folder?: FolderChat }) {
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
  // Stick to the bottom: follow new output until the user scrolls up, and
  // again once they scroll back to the end. Opening a session starts there.
  const follow = useRef(true);
  useEffect(() => {
    follow.current = true;
  }, [id, s.joined]);
  // On the web scrollToEnd aims at FlatList's estimated item sizes and stops short
  // while the last message grows, so scroll the element itself to its real end.
  const toEnd = () => {
    if (!follow.current) return;
    const node = (list.current as any)?.getScrollableNode?.();
    if (Platform.OS === "web" && node) node.scrollTop = node.scrollHeight;
    else list.current?.scrollToEnd({ animated: false });
  };
  // The keyboard opening shrinks the list; keep the end in view. Typing itself
  // must not scroll (that reads as the chat jittering), so only the keyboard.
  const toEndRef = useRef(toEnd);
  useEffect(() => {
    toEndRef.current = toEnd;
  });
  useEffect(() => {
    toEndRef.current();
  }, [keyboard]);
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
  const own = useChannel(s.project && !inFolder ? `project:${s.project.id}` : null);
  const folder = inFolder ? { joined: true, call: inFolder.ctx.call } : own;
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
    if (inFolder) return setPaneFile(r);
    setOpened((o) => (o.includes(r) ? o : [...o, r]));
    setView(r);
    setPaneHidden(false);
  };
  // In a Folder: the file beside the chat, and the newest one the agent wrote.
  const [paneFile, setPaneFile] = useState<string | null>(null);
  // Desktop: what the pane shows goes along with each message, until ×.
  const [inView, setInView] = useState<Attached | null>(null);
  const [dismissed, setDismissed] = useState<string | null>(null);
  const viewKey = inView && `${inView.path}·${inView.view ?? ""}`;
  const attached = wide ? (viewKey && viewKey !== dismissed ? inView : null) : (inFolder?.attached ?? null);
  const written = all.findLast((b) => b.kind === "file");
  const lastWritten = written?.kind === "file" ? rel(written.path) : null;
  const [shownWritten, setShownWritten] = useState<string | null>(null);
  if (inFolder && lastWritten !== shownWritten) {
    setShownWritten(lastWritten);
    if (lastWritten) setPaneFile(lastWritten);
  }
  const offset = useRef(0);
  const height = useRef(600);
  useCurrent(s.project?.id, id);
  // A single-chat Folder's chat lives in the Folder, beside its files.
  const project = s.project;
  useEffect(() => {
    if (!inFolder && project && singleChat(project.kind))
      router.replace({ pathname: "/project/[id]", params: { id: String(project.id) } } as any);
  }, [inFolder, project]);

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
  const context = contextUsed(s.items, options, modelValue(s.session?.model));

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
  useCommand("session:last", () => {
    follow.current = true;
    toEnd();
  });
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
  // Messages before the last compaction stay, faded: the agent works from its summary.
  const lastCompaction = blocks.map((b) => b.kind).lastIndexOf("compaction");
  const current =
    view && (view === "diff" ? changed > 0 : opened.includes(view)) ? view : changed ? "diff" : opened[0];
  const pane = wide && (inFolder ? true : !paneHidden && current != null);
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
      extraData={pane ? (inFolder ? paneFile : current) : null}
      keyExtractor={(b) => b.key}
      renderItem={({ item, index }) =>
        index < lastCompaction ? (
          <View style={st.compacted}>
            <BlockView block={item} onFile={openFile} rel={rel} />
          </View>
        ) : item.kind === "note" && item.key === FOLD ? (
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
            viewing={inFolder ? (pane ? paneFile : null) : pane && current !== "diff" ? current : null}
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
        const fromEnd = contentSize.height - layoutMeasurement.height - contentOffset.y;
        // Only a move up stops following: scrolls to the end and growth only move
        // down, so their (late) events can't turn it off.
        const up = contentOffset.y < offset.current;
        offset.current = contentOffset.y;
        height.current = layoutMeasurement.height;
        if (fromEnd <= 40) follow.current = true;
        else if (up) follow.current = false;
        // Near the top: pull in the page of messages just above.
        if (contentOffset.y < 160) s.loadOlder();
      }}
      scrollEventThrottle={16}
      onContentSizeChange={toEnd}
      ListHeaderComponent={
        <>
          {s.loadingOlder ? (
            <View style={st.earlierLoad}>
              <ActivityIndicator size="small" color={color.muted} />
            </View>
          ) : null}
          {inFolder?.earlier.length ? (
            <EarlierChats call={inFolder.ctx.call} chats={inFolder.earlier} />
          ) : s.run && run ? (
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
          ) : null}
        </>
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

  const chatBar = (
    <View style={[st.chatBar, !wide && { paddingHorizontal: 18 }]}>
      <Text style={st.chatBarTitle}>Chat</Text>
      {wide && s.status === "waiting" ? <Badge label="Needs you" tint="needs" /> : null}
      <View style={{ flex: 1 }} />
      {context != null ? (
        <View style={st.meter} testID="context-meter">
          <View style={st.meterTrack}>
            <View
              style={[
                st.meterFill,
                {
                  width: `${Math.max(context, 2)}%`,
                  backgroundColor: context >= 85 ? color.needs : context < 50 ? color.accent : color.muted,
                },
              ]}
            />
          </View>
          <Text style={st.meterText}>{context}% context</Text>
        </View>
      ) : null}
      <Tap onPress={compact} style={st.compactButton} testID="compact">
        <Text style={st.compactText}>Compact</Text>
      </Tap>
    </View>
  );

  const body = (
    <View style={{ flex: 1, flexDirection: "row", minHeight: 0 }}>
      <View
        style={[
          { flex: 1, paddingBottom: keyboard, minWidth: 0 },
          pane && (inFolder ? st.folderChatColumn : st.chatColumn),
        ]}
      >
        <View style={!inFolder && wide ? st.conversationWide : st.conversation}>
          {inFolder ? chatBar : null}
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
              follow.current = true;
              return s.send(text, files);
            }}
            findFiles={(query) => call("find_files", { query })}
            setAgent={(agent) => call("set_agent", { agent })}
            setModel={(model, variant) => call("set_model", { model, ...(variant ? { variant } : {}) })}
            onError={setError}
            attached={attached}
            keepAttached={wide}
            onDetach={() => (wide ? setDismissed(viewKey) : inFolder?.onAttach(null))}
          />
        </View>
      </View>
      {/* Desktop, in a Folder: its files beside the chat. */}
      {pane && inFolder ? (
        <View style={st.side}>
          <FolderPane
            ctx={{ ...inFolder.ctx, changed: inFolder.ctx.changed + all.length }}
            file={paneFile}
            onFile={setPaneFile}
            onShown={(path, view) => setInView({ path, view })}
          />
        </View>
      ) : null}
      {/* Desktop: the View beside the conversation, the diff or a file the agent wrote. */}
      {pane && !inFolder ? (
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
                  <Tap key={f} onPress={() => setView(f)} style={[st.paneTab, current === f && st.paneTabOn]}>
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
  );

  const imageSheet = (
    <Sheet visible={image != null} onClose={() => setImage(null)} width={900}>
      {image ? <Image source={{ uri: image }} style={st.full} resizeMode="contain" /> : null}
    </Sheet>
  );

  if (inFolder)
    return (
      <>
        {body}
        {imageSheet}
      </>
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

      {body}
      {imageSheet}

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

/**
 * How full the model's context is, in percent: what the last reply since the
 * last compaction read and wrote, over what the model holds. Null when unknown.
 */
function contextUsed(items: Message[], options: SessionOptions | null, model: string | null) {
  const limit = (model ? options?.models.find((m) => m.value === model) : options?.default)?.context;
  if (!limit) return null;
  for (let i = items.length - 1; i >= 0; i--) {
    const m = items[i];
    if (m.type === "compaction") return 0;
    const t = m.type === "assistant" ? m.tokens : null;
    if (t && t.input + t.output > 0) {
      const used = t.input + t.output + t.reasoning + t.cache.read + t.cache.write;
      return Math.min(100, Math.round((used / limit) * 100));
    }
  }
  return 0;
}

/** A Folder's chats from before it had one chat, oldest first, each opening to its messages. */
function EarlierChats({ call, chats }: { call: FolderChat["ctx"]["call"]; chats: SessionSummary[] }) {
  return (
    <View style={st.earlier}>
      {chats.map((c) => (
        <EarlierChat key={c.id} call={call} chat={c} />
      ))}
      <View style={st.earlierRule} />
    </View>
  );
}

function EarlierChat({ call, chat }: { call: FolderChat["ctx"]["call"]; chat: SessionSummary }) {
  const [open, setOpen] = useState(false);
  const [blocks, setBlocks] = useState<Block[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  async function toggle() {
    setOpen(!open);
    if (blocks || open) return;
    try {
      const r = await call<{ messages: Message[] }>("chat_history", { session_id: chat.id }, 60000);
      setBlocks(toBlocks(r.messages));
    } catch (e: any) {
      setError(e.message);
    }
  }
  const when = chat.created
    ? new Date(chat.created).toLocaleDateString("en-GB", { day: "numeric", month: "short" })
    : "";
  return (
    <View style={{ gap: 12 }}>
      <Tap onPress={toggle} style={st.earlierHead} kb="row">
        <Text style={st.earlierTitle} numberOfLines={1}>
          {chat.title}
        </Text>
        <Text style={st.earlierWhen}>{when}</Text>
        <Text style={st.earlierWhen}>{open ? "⌄" : "›"}</Text>
      </Tap>
      <ErrorLine message={open ? error : null} />
      {open && !blocks && !error ? <ActivityIndicator size="small" color={color.muted} /> : null}
      {open && blocks
        ? blocks.map((b) => (
            <View key={b.key} style={st.compacted}>
              <BlockView block={b} />
            </View>
          ))
        : null}
    </View>
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
  transcript: { padding: 16, paddingBottom: 44, gap: 14 },
  earlierLoad: { alignItems: "center", paddingVertical: 10 },
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
  conversation: { flex: 1, minWidth: 0 },
  // A session's own screen fills the content area; keep it as narrow as the
  // Folder's chat list (SessionsTab) instead of stretching across a wide window.
  conversationWide: { flex: 1, width: "100%", maxWidth: 868, alignSelf: "center", minWidth: 0 },
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
  chatBar: {
    height: 44,
    flexDirection: "row",
    alignItems: "center",
    gap: 8,
    paddingHorizontal: 16,
    borderBottomWidth: 1,
    borderBottomColor: color.hairline,
  },
  chatBarTitle: { fontSize: 13, fontWeight: "600", color: color.text },
  meter: { flexDirection: "row", alignItems: "center", gap: 6 },
  meterTrack: { width: 44, height: 4, borderRadius: 2, backgroundColor: color.raised, overflow: "hidden" },
  meterFill: { height: 4, borderRadius: 2 },
  meterText: { fontSize: 12, color: color.faint, fontVariant: ["tabular-nums"] },
  compactButton: {
    paddingHorizontal: 10,
    paddingVertical: 4,
    borderRadius: 6,
    borderWidth: 1,
    borderColor: "#2c2c34",
  },
  compactText: { fontSize: 12, color: color.textSoft },
  folderChatColumn: {
    flexGrow: 0,
    flexShrink: 0,
    flexBasis: 430,
    width: 430,
    borderRightWidth: 1,
    borderRightColor: color.hairline,
  },
  compacted: { opacity: 0.45 },
  earlier: { gap: 12, paddingBottom: 4 },
  earlierHead: {
    flexDirection: "row",
    alignItems: "center",
    gap: 10,
    paddingHorizontal: 12,
    paddingVertical: 9,
    borderRadius: 10,
    borderWidth: 1,
    borderColor: color.divider,
  },
  earlierTitle: { flex: 1, fontSize: 13, color: color.textDim },
  earlierWhen: { fontSize: 12, color: color.faint },
  earlierRule: { height: 1, backgroundColor: color.hairline, marginVertical: 4 },
  full: { width: "100%", height: 560 },
});
