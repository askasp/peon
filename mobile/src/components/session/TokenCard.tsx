// The card the agent's `ask_token` call shows in a chat: paste a token and it
// goes straight to the Project's secrets (`api_secret`), never into the chat.
// The chat that asked is told it's saved; the agent can call with it but
// never read it.

import { useEffect, useState } from "react";
import { Linking, StyleSheet, Text, TextInput, View } from "react-native";
import { Icon } from "../Icon";
import { Button, ErrorLine, Tap } from "../ui";
import { ago } from "@/lib/time";
import { color, font } from "@/lib/theme";
import type { ApiToken } from "@/lib/apiCalls";
import type { ProjectCtx } from "../project/types";

export type TokenAsk = { name: string; service: string; what?: string | null; link?: string | null };

export function TokenCard({
  ask,
  call,
  sessionId,
}: {
  ask: TokenAsk;
  /** The Project's channel; without it (a chat shown read-only) the card only names the token. */
  call?: ProjectCtx["call"];
  sessionId?: string;
}) {
  const [state, setState] = useState<{ token: ApiToken | null; project: string } | null>(null);
  const [value, setValue] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!call) return;
    let live = true;
    call<{ token: ApiToken | null; project: string }>("api_token", { name: ask.name }, 15000)
      .then((r) => live && setState(r))
      .catch(() => {});
    return () => {
      live = false;
    };
  }, [call, ask.name]);

  async function save() {
    if (!call) return;
    setBusy(true);
    setError(null);
    try {
      await call("api_secret", { name: ask.name, value, session_id: sessionId }, 30000);
      const r = await call<{ token: ApiToken | null; project: string }>(
        "api_token",
        { name: ask.name },
        15000,
      );
      setState(r);
      setValue("");
    } catch (e: any) {
      setError(e.message);
    }
    setBusy(false);
  }

  const project = state?.project ?? "this Project";

  // Saved: one quiet line with the name and where it lives, never the value.
  if (state?.token)
    return (
      <View style={st.saved} testID={`token-saved-${ask.name}`}>
        <Icon name="lock" size={13} color={color.accentText} />
        <Text style={st.savedText} numberOfLines={2}>
          <Text style={st.mono}>{ask.name}</Text> saved to {project}
          {state.token.set_by ? ` by ${state.token.set_by}` : ""} · {ago(state.token.updated_at, true)}
        </Text>
      </View>
    );

  return (
    <View style={st.card} testID={`token-card-${ask.name}`}>
      <View style={st.head}>
        <View style={st.lock}>
          <Icon name="lock" size={14} color={color.needs} />
        </View>
        <Text style={st.title}>
          Token for <Text style={st.mono}>{ask.service}</Text>
        </Text>
        <Text style={st.only}>{state ? `${project} only` : ""}</Text>
      </View>
      {ask.what ? <Text style={st.what}>{ask.what}</Text> : null}
      {call ? (
        <>
          <TextInput
            value={value}
            onChangeText={setValue}
            placeholder={`Paste ${ask.name}`}
            placeholderTextColor={color.faint}
            secureTextEntry
            autoCapitalize="none"
            autoCorrect={false}
            style={st.input}
            onSubmitEditing={() => value.trim() && save()}
            testID={`token-input-${ask.name}`}
          />
          <View style={st.row}>
            <Button
              label={`Save to ${project}`}
              height={34}
              busy={busy}
              disabled={!value.trim()}
              onPress={save}
              testID={`token-save-${ask.name}`}
            />
            {ask.link ? (
              <Tap onPress={() => Linking.openURL(ask.link!)} hitSlop={8}>
                <Text style={st.link}>Create one ↗</Text>
              </Tap>
            ) : null}
          </View>
        </>
      ) : null}
      <ErrorLine message={error} />
      <Text style={st.note}>Saved to {project}&apos;s secrets, never to the chat.</Text>
    </View>
  );
}

const st = StyleSheet.create({
  card: {
    gap: 10,
    padding: 14,
    borderRadius: 14,
    backgroundColor: color.needsCard,
    borderWidth: 1,
    borderColor: color.needsBorder,
    maxWidth: 560,
  },
  head: { flexDirection: "row", alignItems: "center", gap: 10 },
  lock: {
    width: 28,
    height: 28,
    borderRadius: 8,
    alignItems: "center",
    justifyContent: "center",
    backgroundColor: color.needsWash,
  },
  title: { flex: 1, fontSize: 14.5, fontWeight: "600", color: color.text },
  mono: { fontFamily: font.mono },
  only: { fontSize: 12, color: color.muted },
  what: { fontSize: 13, lineHeight: 19, color: color.textDim },
  input: {
    height: 40,
    borderRadius: 10,
    backgroundColor: color.field,
    borderWidth: 1,
    borderColor: color.border,
    paddingHorizontal: 12,
    color: color.text,
    fontFamily: font.mono,
    fontSize: 13,
    outlineStyle: "none",
  } as any,
  row: { flexDirection: "row", alignItems: "center", gap: 14 },
  link: { fontSize: 13, color: color.accentText },
  note: { fontSize: 12, color: color.faint },
  saved: {
    flexDirection: "row",
    alignItems: "center",
    gap: 8,
    alignSelf: "flex-start",
    paddingHorizontal: 10,
    paddingVertical: 6,
    borderRadius: 8,
    backgroundColor: color.accentCard,
    borderWidth: 1,
    borderColor: color.accentBorder,
  },
  savedText: { fontSize: 12.5, color: color.textSoft, flexShrink: 1 },
});
