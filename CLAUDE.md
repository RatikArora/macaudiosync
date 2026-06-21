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

`./make-app.sh` builds `dist/Sonar.app` — a universal (arm64+x86_64)
SwiftUI shell in `Sources/MacAudioSyncApp` that bundles and drives the two
CLI engines as child processes (it contains NO audio/network code; it parses
the engines' log lines for status — if you change log formats, update
`EngineProcess.parse`. It also parses `join-code=`, `diag=`, the
`via <transport>` suffix on the connected line, and high-rate `viz=` spectrum
frames — hex band magnitudes the receiver emits ~24×/s for the visualizer,
which `parse` decodes into `spectrum` and deliberately keeps OUT of the
activity log). The app also self-updates (`Updater`, checks `release/
appcast.json` on GitHub — which MUST carry a `sha256` of `Sonar.app.zip`;
the updater verifies it before swapping and refuses to install without it,
so every release must regenerate the hash: `shasum -a 256 release/Sonar.app.zip`).
Receiver runs with
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
   - `clients=N packets/s=~150–200×N` once receivers join (`clients=0
     packets/s=0` just means nobody has connected yet — not an error). The
     Int16 wire codec packs ~320 frames/packet (`Wire.maxFramesPerPacket(for:
     channels:)`), so the rate is ~half the old fixed 160-frame/300-pps — fewer
     packets = less Wi-Fi airtime — for the same ~1.5 Mbps of audio per receiver.
   - on a Wi-Fi change: `network changed … — rebuilding listener` then a
     fresh `listening on …` + `join-code=` — the process does NOT restart
     (party-mode mute/tap stay up); `SenderServer.rebuildListener` re-binds
     and re-publishes Bonjour on the new interface.
3. User plays audio; that's it. NOTE: in party mode, killing the sender
   un-mutes the system (tap dies with the process) — audio reverts to
   normal local playback, nothing is left broken.

**Follow-system-mute (default ON).** `SystemMuteMonitor` polls the default
output device; when the sender's Mac is muted (F10 / volume 0), `sendAudio`
sends SILENCE (not nothing — keeps the stream/clocks alive) so the WHOLE ROOM
goes quiet, and resumes instantly on unmute. Logs `system muted/unmuted`; the
app reflects it ("Muted — room is silent"). Disable with `--no-follow-mute`.
(Needed because capture taps audio *before* the output volume, so muting your
own Mac otherwise wouldn't mute receivers.)

Useful flags: `--tone [freq]` (test signal), `--no-local-play` (party
without sender speakers), `--no-follow-mute`, `--latency <music|video|call>`
(latency profile — see tuning; default music), `--no-adapt` (pin the buffer at
the floor — disables auto-raise), `--port <p>`, `--buffer-ms <ms>` (see tuning),
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
| `buffered` | audio queued ahead | ≈ the sender's current buffer (`--buffer-ms` floor, auto-raised) |
| `margin` | min arrival headroom last second | > 30 ms; `LOW` warning printed under 15 ms |
| `fill` | % of frames actually played | 100% |
| `late` | chunks that arrived too late | 0 (occasional 1–2 on Wi-Fi ok) |
| `peak` | max |sample| rendered last second | >0 when audio is actually playing; 0.00 = silence on the wire (nothing playing on sender) |
| `tsJit` | consecutive chunks whose timestamps don't abut (>30µs) | 0 — ALWAYS. Nonzero = sender capture timestamps jitter → crackle at 100% fill; bug on the sender side (see gotcha below). NOTE: an adaptive buffer RAISE deliberately steps `playAt` forward once — that shows as a brief fill dip (concealed), NOT as `tsJit` (the step is one clean gap, not jittered abutment) |
| `decodeErr` | malformed packets | 0 (also counts wrong-`--key` and unknown-codec packets) |

The receiver still sends a once-a-second `feedback` packet upstream (min
margin, late delta, fill‰, buffered, rtt) — only while actively receiving —
but the sender **does NOT act on it** (it's informational, for the receiver's
own stats and possible future use). The `feedback` case in `SenderServer.handle`
is a no-op.

### Latency profiles (`--latency music|video|call`) — pick the tradeoff

What you stream decides the latency tradeoff, so the sender has three profiles
(each is a `(floor, ceiling)` the adaptive buffer lives within;
`SenderOptions.LatencyProfile`, passed to `SenderServer` as `bufferDelayMs`
floor + `ceilingMs`):
- **music** (default): floor 150, ceiling **400**. Dropout-free wins; lip-sync
  is irrelevant for audio, so it may buffer generously. (The old ceiling was a
  runaway 1000ms — that's the "ms got too high, video looked off" report; it's
  now 400 for music and ~130 for video/call.)
- **video**: floor 80, ceiling **130** (~100ms). Keeps the **sender's own
  screen** in lip-sync — in `--party` the sender plays its audio `buffer-ms`
  behind its video, so a big buffer = visible lip-sync drift on the sender.
- **call**: floor 80, ceiling **130**. Tight for natural Zoom/Meet/Teams/
  FaceTime back-and-forth.
`--buffer-ms` overrides the floor (e.g. `--latency video --buffer-ms 60`).

**Recognition is manual + honest, never auto-switching** (changing latency
mid-stream means a brief resync blip, so we never do it under the user). The app
(`ContentDetector`) only *suggests*, and only when it's actually SURE — because
from captured audio you **cannot** tell music from video (same PCM). Confident
signals: mic-in-use (CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere` on
the default input, zero permissions — catches Zoom/Meet/Teams/FaceTime) or a
conferencing app frontmost → **call**; a *dedicated* video player
(QuickTime/VLC/IINA/TV/Netflix) frontmost → **video**. A **browser** frontmost is
deliberately NOT treated as video — YouTube et al. is just as often music, and
forcing the tight buffer on music risks dropouts (this was the bug). Instead, if
a browser is up front AND audio is playing (`...DeviceIsRunningSomewhere` on the
default *output*), the picker shows an honest "can't tell — pick it yourself"
hint and defaults to **music**. Only a *confident* reading shows the
"Detected …" pill. The user confirms/overrides via the segmented picker in
`SenderView` (`LatencyModeRow`, `ContentSuggestion`), locked while streaming. CLI
is purely manual (`--latency`). Switching profiles = stop and restart the sender.

### Buffer auto-raise within a profile (sender's `--buffer-ms` = the floor)

End-to-end delay ≈ buffer-ms + ~25–40 ms fixed stack floor. **The buffer
auto-adapts (default ON): `--buffer-ms` is the FLOOR/initial; the sender
ratchets it UP — never down — toward whatever the worst-case receiver needs for
a clean, no-drop stream, then HOLDS.** This is the artifact-free scheme the old
fixed buffer was waiting for: the receivers already report health upstream
(`Feedback`: margin/late/fill), and `SenderServer.controlTick` (1 Hz) feeds the
worst case to the unit-tested `AdaptiveController` (raise-only ratchet:
distress=late|fill<98.5%|margin<12 → +30 ms; tight=margin<30 → +10 ms;
healthy → hold). Each raise is applied as a **single STEP** — the next packet's
`playAt` jumps forward by the increment, which every receiver renders as ONE
brief silence gap that `GapConcealer` fades in/out click-free. We never LOWER it
(shrinking the deadline makes in-flight packets land late = a real break) and
never SLEW it (the continuous ramp was the static we used to hear — a clean step
+ concealment is what makes runtime tuning safe; `bufferDelayNs` is guarded by
`bufferLock` and read once per `sendAudio`). After a raise the controller skips
3 ticks (`raiseSettleTicks`) so the raise's own dip doesn't read as fresh
distress and overshoot. `--no-adapt` pins the buffer at the floor (old fixed
behavior). To set the floor by hand: watch `margin=` — a comfortable floor is
roughly `margin − 30 ms`; you can still raise `--buffer-ms` (or wire the Macs)
to skip the climb-from-cold. Wired LAN ~40–60. Good 5 GHz Wi-Fi ~100–150.
Congested Wi-Fi: just let it adapt. Sub-10 ms is NOT achievable (capture blocks
+ DAC alone exceed it) — don't promise it; receiver↔receiver skew is sub-ms,
which is what audible sync depends on, and adaptation keeps every receiver on
the SAME buffer so that skew is preserved.

### Wi-Fi dropout bursts (observed in production 2026-06-03)

Symptom: steady 100% fill with margin ~75 ms, but every 10–30 s one second
shows `margin=…LOW`, `late` +60–100, fill 65–90% → a brief dropout. Cause:
macOS Wi-Fi power-save/scan bursts delaying packets 70–150 ms. **`GapConcealer`
(in `SyncedPlayer`) now makes those drops a click-free dip instead of a pop** —
it holds+fades the last good sample and crossfades audio back in, so the abrupt
step to/from zero that you actually *hear* is gone. The stats still report the
underlying gap honestly (`fill`<100%, `late`), but it's far less audible. The
16-bit wire format halves the traffic that causes congestion. The buffer now
auto-raises (see Latency tuning): a sustained burst pattern makes the sender
ratchet the buffer up until the bursts fit inside it, then it holds — so this
class of dropout self-corrects within a few seconds without you touching a flag.
If you've pinned it with `--no-adapt`, or want to skip the climb, in
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
| receiver logs `diag=isolated` (connected, but no audio) | network blocks device-to-device traffic (client isolation) or filters our port. THE common corporate-Wi-Fi failure. The receiver now **auto-fails-over to AWDL**: on each isolated round it toggles `forcePeerToPeer`, reconnecting with `NWParameters.prohibitedInterfaces = [en0…]` so the only path left is the direct Mac-to-Mac AWDL radio (what AirDrop uses) — bypasses the AP and the subnet. Verify with `sudo tcpdump -i awdl0 udp`. `--p2p-only` pins it to AWDL. If even AWDL is blocked, escalates (after 3 strikes) to "use a hotspot/cable" |
| receiver logs `diag=unreachable` | `--connect`/Manual Connect to a wrong or absent address (UDP has no handshake, so a bad address looks like silence) → check the IP:port and that the sender is running on the same network |
| receiver logs `diag=key` | wrong `--key`/password (decode/seal failed) → set the SAME password on both. App title: "Password doesn't match the sender" |
| receiver logs `diag=version` | the two Macs run different `Wire.version` → update both (the app offers it). App title: "Update needed — different versions" |
| garbled audio for ~10–15 s after a Mac wakes from sleep | should NOT happen anymore — `ClockSynchronizer` detects the offset step (CLOCK_UPTIME_RAW pauses during sleep) and flushes its window to re-baseline instead of averaging across the discontinuity (`stepThresholdNs`) |
| app pinning CPU while hidden | should NOT happen — `AppActivity` pauses the ripple/waveform/radar TimelineViews when no window is visible (occluded/miniaturized/hidden). Audio is unaffected (engine subprocess) |
| `pkts=0` / `peak=0.00` but sync works | audio source died on sender (nothing playing) — check sender log |
| `late` climbing / fill <100% | network can't keep up at this buffer — the sender now auto-raises it within a few seconds (watch for `buffer raised …` in the sender log, then fill should recover and hold). If it's pinned with `--no-adapt`, raise `--buffer-ms` by hand or wire the Macs |
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
   `GapConcealer`, `AdaptiveController` + `Feedback`) — fully unit-tested, no
   network/audio imports; keep it that way. `Sources/AudioPipeline` = shared
   `SyncedPlayer` (AVAudioEngine playback of a JitterBuffer against an injected
   master clock; used by receivers and by the sender's party mode — it runs the
   renderer's per-frame coverage mask through `GapConcealer` so a late/lost
   packet is a click-free dip, not a pop; it also feeds its output to a
   `SpectrumAnalyzer` (Accelerate FFT → log-spaced bands) that drives the app's
   real visualizer). `Sources/AudioSyncSender`,
   `Sources/AudioSyncReceiver` = thin Network.framework/ScreenCaptureKit/
   CoreAudio-tap shells. `AdaptiveController` is now WIRED into the sender
   (`SenderServer.controlTick`): it raise-only ratchets `bufferDelayNs` from
   live receiver `Feedback`, applied as concealed STEPs (see Latency tuning).
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
   - **The send buffer auto-raises by STEP, never by SLEW, never down.** The
     hard-won rule is about HOW you change it: a continuous slew (a few µs per
     packet) shifts every later `playAt` by tiny amounts forever → continuous
     static; lowering it makes in-flight packets land late → a real break. Both
     are still forbidden. What IS safe (and now wired): a single discrete STEP
     UP — the next packet's `playAt` jumps forward once, the receiver renders
     exactly one silence gap, and `GapConcealer` fades it click-free. That's the
     "grow by inserting silence" scheme. `bufferDelayNs` is now a `var` guarded
     by `bufferLock` (written by `controlTick` on the net queue, read once per
     `sendAudio` on the capture queue) and only ever ratchets up via
     `AdaptiveController`. `--no-adapt` keeps it pinned (old fixed behavior).
6. **Core invariant:** receivers never "play the next packet"; every render
   asks "what does the master timeline put in this window?" Alignment is
   recomputed from timestamps every callback so errors can't accumulate.
   The end-to-end tests assert bit-exact reproduction — keep them passing.
   - **Drift-locked playback (no frame-snap clicks).** `SyncedPlayer` does NOT
     re-anchor its render window to the master clock every callback — that
     snapped a whole sample at each DAC-drift / clock-correction step (a faint
     periodic tick that needed an external mic to spot; the audio data was
     complete, the receiver was just dropping/repeating one frame to stay
     time-aligned). Instead it advances a **continuous fractional playhead**
     and a gentle proportional servo nudges the consume rate by a few tens of
     ppm (`rateRatio`, clamped ±0.003 ≈ 5 cents, inaudible) so the playhead
     tracks the master clock by **micro-resampling** (`TimelineRenderer.
     renderResampled`, linear interpolation) rather than skipping frames. A
     jump bigger than `resyncThresholdNs` (50 ms: startup, reconnect, wake)
     re-anchors instead of slewing. At `ratio == 1` + zero sub-frame offset
     `renderResampled` is bit-for-bit identical to the grid `render`, so the
     bit-exact tests and `--party` identity-clock path are unaffected. The
     headless test renderer still uses contiguous-window grid `render` (it
     measures fill, doesn't drive a real DAC).

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
5. ~~Micro-resampler for DAC drift~~ — DONE (2026-06-22): `SyncedPlayer`'s
   continuous playhead + servo + `TimelineRenderer.renderResampled` resamples
   to the local DAC instead of frame-snapping, killing the periodic seam click.
   (Could still be refined: drive the servo from `DriftEstimator` directly, or
   swap linear interp for windowed-sinc if golden ears object.)
6. Party-mode niceties: handle default-output-device changes mid-stream
   (rebuild the aggregate); video lip-sync mode (small fixed buffer +
   wired link guidance).
