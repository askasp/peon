import { useCallback, useEffect, useRef, useState } from "react";

/**
 * Data a screen fetches over the socket: fetched again whenever `deps`
 * change (pushes bump counters in the store), and on `reload()` (pull to
 * refresh, which resolves when done).
 */
export function useLoad<T>(fetch: () => Promise<T>, deps: unknown[]) {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<string | null>(null);
  const latest = useRef(fetch);

  useEffect(() => {
    latest.current = fetch;
  });

  useEffect(() => {
    let live = true;
    fetch().then(
      (d) => {
        if (!live) return;
        setData(d);
        setError(null);
      },
      (e) => live && setError(e.message),
    );
    return () => {
      live = false;
    };
    // The caller's deps decide when to fetch again.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);

  const reload = useCallback(async () => {
    try {
      setData(await latest.current());
      setError(null);
    } catch (e: any) {
      setError(e.message);
    }
  }, []);

  return { data, error, reload };
}
