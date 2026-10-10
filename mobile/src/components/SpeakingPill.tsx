import { StyleSheet, Text, View } from "react-native";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { Tap } from "./ui";
import { stopSpeaking, useSpeaking } from "@/lib/voice";
import { color } from "@/lib/theme";

/** While Peon talks: "Speaking · Stop", anywhere in the app (Escape stops it on desktop). */
export function SpeakingPill() {
  const speaking = useSpeaking();
  const insets = useSafeAreaInsets();
  if (!speaking) return null;
  return (
    <View style={[st.wrap, { top: insets.top + 8 }]} pointerEvents="box-none">
      <View style={st.pill}>
        <View style={st.wave}>
          {[10, 16, 8, 14, 6].map((h, i) => (
            <View key={i} style={[st.bar, { height: h }]} />
          ))}
        </View>
        <Text style={st.text}>Speaking</Text>
        <Tap onPress={stopSpeaking} style={st.stop} testID="stop-speaking">
          <Text style={st.stopText}>Stop</Text>
        </Tap>
      </View>
    </View>
  );
}

const st = StyleSheet.create({
  wrap: { position: "absolute", left: 0, right: 0, alignItems: "center", zIndex: 200 },
  pill: {
    flexDirection: "row",
    alignItems: "center",
    gap: 10,
    paddingLeft: 14,
    paddingRight: 6,
    height: 38,
    borderRadius: 19,
    backgroundColor: color.raised,
    borderWidth: 1,
    borderColor: color.accentBorder,
  },
  wave: { flexDirection: "row", alignItems: "center", gap: 2 },
  bar: { width: 3, borderRadius: 2, backgroundColor: color.accent },
  text: { fontSize: 13, color: color.text },
  stop: {
    paddingHorizontal: 12,
    height: 28,
    borderRadius: 14,
    backgroundColor: color.pill,
    justifyContent: "center",
  },
  stopText: { fontSize: 13, color: color.text },
});
