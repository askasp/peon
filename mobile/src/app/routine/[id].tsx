import { useLocalSearchParams } from "expo-router";
import { ProjectView } from "@/components/project/ProjectView";

// 07 · Routine and runs: run it (with inputs), its runs, chats, skills, schedules and settings.
export default function RoutineScreen() {
  const { id, tab } = useLocalSearchParams<{ id: string; tab?: string }>();
  return <ProjectView id={id} back="Procedures" initialTab={tab} />;
}
