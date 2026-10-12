import { useLocalSearchParams } from "expo-router";
import { SessionChat } from "@/components/session/SessionChat";

// 05 · Session: the conversation, live; reply by typing or talking.
export default function SessionScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  return <SessionChat id={id} />;
}
