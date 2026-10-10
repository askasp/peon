import { useState } from "react";
import { StyleSheet, Text, TextInput, View } from "react-native";
import { AppIcon } from "@/components/Icon";
import { Button, ErrorLine, Screen } from "@/components/ui";
import { getState, login } from "@/lib/peon";
import { useKeyboardHeight } from "@/lib/useKeyboard";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { color, font } from "@/lib/theme";

// 01 · Connect. The design's SSO and QR options come later; the server has
// username and password today.
export default function Connect() {
  const [server, setServer] = useState(getState().server ?? "");
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const keyboard = useKeyboardHeight();
  const insets = useSafeAreaInsets();

  async function go() {
    if (!server.trim() || !username.trim() || !password) {
      setError("Fill in the server, your username and password.");
      return;
    }
    setBusy(true);
    setError(null);
    try {
      await login(server, username, password);
    } catch (e: any) {
      setError(e.message);
      setBusy(false);
    }
  }

  return (
    <Screen bottom>
      <View style={{ flex: 1, paddingBottom: Math.max(0, keyboard - insets.bottom) }}>
        {/* With the keyboard up there is only room for a small mark. */}
        <View style={[st.hero, keyboard > 0 && { gap: 8 }]}>
          <AppIcon size={keyboard > 0 ? 44 : 88} />
          <Text style={[st.word, keyboard > 0 && { fontSize: 26 }]}>peon</Text>
          {keyboard > 0 ? null : <Text style={st.lead}>Connect to your team’s server</Text>}
        </View>
        <View style={st.form}>
          <Field
            label="Server"
            value={server}
            onChange={setServer}
            placeholder="peon.stadler.no"
            testID="server"
          />
          <Field
            label="Username"
            value={username}
            onChange={setUsername}
            placeholder="aksel"
            testID="username"
          />
          <Field
            label="Password"
            value={password}
            onChange={setPassword}
            secure
            onSubmit={go}
            testID="password"
          />
          <ErrorLine message={error} />
          <Button label="Continue" onPress={go} busy={busy} height={52} testID="continue" />
          <Text style={st.hint}>Same login as on the web.</Text>
        </View>
      </View>
    </Screen>
  );
}

function Field({
  label,
  value,
  onChange,
  placeholder,
  secure,
  onSubmit,
  testID,
}: {
  label: string;
  value: string;
  onChange: (v: string) => void;
  placeholder?: string;
  secure?: boolean;
  onSubmit?: () => void;
  testID?: string;
}) {
  const [focused, setFocused] = useState(false);
  return (
    <View style={{ gap: 6 }}>
      <Text style={st.label}>{label}</Text>
      <TextInput
        testID={testID}
        value={value}
        onChangeText={onChange}
        placeholder={placeholder}
        placeholderTextColor={color.faint}
        secureTextEntry={secure}
        autoCapitalize="none"
        autoCorrect={false}
        keyboardType={label === "Server" ? "url" : "default"}
        onFocus={() => setFocused(true)}
        onBlur={() => setFocused(false)}
        onSubmitEditing={onSubmit}
        returnKeyType={onSubmit ? "go" : "next"}
        style={[st.input, focused && { borderColor: color.accent }]}
      />
    </View>
  );
}

const st = StyleSheet.create({
  hero: { flex: 1, alignItems: "center", justifyContent: "center", gap: 18, paddingHorizontal: 28 },
  word: { fontFamily: font.brand, fontSize: 40, letterSpacing: -1.6, color: color.text },
  lead: { fontSize: 15, color: color.muted },
  form: { paddingHorizontal: 22, paddingBottom: 32, gap: 12 },
  label: { fontSize: 13, color: color.muted, paddingLeft: 4 },
  input: {
    height: 52,
    borderRadius: 12,
    backgroundColor: color.card,
    borderWidth: 1,
    borderColor: color.border,
    paddingHorizontal: 16,
    fontSize: 16,
    color: color.text,
  },
  hint: { fontSize: 13, color: color.faint, textAlign: "center", paddingTop: 6 },
});
