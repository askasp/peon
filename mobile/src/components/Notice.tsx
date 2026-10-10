import { StyleSheet, Text, View } from "react-native";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { Tap } from "./ui";
import { dismissNotice, useNotice } from "@/lib/notice";
import { color } from "@/lib/theme";

/** The current notice (lib/notice), above the tab bar, until dismissed. */
export function Notice() {
  const text = useNotice();
  const insets = useSafeAreaInsets();
  if (!text) return null;
  return (
    <View style={[st.wrap, { bottom: insets.bottom + 90 }]} pointerEvents="box-none">
      <View style={st.card} testID="notice">
        <Text style={st.text}>{text}</Text>
        <Tap onPress={dismissNotice} style={st.ok} testID="notice-ok">
          <Text style={st.okText}>OK</Text>
        </Tap>
      </View>
    </View>
  );
}

const st = StyleSheet.create({
  wrap: { position: "absolute", left: 16, right: 16, alignItems: "center", zIndex: 190 },
  card: {
    maxWidth: 520,
    flexDirection: "row",
    alignItems: "center",
    gap: 12,
    paddingVertical: 12,
    paddingLeft: 16,
    paddingRight: 8,
    borderRadius: 14,
    backgroundColor: color.raised,
    borderWidth: 1,
    borderColor: color.border,
  },
  text: { flex: 1, fontSize: 14, lineHeight: 20, color: color.text },
  ok: { paddingHorizontal: 12, paddingVertical: 8, borderRadius: 10, backgroundColor: color.field },
  okText: { fontSize: 14, fontWeight: "600", color: color.accentText },
});
