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

## The app

`./make-app.sh` builds `dist/MacAudioSync.app` — a universal (arm64+x86_64)
SwiftUI shell in `Sources/MacAudioSyncApp` that bundles and drives the two
CLI engines as child processes (it contains NO audio/network code; it parses
the engines' log lines for status — if you change log formats, update
`EngineProcess.parse`. It now also parses `join-code=`, `diag=`, and the
`via <transport>` suffix on the connected line). Receiver runs with
auto-restart (now a backstop only — the engine self-heals network changes
in-process without dying; see below). Sender auto-selects `--party`
(macOS 14.2+) or `--capture` (older), and stays `autoRestart=false` on
purpose (a process restart in party mode would un-mute/re-mute system audio).
The receiver UI has a **Manual Connect** field (→ `--connect`); the sender UI
shows a copyable **join code**. The app is the preferred thing to give
non-technical users; `dist/` is gitignored, rebuild after every engine change.

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
   - `listening on UDP port <N>, Bonjour "<name>" (_audiosync._udp)` — N is
     OS-assigned (ephemeral 49152–65535) by default; use `--port <p>` to
     pin. The randomized default dodges corporate Wi-Fi controllers that
     filter specific ports (we hit one office filtering 7805 on 2026-06-03);
     the IANA dynamic range is essentially never on those blocklists.
     Receivers using `--browse` auto-pick up whatever port the sender
     publishes via Bonjour; `--connect` users read N from this log line.
   - `join-code=<ip>:<port> (en0)` — copyable address for `--connect` /
     the app's Manual Connect when discovery is blocked. Re-emitted on every
     listener (re)bind, so after a network change read the newest one.
   - party: `local synced playback started` + `process-tap capture started
     (… original output MUTED)`; capture: `system audio capture started`
   - `clients=N packets/s=~300×N` once receivers join (`clients=0
     packets/s=0` just means nobody has connected yet — not an error).
   - on a Wi-Fi change: `network changed … — rebuilding listener` then a
     fresh `listening on …` + `join-code=` — the process does NOT restart
     (party-mode mute/tap stay up); `SenderServer.rebuildListener` re-binds
     and re-publishes Bonjour on the new interface.
3. User plays audio; that's it. NOTE: in party mode, killing the sender
   un-mutes the system (tap dies with the process) — audio reverts to
   normal local playback, nothing is left broken.

Useful flags: `--tone [freq]` (test signal), `--no-local-play` (party
without sender speakers), `--port <p>`, `--buffer-ms <ms>` (see tuning),
`--name <bonjour name>`, `--key <passphrase>` (encrypt/authenticate the
stream — ChaCha20-Poly1305; receivers need the same `--key`; without it
the wire is plaintext and anyone on the LAN can listen — recommend a key
on shared Wi-Fi. Receivers that can't authenticate get ZERO packets;
mismatches show as receiver `decodeErr` + an `ENCRYPTION MISMATCH` log
line).

## Receiver steps

1. Start:
   ```sh
   .build/release/audiosync-recv            # Bonjour auto-discovery
   .build/release/audiosync-recv --connect <ip>:<port> # if mDNS blocked (use the sender's join-code)
   ```
2. Confirm from its log:
   - `found sender: …` then `connected to … via <transport>` (transport is
     `Wi-Fi router` / `wired Ethernet` / `peer-to-peer (AWDL)`)
   - `playback engine started (48000 Hz, 2ch)`
   - stats line each second — healthy looks like:
     `sync offset=0.0xx ms rtt<1000µs … margin=NNms … (100% fill) … late=0 decodeErr=0`
3. Audio starts ~0.3 s after connect (clock-sync warmup burst).

**Self-healing (no process restart).** The receiver keeps its audio engine,
jitter buffer and clock estimate alive for the whole process and only swaps
its `NWConnection` on trouble. An `NWPathMonitor` reconnects proactively on a
Wi-Fi/hotspot change; a traffic watchdog reconnects after 3 s of silence
(silently-dead sender, filtered/isolated network). All triggers funnel through
one generation-guarded `ReceiverClient.reconnect`. Resume is near-instant
because the master-clock offset survives the swap. On resume you'll see
`stream resumed — reconnected to … via …`. If it can't get audio it prints a
diagnosis line: `diag=no-mdns` (discovery blocked → Manual Connect / hotspot)
or `diag=isolated` (client isolation / port filter → hotspot or cable).

Test/CI flags: `--headless` (full pipeline, no speakers), `--exit-after <s>`.

### Reading the receiver stats line

| field | meaning | healthy |
|---|---|---|
| `offset` | master-clock offset estimate | stable, sub-ms changes |
| `rtt` | best probe round-trip | <1 ms LAN, <10 ms Wi-Fi |
| `drift` | crystal skew estimate (ppm) | settles within ±50 |
| `buffered` | audio queued ahead | ≈ the sender's fixed `--buffer-ms` |
| `margin` | min arrival headroom last second | > 30 ms; `LOW` warning printed under 15 ms |
| `fill` | % of frames actually played | 100% |
| `late` | chunks that arrived too late | 0 (occasional 1–2 on Wi-Fi ok) |
| `peak` | max |sample| rendered last second | >0 when audio is actually playing; 0.00 = silence on the wire (nothing playing on sender) |
| `tsJit` | consecutive chunks whose timestamps don't abut (>30µs) | 0 — ALWAYS. Nonzero = sender capture timestamps jitter → crackle at 100% fill; bug on the sender side (see gotcha below). The buffer is fixed, so a buffer change can never be the cause |
| `decodeErr` | malformed packets | 0 (also counts wrong-`--key` and unknown-codec packets) |

The receiver still sends a once-a-second `feedback` packet upstream (min
margin, late delta, fill‰, buffered, rtt) — only while actively receiving —
but the sender **does NOT act on it** (it's informational, for the receiver's
own stats and possible future use). The `feedback` case in `SenderServer.handle`
is a no-op.

### Latency tuning (sender's `--buffer-ms`, default 150 — a FIXED value)

End-to-end delay ≈ buffer-ms + ~25–40 ms fixed stack floor. **The buffer is
FIXED for the whole stream — the sender never changes it at runtime.** We tried
adapting it (raise-and-lower, then raise-only); BOTH broke audio: changing the
buffer mid-stream shifts every subsequent packet's play time, and the receiver
hears that seam as a click or a burst of static while the timeline ramps. A
constant buffer is the only thing that guarantees the stream never breaks from
buffer tuning, so adaptation is gone — `--buffer-ms` is set once and held
(`SenderServer.bufferDelayNs`). Tune it by hand for the network: watch the
receiver's `margin=` — a comfortable floor is roughly `margin − 30 ms`; if you
see `late`/fill<100%, raise `--buffer-ms` (or wire the Macs). Wired LAN ~40–60.
Good 5 GHz Wi-Fi ~100–150. Congested Wi-Fi higher. Sub-10 ms is NOT achievable
(capture blocks + DAC alone exceed it) — don't promise it; receiver↔receiver
skew is already sub-ms, which is what audible sync depends on.
(`AdaptiveController`/`Feedback` remain in SyncCore, unit-tested but unwired —
reserved for a future artifact-free scheme, e.g. growing the buffer by
inserting silence rather than shifting timestamps.)

### Wi-Fi dropout bursts (observed in production 2026-06-03)

Symptom: steady 100% fill with margin ~75 ms, but every 10–30 s one second
shows `margin=…LOW`, `late` +60–100, fill 65–90% → audible break. Cause:
macOS Wi-Fi power-save/scan bursts delaying packets 70–150 ms. The 16-bit wire
format halves the traffic that causes congestion. The buffer no longer adapts
(it broke audio — see Latency tuning), so you tune it by hand. If it breaks, in
order: (1) wire the Macs (Ethernet or USB-C cable → `--buffer-ms 40–60`, zero
dropouts); (2) QoS voice-class + AWDL p2p are ON by default — compare with
`--no-p2p` on BOTH sides if things get worse; (3) raise `--buffer-ms` above your
worst observed burst (e.g. 250–500). If `pkts` stops climbing
and `buffered` drains to 0, the SENDER's audio source died (or the sender
process exited) — but a mere Wi-Fi change no longer kills either side; the
receiver prints `reconnecting …` and resumes by itself. Keep the sender under
`caffeinate -i` so the Mac doesn't sleep it.

### Same room / echo

Receivers play `--buffer-ms` behind the sender's own speakers. If sender and
receivers are within earshot: mute the sender's speakers (capture still
works — SCK taps audio before output volume), or also run a local receiver
on the sender Mac (`audiosync-recv --connect 127.0.0.1:<port>`) and mute the
original… which needs the not-yet-built process-tap mode (see Roadmap).

## Troubleshooting quick table

| symptom | cause / fix |
|---|---|
| `-3801` on sender | Screen Recording permission missing (see Sender §1) |
| receiver logs `diag=no-mdns` / stuck `browsing for senders` | mDNS/Bonjour blocked → use the sender's `join-code=` with `--connect` (or the app's Manual Connect); check both Macs on same network + macOS Local Network permission |
| receiver logs `diag=isolated` (connected, but no audio) | network blocks device-to-device traffic (client isolation) or filters our port → use a personal hotspot or a cable; or `--no-p2p` toggling. This is THE common corporate-Wi-Fi failure |
| `pkts=0` / `peak=0.00` but sync works | audio source died on sender (nothing playing) — check sender log |
| `late` climbing / fill <100% | network can't keep up at this buffer — raise `--buffer-ms` (the buffer is fixed, it won't self-correct) or wire the Macs |
| `decodeErr` nonzero | wire-version mismatch (must be v2 on BOTH → `git pull` + rebuild BOTH), OR wrong `--key`, OR unknown codec tag |
| port in use | another sender instance: `pkill -f audiosync-send` |
| stream breaks on Wi-Fi/hotspot switch | should NOT happen anymore — both sides watch `NWPathMonitor` and re-establish in-process (receiver `reconnect`, sender `rebuildListener`). If it does, check for `network changed …` / `reconnecting …` lines and that Local Network permission is granted on the new network |
| receiver shows `connected to …` but `pkts=0 rtt=—`, ping/ARP work but `nc -uvz <peer> <port>` fails | corporate Wi-Fi controller filtering our UDP port (other random high ports pass). Default is an OS-assigned ephemeral port to dodge this; the receiver now prints `diag=isolated` and keeps retrying via `ReceiverClient.reconnect` (re-resolving the port). If the user pinned `--port` to a blocked port, drop the flag |
| `buffered`/`margin` grow by seconds per second, `tsJit` climbs ~190/s, garbled audio | sender's tap delivered a different buffer layout than its nominal format claimed (frame count miscomputed → timeline runs 2× fast). Fixed 2026-06-03 by deriving layout from the buffer list's `mNumberChannels`; if it recurs, check the sender's one-time `tap IO layout:` log line and any `WARNING: tap timeline diverged` lines |

## Development rules (keep everything up to date)

1. **Pull before touching anything; push after every change.** The Macs
   share state only through this repo (github.com/RatikArora/macaudiosync).
   After changing behavior, flags, stats format, or procedures: update
   README.md AND this file in the same commit.
2. **Wire compatibility:** `Wire.version` is **2** (v2 added the per-packet
   audio codec byte + the client→server `feedback` message). If you change
   `Wire`/packet layout, bump the version — receivers reject mismatched
   versions, and every Mac must be rebuilt. Audio packets carry an
   `AudioCodec` tag (per-packet, so the tier can change mid-stream): `0`
   Float32 (bit-exact, used by tests + local party playback), `1` Int16
   (default on the wire), `2` Opus (reserved, not implemented). `feedback` is
   client→server only — the receiver ignores it if echoed back, symmetric to
   how the sender ignores `audio`/`clockReply` from clients.
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
   buffer, timeline renderer, resampler, wire protocol, `AudioCodec`,
   `AdaptiveController` + `Feedback`) — fully unit-tested, no network/audio
   imports; keep it that way. `Sources/AudioPipeline` = shared `SyncedPlayer`
   (AVAudioEngine playback of a JitterBuffer against an injected master clock;
   used by receivers and by the sender's party mode). `Sources/AudioSyncSender`,
   `Sources/AudioSyncReceiver` = thin Network.framework/ScreenCaptureKit/
   CoreAudio-tap shells. `AdaptiveController` is unit-tested but currently
   UNWIRED — the sender holds a fixed `bufferDelayNs` and never tunes it at
   runtime (runtime buffer changes broke audio; see Latency tuning).
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
   - **Reconnect lifecycle (network resilience):** a cancelled `NWConnection`
     can still deliver one in-flight callback. Every connection callback is
     guarded by a **generation counter** (`gen == self.generation`) so stale
     ones no-op. All reconnect triggers (path change, watchdog, `.failed`,
     receive error) funnel through ONE serialized `reconnect()` on
     `audiosync.recv.net`; never call `exit()` for a network problem. NEVER
     `removeAll()` the jitter buffer or recreate `ClockSynchronizer` on
     reconnect — the master-clock offset is per-boot and stays valid, so
     keeping it is what makes resume instant. `NWPathMonitor` only reconnects
     on a *transition* (dedupe on status+interface-set), and holds (renders
     silence) while the path is unsatisfied. Same generation+debounce pattern
     guards the sender's `rebuildListener`.
   - **The send buffer is FIXED — never tune it at runtime.** We tried both an
     adaptive raise/lower controller and a raise-only ratchet with a sub-30 µs
     slew; both still produced audible clicks/static, because ANY change to the
     buffer shifts every later packet's `playAt`, and the receiver hears that
     timeline seam. `SenderServer.bufferDelayNs` is set once from `--buffer-ms`
     and held for the whole stream. If you ever re-add adaptation, do it without
     shifting timestamps (e.g. grow the buffer by inserting real silence), not
     by sliding `playAt`.
6. **Core invariant:** receivers never "play the next packet"; every render
   asks "what does the master timeline put in this window?" Alignment is
   recomputed from timestamps every callback so errors can't accumulate.
   The end-to-end tests assert bit-exact reproduction — keep them passing.

## Roadmap (next features, in value order)

1. ~~Process-tap capture~~ — DONE (--party mode, 2026-06-03).
2. ~~Seamless network-change recovery~~ — DONE (2026-06-20): `NWPathMonitor`
   + in-process reconnect/`rebuildListener`, no teardown on Wi-Fi/hotspot
   switch. ~~Honest connect diagnosis~~ (`diag=no-mdns`/`isolated`) + join
   code + Manual Connect — DONE. ~~Int16 wire codec + adaptive buffer~~ — DONE.
3. **Opus codec tier** (`AudioCodec.opus` is reserved): perceptual VBR + FEC/
   PLC for very-bad-Wi-Fi/WAN. Needs a libopus dependency (vendored SwiftPM C
   target or a package) behind a build flag, with capability negotiation so a
   receiver that lacks it still gets PCM. The codec seam + per-packet tag are
   already in place.
4. Device-latency calibration (`kAudioDevicePropertyLatency`) per receiver.
5. Micro-resampler driven by `DriftEstimator` for DAC drift (the adaptive
   buffer already uses a smooth sub-threshold slew — extend that technique).
6. Party-mode niceties: handle default-output-device changes mid-stream
   (rebuild the aggregate); video lip-sync mode (small fixed buffer +
   wired link guidance).
