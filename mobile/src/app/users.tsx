import { useState } from "react";
import { ScrollView, StyleSheet, Text, TextInput, View } from "react-native";
import {
  BackHeader,
  Button,
  ErrorLine,
  Group,
  LargeTitle,
  Loading,
  Screen,
  SectionLabel,
  Toggle,
} from "@/components/ui";
import { confirm } from "@/lib/confirm";
import { usePeon } from "@/lib/peon";
import { useChannel } from "@/lib/useChannel";
import { useLoad } from "@/lib/useLoad";
import { useWide } from "@/lib/useWide";
import { color } from "@/lib/theme";

type User = { id: number; username: string; admin: boolean };

// Users (admins): add people with a username and password, make admins, remove.
export default function Users() {
  const wide = useWide();
  const me = usePeon((s) => s.user);
  const ch = useChannel("admin");
  const [version, setVersion] = useState(0);
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [admin, setAdmin] = useState(false);
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const { data: users } = useLoad(
    () => (ch.joined ? ch.call<{ users: User[] }>("users").then((r) => r.users) : Promise.resolve(null)),
    [ch.joined, version],
  );

  async function act(fn: () => Promise<unknown>, message?: string) {
    setError(null);
    setNote(null);
    try {
      await fn();
      if (message) setNote(message);
      setVersion((v) => v + 1);
    } catch (e: any) {
      setError(e.message);
    }
  }

  async function create() {
    setBusy(true);
    await act(async () => {
      await ch.call("create_user", { username: username.trim(), password, admin });
      setUsername("");
      setPassword("");
      setAdmin(false);
    }, `${username.trim()} can sign in now.`);
    setBusy(false);
  }

  return (
    <Screen>
      {!wide ? <BackHeader label="Settings" /> : null}
      <ScrollView contentContainerStyle={st.body}>
        <LargeTitle>Users</LargeTitle>
        <ErrorLine message={ch.error ?? error} />
        {note ? <Text style={st.note}>{note}</Text> : null}
        {users == null ? <Loading /> : null}
        <Group>
          {(users ?? []).map((u, i) => (
            <View key={u.id} style={[st.row, i > 0 && st.top]}>
              <Text style={st.name}>{u.username}</Text>
              <Text style={st.meta}>{u.id === me?.id ? "you" : u.admin ? "admin" : "member"}</Text>
              {u.id !== me?.id ? (
                <>
                  <Button
                    label={u.admin ? "Make member" : "Make admin"}
                    kind="secondary"
                    height={30}
                    onPress={() => act(() => ch.call("toggle_admin", { id: u.id }))}
                  />
                  <Button
                    label="Remove"
                    kind="danger"
                    height={30}
                    onPress={async () => {
                      if (await confirm(`Remove ${u.username}?`, "They can't sign in any more.", "Remove"))
                        act(() => ch.call("delete_user", { id: u.id }), `${u.username} removed.`);
                    }}
                  />
                </>
              ) : null}
            </View>
          ))}
        </Group>

        <SectionLabel style={{ paddingTop: 14 }}>Add someone</SectionLabel>
        <Group style={{ padding: 14, gap: 10 }}>
          <TextInput
            value={username}
            onChangeText={setUsername}
            placeholder="Username"
            placeholderTextColor={color.faint}
            autoCapitalize="none"
            style={st.input}
          />
          <TextInput
            value={password}
            onChangeText={setPassword}
            placeholder="Password (8 characters or more)"
            placeholderTextColor={color.faint}
            secureTextEntry
            style={st.input}
          />
          <View style={st.toggle}>
            <Text style={st.name}>Admin</Text>
            <Toggle value={admin} onChange={setAdmin} />
          </View>
          <Button
            label="Add"
            height={42}
            busy={busy}
            disabled={!username.trim() || !password}
            onPress={create}
          />
        </Group>
      </ScrollView>
    </Screen>
  );
}

const st = StyleSheet.create({
  body: { paddingHorizontal: 18, paddingTop: 6, paddingBottom: 40, gap: 8 },
  row: { flexDirection: "row", alignItems: "center", gap: 10, paddingHorizontal: 14, paddingVertical: 10 },
  top: { borderTopWidth: 1, borderTopColor: color.divider },
  name: { flex: 1, fontSize: 15, color: color.text },
  meta: { fontSize: 13, color: color.muted },
  note: { fontSize: 13, color: color.teal },
  input: {
    height: 42,
    borderRadius: 10,
    backgroundColor: color.field,
    paddingHorizontal: 12,
    color: color.text,
    fontSize: 15,
  },
  toggle: { flexDirection: "row", alignItems: "center" },
});
