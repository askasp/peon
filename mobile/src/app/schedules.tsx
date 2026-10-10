import { useState } from "react";
import { StyleSheet, Text, View } from "react-native";
import { BackHeader, Screen, Segmented } from "@/components/ui";
import { ScheduleList } from "@/components/ScheduleList";
import { color } from "@/lib/theme";

// 08 · Schedules across every project, by when they next run.
export default function Schedules() {
  const [scope, setScope] = useState<"me" | "team" | "all">("all");
  return (
    <Screen>
      <BackHeader label="Routines" />
      <View style={st.head}>
        <Text style={st.title}>Schedules</Text>
        <Segmented
          value={scope}
          onChange={setScope}
          options={[
            { value: "me", label: "Only me" },
            { value: "team", label: "Team" },
            { value: "all", label: "All" },
          ]}
        />
      </View>
      <ScheduleList scope={scope} />
    </Screen>
  );
}

const st = StyleSheet.create({
  head: { paddingHorizontal: 18, paddingTop: 4, gap: 14 },
  title: { fontSize: 32, fontWeight: "700", letterSpacing: -0.6, color: color.text },
});
