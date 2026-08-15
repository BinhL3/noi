#!/usr/bin/env node
// Eval harness for the three post-transcription passes.
// Zero dependencies: plain Node + fetch against any OpenAI-compatible endpoint.
//
//   node run.mjs                          # refine + split over every case
//   node run.mjs --only refine            # one pass
//   node run.mjs --model qwen3:4b         # override model
//   node run.mjs --base http://localhost:1234/v1   # LM Studio instead of Ollama
//   node run.mjs --instruct "make it shorter"      # exercise hold-mode
//
// Results are appended to results/<timestamp>.json so you can diff models.

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { REFINE, INSTRUCT, SPLIT, INTENT_SCHEMA } from "./prompts.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));

const args = parseArgs(process.argv.slice(2));
const BASE = args.base ?? process.env.SCRIBE_BASE ?? "http://localhost:11434/v1";
const MODEL = args.model ?? process.env.SCRIBE_MODEL ?? "qwen2.5:3b-instruct";
const API_KEY = process.env.SCRIBE_API_KEY ?? "not-needed";
// Latency target: past this, the tap gesture stops feeling instant and the
// whole premise of the product (speed) is gone.
const LATENCY_BUDGET_MS = 1000;
// Generous — a cold model load is ~15s. This only exists to turn a hung socket
// into a retryable error instead of an infinite wait.
const REQUEST_TIMEOUT_MS = 60_000;

const cases = JSON.parse(readFileSync(join(HERE, "cases.json"), "utf8"));
const passes = args.only ? [args.only] : ["refine", "split"];

async function chat(system, user, schema) {
  const body = {
    model: MODEL,
    messages: [
      { role: "system", content: system },
      { role: "user", content: user },
    ],
    temperature: 0,
    stream: false,
  };
  if (schema) {
    body.response_format = { type: "json_schema", json_schema: schema };
  }
  // Reasoning models (qwen3, deepseek-r1) think before answering, which burns
  // the entire latency budget. MEASURED on Ollama 0.32.9: neither this field nor
  // the native API's `think: false` actually suppresses it — qwen3:4b took 7-11s
  // to answer "Say OK." Do not use a reasoning model for the refine pass; pick a
  // plain instruct model instead. Kept because other servers (vLLM) do honour it.
  if (args.nothink) {
    body.chat_template_kwargs = { enable_thinking: false };
  }

  // Ollama closes idle keep-alive sockets; Node happily reuses one a moment
  // after it dies and reports the race as a bare "fetch failed". Retry once on
  // a transport error — but never on an HTTP error, which is a real answer.
  let res, started, ms;
  for (let attempt = 0; ; attempt++) {
    started = performance.now();
    try {
      res = await fetch(`${BASE}/chat/completions`, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          authorization: `Bearer ${API_KEY}`,
        },
        body: JSON.stringify(body),
        // Node's fetch has no default timeout, so a half-dead keep-alive socket
        // hangs forever and the retry below never gets to run.
        signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
      });
      ms = Math.round(performance.now() - started);
      break;
    } catch (err) {
      if (attempt >= 1 || err.cause?.code === "ECONNREFUSED") {
        // Do not mutate err.message — on a DOMException (AbortSignal.timeout)
        // it is getter-only and assigning to it throws, hiding the real cause.
        const detail = err.cause?.code ?? err.name ?? "unknown";
        const wrapped = new Error(`${err.message} (cause: ${detail})`);
        wrapped.cause = err.cause;
        throw wrapped;
      }
    }
  }

  if (!res.ok) {
    throw new Error(`${res.status} ${res.statusText}: ${(await res.text()).slice(0, 300)}`);
  }
  const json = await res.json();
  const content = json.choices?.[0]?.message?.content ?? "";
  // Small local models still emit <think> blocks even when asked not to.
  const cleaned = content.replace(/<think>[\s\S]*?<\/think>/g, "").trim();
  return { text: cleaned, ms };
}

async function runCase(c) {
  const out = { id: c.id, raw: c.raw, expect: c.expect };

  // Delimiting the transcript is what stops instruction-tuned models from
  // obeying dictation that happens to be phrased as a command. Upstream Handy's
  // default prompt does the same thing, having presumably hit the same wall.
  const tagged = `<transcript>\n${c.raw}\n</transcript>`;

  if (passes.includes("refine")) {
    const user = args.instruct
      ? `Instruction: ${args.instruct}\n\n${tagged}`
      : tagged;
    const { text, ms } = await chat(args.instruct ? INSTRUCT : REFINE, user);
    out.refine = { text, ms, mode: args.instruct ? "instruct" : "tap" };
  }

  if (passes.includes("split")) {
    const { text, ms } = await chat(SPLIT, tagged, INTENT_SCHEMA);
    let intents = null;
    let parseError = null;
    try {
      intents = JSON.parse(text).intents;
    } catch (err) {
      parseError = `${err.message} — raw: ${text.slice(0, 200)}`;
    }
    out.split = { intents, parseError, ms };
  }

  return out;
}

function scoreSplit(result) {
  // Only checks the *shape* — the ordered list of intent types. Whether the
  // refined text is actually good is your call, not the harness's.
  const expected = result.expect?.intents;
  if (!expected || !result.split?.intents) return null;
  const got = result.split.intents.map((i) => i.type);
  return JSON.stringify(got) === JSON.stringify(expected);
}

function bar(label, value, ok) {
  const mark = ok === null ? "·" : ok ? "\x1b[32m✓\x1b[0m" : "\x1b[31m✗\x1b[0m";
  return `${mark} ${label} ${value}`;
}

const results = [];
let splitPass = 0;
let splitScored = 0;
let slow = 0;

console.log(`\nmodel: ${MODEL}   endpoint: ${BASE}   passes: ${passes.join(", ")}`);
if (args.instruct) console.log(`instruction: "${args.instruct}"`);
console.log("─".repeat(72));

for (const c of cases) {
  let r;
  try {
    r = await runCase(c);
  } catch (err) {
    console.error(`\n\x1b[31m${c.id}\x1b[0m — request failed: ${err.message}`);
    if (err.cause?.code === "ECONNREFUSED") {
      console.error(
        `\nNothing is listening on ${BASE}.\n` +
          `  Ollama:    brew install ollama && ollama serve && ollama pull ${MODEL}\n` +
          `  LM Studio: start the local server, then --base http://localhost:1234/v1\n`,
      );
      process.exit(1);
    }
    continue;
  }

  results.push(r);
  console.log(`\n\x1b[1m${r.id}\x1b[0m`);
  console.log(`  raw      ${truncate(r.raw)}`);

  if (r.refine) {
    const fast = r.refine.ms <= LATENCY_BUDGET_MS;
    if (!fast) slow++;
    console.log(`  ${bar("refined ", truncate(r.refine.text), null)}`);
    console.log(`  ${bar("latency ", `${r.refine.ms}ms`, fast)}`);
  }

  if (r.split) {
    const ok = scoreSplit(r);
    if (ok !== null) {
      splitScored++;
      if (ok) splitPass++;
    }
    const got = r.split.parseError
      ? `\x1b[31mparse error\x1b[0m ${r.split.parseError}`
      : r.split.intents.map((i) => i.type).join(" + ");
    console.log(`  ${bar("intents ", got, ok)}`);
    if (r.expect?.intents && ok === false) {
      console.log(`             expected: ${r.expect.intents.join(" + ")}`);
    }
    console.log(`  ${bar("latency ", `${r.split.ms}ms`, r.split.ms <= LATENCY_BUDGET_MS)}`);
  }
}

console.log("\n" + "─".repeat(72));
if (splitScored) {
  console.log(`intent shape:  ${splitPass}/${splitScored} correct`);
}
console.log(`over ${LATENCY_BUDGET_MS}ms:  ${slow} refine call(s)`);
console.log(
  `\nThe harness only scores intent *shape* and latency.\n` +
    `Refinement quality is yours to judge — read the refined column and be honest.\n` +
    `Ship gate: refine wins on >=16/20 of your own real utterances, under ${LATENCY_BUDGET_MS}ms.\n`,
);

const stamp = new Date().toISOString().replace(/[:.]/g, "-");
mkdirSync(join(HERE, "results"), { recursive: true });
const outPath = join(HERE, "results", `${stamp}.json`);
writeFileSync(outPath, JSON.stringify({ model: MODEL, base: BASE, results }, null, 2));
console.log(`saved: ${outPath}\n`);

function truncate(s, n = 120) {
  const flat = s.replace(/\s+/g, " ").trim();
  return flat.length > n ? flat.slice(0, n) + "…" : flat;
}

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    if (!argv[i].startsWith("--")) continue;
    const key = argv[i].slice(2);
    const next = argv[i + 1];
    // Bare flags (--nothink) take no value; --key value consumes the next arg.
    if (next === undefined || next.startsWith("--")) {
      out[key] = true;
    } else {
      out[key] = next;
      i++;
    }
  }
  return out;
}
