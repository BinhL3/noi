import React, { useCallback, useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { listen } from "@tauri-apps/api/event";
import { commands, Note } from "../../../bindings";
import { ToggleSwitch } from "../../ui/ToggleSwitch";
import { useSettings } from "../../../hooks/useSettings";

/**
 * Notes captured by voice ("note down…"). Newest first; copy, delete with a
 * short undo. Sparse on purpose.
 */
export const NotesSection: React.FC = () => {
  const { t } = useTranslation();
  const { getSetting, updateSetting, isUpdating } = useSettings();
  const enabled = getSetting("notes_enabled") ?? true;
  const [notes, setNotes] = useState<Note[]>([]);
  const [undo, setUndo] = useState<Note | null>(null);
  const [copiedId, setCopiedId] = useState<number | null>(null);

  const refresh = useCallback(async () => {
    const r = await commands.listNotes(200);
    if (r.status === "ok") setNotes(r.data);
  }, []);

  useEffect(() => {
    refresh();
    const un = listen("note-added", refresh);
    return () => {
      un.then((f) => f());
    };
  }, [refresh]);

  const remove = async (n: Note) => {
    await commands.deleteNote(n.id);
    setUndo(n);
    refresh();
    setTimeout(() => setUndo((u) => (u?.id === n.id ? null : u)), 6000);
  };
  const restore = async () => {
    if (!undo) return;
    await commands.restoreNote(undo.id);
    setUndo(null);
    refresh();
  };
  const toggleDone = async (n: Note) => {
    await commands.setNoteDone(n.id, n.done_at === null);
    refresh();
  };
  const archive = async (n: Note) => {
    await commands.archiveNote(n.id);
    refresh();
  };
  const copy = async (n: Note) => {
    await navigator.clipboard.writeText(n.body);
    setCopiedId(n.id);
    setTimeout(() => setCopiedId((c) => (c === n.id ? null : c)), 1200);
  };

  const when = (unix: number) => {
    const d = new Date(unix * 1000);
    const today = new Date();
    const sameDay = d.toDateString() === today.toDateString();
    return sameDay
      ? d.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" })
      : d.toLocaleDateString(undefined, { month: "short", day: "numeric" });
  };

  return (
    <div>
      <ToggleSwitch
        checked={enabled}
        onChange={(v) => updateSetting("notes_enabled", v)}
        isUpdating={isUpdating("notes_enabled")}
        label={t("notes.toggle.label")}
        description={t("notes.toggle.description")}
        descriptionMode="tooltip"
        grouped={true}
      />
      {undo && (
        <div className="px-4 py-2 text-xs text-mid-gray flex items-center gap-2">
          <span>{t("notes.deleted")}</span>
          <button
            type="button"
            className="text-logo-primary hover:underline cursor-pointer"
            onClick={restore}
          >
            {t("notes.undo")}
          </button>
        </div>
      )}
      {notes.length === 0 ? (
        <p className="px-4 py-3 text-sm text-mid-gray">{t("notes.empty")}</p>
      ) : (
        <ul>
          {notes.map((n) => (
            <li
              key={n.id}
              className="group px-4 py-2 flex items-center gap-3 border-t border-text/10"
            >
              <button
                type="button"
                aria-label={
                  n.done_at ? t("notes.markUndone") : t("notes.markDone")
                }
                className={`shrink-0 w-4 h-4 rounded-full border cursor-pointer transition-colors ${
                  n.done_at
                    ? "bg-logo-primary border-logo-primary"
                    : "border-text/30 hover:border-logo-primary"
                }`}
                onClick={() => toggleDone(n)}
              />
              <span
                className={`flex-1 text-sm whitespace-pre-wrap select-text ${
                  n.done_at ? "line-through text-mid-gray" : ""
                }`}
              >
                {n.body}
              </span>
              <span className="text-xs text-mid-gray tabular-nums shrink-0">
                {when(n.created_at)}
              </span>
              <span className="shrink-0 flex gap-2 opacity-0 group-hover:opacity-100 transition-opacity">
                <button
                  type="button"
                  className="text-xs text-logo-primary hover:underline cursor-pointer"
                  onClick={() => copy(n)}
                >
                  {copiedId === n.id ? t("notes.copied") : t("notes.copy")}
                </button>
                <button
                  type="button"
                  className="text-xs text-mid-gray hover:text-text cursor-pointer"
                  onClick={() => archive(n)}
                >
                  {t("notes.archive")}
                </button>
                <button
                  type="button"
                  className="text-xs text-mid-gray hover:text-error cursor-pointer"
                  onClick={() => remove(n)}
                >
                  {t("notes.delete")}
                </button>
              </span>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
};
