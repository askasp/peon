// Images to send with a message, as data URIs. Big photos are shrunk to at
// most 1600px wide JPEGs first, like the web composer does, so they travel
// over the socket quickly.

import { Platform } from "react-native";
import * as ImagePicker from "expo-image-picker";
import { ImageManipulator, SaveFormat } from "expo-image-manipulator";

export type Attachment = { uri: string; name: string };

const MAX = 1600;

/** Opens the photo library (or a file dialog on the web). Null when cancelled. */
export async function pickImage(): Promise<Attachment | null> {
  const result = await ImagePicker.launchImageLibraryAsync({
    mediaTypes: ["images"],
    base64: true,
    quality: 0.8,
  });
  const asset = result.canceled ? null : result.assets?.[0];
  if (!asset) return null;
  const name = asset.fileName ?? "image.jpg";

  if (asset.width > MAX) {
    const image = await ImageManipulator.manipulate(asset.uri).resize({ width: MAX }).renderAsync();
    const saved = await image.saveAsync({ format: SaveFormat.JPEG, compress: 0.8, base64: true });
    return { uri: `data:image/jpeg;base64,${saved.base64}`, name };
  }
  if (asset.uri.startsWith("data:")) return { uri: asset.uri, name };
  return { uri: `data:${asset.mimeType ?? "image/jpeg"};base64,${asset.base64}`, name };
}

/** Web only: a pasted or dropped image file, shrunk in a canvas. */
export function fileToAttachment(file: File): Promise<Attachment> {
  return new Promise((resolve, reject) => {
    if (Platform.OS !== "web") return reject(new Error("web only"));
    const reader = new FileReader();
    reader.onerror = () => reject(new Error("Couldn't read the image."));
    reader.onload = () => {
      const img = new Image();
      img.onerror = () => reject(new Error("Couldn't read the image."));
      img.onload = () => {
        if (img.width <= MAX && file.size < 1_500_000)
          return resolve({ uri: reader.result as string, name: file.name || "image.png" });
        const scale = Math.min(1, MAX / img.width);
        const canvas = document.createElement("canvas");
        canvas.width = Math.round(img.width * scale);
        canvas.height = Math.round(img.height * scale);
        canvas.getContext("2d")!.drawImage(img, 0, 0, canvas.width, canvas.height);
        resolve({ uri: canvas.toDataURL("image/jpeg", 0.8), name: file.name || "image.jpg" });
      };
      img.src = reader.result as string;
    };
    reader.readAsDataURL(file);
  });
}
