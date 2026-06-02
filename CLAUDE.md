# CLAUDE.md — MacAudioSync operator & developer guide

Multi-MacBook synced audio: one Mac (the **sender**) captures its system
audio and streams it over the LAN; every other Mac (a **receiver**) plays it
back aligned to the sender's master clock (sub-ms receiver-to-receiver skew).
Read README.md for the architecture; this file is what *you* (Claude) need
to operate, debug, and extend it on whichever Mac you're running on.

## Which role is this Mac?

- **Sender** — this Mac is the one playing the music/video (YouTube,
  Spotify, …). There is exactly ONE sender.
- **Receiver** — this Mac should act as a speaker. Any number of these.
- A Mac can be both (receiver pointed at `127.0.0.1` while sending) — that's
  how you keep the sender's own speakers in sync with everyone else
  (mute nothing; just don't double-play: see "Same room" below).

Ask the user which role this Mac plays if it isn't obvious from their request.

## First-time setup (either role)

```sh
git clone https://github.com/RatikArora/macaudiosync.git   # if not present
cd macaudiosync
git pull                  # ALWAYS pull first — the other Macs push fixes
swift build -c release    # needs Command Line Tools; binaries in .build/release/
```

Both Macs must be on the same Wi-Fi/LAN. macOS may prompt for
**Local Network** access on first run — the user must allow it.

## Sender steps

Two capture modes — pick deliberately:

- **`--party` (default recommendation, macOS 14.2+):** Core Audio process
  tap captures system audio AND MUTES the original output; the sender plays
  the synced delayed timeline through its own speakers via a local
  `SyncedPlayer`. Every speaker in the room (sender + receivers) plays in
  unison → zero *perceived* latency for music. Permission: **System Audio
  Recording** (its own TCC prompt; separate from Screen Recording). Failure
  `AudioHardwareCreateProcessTap failed` → that permission is missing.
- **`--capture`:** ScreenCaptureKit; original keeps playing immediately on
  the sender (use when watching video on the sender's screen, or macOS 13).
  Permission: **Screen Recording**; SCStreamErrorDomain **-3801** ("user
  declined TCCs") always means it's missing.

1. Start (run in background, keep the shell; `caffeinate -i` to survive
   sleep):
   ```sh
   caffeinate -i .build/release/audiosync-send --party
   ```
2. Confirm from its log, in order:
   - `listening on UDP port 7805, Bonjour "<name>" (_audiosync._udp)`
   - party: `local synced playback started` + `process-tap capture started
     (… original output MUTED)`; capture: `system audio capture started`
   - `clients=N packets/s=~300×N` once receivers join (`clients=0
     packets/s=0` just means nobody has connected yet — not an error).
3. User plays audio; that's it. NOTE: in party mode, killing the sender
   un-mutes the system (tap dies with the process) — audio reverts to
   normal local playback, nothing is left broken.

Useful flags: `--tone [freq]` (test signal), `--no-local-play` (party
without sender speakers), `--port <p>`, `--buffer-ms <ms>` (see tuning),
`--name <bonjour name>`.

## Receiver steps

1. Start:
   ```sh
   .build/release/audiosync-recv            # Bonjour auto-discovery
   .build/release/audiosync-recv --connect <sender>.local:7805   # if mDNS blocked
   ```
2. Confirm from its log:
   - `found sender: …` then `connected to …`
   - `playback engine started (48000 Hz, 2ch)`
   - stats line each second — healthy looks like:
     `sync offset=0.0xx ms rtt<1000µs … margin=NNms … (100% fill) … late=0 decodeErr=0`
3. Audio starts ~0.3 s after connect (clock-sync warmup burst).

Test/CI flags: `--headless` (full pipeline, no speakers), `--exit-after <s>`.

### Reading the receiver stats line

| field | meaning | healthy |
|---|---|---|
| `offset` | master-clock offset estimate | stable, sub-ms changes |
| `rtt` | best probe round-trip | <1 ms LAN, <10 ms Wi-Fi |
| `drift` | crystal skew estimate (ppm) | settles within ±50 |
| `buffered` | audio queued ahead | ≈ sender `--buffer-ms` |
| `margin` | min arrival headroom last second | > 30 ms; `LOW` warning printed under 15 ms |
| `fill` | % of frames actually played | 100% |
| `late` | chunks that arrived too late | 0 (occasional 1–2 on Wi-Fi ok) |
| `peak` | max |sample| rendered last second | >0 when audio is actually playing; 0.00 = silence on the wire (nothing playing on sender) |
| `tsJit` | consecutive chunks whose timestamps don't abut (>30µs) | 0 — ALWAYS. Nonzero = sender capture timestamps jitter → crackle at 100% fill; bug on the sender side (see gotcha below) |
| `decodeErr` | malformed packets | 0 |

### Latency tuning (sender's `--buffer-ms`, default 150)

End-to-end delay ≈ buffer-ms + ~25–40 ms fixed stack floor. Watch the
receiver's `margin=`: you can lower buffer-ms by about `margin − 30 ms`.
Raise it if `late>0` or fill < 100%. Wired LAN: 40–60. Good 5 GHz Wi-Fi:
100–150. Congested Wi-Fi: 250–500. Sub-10 ms is NOT achievable (capture
blocks + DAC alone exceed it) — don't promise it; receiver↔receiver skew is
already sub-ms, which is what audible sync quality depends on.

### Wi-Fi dropout bursts (observed in production 2026-06-03)

Symptom: steady 100% fill with margin ~75 ms, but every 10–30 s one second
shows `margin=…LOW`, `late` +60–100, fill 65–90% → audible break. Cause:
macOS Wi-Fi power-save/scan bursts delaying packets 70–150 ms. Fixes in
order: (1) wire the Macs (Ethernet or USB-C cable → buffer 40–60 ms, zero
dropouts); (2) QoS voice-class + AWDL p2p are ON by default — compare with
`--no-p2p` on BOTH sides if things get worse; (3) raise `--buffer-ms` above
the worst burst (250 usually silences busy Wi-Fi). If `pkts` stops climbing
and `buffered` drains to 0, the SENDER died — restart it (keep it with
`caffeinate -i` so the Mac doesn't sleep it).

### Same room / echo

Receivers play `--buffer-ms` behind the sender's own speakers. If sender and
receivers are within earshot: mute the sender's speakers (capture still
works — SCK taps audio before output volume), or also run a local receiver
on the sender Mac (`audiosync-recv --connect 127.0.0.1:7805`) and mute the
original… which needs the not-yet-built process-tap mode (see Roadmap).

## Troubleshooting quick table

| symptom | cause / fix |
|---|---|
| `-3801` on sender | Screen Recording permission missing (see Sender §1) |
| receiver stuck `browsing for senders` | mDNS blocked → use `--connect`; check both Macs on same network; check macOS Local Network permission |
| `pkts=0` but sync works | audio source died on sender — check sender log |
| `late` climbing / fill <100% | buffer too small for this network → raise `--buffer-ms` |
| `decodeErr` nonzero | version mismatch between Macs → `git pull` + rebuild BOTH |
| port in use | another sender instance: `pkill -f audiosync-send` |

## Development rules (keep everything up to date)

1. **Pull before touching anything; push after every change.** The Macs
   share state only through this repo (github.com/RatikArora/macaudiosync).
   After changing behavior, flags, stats format, or procedures: update
   README.md AND this file in the same commit.
2. **Wire compatibility:** if you change `Wire`/packet layout, bump
   `Wire.version` — receivers reject mismatched versions as `decodeErr`,
   and every Mac must be rebuilt. Avoid breaking it casually.
3. **Tests:** run `./run-tests.sh` (NOT bare `swift test` — only Command
   Line Tools are installed, so XCTest is absent and Swift Testing needs
   the framework paths the script adds). All tests must pass before pushing.
   Quick live smoke test (no speakers):
   ```sh
   .build/debug/audiosync-send --tone &
   .build/debug/audiosync-recv --browse --headless --exit-after 10
   # expect: 100% fill, silent=0, late=0, offset ~0.01ms; then pkill -f audiosync-
   ```
4. **Code layout:** `Sources/SyncCore` = pure logic (clock sync, jitter
   buffer, timeline renderer, resampler, wire protocol) — fully
   unit-tested, no network/audio imports; keep it that way.
   `Sources/AudioPipeline` = shared `SyncedPlayer` (AVAudioEngine playback
   of a JitterBuffer against an injected master clock; used by receivers
   and by the sender's party mode). `Sources/AudioSyncSender`,
   `Sources/AudioSyncReceiver` = thin Network.framework/ScreenCaptureKit/
   CoreAudio-tap shells.
5. **Known macOS gotchas (cost real debugging time):**
   - Objects created inside switch-case blocks in `main.swift` top-level
     code are RELEASED when the block ends — dispatch timers/NWBrowser
     silently cancel. Keep long-lived objects in top-level globals.
   - AVAudioEngine's mixer rejects interleaved source formats (error
     -10868): AVAudioSourceNode must use `standardFormatWithSampleRate`
     (deinterleaved) and the render callback deinterleaves scratch.
   - SCK system-audio capture needs Screen Recording TCC, delivers Float32
     possibly planar OR interleaved — both handled in SystemAudioCapture.
   - All timestamps are `CLOCK_UPTIME_RAW` ns (== mach host time == Core
     Audio host clock). Never mix in wall-clock time.
   - NEVER stamp captured audio with per-callback IO host timestamps — they
     jitter ±frames between callbacks, so chunks overlap/gap at every
     boundary = continuous crackle at 100% fill (`tsJit` counts this).
     Synthesize timestamps from a FRAME COUNTER anchored once to the host
     clock with a gentle servo (see ProcessTapCapture.process). Also: do no
     heavy work (resample/encode/send) inside a Core Audio IO callback —
     hop to a serial queue.
6. **Core invariant:** receivers never "play the next packet"; every render
   asks "what does the master timeline put in this window?" Alignment is
   recomputed from timestamps every callback so errors can't accumulate.
   The end-to-end tests assert bit-exact reproduction — keep them passing.

## Roadmap (next features, in value order)

1. ~~Process-tap capture~~ — DONE (--party mode, 2026-06-03).
2. Device-latency calibration (`kAudioDevicePropertyLatency`) per receiver.
3. Micro-resampler driven by `DriftEstimator` (smooth rate-matching instead
   of frame repeat/skip at chunk boundaries).
4. Opus compression for WAN; DTLS if streaming beyond the home LAN.
5. Party-mode niceties: handle default-output-device changes mid-stream
   (rebuild the aggregate); video lip-sync mode (small fixed buffer +
   wired link guidance).
