# notch-scribe

Handy fork: voice → refined text + parsed intents, shown in a notch-hugging overlay.

```
notch-scribe/
  eval/     zero-dependency harness for the three model passes. Start here.
  handy/    full clone of cjpais/Handy on branch `notch-scribe`.
```

## The thesis

One small local model, running after transcription, does two jobs:

- **refine** — clean up messy dictation (tap the modifier)
- **instruct** — apply a spoken instruction to the text (hold, speak, release)
- **split** — decompose a compound utterance into intents

Everything else — the notch, the phone, screen context — is chrome around that
pass, and is replaceable. Keep the core headless so it stays that way.

## Ground truth about Handy (verified, not remembered)

Stack is **Tauri v2 + React 18 + TypeScript + Tailwind**. ~25k lines of Rust,
but the parts you touch are mostly TS.

Already built, do not rebuild:

| What | Where |
|---|---|
| LLM post-processing, OpenAI-compatible, JSON-schema structured output | `src-tauri/src/llm_client.rs` |
| User-editable prompt library + provider/model settings | `src-tauri/src/settings.rs` (`post_process_prompts`, `post_process_providers`) |
| A second shortcut, `transcribe_with_post_process` (`option+shift+space`) | `src-tauri/src/settings.rs:832` |
| Floating NSPanel overlay with animated states | `src-tauri/src/overlay.rs` |
| Overlay React UI | `src/components/` (`RecordingOverlay.css`) |
| Push-to-talk, VAD, model download, history | `settings.rs`, `audio_toolkit/`, `managers/` |

The overlay panel is already configured the way an Alcove-style notch UI needs
(`overlay.rs:451`):

```rust
.level(PanelLevel::Status)                       // above the menu bar
.no_activate(true)
.style_mask(StyleMask::empty().borderless().nonactivating_panel())
.with_window(|w| w.decorations(false).transparent(true).focusable(false))
.collection_behavior(CollectionBehavior::new()
    .can_join_all_spaces()                        // follows you across Spaces
    .full_screen_auxiliary())                     // draws over fullscreen apps
```

Transparent + `corner_radius(0.0)` means all shaping is CSS.

## Build prerequisites (verified on this machine)

macOS 26.0.1, M1 Pro, Xcode CLT present.

```sh
brew install oven-sh/bun/bun
rustup update stable          # >= 1.85 — a transitive dep (time 0.3.47) needs edition 2024
cd handy && bun install       # 343 packages, ~3s
bun run tauri dev
```

Rust 1.83 fails with `The package requires the Cargo feature called
'edition2024'`. Apple Silicon needs no ONNX Runtime workaround; Intel Macs do
(see BUILD.md).

## What is actually missing

### 1. Notch geometry (the only real Rust task)

`OVERLAY_TOP_OFFSET = 46.0` (`overlay.rs:66`) parks the pill below the menu bar.
Set it to `0` for notch displays and wrap the cutout.

macOS does not expose the notch to Tauri. Add a helper using `objc2-app-kit`:

```rust
fn notch_geometry(screen) -> Option<NotchGeometry>  // safeAreaInsets.top, cutout width
```

`NSScreen.safeAreaInsets.top` is non-zero only on notched displays;
`auxiliaryTopLeftArea` gives the usable width beside the cutout. ~40 lines.
Fall back to the current top-centre behaviour when it returns `None` — external
monitors and non-notch Macs must keep working.

### 2. Hold-to-instruct

Handy's prompts are **presets picked in settings**. You want an **ad-hoc spoken
instruction**. Shape:

- tap modifier → record → transcribe → `refine` → paste (this already exists)
- hold modifier → record instruction → release → transcribe instruction →
  `instruct(previous_text, instruction)` → replace

Needs a new binding in `get_default_settings()` plus a tap-vs-hold discriminator
in `src-tauri/src/shortcut/`. There is no hold/tap distinction there today —
`push_to_talk` is a global setting, not a per-binding mode. This is the fiddliest
part of the fork; budget accordingly.

### 3. Intent split + actions

`llm_client.rs` already does JSON-schema calls, so the schema in
`eval/prompts.mjs` drops in. Then a small **closed** action set in `actions.rs`.
Start with Spotify only.

**Fire-and-forget only.** The overlay never asks a question mid-task, so every
action must succeed or fail silently. `note` and `reminder` are safe;
`play music` is safe; anything that sends something to another human is not.

### 4. Undo, not confirm

Trust is the whole game — voice products die on the first wrong action, and a
confirmation step kills the speed that justifies the product. So: fire
immediately, show what fired in the overlay, and keep a visible undo for ~10s.

### 5. Local model as default provider

Add Ollama (`http://localhost:11434/v1`) to `default_post_process_providers()`.
It is OpenAI-compatible, so `llm_client.rs` needs no changes — this is a
settings-only edit.

## Explicitly out of scope for v1

- **Phone sync.** Sync is the component that dies when you stop maintaining it,
  and hieuchua.com is the evidence. Local-only, no backend, no accounts, no
  server bill — it keeps working when you disappear for three months.
- **Screen context / Coast integration.** All-day screen capture feeding an
  agent that can act is a keylogger with a task queue. Not until there is a
  permission model.
- **Typing in the notch.** `can_become_key_window: false` makes the panel unable
  to take keyboard input. Flipping it is a large change. Voice-first says leave it.

## Eval results (measured 2026-08-14, M1 Pro, 11.8 GiB, Ollama 0.32.9)

Five cases, three of them real transcripts. Numbers are warm — the first call
after a pull includes a ~15s model load.

| model | refine quality | refine latency (short / long) | verdict |
|---|---|---|---|
| `llama3.2:3b` | **fabricates** — invented "the new software tutorial I was going to record today"; appended sentences never spoken | 500 / 2100ms | rejected |
| `qwen3:4b` | untested | **7-11s for "Say OK."** | rejected |
| `qwen2.5:3b-instruct` | faithful on all 5 — no fabrication | 489-565 / 1900-2500ms | **use this** |

Three findings that change the build:

**1. The refine prompt must forbid obeying the text.** First run, `llama3.2:3b`
turned "Play spotify and also note down..." into "I'm going to go ahead and play
some music on Spotify for you." It answered the utterance instead of cleaning
it. Dictation input is frequently phrased as a command and instruction-tuned
models obey it by default. The same root cause made `split` hallucinate a
`reminder` from any sentence containing the word. Both prompts now say so
explicitly, with examples; intent shape went 2/5 -> 3/5 on the same model.

**2. Reasoning models are unusable here, and cannot be switched off.**
`qwen3:4b` took 7-11s to answer "Say OK." Ollama 0.32.9 ignores **both**
`chat_template_kwargs.enable_thinking` (on `/v1`) and `think: false` (on
`/api/chat`) — the reasoning is still generated, and `/v1` returns it in a
separate `reasoning` field, so stripping `<think>` tags does not help either.
Use plain instruct models.

**3. Stream the refine pass. This is the important one.** Latency tracks output
length, not difficulty. On the worst case: **456ms to first token, 2420ms
total.** Perceived latency is TTFT, so streaming keeps even long dictation under
budget. Handy already streams (`StreamWorkKind` in `managers/transcription.rs`,
the `Live` overlay style) — reuse that path rather than waiting for the full
completion.

**4. Constrained JSON decoding degenerates on long input.** With an unbounded
`intents` array, the split call on a long rambling transcript **never returned**
(>90s; truncating at `max_tokens=300` gave invalid JSON instead). The model
splits forever and echoes the transcript into every `text` field. Fixed with
`maxItems: 4` and `maxLength: 120` on `text` — same call now returns valid JSON
in 3.7s. Any structured-output schema shipped in the app needs these bounds, or
a rambling dictation will hang the pass.

**5. Split is not good enough locally. Refine is.** After the bounds fix,
`qwen2.5:3b-instruct` scores **2/5** on intent shape — it fills the cap with
spurious `note` entries on long input. Refine, by contrast, is faithful on all
five. So: ship refine on the local model, and treat split as unproven. This is
the specific scenario where paying for cloud inference on the split pass only
(local refine, cloud intents) is a justified trade rather than a reflex.

Corollary: **the 1000ms budget applies to refine only.** `split` (1.4-4.4s) does
not block the user — fire it after the text has already landed and let the
overlay update a beat later.

## Order of work

1. **Run the eval first.** No UI. If the model pass is not good on your own real
   speech, no amount of notch polish saves it — and you find out in a weekend.
2. Ollama as a provider (settings-only).
3. Notch geometry + CSS.
4. Intent split behind a flag, display only, no actions.
5. One action (Spotify) + undo.
6. Hold-to-instruct.

Steps 2–5 are worth shipping on their own. If the split never gets good enough,
stop after 3 and you still have a better Handy — which is a real product.

## Maintenance rule

You do not write Rust, and unmaintained code is how the last project died. So:
keep Rust changes **small, localised, and few**, and rebase on upstream Handy
regularly. Every line of Rust you add is a line you must debug at 11pm.

```sh
cd handy
git remote add upstream https://github.com/cjpais/Handy.git
git fetch upstream && git rebase upstream/main
```
