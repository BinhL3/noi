# Notch Scribe

**Voice in, finished text out — from the notch.**

Notch Scribe is a macOS dictation app built on [Handy](https://github.com/cjpais/Handy). Press a key, speak, and clean text lands wherever your cursor is. Everything runs on your machine: local speech-to-text, and a small local language model that tidies what you said before it is pasted.

What it adds to Handy:

- **A native Dynamic-Island overlay** that grows out of the camera housing. Pure CALayer + `CASpringAnimation` (no webview), so it moves the way the iPhone's does: one spring, content revealed by the shape, hover-to-peek at rest.
- **Refine on selection.** Select any text and *tap* the refine key to have the local model clean it up in place. *Tap, then hold* to speak an instruction ("make this a bullet list", "shorter") and it is applied to the selection when you release.
- **A local model as the default post-processor** (Ollama, `qwen2.5:3b-instruct`), chosen by an [eval against real transcripts](eval/README.md). Cloud providers are opt-in.
- **Nothing dictated is ever lost.** If no text field takes the paste, the transcript stays on the clipboard.

Everything Handy does — models, shortcuts, history, push-to-talk, VAD, Windows/Linux builds — is still here; see [docs/HANDY_README.md](docs/HANDY_README.md).

## Status

Personal fork, actively iterated, macOS-first. Roadmap and design notes: [PLAN.md](PLAN.md), [docs/research/notch-ui-design.md](docs/research/notch-ui-design.md).

Next: compound intents ("play some music and note down my next idea, remind me") split into fire-and-forget actions with a visible undo — notes as a byproduct — and a companion iPhone app sharing state.

## Build

```sh
brew install oven-sh/bun/bun   # and Rust ≥ 1.85 via rustup
bun install
bun run tauri dev
```

Requires macOS 12+ for the notch overlay (falls back to Handy's overlay on other displays). Ollama at `http://localhost:11434` for local refine: `ollama pull qwen2.5:3b-instruct`. Full platform notes in [BUILD.md](BUILD.md); contributor conventions in [AGENTS.md](AGENTS.md).

## Credit

Built on [Handy](https://github.com/cjpais/Handy) by CJ Pais and contributors, MIT licensed. Notch Scribe keeps the same license — see [LICENSE](LICENSE).
