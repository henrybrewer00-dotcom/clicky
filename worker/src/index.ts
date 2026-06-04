/**
 * Clicky Proxy Worker
 *
 * Proxies requests to Claude, ElevenLabs, and AssemblyAI so the app never
 * ships with raw API keys. Keys are stored as Cloudflare secrets and never
 * leave the Worker.
 *
 * Routes:
 *   GET  /health            → liveness + which upstream keys are configured
 *   POST /chat              → Anthropic Messages API (SSE streaming passthrough)
 *   POST /tts               → ElevenLabs TTS, full audio buffer (audio/mpeg)
 *   POST /tts/stream        → ElevenLabs TTS, streamed for lower latency
 *   GET  /voices            → ElevenLabs voice list (id + name + category)
 *   POST /transcribe-token  → AssemblyAI short-lived streaming token
 *
 * Every response includes permissive CORS headers and OPTIONS preflight is
 * handled, so the proxy also works from browser-based clients and tests.
 */

interface Env {
  ANTHROPIC_API_KEY: string;
  ELEVENLABS_API_KEY: string;
  ELEVENLABS_VOICE_ID: string;
  ASSEMBLYAI_API_KEY: string;
}

/// The largest request body we accept. Chat requests carry base64 screenshots
/// (often a few MB across multiple monitors), so the ceiling is generous but
/// still bounded to protect the upstream APIs from oversized payloads.
const MAX_REQUEST_BODY_BYTES = 16 * 1024 * 1024; // 16 MB

/// ElevenLabs rejects very long inputs and they cost a lot of credits, so we
/// cap spoken text well below the model limit. Clicky replies are short anyway.
const MAX_TTS_TEXT_LENGTH = 5000;

/// Default TTS model. Flash is the lowest-latency ElevenLabs model, which keeps
/// the companion feeling responsive when it talks back.
const DEFAULT_TTS_MODEL_ID = "eleven_flash_v2_5";

/// CORS headers applied to every response. The app is a native macOS client so
/// it has no browser origin, but allowing all origins lets the proxy double as
/// a backend for web clients and lets the test suite hit it from anywhere.
const CORS_HEADERS: Record<string, string> = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET, POST, OPTIONS",
  "access-control-allow-headers": "content-type, x-clicky-client",
  "access-control-max-age": "86400",
};

/// Builds a JSON error response with a consistent envelope and CORS headers.
/// Centralizing this means every failure path returns the same shape, which
/// the app and the tests can rely on.
function jsonError(message: string, status: number): Response {
  return new Response(
    JSON.stringify({ error: { message, status } }),
    {
      status,
      headers: { "content-type": "application/json", ...CORS_HEADERS },
    }
  );
}

/// Returns true when a secret looks like a real, configured value rather than
/// the "REPLACE_ME" placeholders shipped in `.dev.vars`. Used by /health so a
/// developer can immediately see which upstreams are ready.
function isConfiguredSecret(value: string | undefined): boolean {
  if (!value) return false;
  const trimmed = value.trim();
  return trimmed.length > 0 && !trimmed.includes("REPLACE_ME");
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    // Answer CORS preflight before doing anything else.
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: CORS_HEADERS });
    }

    try {
      // ── GET routes ──────────────────────────────────────────────────
      if (request.method === "GET") {
        if (url.pathname === "/health") {
          return handleHealth(env);
        }
        if (url.pathname === "/voices") {
          return await handleListVoices(env);
        }
        return jsonError(`No GET route for ${url.pathname}`, 404);
      }

      // ── POST routes ─────────────────────────────────────────────────
      if (request.method === "POST") {
        if (url.pathname === "/chat") {
          return await handleChat(request, env);
        }
        if (url.pathname === "/tts") {
          return await handleTTS(request, env, { streaming: false });
        }
        if (url.pathname === "/tts/stream") {
          return await handleTTS(request, env, { streaming: true });
        }
        if (url.pathname === "/transcribe-token") {
          return await handleTranscribeToken(env);
        }
        return jsonError(`No POST route for ${url.pathname}`, 404);
      }

      return jsonError("Method not allowed", 405);
    } catch (error) {
      console.error(`[${url.pathname}] Unhandled error:`, error);
      return jsonError(String(error), 500);
    }
  },
};

/// Liveness probe. Reports which upstream keys are configured without ever
/// revealing the key values themselves.
function handleHealth(env: Env): Response {
  const body = {
    ok: true,
    service: "clicky-proxy",
    time: new Date().toISOString(),
    upstreams: {
      anthropic: isConfiguredSecret(env.ANTHROPIC_API_KEY),
      elevenlabs: isConfiguredSecret(env.ELEVENLABS_API_KEY),
      assemblyai: isConfiguredSecret(env.ASSEMBLYAI_API_KEY),
    },
    defaultVoiceId: env.ELEVENLABS_VOICE_ID ?? null,
    routes: ["/health", "/voices", "/chat", "/tts", "/tts/stream", "/transcribe-token"],
  };
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { "content-type": "application/json", ...CORS_HEADERS },
  });
}

/// Reads the request body as text, enforcing the size ceiling. Returns the raw
/// string so route handlers can forward it verbatim to the upstream API.
async function readBodyWithLimit(request: Request): Promise<string> {
  const contentLengthHeader = request.headers.get("content-length");
  if (contentLengthHeader) {
    const declaredLength = Number(contentLengthHeader);
    if (Number.isFinite(declaredLength) && declaredLength > MAX_REQUEST_BODY_BYTES) {
      throw new RequestTooLargeError();
    }
  }

  const bodyText = await request.text();
  // Re-check after reading in case content-length was missing or lied.
  if (bodyText.length > MAX_REQUEST_BODY_BYTES) {
    throw new RequestTooLargeError();
  }
  return bodyText;
}

class RequestTooLargeError extends Error {
  constructor() {
    super("Request body exceeds the maximum allowed size");
    this.name = "RequestTooLargeError";
  }
}

async function handleChat(request: Request, env: Env): Promise<Response> {
  if (!isConfiguredSecret(env.ANTHROPIC_API_KEY)) {
    return jsonError("ANTHROPIC_API_KEY is not configured on the Worker", 503);
  }

  let body: string;
  try {
    body = await readBodyWithLimit(request);
  } catch (error) {
    if (error instanceof RequestTooLargeError) {
      return jsonError(error.message, 413);
    }
    throw error;
  }

  // Validate that the body is JSON with a non-empty messages array before we
  // spend an upstream call on it. This catches malformed app requests early.
  let parsedBody: unknown;
  try {
    parsedBody = JSON.parse(body);
  } catch {
    return jsonError("Request body must be valid JSON", 400);
  }
  if (
    typeof parsedBody !== "object" ||
    parsedBody === null ||
    !Array.isArray((parsedBody as { messages?: unknown }).messages) ||
    (parsedBody as { messages: unknown[] }).messages.length === 0
  ) {
    return jsonError("Request body must include a non-empty 'messages' array", 400);
  }

  const upstreamResponse = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": env.ANTHROPIC_API_KEY,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body,
  });

  if (!upstreamResponse.ok) {
    const errorBody = await upstreamResponse.text();
    console.error(`[/chat] Anthropic API error ${upstreamResponse.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: upstreamResponse.status,
      headers: { "content-type": "application/json", ...CORS_HEADERS },
    });
  }

  // Stream the SSE response straight through to the client.
  return new Response(upstreamResponse.body, {
    status: upstreamResponse.status,
    headers: {
      "content-type": upstreamResponse.headers.get("content-type") || "text/event-stream",
      "cache-control": "no-cache",
      ...CORS_HEADERS,
    },
  });
}

async function handleTranscribeToken(env: Env): Promise<Response> {
  if (!isConfiguredSecret(env.ASSEMBLYAI_API_KEY)) {
    return jsonError("ASSEMBLYAI_API_KEY is not configured on the Worker", 503);
  }

  const upstreamResponse = await fetch(
    "https://streaming.assemblyai.com/v3/token?expires_in_seconds=480",
    {
      method: "GET",
      headers: { authorization: env.ASSEMBLYAI_API_KEY },
    }
  );

  const responseBody = await upstreamResponse.text();
  if (!upstreamResponse.ok) {
    console.error(`[/transcribe-token] AssemblyAI token error ${upstreamResponse.status}: ${responseBody}`);
    return new Response(responseBody, {
      status: upstreamResponse.status,
      headers: { "content-type": "application/json", ...CORS_HEADERS },
    });
  }

  return new Response(responseBody, {
    status: 200,
    headers: { "content-type": "application/json", ...CORS_HEADERS },
  });
}

/// Result of validating and normalizing a /tts request body. Exported-shaped
/// so the validation rules are easy to reason about and test.
interface NormalizedTtsRequest {
  text: string;
  voiceId: string;
  modelId: string;
  voiceSettings: Record<string, unknown>;
}

/// Voice IDs are used to build the upstream URL path, so we only allow the
/// alphanumeric characters ElevenLabs actually uses. This prevents path
/// traversal or injection through the voice_id field.
function isSafeVoiceId(voiceId: string): boolean {
  return /^[A-Za-z0-9]{1,40}$/.test(voiceId);
}

/// Validates and normalizes the JSON body of a /tts request. Throws a string
/// describing the problem when the body is invalid so the caller can return a
/// 400 with that message.
export function normalizeTtsRequestBody(rawBody: string, defaultVoiceId: string): NormalizedTtsRequest {
  let parsed: unknown;
  try {
    parsed = JSON.parse(rawBody);
  } catch {
    throw "Request body must be valid JSON";
  }
  if (typeof parsed !== "object" || parsed === null) {
    throw "Request body must be a JSON object";
  }

  const bodyObject = parsed as Record<string, unknown>;

  const text = bodyObject.text;
  if (typeof text !== "string" || text.trim().length === 0) {
    throw "Field 'text' is required and must be a non-empty string";
  }
  if (text.length > MAX_TTS_TEXT_LENGTH) {
    throw `Field 'text' must be at most ${MAX_TTS_TEXT_LENGTH} characters`;
  }

  // The app may override the voice per request; otherwise fall back to the
  // Worker's configured default voice.
  const requestedVoiceId = typeof bodyObject.voice_id === "string" ? bodyObject.voice_id : defaultVoiceId;
  if (typeof requestedVoiceId !== "string" || !isSafeVoiceId(requestedVoiceId)) {
    throw "Field 'voice_id' is missing or malformed and no valid default is configured";
  }

  const modelId = typeof bodyObject.model_id === "string" ? bodyObject.model_id : DEFAULT_TTS_MODEL_ID;

  const voiceSettings =
    typeof bodyObject.voice_settings === "object" && bodyObject.voice_settings !== null
      ? (bodyObject.voice_settings as Record<string, unknown>)
      : { stability: 0.5, similarity_boost: 0.75 };

  return { text, voiceId: requestedVoiceId, modelId, voiceSettings };
}

async function handleTTS(
  request: Request,
  env: Env,
  options: { streaming: boolean }
): Promise<Response> {
  if (!isConfiguredSecret(env.ELEVENLABS_API_KEY)) {
    return jsonError("ELEVENLABS_API_KEY is not configured on the Worker", 503);
  }

  let rawBody: string;
  try {
    rawBody = await readBodyWithLimit(request);
  } catch (error) {
    if (error instanceof RequestTooLargeError) {
      return jsonError(error.message, 413);
    }
    throw error;
  }

  let normalized: NormalizedTtsRequest;
  try {
    normalized = normalizeTtsRequestBody(rawBody, env.ELEVENLABS_VOICE_ID);
  } catch (validationMessage) {
    return jsonError(String(validationMessage), 400);
  }

  // The streaming endpoint begins returning audio before generation finishes,
  // which noticeably lowers the time-to-first-sound for short replies.
  const upstreamPath = options.streaming
    ? `https://api.elevenlabs.io/v1/text-to-speech/${normalized.voiceId}/stream`
    : `https://api.elevenlabs.io/v1/text-to-speech/${normalized.voiceId}`;

  const upstreamResponse = await fetch(upstreamPath, {
    method: "POST",
    headers: {
      "xi-api-key": env.ELEVENLABS_API_KEY,
      "content-type": "application/json",
      accept: "audio/mpeg",
    },
    body: JSON.stringify({
      text: normalized.text,
      model_id: normalized.modelId,
      voice_settings: normalized.voiceSettings,
    }),
  });

  if (!upstreamResponse.ok) {
    const errorBody = await upstreamResponse.text();
    console.error(`[/tts] ElevenLabs API error ${upstreamResponse.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: upstreamResponse.status,
      headers: { "content-type": "application/json", ...CORS_HEADERS },
    });
  }

  return new Response(upstreamResponse.body, {
    status: upstreamResponse.status,
    headers: {
      "content-type": upstreamResponse.headers.get("content-type") || "audio/mpeg",
      "cache-control": "no-cache",
      ...CORS_HEADERS,
    },
  });
}

/// Returns a trimmed-down list of the account's voices (id, name, category) so
/// the app can offer a voice picker without exposing the full ElevenLabs payload.
async function handleListVoices(env: Env): Promise<Response> {
  if (!isConfiguredSecret(env.ELEVENLABS_API_KEY)) {
    return jsonError("ELEVENLABS_API_KEY is not configured on the Worker", 503);
  }

  const upstreamResponse = await fetch("https://api.elevenlabs.io/v1/voices", {
    method: "GET",
    headers: { "xi-api-key": env.ELEVENLABS_API_KEY },
  });

  if (!upstreamResponse.ok) {
    const errorBody = await upstreamResponse.text();
    console.error(`[/voices] ElevenLabs API error ${upstreamResponse.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: upstreamResponse.status,
      headers: { "content-type": "application/json", ...CORS_HEADERS },
    });
  }

  const upstreamData = (await upstreamResponse.json()) as {
    voices?: Array<{ voice_id?: string; name?: string; category?: string }>;
  };

  const simplifiedVoices = (upstreamData.voices ?? []).map((voice) => ({
    voice_id: voice.voice_id,
    name: voice.name,
    category: voice.category,
  }));

  return new Response(JSON.stringify({ voices: simplifiedVoices }), {
    status: 200,
    headers: { "content-type": "application/json", ...CORS_HEADERS },
  });
}
