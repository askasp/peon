import { useState } from "react";
import { Linking, Pressable, StyleSheet, Text, TextInput, View } from "react-native";
import { Button, Card, ErrorLine } from "../ui";
import { color } from "@/lib/theme";
import type { Form, FormField } from "@/lib/types";

type Value = string | number | boolean | string[];

// A question the agent asked and is waiting on: pick an option or type an
// answer for each field, then send it back (or skip it).

const initialValue = (f: FormField): Value | undefined =>
  f.default ?? (f.type === "multiselect" ? [] : undefined);

const filled = (v: Value | undefined) => v !== undefined && v !== "" && !(Array.isArray(v) && v.length === 0);

export function FormCard({
  form,
  onSend,
  onSkip,
}: {
  form: Form;
  onSend: (answer: Record<string, Value>) => Promise<unknown>;
  onSkip: () => Promise<unknown>;
}) {
  const fields = form.fields.filter((f) => !f.hidden);
  const [values, setValues] = useState<Record<string, Value | undefined>>(() =>
    Object.fromEntries(fields.map((f) => [f.key, initialValue(f)])),
  );
  const [busy, setBusy] = useState<"send" | "skip" | null>(null);
  const [error, setError] = useState<string | null>(null);
  const set = (key: string, v: Value | undefined) => setValues((vs) => ({ ...vs, [key]: v }));

  // One question with options: tapping an option answers it.
  const quick = fields.length === 1 && fields[0].type === "string" && (fields[0].options?.length ?? 0) > 0;
  const ready = fields.every((f) => f.type === "external" || !f.required || filled(values[f.key]));

  const run = async (what: "send" | "skip", given?: Record<string, Value>) => {
    setBusy(what);
    setError(null);
    try {
      if (what === "skip") await onSkip();
      else {
        const answer: Record<string, Value> = {};
        for (const f of fields) {
          const v = values[f.key];
          if (f.type !== "external" && filled(v)) answer[f.key] = v as Value;
        }
        await onSend(given ?? answer);
      }
    } catch (e: any) {
      setError(e.message);
      setBusy(null);
    }
  };

  return (
    <Card needs>
      <Text style={st.title}>{form.title}</Text>
      {fields.map((f) => (
        <FieldInput
          key={f.key}
          field={f}
          value={values[f.key]}
          onChange={(v) => set(f.key, v)}
          onPick={quick && busy == null ? (v) => run("send", { [f.key]: v }) : undefined}
        />
      ))}
      <ErrorLine message={error} />
      <View style={st.actions}>
        <Button
          label="Send answer"
          style={{ flex: 1 }}
          busy={busy === "send"}
          disabled={!ready || busy != null}
          onPress={() => run("send")}
          testID="form-send"
        />
        <Button
          label="Skip"
          kind="secondary"
          busy={busy === "skip"}
          disabled={busy != null}
          onPress={() => run("skip")}
          testID="form-skip"
        />
      </View>
    </Card>
  );
}

function FieldInput({
  field: f,
  value,
  onChange,
  onPick,
}: {
  field: FormField;
  value: Value | undefined;
  onChange: (v: Value | undefined) => void;
  /** Set when picking an option sends the answer straight away. */
  onPick?: (v: string) => void;
}) {
  const label = f.title || (f.description ? null : f.key);
  const head = (
    <>
      {label ? (
        <Text style={st.label}>
          {label}
          {f.required ? <Text style={{ color: color.needs }}> *</Text> : null}
        </Text>
      ) : null}
      {f.description ? <Text style={st.description}>{f.description}</Text> : null}
    </>
  );

  if (f.type === "external")
    return (
      <View style={st.field}>
        {head}
        {f.url ? (
          <Button label="Open" kind="secondary" height={34} onPress={() => Linking.openURL(f.url!)} />
        ) : null}
      </View>
    );

  if (f.type === "boolean")
    return (
      <View style={st.field}>
        {head}
        <View style={st.options}>
          {[true, false].map((b) => (
            <Choice key={String(b)} label={b ? "Yes" : "No"} on={value === b} onPress={() => onChange(b)} />
          ))}
        </View>
      </View>
    );

  if (f.type === "multiselect") {
    const list = Array.isArray(value) ? value : [];
    const known = new Set((f.options ?? []).map((o) => o.value));
    const own = list.filter((v) => !known.has(v)).join(", ");
    return (
      <View style={st.field}>
        {head}
        <View style={st.options}>
          {(f.options ?? []).map((o) => (
            <Choice
              key={o.value}
              label={o.label}
              detail={o.description}
              on={list.includes(o.value)}
              onPress={() =>
                onChange(list.includes(o.value) ? list.filter((v) => v !== o.value) : [...list, o.value])
              }
            />
          ))}
        </View>
        {f.custom ? (
          <Field
            value={own}
            placeholder="Something else (comma separated)"
            onChange={(t) =>
              onChange([
                ...list.filter((v) => known.has(v)),
                ...t
                  .split(",")
                  .map((x) => x.trim())
                  .filter(Boolean),
              ])
            }
          />
        ) : null}
      </View>
    );
  }

  if (f.type === "number" || f.type === "integer")
    return (
      <View style={st.field}>
        {head}
        <Field
          value={value == null ? "" : String(value)}
          placeholder={f.placeholder ?? "A number"}
          numeric
          onChange={(t) => {
            const n = f.type === "integer" ? parseInt(t, 10) : parseFloat(t);
            onChange(t.trim() === "" || Number.isNaN(n) ? undefined : n);
          }}
        />
      </View>
    );

  // A string: options to pick from, a box to type in, or both.
  const options = f.options ?? [];
  const picked = options.some((o) => o.value === value);
  return (
    <View style={st.field}>
      {head}
      {options.length ? (
        <View style={st.options}>
          {options.map((o) => (
            <Choice
              key={o.value}
              label={o.label}
              detail={o.description}
              on={value === o.value}
              onPress={() => {
                onChange(value === o.value ? undefined : o.value);
                if (onPick && value !== o.value) onPick(o.value);
              }}
            />
          ))}
        </View>
      ) : null}
      {!options.length || f.custom ? (
        <Field
          value={typeof value === "string" && !picked ? value : ""}
          placeholder={f.placeholder ?? (options.length ? "Something else" : "Your answer")}
          onChange={(t) => onChange(t === "" ? undefined : t)}
        />
      ) : null}
    </View>
  );
}

function Choice({
  label,
  detail,
  on,
  onPress,
}: {
  label: string;
  detail?: string;
  on: boolean;
  onPress: () => void;
}) {
  return (
    <Pressable
      onPress={onPress}
      style={(s: any) => [
        st.choice,
        s.hovered && !on && { backgroundColor: color.raised },
        on && st.choiceOn,
      ]}
    >
      <Text style={[st.choiceText, on && { color: color.accentText }]}>{label}</Text>
      {detail ? <Text style={st.choiceDetail}>{detail}</Text> : null}
    </Pressable>
  );
}

function Field({
  value,
  placeholder,
  numeric,
  onChange,
}: {
  value: string;
  placeholder: string;
  numeric?: boolean;
  onChange: (t: string) => void;
}) {
  return (
    <TextInput
      value={value}
      onChangeText={onChange}
      placeholder={placeholder}
      placeholderTextColor={color.faint}
      keyboardType={numeric ? "numeric" : "default"}
      multiline={!numeric}
      style={st.input}
    />
  );
}

const st = StyleSheet.create({
  title: { fontSize: 13, color: color.muted },
  field: { gap: 6 },
  label: {
    fontSize: 12,
    fontWeight: "600",
    color: color.needs,
    textTransform: "uppercase",
    letterSpacing: 0.4,
  },
  description: { fontSize: 15, lineHeight: 21, color: color.text },
  options: { gap: 6 },
  choice: {
    paddingHorizontal: 12,
    paddingVertical: 9,
    borderRadius: 10,
    borderWidth: 1,
    borderColor: color.border,
    backgroundColor: color.field,
    gap: 2,
  },
  choiceOn: { borderColor: color.accentBorder, backgroundColor: color.accentWash },
  choiceText: { fontSize: 14, color: color.text },
  choiceDetail: { fontSize: 12, lineHeight: 16, color: color.muted },
  input: {
    minHeight: 38,
    maxHeight: 120,
    borderRadius: 10,
    backgroundColor: color.field,
    paddingHorizontal: 12,
    paddingVertical: 9,
    color: color.text,
    fontSize: 14,
    outlineStyle: "none",
  } as any,
  actions: { flexDirection: "row", gap: 8, marginTop: 2 },
});
