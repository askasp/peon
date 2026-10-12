// Hands a chat's diff to the full-screen View (it isn't a file to fetch).

import type { DiffFile } from "./types";

let diff: DiffFile[] = [];
export const setViewDiff = (files: DiffFile[]) => {
  diff = files;
};
export const getViewDiff = () => diff;
