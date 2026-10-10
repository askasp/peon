// Where the user is: the project (and session) on screen, for shortcuts like
// "new session here" and "run this routine".

import { useCallback, useEffect } from "react";
import { useFocusEffect } from "expo-router";

let current: { projectId: number | null; sessionId: string | null } = { projectId: null, sessionId: null };

export const getCurrent = () => current;

/** The current page as the composer's `current` param. */
export const currentPayload = () => ({ project_id: current.projectId, session_id: current.sessionId });

/**
 * Marks the project (and session) on screen. Screens stay mounted under the
 * one on top, so it is set again whenever the screen gets focus (coming back
 * from a session marks the project again), and kept while a sheet like the
 * composer or hands-free covers it. Cleared when the screen goes away.
 */
export function useCurrent(projectId: number | null | undefined, sessionId: string | null = null) {
  useFocusEffect(
    useCallback(() => {
      if (projectId != null) current = { projectId, sessionId };
    }, [projectId, sessionId]),
  );
  useEffect(
    () => () => {
      if (current.projectId === projectId && current.sessionId === sessionId)
        current = { projectId: null, sessionId: null };
    },
    [projectId, sessionId],
  );
}
