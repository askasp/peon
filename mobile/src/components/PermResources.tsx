import { ScrollView, StyleSheet, Text } from "react-native";
import { color, font } from "@/lib/theme";

/** Exactly what a permission request covers: the full command, path or files. */
export function PermResources({ resources }: { resources: string[] }) {
  if (!resources.length) return null;
  return (
    <ScrollView style={st.box} contentContainerStyle={{ padding: 10 }} nestedScrollEnabled>
      <Text style={st.text} selectable>
        {resources.join("\n")}
      </Text>
    </ScrollView>
  );
}

const st = StyleSheet.create({
  box: {
    maxHeight: 180,
    borderRadius: 8,
    backgroundColor: color.bgDeep,
    borderWidth: 1,
    borderColor: color.border,
  },
  text: { fontSize: 12, lineHeight: 18, fontFamily: font.mono, color: color.textSoft },
});
