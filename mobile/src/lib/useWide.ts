import { Platform, useWindowDimensions } from "react-native";

/** True in a desktop-sized browser window: the sidebar layout instead of tabs. */
export function useWide(): boolean {
  const { width } = useWindowDimensions();
  return Platform.OS === "web" && width >= 900;
}
