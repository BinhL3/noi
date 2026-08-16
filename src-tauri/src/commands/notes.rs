use crate::notes::{Note, NoteStore};
use std::sync::Arc;
use tauri::State;

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
pub fn delete_note(store: State<'_, Arc<NoteStore>>, id: i64) -> Result<(), String> {
    store.delete(id).map_err(|e| e.to_string())
}

#[tauri::command]
#[specta::specta]
pub fn restore_note(store: State<'_, Arc<NoteStore>>, id: i64) -> Result<(), String> {
    store.restore(id).map_err(|e| e.to_string())
}
