//! Notes: things said to be kept, not typed. v0 is triggered by a leading
//! phrase ("note", "note down", "note to self", "remember"); the intent layer
//! will later pull notes out of compound utterances. Local SQLite is the
//! source of truth; a synced adapter can sit behind the same interface.

use anyhow::Result;
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use specta::Type;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter, Manager};

#[derive(Debug, Clone, Serialize, Deserialize, Type)]
pub struct Note {
    pub id: i64,
    pub body: String,
    /// Unix seconds.
    pub created_at: i64,
    /// Where it came from: "dictation" for now; the agent layer will add more.
    pub source: String,
}

/// Leading phrases that turn a dictation into a note. Matched case-insensitively
/// against the start of the transcript; the phrase itself is dropped.
const TRIGGERS: &[&str] = &[
    "note to self",
    "note down",
    "make a note",
    "take a note",
    "remember that",
    "remember to",
    "note",
];

/// If `text` starts with a note trigger, returns the note body (trigger and
/// leading punctuation removed). `None` means it is ordinary dictation.
pub fn note_body(text: &str) -> Option<String> {
    let trimmed = text.trim();
    let lower = trimmed.to_lowercase();
    for trigger in TRIGGERS {
        if let Some(rest) = lower.strip_prefix(trigger) {
            // Must be a whole word: "notebook" is not a note.
            let boundary = rest.chars().next().is_none_or(|c| !c.is_alphanumeric());
            if !boundary {
                continue;
            }
            let body = trimmed[trigger.len()..].trim_start_matches(|c: char| {
                c == ',' || c == ':' || c == '.' || c.is_whitespace()
            });
            if body.is_empty() {
                return None;
            }
            // Capitalise the first letter; the trigger swallowed the sentence start.
            let mut chars = body.chars();
            let cap = match chars.next() {
                Some(f) => f.to_uppercase().collect::<String>() + chars.as_str(),
                None => String::new(),
            };
            return Some(cap);
        }
    }
    None
}

pub struct NoteStore {
    db_path: PathBuf,
    lock: Mutex<()>,
}

impl NoteStore {
    pub fn new(app: &AppHandle) -> Result<Self> {
        let dir = crate::portable::app_data_dir(app)?;
        let store = Self {
            db_path: dir.join("notes.db"),
            lock: Mutex::new(()),
        };
        store.conn()?.execute_batch(
            "CREATE TABLE IF NOT EXISTS notes (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                body TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                source TEXT NOT NULL DEFAULT 'dictation',
                deleted_at INTEGER
            );",
        )?;
        Ok(store)
    }

    fn conn(&self) -> Result<Connection> {
        Ok(Connection::open(&self.db_path)?)
    }

    pub fn put(&self, body: &str, source: &str) -> Result<Note> {
        let _g = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        let created_at = chrono::Utc::now().timestamp();
        let conn = self.conn()?;
        conn.execute(
            "INSERT INTO notes (body, created_at, source) VALUES (?1, ?2, ?3)",
            params![body, created_at, source],
        )?;
        Ok(Note {
            id: conn.last_insert_rowid(),
            body: body.to_string(),
            created_at,
            source: source.to_string(),
        })
    }

    pub fn list(&self, limit: usize) -> Result<Vec<Note>> {
        let conn = self.conn()?;
        let mut stmt = conn.prepare(
            "SELECT id, body, created_at, source FROM notes
             WHERE deleted_at IS NULL ORDER BY created_at DESC, id DESC LIMIT ?1",
        )?;
        let rows = stmt.query_map(params![limit as i64], |r| {
            Ok(Note {
                id: r.get(0)?,
                body: r.get(1)?,
                created_at: r.get(2)?,
                source: r.get(3)?,
            })
        })?;
        Ok(rows.filter_map(|r| r.ok()).collect())
    }

    /// Soft delete, so undo (and later sync) can bring it back.
    pub fn delete(&self, id: i64) -> Result<()> {
        let _g = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        self.conn()?.execute(
            "UPDATE notes SET deleted_at = ?1 WHERE id = ?2",
            params![chrono::Utc::now().timestamp(), id],
        )?;
        Ok(())
    }

    pub fn restore(&self, id: i64) -> Result<()> {
        let _g = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        self.conn()?.execute(
            "UPDATE notes SET deleted_at = NULL WHERE id = ?1",
            params![id],
        )?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::note_body;

    #[test]
    fn triggers() {
        assert_eq!(
            note_body("note down my next video idea"),
            Some("My next video idea".into())
        );
        assert_eq!(note_body("Note to self: buy milk"), Some("Buy milk".into()));
        assert_eq!(note_body("remember to call mum"), Some("Call mum".into()));
        assert_eq!(
            note_body("Note, the meeting moved."),
            Some("The meeting moved.".into())
        );
        assert_eq!(note_body("notebook is on the desk"), None);
        assert_eq!(note_body("I should note that"), None);
        assert_eq!(note_body("note"), None);
    }
}

/// If the transcript is a note (see `note_body`) and notes are enabled, store
/// it and put it on the clipboard. Returns the note, or `None` for ordinary
/// dictation.
pub fn maybe_capture_note(app: &AppHandle, text: &str) -> Option<Note> {
    let settings = crate::settings::get_settings(app);
    if !settings.notes_enabled {
        return None;
    }
    let body = note_body(text)?;
    let store = app.try_state::<Arc<NoteStore>>()?;
    match store.put(&body, "dictation") {
        Ok(note) => {
            let _ = crate::clipboard::write_text_to_clipboard(app, &body);
            let _ = app.emit("note-added", &note);
            push_latest(app);
            Some(note)
        }
        Err(e) => {
            log::error!("Failed to store note: {e}");
            None
        }
    }
}

/// Island says "Noted"; falls back to closing the webview overlay.
pub fn acknowledge(app: &AppHandle) {
    #[cfg(target_os = "macos")]
    {
        let settings = crate::settings::get_settings(app);
        if settings.overlay_style != crate::settings::OverlayStyle::None
            && settings.overlay_position == crate::settings::OverlayPosition::Top
            && crate::native_notch::is_available()
        {
            crate::native_notch::finish_with(crate::native_notch::Outcome::Noted);
            return;
        }
    }
    crate::utils::hide_recording_overlay(app);
}

/// Tell the island what its long-hover preview should show. Call after any
/// change to the notes and once at startup.
pub fn push_latest(app: &AppHandle) {
    #[cfg(target_os = "macos")]
    {
        let Some(store) = app.try_state::<Arc<NoteStore>>() else {
            return;
        };
        let latest = store.list(1).ok().and_then(|v| v.into_iter().next());
        match latest {
            Some(n) => {
                let first_line = n.body.lines().next().unwrap_or("").to_string();
                crate::native_notch::set_latest_note(Some((
                    &first_line,
                    &relative_time(n.created_at),
                )));
            }
            None => crate::native_notch::set_latest_note(None),
        }
    }
    #[cfg(not(target_os = "macos"))]
    let _ = app;
}

/// "just now", "5m ago", "2h ago", "yesterday", "Aug 3".
pub fn relative_time(unix: i64) -> String {
    let now = chrono::Utc::now().timestamp();
    let d = (now - unix).max(0);
    if d < 60 {
        "Noted just now".into()
    } else if d < 3600 {
        format!("Noted {}m ago", d / 60)
    } else if d < 86_400 {
        format!("Noted {}h ago", d / 3600)
    } else if d < 172_800 {
        "Noted yesterday".into()
    } else {
        let dt = chrono::DateTime::from_timestamp(unix, 0).unwrap_or_default();
        format!("Noted {}", dt.format("%b %-d"))
    }
}
