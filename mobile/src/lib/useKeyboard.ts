import { useEffect, useState } from "react";
import { Dimensions, Keyboard, Platform } from "react-native";

/**
 * The keyboard's height while it is up, else 0. Screens pad their bottom by
 * it: with Android's edge-to-edge the window no longer resizes for the
 * keyboard, and KeyboardAvoidingView doesn't follow.
 */
export function useKeyboardHeight(): number {
  const [height, setHeight] = useState(0);
  useEffect(() => {
    // Measured from the screen's bottom edge: on Android the reported height
    // leaves out the navigation bar under the keyboard.
    const show = Keyboard.addListener(Platform.OS === "ios" ? "keyboardWillShow" : "keyboardDidShow", (e) =>
      setHeight(
        Math.max(e.endCoordinates.height, Dimensions.get("screen").height - e.endCoordinates.screenY),
      ),
    );
    const hide = Keyboard.addListener(Platform.OS === "ios" ? "keyboardWillHide" : "keyboardDidHide", () =>
      setHeight(0),
    );
    return () => {
      show.remove();
      hide.remove();
    };
  }, []);
  return height;
}
