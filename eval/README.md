# eval

Answers one question: **is a small local model good enough at refining your real
speech and splitting your real compound utterances?** If no, the notch cannot
save the product. Run this before writing any UI.

Zero dependencies. Plain Node + `fetch` against any OpenAI-compatible endpoint.

## Setup

```sh
brew install ollama
ollama serve
ollama pull qwen2.5:3b-instruct
```

Use a **plain instruct model**. Measured on an M1 Pro:

- `qwen2.5:3b-instruct` — faithful, ~500ms on short utterances. The current pick.
- `llama3.2:3b` — fast but **fabricates**, inventing details you never said.
- `qwen3:4b` — reasoning model, 7-11s for "Say OK." Ollama 0.32.9 ignores both
  `chat_template_kwargs.enable_thinking` and `think: false`, so you cannot turn
  it off. Unusable.

`qwen2.5:3b-instruct` is the default in `run.mjs`.

## Run

```sh
node run.mjs                                    # refine + split, every case
node run.mjs --model llama3.1:8b                # compare models
node run.mjs --only refine                      # one pass
node run.mjs --instruct "make it two sentences" # hold-mode
node run.mjs --base http://localhost:1234/v1    # LM Studio instead
```

Results land in `results/<timestamp>.json` so you can diff models.

## Getting your 20 cases

`cases.json` ships with 5, three of which are transcripts of you actually
talking. Fill it to 20 with **real** utterances, not typed ones — typed
sentences are clean, and cleanliness is the entire problem.

Easiest source: run Handy normally for a day, then pull raw transcripts out of
its history (`src-tauri/src/managers/history.rs`, SQLite via
`@tauri-apps/plugin-sql`). Paste them into `raw`, hand-write the `refine` you
wish you'd got, and list the intent types you'd expect.

`expect.refine` is not auto-scored — the harness cannot tell you whether a
rewrite is good. Judge that column yourself, honestly.

## Ship gate

- refine beats raw transcription on **≥16 of 20**, judged by you
- refine completes in **under 1000ms** — past that, tap stops feeling instant
- split invents **no** intents that were not spoken

Hallucinated actions are fatal; undo does not help once the wrong thing has
already happened. Under-splitting is always the safer failure.

If refine passes and split does not: **ship the dictation app anyway.** It is a
real product on its own, and the agent layer can come later.
