import { useLocalSearchParams } from "expo-router";
import { ProjectView } from "@/components/project/ProjectView";

// 04 · Project: its sessions, skills, schedules and settings.
export default function ProjectScreen() {
  const { id, tab } = useLocalSearchParams<{ id: string; tab?: string }>();
  return <ProjectView id={id} back="Projects" initialTab={tab} />;
}
