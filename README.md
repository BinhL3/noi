# Noi

**Voice in, finished text out — from the notch.**

Noi is a macOS dictation app. Hold a key, speak, release: the text lands wherever your cursor is. Select any text and tap a second key to have it cleaned up in place — or hold and say what to change.

Built on [Handy](https://github.com/cjpais/Handy).

- **The notch is the UI.** A native Dynamic-Island overlay grows out of the camera housing — one spring, content revealed by the shape, hover to peek. Pure CALayer, no webview.
- **On-device by default.** Apple Speech (`SpeechAnalyzer`, macOS 26) transcribes with nothing to download, ~0.2 s for a sentence. Nemotron, Parakeet and Whisper are one click away.
- **Refine on selection.** Tap the refine key to clean up selected text; tap-and-hold to speak an instruction ("make this a list", "shorter"). Bring your own model key, or run Ollama locally.
- **Never lose a dictation.** No text field to paste into? It stays on the clipboard.

## Install

Requires macOS 26 on Apple Silicon for the notch overlay and Apple Speech; other Macs fall back to Handy's overlay and models.

Grab the `.dmg` from [Releases](https://github.com/BinhL3/noi/releases). If macOS says the app is damaged (unsigned build): `xattr -d com.apple.quarantine /Applications/Noi.app`.

## Build

```sh
brew install oven-sh/bun/bun   # and Rust ≥ 1.85 via rustup
bun install
bun run tauri dev
```

## Credits

[Handy](https://github.com/cjpais/Handy) by CJ Pais and contributors (MIT) is the foundation. [Talkify](https://github.com/tornikegomareli/Talkify) by Tornike Gomareli showed how fast Apple's on-device recogniser is. MIT — see [LICENSE](LICENSE).
