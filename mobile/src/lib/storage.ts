// Small key/value storage: the keychain/keystore on phones, localStorage on the web.

import { Platform } from "react-native";
import * as SecureStore from "expo-secure-store";

const web = Platform.OS === "web";

export async function getItem(key: string): Promise<string | null> {
  if (!web) return SecureStore.getItemAsync(key);
  try {
    return localStorage.getItem(key);
  } catch {
    return null;
  }
}

export async function setItem(key: string, value: string): Promise<void> {
  if (!web) return SecureStore.setItemAsync(key, value);
  try {
    localStorage.setItem(key, value);
  } catch {}
}

export async function deleteItem(key: string): Promise<void> {
  if (!web) return SecureStore.deleteItemAsync(key);
  try {
    localStorage.removeItem(key);
  } catch {}
}
