import { useLocalSearchParams } from "expo-router";
import { ProjectView } from "@/components/project/ProjectView";

// An Operations Project: its procedures and runs; `chat` opens a procedure's
// chat, `run` a run's (on the phone each is its own screen).
export default function RoutineScreen() {
  const { id, tab, chat, run } = useLocalSearchParams<{
    id: string;
    tab?: string;
    chat?: string;
    run?: string;
  }>();
  return <ProjectView id={id} back="Procedures" initialTab={tab} chat={chat} run={run} />;
}
