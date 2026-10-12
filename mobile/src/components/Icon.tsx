import Svg, { Circle, Path, Rect } from "react-native-svg";

export type IconName =
  | "inbox"
  | "folder"
  | "file"
  | "external"
  | "compose"
  | "plus"
  | "mic"
  | "micOff"
  | "clock"
  | "sliders"
  | "phone"
  | "speaker"
  | "back"
  | "play"
  | "stop"
  | "chevron"
  | "send"
  | "keyboard"
  | "close"
  | "lock";

type Props = { name: IconName; size?: number; color?: string; strokeWidth?: number };

// The design's icons, drawn on their original view boxes.
export function Icon({ name, size = 24, color = "currentColor", strokeWidth }: Props) {
  const stroke = {
    stroke: color,
    fill: "none" as const,
    strokeLinecap: "round" as const,
    strokeLinejoin: "round" as const,
  };

  switch (name) {
    case "lock":
      return (
        <Svg width={size} height={size} viewBox="0 0 24 24">
          <Rect x={5} y={11} width={14} height={9} rx={2} {...stroke} strokeWidth={strokeWidth ?? 1.8} />
          <Path d="M8 11V8a4 4 0 0 1 8 0v3" {...stroke} strokeWidth={strokeWidth ?? 1.8} />
        </Svg>
      );
    case "inbox":
      return (
        <Svg width={size} height={size} viewBox="0 0 24 24">
          <Path d="M3 13l3-8h12l3 8v6H3z" {...stroke} strokeWidth={strokeWidth ?? 1.8} />
          <Path d="M3 13h5l1 2h6l1-2h5" {...stroke} strokeWidth={strokeWidth ?? 1.8} />
        </Svg>
      );
    case "folder":
      return (
        <Svg width={size} height={size} viewBox="0 0 24 24">
          <Path d="M3 6h6l2 2h10v11H3z" {...stroke} strokeWidth={strokeWidth ?? 1.8} />
        </Svg>
      );
    case "file":
      return (
        <Svg width={size} height={size} viewBox="0 0 24 24">
          <Path d="M6 3h8l4 4v14H6z" {...stroke} strokeWidth={strokeWidth ?? 1.8} />
          <Path d="M14 3v4h4" {...stroke} strokeWidth={strokeWidth ?? 1.8} />
        </Svg>
      );
    case "external":
      return (
        <Svg width={size} height={size} viewBox="0 0 24 24">
          <Path d="M14 4h6v6M20 4l-9 9" {...stroke} strokeWidth={strokeWidth ?? 1.8} />
          <Path d="M18 14v6H4V6h6" {...stroke} strokeWidth={strokeWidth ?? 1.8} />
        </Svg>
      );
    case "plus":
      return (
        <Svg width={size} height={size} viewBox="0 0 24 24">
          <Path d="M12 5v14M5 12h14" {...stroke} strokeWidth={strokeWidth ?? 2.4} />
        </Svg>
      );
    case "compose":
      return (
        <Svg width={size} height={size} viewBox="0 0 24 24">
          <Path d="M4 20h4L19 9l-4-4L4 16z" {...stroke} strokeWidth={strokeWidth ?? 2} />
          <Path d="M13.5 6.5l4 4" {...stroke} strokeWidth={strokeWidth ?? 2} />
        </Svg>
      );
    case "clock":
      return (
        <Svg width={size} height={size} viewBox="0 0 24 24">
          <Circle cx={12} cy={12} r={8} {...stroke} strokeWidth={strokeWidth ?? 1.8} />
          <Path d="M12 8v4l3 2" {...stroke} strokeWidth={strokeWidth ?? 1.8} />
        </Svg>
      );
    case "sliders":
      return (
        <Svg width={size} height={size} viewBox="0 0 24 24">
          <Path d="M4 7h10M18 7h2M4 17h4M12 17h8" {...stroke} strokeWidth={strokeWidth ?? 1.8} />
          <Circle cx={16} cy={7} r={2} {...stroke} strokeWidth={strokeWidth ?? 1.8} />
          <Circle cx={10} cy={17} r={2} {...stroke} strokeWidth={strokeWidth ?? 1.8} />
        </Svg>
      );
    case "mic":
      return (
        <Svg width={size} height={size} viewBox="0 0 16 16">
          <Rect x={5.5} y={1.5} width={5} height={8.5} rx={2.5} fill={color} />
          <Path d="M3 8a5 5 0 0 0 10 0M8 13v2" {...stroke} strokeWidth={1.5} />
        </Svg>
      );
    case "micOff":
      return (
        <Svg width={size} height={size} viewBox="0 0 16 16">
          <Rect x={5.5} y={1.5} width={5} height={8.5} rx={2.5} fill={color} />
          <Path d="M3 8a5 5 0 0 0 10 0M8 13v2M2 2l12 12" {...stroke} strokeWidth={1.5} />
        </Svg>
      );
    case "speaker":
      return (
        <Svg width={size} height={size} viewBox="0 0 16 16">
          <Path d="M2 6h3l4-3v10L5 10H2z" fill={color} />
          <Path d="M11.5 5.5a3.5 3.5 0 0 1 0 5" {...stroke} strokeWidth={1.5} />
        </Svg>
      );
    case "phone":
      return (
        <Svg width={size} height={size} viewBox="0 0 24 24">
          <Path
            d="M5 4h4l2 5-2.5 1.5a11 11 0 0 0 5 5L15 13l5 2v4a1 1 0 0 1-1 1A16 16 0 0 1 4 5a1 1 0 0 1 1-1z"
            {...stroke}
            strokeWidth={strokeWidth ?? 1.8}
          />
        </Svg>
      );
    case "back":
      return (
        <Svg width={size} height={size} viewBox="0 0 24 24">
          <Path d="M15 5l-7 7 7 7" {...stroke} strokeWidth={strokeWidth ?? 2.2} />
        </Svg>
      );
    case "chevron":
      return (
        <Svg width={size} height={size} viewBox="0 0 24 24">
          <Path d="M9 5l7 7-7 7" {...stroke} strokeWidth={strokeWidth ?? 2} />
        </Svg>
      );
    case "play":
      return (
        <Svg width={size} height={size} viewBox="0 0 14 14">
          <Path d="M3 1.5l9 5.5-9 5.5z" fill={color} />
        </Svg>
      );
    case "stop":
      return (
        <Svg width={size} height={size} viewBox="0 0 14 14">
          <Rect x={2} y={2} width={10} height={10} rx={2} fill={color} />
        </Svg>
      );
    case "send":
      return (
        <Svg width={size} height={size} viewBox="0 0 24 24">
          <Path d="M12 19V5M5 12l7-7 7 7" {...stroke} strokeWidth={strokeWidth ?? 2.2} />
        </Svg>
      );
    case "keyboard":
      return (
        <Svg width={size} height={size} viewBox="0 0 24 24">
          <Rect x={2.5} y={6} width={19} height={12} rx={2} {...stroke} strokeWidth={1.6} />
          <Path d="M6 10h.01M10 10h.01M14 10h.01M18 10h.01M7 14h10" {...stroke} strokeWidth={1.8} />
        </Svg>
      );
    case "close":
      return (
        <Svg width={size} height={size} viewBox="0 0 24 24">
          <Path d="M6 6l12 12M18 6L6 18" {...stroke} strokeWidth={strokeWidth ?? 2.2} />
        </Svg>
      );
  }
}

/** Peon's face (3e): a green tile with two eyes and two small tusks. */
function Face({ size, rx }: { size: number; rx: number }) {
  return (
    <Svg width={size} height={size} viewBox="0 0 64 64">
      <Rect width={64} height={64} rx={rx} fill="#8bbd50" />
      <Circle cx={23} cy={27} r={5} fill="#121a0c" />
      <Circle cx={41} cy={27} r={5} fill="#121a0c" />
      <Path d="M22 52 L25 42 L28 52 Z" fill="#f4f1e8" />
      <Path d="M36 52 L39 42 L42 52 Z" fill="#f4f1e8" />
    </Svg>
  );
}

/** The mark next to the wordmark. */
export function Mark({ size = 34 }: { size?: number }) {
  return <Face size={size} rx={15} />;
}

/** The app icon (or a circle). */
export function AppIcon({ size = 88, round = false }: { size?: number; round?: boolean }) {
  return <Face size={size} rx={round ? 32 : 15} />;
}
