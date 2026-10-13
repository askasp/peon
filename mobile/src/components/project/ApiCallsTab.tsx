// A Project's API calls: one card per API (its file in .peon/api/) with its
// token, the tables it fills and its actions in a Dataset, and a row per call.
// Describe an API at the top and the chat reads its docs and writes the file;
// a row opens the call to edit it and send it by hand.

import { useState } from "react";
import { ScrollView, StyleSheet, Text, TextInput, View } from "react-native";
import { router } from "expo-router";
import { Icon } from "../Icon";
import { Button, ErrorLine, Loading, Tap } from "../ui";
import { ApiCallDetail } from "./ApiCallDetail";
import { ApiServiceCard } from "./ApiServiceCard";
import { confirm } from "@/lib/confirm";
import { singleChat } from "@/lib/folders";
import { useLoad } from "@/lib/useLoad";
import { useWide } from "@/lib/useWide";
import { color, font } from "@/lib/theme";
import type { ApiService } from "@/lib/apiCalls";
import type { ProjectCtx } from "./types";

type Open = { service: string; call: string | null } | { json: string };

export function ApiCallsTab({ ctx, onRan }: { ctx: ProjectCtx; onRan?: () => void }) {
  const wide = useWide();
  const [open, setOpen] = useState<Open | null>(null);
  const [error, setError] = useState<string | null>(null);
  const { data, error: loadError } = useLoad(
    () => ctx.call<{ services: ApiService[] }>("api_calls", {}, 30000).then((r) => r.services),
    [ctx.project.id, ctx.changed],
  );
  // What an edit replied with, until the next load replaces it.
  const [fresh, setFresh] = useState<{ base: ApiService[] | null; list: ApiService[] } | null>(null);
  const services = fresh && fresh.base === data ? fresh.list : data;

  /** Sends an edit; the reply is the new list. Throws so forms can show it. */
  async function edit(event: string, payload: object) {
    const r = await ctx.call<{ services: ApiService[] }>(event, payload, 60000);
    setFresh({ base: data, list: r.services });
    return r.services;
  }

  async function generate(description: string) {
    const r = await ctx.call<{ session_id: string }>("api_generate", { description }, 60000);
    if (singleChat(ctx.project.kind)) onRan?.();
    else router.push(`/session/${r.session_id}`);
  }

  const shownService = open && "service" in open ? services?.find((s) => s.name === open.service) : null;
  if (open && "service" in open && shownService)
    return (
      <ApiCallDetail
        key={`${shownService.name}.${open.call ?? ""}`}
        ctx={ctx}
        service={shownService}
        callName={open.call}
        onBack={() => setOpen(null)}
        onSaved={(name) => setOpen({ service: shownService.name, call: name })}
        save={(content) => edit("api_save", { service: shownService.name, content })}
      />
    );

  const jsonService = open && "json" in open ? services?.find((s) => s.name === open.json) : null;
  if (jsonService)
    return (
      <JsonEditor
        service={jsonService}
        wide={wide}
        onBack={() => setOpen(null)}
        save={async (content) => {
          await edit("api_save", { service: jsonService.name, content });
          setOpen(null);
        }}
        remove={async () => {
          await edit("api_delete", { service: jsonService.name });
          setOpen(null);
        }}
      />
    );

  return (
    <ScrollView
      contentContainerStyle={[st.body, wide && { paddingHorizontal: 28 }]}
      keyboardShouldPersistTaps="handled"
    >
      {ctx.canEdit ? <GenerateBox onGenerate={generate} empty={services?.length === 0} /> : null}
      <ErrorLine message={loadError ?? error} />
      {services == null ? <Loading /> : null}
      {services?.length === 0 ? <Text style={st.empty}>No API calls yet.</Text> : null}

      {(services ?? []).map((s) => (
        <ApiServiceCard
          key={s.name}
          service={s}
          project={ctx.project.name}
          canEdit={ctx.canEdit}
          dataset={ctx.project.kind === "dataset"}
          wide={wide}
          edit={edit}
          onCall={(call) => setOpen({ service: s.name, call })}
          onFile={() => setOpen({ json: s.name })}
          onMove={async () => {
            setError(null);
            try {
              await edit("api_move", { service: s.name });
            } catch (e: any) {
              setError(e.message);
            }
          }}
        />
      ))}

      {services?.some((s) => s.secret) ? (
        <View style={st.who} testID="api-token-note">
          <Text style={st.whoTitle}>Who uses these tokens</Text>
          <Text style={st.whoText}>
            Chats, views and scheduled runs in {ctx.project.name}. No other Project can see or use them.
          </Text>
          {ctx.project.scope === "team" ? (
            <Text style={st.whoText}>
              {ctx.project.name} is shared with your team. Their changes post through these tokens, so the
              services show them as the token&apos;s owner.
            </Text>
          ) : null}
        </View>
      ) : null}
    </ScrollView>
  );
}

/** Describe what to call; the chat reads the docs and writes the file. */
function GenerateBox({ onGenerate, empty }: { onGenerate: (text: string) => Promise<void>; empty: boolean }) {
  const [text, setText] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  async function go() {
    setBusy(true);
    setError(null);
    try {
      await onGenerate(text.trim());
      setText("");
    } catch (e: any) {
      setError(e.message);
    }
    setBusy(false);
  }
  return (
    <View style={[st.generate, empty && st.generateEmpty]}>
      <View style={st.generateRow}>
        <Icon name="compose" size={16} color={color.accentText} />
        <TextInput
          value={text}
          onChangeText={setText}
          placeholder={
            empty
              ? "Add an API, e.g. Front: the Support inbox's conversations"
              : "+ Add API: name it and what to read or do"
          }
          returnKeyType="go"
          placeholderTextColor={color.faint}
          style={st.generateInput}
          onSubmitEditing={() => text.trim() && go()}
          testID="api-generate-text"
        />
        <Button
          label="Generate"
          kind="accent"
          height={34}
          busy={busy}
          disabled={!text.trim()}
          onPress={go}
          testID="api-generate"
        />
      </View>
      <ErrorLine message={error} />
    </View>
  );
}

/** The service's whole file: base URL, auth, rate limit, every call. */
function JsonEditor({
  service,
  wide,
  onBack,
  save,
  remove,
}: {
  service: ApiService;
  wide: boolean;
  onBack: () => void;
  save: (content: string) => Promise<void>;
  remove: () => Promise<void>;
}) {
  const [text, setText] = useState(service.raw);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  async function act(fn: () => Promise<void>) {
    setBusy(true);
    setError(null);
    try {
      await fn();
    } catch (e: any) {
      setError(e.message);
      setBusy(false);
    }
  }
  return (
    <ScrollView contentContainerStyle={[st.body, wide && { paddingHorizontal: 28 }]}>
      <View style={st.top}>
        <Tap onPress={onBack} hitSlop={8} style={st.back} testID="api-back">
          <Icon name="back" size={14} color={color.muted} strokeWidth={2.4} />
          <Text style={st.backText}>API calls</Text>
        </Tap>
        <Text style={st.title} numberOfLines={1}>
          {service.path}
        </Text>
        <View style={{ flex: 1 }} />
        <Tap
          hitSlop={8}
          onPress={async () => {
            if (await confirm(`Delete ${service.name}?`, "Procedures that call it stop working.", "Delete"))
              act(remove);
          }}
        >
          <Text style={[st.link, { color: color.red }]}>Delete</Text>
        </Tap>
      </View>
      <TextInput
        value={text}
        onChangeText={setText}
        multiline
        autoCapitalize="none"
        autoCorrect={false}
        spellCheck={false}
        style={st.code}
        testID="api-json-text"
      />
      <ErrorLine message={error} />
      <View style={{ flexDirection: "row", gap: 10 }}>
        <Button
          label="Save"
          height={38}
          busy={busy}
          disabled={text === service.raw}
          onPress={() => act(() => save(text))}
          testID="api-json-save"
        />
      </View>
    </ScrollView>
  );
}

const st = StyleSheet.create({
  body: { paddingHorizontal: 16, paddingTop: 14, paddingBottom: 40, gap: 18, maxWidth: 900, width: "100%" },
  empty: { fontSize: 13, color: color.muted },
  who: { gap: 6, paddingHorizontal: 4 },
  whoTitle: { fontSize: 13, fontWeight: "600", color: color.textSoft },
  whoText: { fontSize: 12.5, lineHeight: 18, color: color.muted },
  generate: {
    gap: 8,
    padding: 10,
    borderRadius: 12,
    backgroundColor: color.card,
    borderWidth: 1,
    borderColor: color.border,
  },
  generateEmpty: { borderColor: color.accentBorder, backgroundColor: color.accentCard },
  generateRow: { flexDirection: "row", alignItems: "center", gap: 10 },
  generateInput: {
    flex: 1,
    flexBasis: 0,
    minWidth: 0,
    height: 34,
    color: color.text,
    fontSize: 14,
    outlineStyle: "none",
  } as any,
  link: { fontSize: 13, color: color.accentText },
  top: { flexDirection: "row", alignItems: "center", gap: 10 },
  back: { flexDirection: "row", alignItems: "center", gap: 3 },
  backText: { fontSize: 13, color: color.muted },
  title: { fontFamily: font.mono, fontSize: 15, fontWeight: "600", color: color.text, flexShrink: 1 },
  code: {
    minHeight: 360,
    borderRadius: 10,
    backgroundColor: "#17171c",
    borderWidth: 1,
    borderColor: color.border,
    padding: 12,
    color: color.text,
    fontFamily: font.mono,
    fontSize: 12.5,
    lineHeight: 18,
    textAlignVertical: "top",
    outlineStyle: "none",
  } as any,
});
