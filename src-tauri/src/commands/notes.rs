use crate::notes::{Note, NoteStore};
use std::sync::Arc;
use tauri::{AppHandle, State};

#[tauri::command]
#[specta::specta]
pub fn list_notes(
    store: State<'_, Arc<NoteStore>>,
    limit: Option<u32>,
) -> Result<Vec<Note>, String> {
    store
        .list(limit.unwrap_or(200) as usize)
        .map_err(|e| e.to_string())
}

#[tauri::command]
#[specta::specta]
pub fn delete_note(
    app: AppHandle,
    store: State<'_, Arc<NoteStore>>,
    id: i64,
) -> Result<(), String> {
    store.delete(id).map_err(|e| e.to_string())?;
    crate::notes::push_latest(&app);
    Ok(())
}

#[tauri::command]
#[specta::specta]
pub fn restore_note(
    app: AppHandle,
    store: State<'_, Arc<NoteStore>>,
    id: i64,
) -> Result<(), String> {
    store.restore(id).map_err(|e| e.to_string())?;
    crate::notes::push_latest(&app);
    Ok(())
}

#[tauri::command]
#[specta::specta]
pub fn set_note_done(
    app: AppHandle,
    store: State<'_, Arc<NoteStore>>,
    id: i64,
    done: bool,
) -> Result<(), String> {
    store.set_done(id, done).map_err(|e| e.to_string())?;
    crate::notes::push_latest(&app);
    Ok(())
}

#[tauri::command]
#[specta::specta]
pub fn archive_note(
    app: AppHandle,
    store: State<'_, Arc<NoteStore>>,
    id: i64,
) -> Result<(), String> {
    store.archive(id).map_err(|e| e.to_string())?;
    crate::notes::push_latest(&app);
    Ok(())
}
