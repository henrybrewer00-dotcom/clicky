/**
 * Integration tests for the Clicky proxy Worker.
 *
 * These boot a real `wrangler dev` server (local workerd runtime) and exercise
 * every route over HTTP — the same way the macOS app talks to it. Upstream keys
 * come from worker/.dev.vars: ElevenLabs is real (so /voices and live TTS work),
 * while Anthropic/AssemblyAI are placeholders (so those routes return 503, which
 * we assert on deterministically).
 *
 * Run:  npm test            (skips the credit-spending live TTS call)
 *       npm run test:live   (also runs one real ElevenLabs TTS call)
 */

import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const workerDirectory = join(dirname(fileURLToPath(import.meta.url)), "..");
const PORT = 8799;
const BASE_URL = `http://127.0.0.1:${PORT}`;

let wranglerProcess;

/// Polls /health until the dev server answers or the timeout elapses.
async function waitForServerReady(timeoutMs = 60000) {
  const startTime = Date.now();
  while (Date.now() - startTime < timeoutMs) {
    try {
      const response = await fetch(`${BASE_URL}/health`);
      if (response.ok) return;
    } catch {
      // Server not up yet — keep polling.
    }
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  throw new Error(`wrangler dev did not become ready within ${timeoutMs}ms`);
}

before(async () => {
  wranglerProcess = spawn(
    "npx",
    ["wrangler", "dev", "--port", String(PORT), "--ip", "127.0.0.1"],
    {
      cwd: workerDirectory,
      env: { ...process.env, WRANGLER_SEND_METRICS: "false", CI: "1" },
      stdio: ["ignore", "pipe", "pipe"],
    }
  );
  // Surface fatal boot errors instead of silently timing out.
  wranglerProcess.stderr.on("data", (chunk) => {
    const text = chunk.toString();
    if (text.toLowerCase().includes("error")) process.stderr.write(`[wrangler] ${text}`);
  });
  await waitForServerReady();
});

after(() => {
  if (wranglerProcess && !wranglerProcess.killed) {
    wranglerProcess.kill("SIGTERM");
  }
});

// ── Health ───────────────────────────────────────────────────────────────

test("GET /health returns ok and reports configured upstreams", async () => {
  const response = await fetch(`${BASE_URL}/health`);
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(body.ok, true);
  assert.equal(body.service, "clicky-proxy");
  // ElevenLabs key is real in .dev.vars; the other two are placeholders.
  assert.equal(body.upstreams.elevenlabs, true);
  assert.equal(body.upstreams.anthropic, false);
  assert.equal(body.upstreams.assemblyai, false);
  assert.ok(Array.isArray(body.routes));
});

// ── CORS ─────────────────────────────────────────────────────────────────

test("OPTIONS preflight returns 204 with CORS headers", async () => {
  const response = await fetch(`${BASE_URL}/tts`, { method: "OPTIONS" });
  assert.equal(response.status, 204);
  assert.equal(response.headers.get("access-control-allow-origin"), "*");
  assert.match(response.headers.get("access-control-allow-methods"), /POST/);
});

test("every response carries the CORS origin header", async () => {
  const response = await fetch(`${BASE_URL}/health`);
  assert.equal(response.headers.get("access-control-allow-origin"), "*");
});

// ── Routing / method handling ──────────────────────────────────────────────

test("unknown GET route returns a 404 JSON error envelope", async () => {
  const response = await fetch(`${BASE_URL}/nope`);
  assert.equal(response.status, 404);
  const body = await response.json();
  assert.equal(body.error.status, 404);
  assert.match(body.error.message, /No GET route/);
});

test("unsupported method returns 405", async () => {
  const response = await fetch(`${BASE_URL}/health`, { method: "DELETE" });
  assert.equal(response.status, 405);
});

// ── /tts validation ────────────────────────────────────────────────────────

test("POST /tts with no text returns 400", async () => {
  const response = await fetch(`${BASE_URL}/tts`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({}),
  });
  assert.equal(response.status, 400);
  const body = await response.json();
  assert.match(body.error.message, /text/);
});

test("POST /tts with invalid JSON returns 400", async () => {
  const response = await fetch(`${BASE_URL}/tts`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: "{not json",
  });
  assert.equal(response.status, 400);
});

test("POST /tts with a malformed voice_id returns 400", async () => {
  const response = await fetch(`${BASE_URL}/tts`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ text: "hi", voice_id: "../../etc/passwd" }),
  });
  assert.equal(response.status, 400);
  const body = await response.json();
  assert.match(body.error.message, /voice_id/);
});

test("POST /tts with over-long text returns 400", async () => {
  const response = await fetch(`${BASE_URL}/tts`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ text: "a".repeat(5001) }),
  });
  assert.equal(response.status, 400);
});

// ── /chat validation ────────────────────────────────────────────────────────

test("POST /chat returns 503 because ANTHROPIC_API_KEY is a placeholder", async () => {
  const response = await fetch(`${BASE_URL}/chat`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ messages: [{ role: "user", content: "hi" }] }),
  });
  assert.equal(response.status, 503);
  const body = await response.json();
  assert.match(body.error.message, /ANTHROPIC_API_KEY/);
});

// ── /transcribe-token ───────────────────────────────────────────────────────

test("POST /transcribe-token returns 503 because ASSEMBLYAI_API_KEY is a placeholder", async () => {
  const response = await fetch(`${BASE_URL}/transcribe-token`, { method: "POST" });
  assert.equal(response.status, 503);
});

// ── /voices (real ElevenLabs call) ──────────────────────────────────────────

test("GET /voices returns a simplified voice list from ElevenLabs", async () => {
  const response = await fetch(`${BASE_URL}/voices`);
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.ok(Array.isArray(body.voices));
  assert.ok(body.voices.length > 0, "expected at least one voice");
  const firstVoice = body.voices[0];
  assert.ok(typeof firstVoice.voice_id === "string");
  assert.ok(typeof firstVoice.name === "string");
  // The simplified shape should NOT leak the full upstream payload.
  assert.equal(firstVoice.samples, undefined);
});

// ── Live TTS (opt-in; spends ElevenLabs credits) ────────────────────────────

test(
  "POST /tts produces real MP3 audio",
  { skip: process.env.CLICKY_RUN_LIVE_TTS ? false : "set CLICKY_RUN_LIVE_TTS=1 to run" },
  async () => {
    const response = await fetch(`${BASE_URL}/tts`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ text: "testing one two three." }),
    });
    assert.equal(response.status, 200);
    assert.match(response.headers.get("content-type"), /audio\/mpeg/);
    const audioBytes = new Uint8Array(await response.arrayBuffer());
    // MP3/ID3 files start with "ID3" (0x49 0x44 0x33) or an MPEG frame sync 0xFF.
    assert.ok(audioBytes.length > 1000, "expected a non-trivial audio payload");
    const startsWithId3 = audioBytes[0] === 0x49 && audioBytes[1] === 0x44 && audioBytes[2] === 0x33;
    const startsWithMpegSync = audioBytes[0] === 0xff;
    assert.ok(startsWithId3 || startsWithMpegSync, "payload is not MP3 audio");
  }
);
