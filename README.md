Update: April 27, 2026.

Hi there! I'm Farza, the guy that made Clicky.

The existing codebase remains open source. Tinker with it, make it yours, start a company out of it, do whatever you want I don't mind. But, for all the new stuff I'm hacking on, gonna keep it private. To get the latest Clicky, you can go [here](https://www.heyclicky.com/).

I also tweeted about this [here](https://x.com/FarzaTV/status/2043402737828962489).

Go crazy with this repo!! It's an MIT license.

# Hi, this is Clicky.
It's an AI teacher that lives as a buddy next to your cursor. It can see your screen, talk to you, and even point at stuff. Kinda like having a real teacher next to you.

Download it [here](https://www.clicky.so/) for free.

Here's the [original tweet](https://x.com/FarzaTV/status/2041314633978659092) that kinda blew up for a demo for more context.

![Clicky — an ai buddy that lives on your mac](clicky-demo.gif)

This is the open-source version of Clicky for those that want to hack on it, build their own features, or just see how it works under the hood.

## ✨ What's new in this fork

This fork extends the open-source Clicky with a few big additions:

- 🚀 **Clicky Coach — guided walkthroughs (the headline feature).** Ask Clicky how to do a multi-step task ("how do I commit and push", "set up dark mode") and instead of pointing once, it lays out an ordered plan, points at step 1, **watches your screen, and auto-advances** as you complete each step — with a live progress HUD. Hands-free, step-by-step coaching.
- 🎨 **Stylized cursors.** Pick the cursor's shape — **Classic** triangle, **Comet** (with a fading particle trail during flight), **Rocket**, or **Sparkle** — and a **color theme** (Blue, Violet, Emerald, Sunset, Rose, Mono). Themes recolor the cursor, glow, waveform, spinner, and speech bubbles. Choices persist; default is unchanged.
- 🛠 **Hardened, tested Worker.** CORS + preflight, input validation, a 16 MB body limit, a consistent error envelope, a `/health` probe, a streaming `/tts/stream` endpoint, a `/voices` listing, and per-request `voice_id`/`model_id` overrides. Backed by an automated test suite (`npm test`) that boots `wrangler dev` and checks every route, plus a live ElevenLabs TTS check.
- ⚙️ **One-place config.** The Worker URL is read from a single `ClickyProxyBaseURL` Info.plist key instead of being hardcoded across files.

See the per-feature details in `CLAUDE.md`. The cursor and Coach controls live in the menu-bar panel.

## Get started with Claude Code

The fastest way to get this running is with [Claude Code](https://docs.anthropic.com/en/docs/claude-code).

Once you get Claude running, paste this:

```
Hi Claude.

Clone https://github.com/farzaa/clicky.git into my current directory.

Then read the CLAUDE.md. I want to get Clicky running locally on my Mac.

Help me set up everything — the Cloudflare Worker with my own API keys, the proxy URLs, and getting it building in Xcode. Walk me through it.
```

That's it. It'll clone the repo, read the docs, and walk you through the whole setup. Once you're running you can just keep talking to it — build features, fix bugs, whatever. Go crazy.

## Manual setup

If you want to do it yourself, here's the deal.

### Prerequisites

- macOS 14.2+ (for ScreenCaptureKit)
- Xcode 15+
- Node.js 18+ (for the Cloudflare Worker)
- A [Cloudflare](https://cloudflare.com) account (free tier works)
- API keys for: [Anthropic](https://console.anthropic.com), [AssemblyAI](https://www.assemblyai.com), [ElevenLabs](https://elevenlabs.io)

### 1. Set up the Cloudflare Worker

The Worker is a tiny proxy that holds your API keys. The app talks to the Worker, the Worker talks to the APIs. This way your keys never ship in the app binary.

```bash
cd worker
npm install
```

Now add your secrets. Wrangler will prompt you to paste each one:

```bash
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put ASSEMBLYAI_API_KEY
npx wrangler secret put ELEVENLABS_API_KEY
```

For the ElevenLabs voice ID, open `wrangler.toml` and set it there (it's not sensitive):

```toml
[vars]
ELEVENLABS_VOICE_ID = "your-voice-id-here"
```

Deploy it:

```bash
npx wrangler deploy
```

It'll give you a URL like `https://your-worker-name.your-subdomain.workers.dev`. Copy that.

### 2. Run the Worker locally (for development)

If you want to test changes to the Worker without deploying:

```bash
cd worker
npx wrangler dev
```

This starts a local server (usually `http://localhost:8787`) that behaves exactly like the deployed Worker. You'll need to create a `.dev.vars` file in the `worker/` directory with your keys:

```
ANTHROPIC_API_KEY=sk-ant-...
ASSEMBLYAI_API_KEY=...
ELEVENLABS_API_KEY=...
ELEVENLABS_VOICE_ID=...
```

Then point the app at `http://localhost:8787` (see step 3) while developing.

You can also verify the Worker without the app:

```bash
cd worker
npm install
npm run typecheck   # type-checks src/index.ts
npm test            # boots wrangler dev and exercises every route over HTTP
npm run test:live   # also runs one real ElevenLabs TTS call (uses credits)
```

### 3. Point the app at your Worker

The Worker URL lives in **one place** now: the `ClickyProxyBaseURL` key in
`leanring-buddy/Info.plist`. Set it to your Worker URL (no trailing path):

```xml
<key>ClickyProxyBaseURL</key>
<string>https://your-worker-name.your-subdomain.workers.dev</string>
```

`AppBundleConfiguration.proxyBaseURL` reads this and both `CompanionManager`
(Claude + ElevenLabs) and `AssemblyAIStreamingTranscriptionProvider` (token
endpoint) derive their URLs from it — so there's nothing else to edit.

### 4. Open in Xcode and run

```bash
open leanring-buddy.xcodeproj
```

In Xcode:
1. Select the `leanring-buddy` scheme (yes, the typo is intentional, long story)
2. Set your signing team under Signing & Capabilities
3. Hit **Cmd + R** to build and run

The app will appear in your menu bar (not the dock). Click the icon to open the panel, grant the permissions it asks for, and you're good.

### Permissions the app needs

- **Microphone** — for push-to-talk voice capture
- **Accessibility** — for the global keyboard shortcut (Control + Option)
- **Screen Recording** — for taking screenshots when you use the hotkey
- **Screen Content** — for ScreenCaptureKit access

## Architecture

If you want the full technical breakdown, read `CLAUDE.md`. But here's the short version:

**Menu bar app** (no dock icon) with two `NSPanel` windows — one for the control panel dropdown, one for the full-screen transparent cursor overlay. Push-to-talk streams audio over a websocket to AssemblyAI, sends the transcript + screenshot to Claude via streaming SSE, and plays the response through ElevenLabs TTS. Claude can embed `[POINT:x,y:label:screenN]` tags in its responses to make the cursor fly to specific UI elements across multiple monitors. All three APIs are proxied through a Cloudflare Worker.

## Project structure

```
leanring-buddy/          # Swift source (yes, the typo stays)
  CompanionManager.swift    # Central state machine
  CompanionPanelView.swift  # Menu bar panel UI
  ClaudeAPI.swift           # Claude streaming client
  ElevenLabsTTSClient.swift # Text-to-speech playback
  OverlayWindow.swift       # Blue cursor overlay
  AssemblyAI*.swift         # Real-time transcription
  BuddyDictation*.swift     # Push-to-talk pipeline
  CursorStyle.swift         # Cursor styles + color themes + glyph view
  GuidedWalkthroughManager.swift  # Clicky Coach: walkthrough plan + parsers
worker/                  # Cloudflare Worker proxy
  src/index.ts              # Routes: /health, /chat, /tts, /tts/stream, /voices, /transcribe-token
  test/worker.test.mjs      # Integration test suite (npm test)
CLAUDE.md                # Full architecture doc (agents read this)
```

## Contributing

PRs welcome. If you're using Claude Code, it already knows the codebase — just tell it what you want to build and point it at `CLAUDE.md`.

Got feedback? DM me on X [@farzatv](https://x.com/farzatv).
