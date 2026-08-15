/**
 * Simple vs. full settings. Noi shows a single-column page with the handful
 * of settings a person touches in the first week; the full Handy sidebar UI
 * is one switch away and untouched. Frontend-only state so the Rust settings
 * struct never learns about it (cheap to rebase, trivial to revert).
 */
export type SettingsMode = "simple" | "full";

const KEY = "noi.settingsMode";

export function getSettingsMode(): SettingsMode {
  try {
    return localStorage.getItem(KEY) === "full" ? "full" : "simple";
  } catch {
    return "simple";
  }
}

export function setSettingsMode(mode: SettingsMode): void {
  try {
    localStorage.setItem(KEY, mode);
  } catch {
    // Private mode / no storage: the choice just doesn't persist.
  }
}
