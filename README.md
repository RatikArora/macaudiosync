# Sonar

Play audio from one MacBook on **two or more MacBooks at the same time, in
sync** — like AirPlay multi-room, but for *any* system audio (YouTube in a
browser, Spotify, anything), over your own Wi-Fi/LAN, with no extra hardware.

One Mac is the **sender** (master): it captures whatever the Mac is playing,
stamps every packet with "play this at master-clock time T", and serves its
clock to receivers. Every other Mac runs the **receiver**: it synchronizes
its clock to the sender (NTP-style, sub-millisecond on a LAN), buffers the
audio, and plays each sample exactly when the master timeline says to.

```
Sender Mac (master)                     Each receiver Mac
┌──────────────────────────┐           ┌──────────────────────────────┐
│ ScreenCaptureKit         │           │ UDP client (Network.framework)│
│  └─ system audio (PCM)   │   Wi-Fi   │  └─ jitter buffer (reorder,  │
│ stamp: play-at = now+750ms│──UDP/LAN─▶│      dedup, drop-late)       │
│ packetize ≤ MTU          │  Bonjour  │ clock sync: NTP-style probes │
│ clock server (t2/t3)     │◀──probes──│  min-RTT filter + median     │
│ Bonjour _audiosync._udp  │           │ TimelineRenderer             │
└──────────────────────────┘           │  └─ AVAudioEngine → speakers │
                                       └──────────────────────────────┘
```

## The app (easiest way)

**Download:** [`release/Sonar.app.zip`](release/Sonar.app.zip)
— universal (Apple Silicon + Intel), macOS 13+.

**First open on each Mac** (the app is ad-hoc signed, not notarized, so
macOS blocks downloaded copies once): double-click it, dismiss the "can't
be opened" dialog with **Done**, then System Settings → Privacy & Security
→ scroll down → **Open Anyway**. Or in Terminal:
`xattr -cr /path/to/Sonar.app`. After that it opens normally
forever. (Apps built locally with `./make-app.sh` are never blocked.)

Or build it yourself:

```sh
./make-app.sh        # builds dist/Sonar.app — universal (Apple Silicon + Intel)
```

Double-click `Sonar.app`, pick **Send** on the Mac playing the music
and **Receive** on every other Mac. That's the whole flow. Share the app by
AirDropping/zipping it to any Mac (macOS 13+); first launch on another Mac
needs right-click → Open (it's ad-hoc signed, no developer account).

- Sender uses party mode automatically (zero perceived latency); Macs older
  than 14.2 fall back to capture mode.
- **Pick your sender.** If more than one Mac is broadcasting, the receiver
  lists them by name and lets you choose; one sender just connects. Name your
  Mac in the sender's "Broadcast name" field.
- **Guided permissions.** If a capture permission is missing, the app says
  exactly which one and gives a button straight to the right System Settings
  pane, then a Try Again — instead of a cryptic failure.
- **A real sonar scope.** The sender shows each connected Mac as a live blip on
  a radar sweep, and the receiver's visualizer is a true FFT spectrum of the
  audio playing (not a canned animation).
- **Survives network changes.** Switch Wi-Fi, move to a phone hotspot, or
  roam between APs and the audio keeps going — both sides watch the network
  path and re-establish the stream underneath the still-running speakers
  (a ~1 s gap, not a teardown). The sender re-publishes itself on the new
  network without restarting.
- **Tells you why it can't connect.** On a locked-down network the receiver
  says whether discovery is blocked (*use Manual Connect*) or the network is
  blocking device-to-device traffic / *client isolation* (*use a hotspot or a
  cable*) — instead of failing silently. The sender shows a copyable **join
  code** for the Manual Connect field.
- **Lighter on the network, self-tuning buffer.** Audio is sent as 16-bit PCM
  (half the bandwidth of before, perceptually identical). The latency buffer
  **auto-adapts**: `--buffer-ms` is the floor, and when a receiver reports it's
  running low on headroom (late packets / falling fill) the sender ratchets the
  buffer **up** — never down — until the stream is clean again, then holds. Each
  raise is a single step that lands as one brief, click-free dip (concealed),
  not the continuous static that live *slewing* used to cause — so a jittery
  network stops breaking up on its own without you touching a flag. `--no-adapt`
  pins it at the floor.
- **Updates itself.** An update banner appears in-app when a newer build is on
  GitHub — one click downloads it, swaps the app in place, and relaunches. (Also
  in the About sheet.)
- The app drives the same engines as the CLI below; permission prompts
  (System Audio Recording, Local Network) belong to the app itself.

## Build (CLI)

Requires macOS 13+ and the Swift toolchain (Xcode or Command Line Tools).

```sh
cd MacAudioSync
swift build -c release
```

Binaries land in `.build/release/audiosync-send` and
`.build/release/audiosync-recv`.

## Use across two (or more) MacBooks

**1. Get the project onto the other MacBook(s).** Either:
   - AirDrop / copy this whole folder and run `swift build -c release` there, or
   - copy just the built binary `.build/release/audiosync-recv` (same CPU
     architecture: Apple Silicon → Apple Silicon).

**2. On the Mac that plays the music (sender):**

```sh
.build/release/audiosync-send --party      # recommended (macOS 14.2+)
```

   **`--party` = zero perceived latency.** It taps the system audio, *mutes
   the original output*, and plays the synced delayed timeline through this
   Mac's own speakers too — so this Mac and every receiver play in unison
   (within ~1 ms, the clock-sync precision). There is no "early" copy left
   to compare against, so the buffer delay becomes inaudible for music.
   First run prompts for **System Audio Recording** permission.

   Alternative: `--capture` (ScreenCaptureKit) keeps the original audio
   playing immediately on the sender — use for video lip-sync on the
   sender's screen, or on macOS 13. Needs **Screen Recording** permission.

   Make sure all Macs are on the **same Wi-Fi/LAN**.

**3. On every other Mac (receivers):**

```sh
.build/release/audiosync-recv
```

   That's it — it finds the sender via Bonjour, syncs, and starts playing.
   It also rides through Wi-Fi changes: switch networks or move to a hotspot
   and it re-discovers and resumes on its own (the master clock is preserved,
   so resume is near-instant).

   If discovery is blocked (some networks filter mDNS), connect directly. The
   sender prints a copyable **join code** on startup — `join-code=<ip>:<port>`
   (re-printed after any network change, since the address changes) — use it:

```sh
.build/release/audiosync-recv --connect <ip>:<port>
```

   If the receiver connects but no audio flows, it will say so explicitly:
   `diag=no-mdns` means discovery is blocked (use the join code above);
   `diag=isolated` means the network blocks device-to-device traffic (client
   isolation) — use a personal hotspot or a cable between the Macs.

**4. Play YouTube / Spotify / anything on the sender Mac.** All Macs play
   it together. In `--party` mode that includes the sender's own speakers,
   perfectly in step with everyone. (In `--capture` mode the sender's
   speakers play `--buffer-ms` ahead of the receivers — mute the sender or
   sit in another room.)

### Options

```
audiosync-send:
  --party              tap system audio, MUTE the original, play the synced
                       timeline locally too (zero perceived latency;
                       macOS 14.2+; alias --capture-mute)
  --no-local-play      with --party: capture+mute without local playback
  --capture            stream system audio via ScreenCaptureKit (original
                       keeps playing on the sender)
  --tone [freq]        stream a 440 Hz test tone instead (default mode)
  --port <port>        UDP port (default 0 = OS-assigned ephemeral port,
                       avoids corporate Wi-Fi port blocklists; Bonjour
                       publishes the actual port for `--browse` receivers)
  --buffer-ms <ms>     playback delay FLOOR 20–5000 (default 150). The sender
                       auto-raises above this when a receiver runs low on
                       headroom, then holds. Watch the receiver's margin=. See
                       "Latency".
  --no-adapt           don't auto-raise; pin the buffer at --buffer-ms
  --name <name>        Bonjour service name
  --no-p2p             disable the AWDL peer-to-peer link (router only)
  --key <passphrase>   encrypt + authenticate the stream (both sides must match)

audiosync-recv:
  --browse             auto-discover via Bonjour (default)
  --sender <name>      with --browse, connect only to the sender with this
                       exact Bonjour name (from --list-senders)
  --list-senders       print discovered senders (sender=<name>) and exit; the
                       app uses this to offer a picker when several are found
  --connect host:port  connect to a specific sender (use the sender's join code)
  --no-p2p             disable the AWDL peer-to-peer link (router only)
  --p2p-only           force the direct Mac-to-Mac AWDL radio (prohibit Wi-Fi
                       infrastructure) — for networks that isolate clients
  --key <passphrase>   decrypt an encrypted stream (must match the sender)
  --headless           full pipeline, no speakers; prints fill stats (testing)
  --exit-after <s>     quit after N seconds (testing)
```

## How the sync actually works

1. **Master clock.** The sender's monotonic clock (`CLOCK_UPTIME_RAW`, same
   time base as Core Audio host time) is the one true timeline. Every audio
   packet carries the master-time at which its first frame must hit the
   speaker (capture time + buffer delay).

2. **Clock sync.** Each receiver probes 4×/s: t1 (client send), t2 (server
   receive), t3 (server send), t4 (client receive) →
   `offset = ((t2−t1)+(t3−t4))/2`. Single probes are polluted by network
   jitter, so the estimator keeps a sliding window and takes the **median of
   the lowest-RTT samples** — queue-delayed probes are discarded by
   construction. Measured on loopback: ~15 µs accuracy; LAN: well under 1 ms.
   The sliding window also tracks crystal drift between the machines
   (typically a few ppm ≈ ms/hour) automatically.

3. **Timeline rendering.** Receivers never "play the next packet" — every
   audio-hardware render callback asks *"what does the master timeline say
   belongs in this exact window?"* and copies the overlapping chunk samples
   into position. Missing data renders as silence of exactly the right
   length; nothing ever shifts. This makes the system self-healing: late
   start, packet loss, even a paused process just resumes aligned.

4. **Jitter buffer.** Chunks are inserted sorted by timestamp, duplicates
   dropped, stragglers behind the playhead rejected, consumed chunks freed
   each render pass. The buffer delay absorbs network jitter: every receiver
   plays equally "late", which is what keeps them together. The sender starts
   at the `--buffer-ms` floor and ratchets it up (same value for everyone, so
   the shared "lateness" — and thus receiver↔receiver sync — is preserved)
   based on receivers' upstream health feedback until the stream runs clean.

## Latency: what it is and how to tune it

End-to-end delay ≈ `--buffer-ms` + a fixed ~25–40 ms stack floor
(ScreenCaptureKit delivers audio in ~10 ms blocks; the receiver's render
quantum and DAC add ~10–25 ms). The buffer is the only part you control —
it exists purely to absorb network jitter, and every receiver pays it
equally, which is exactly what keeps them in sync.

**Tune it with the receiver's `margin=` stat** (printed every second): the
minimum arrival headroom of the last second. If margin stays comfortably
positive, you can cut the sender's `--buffer-ms` by roughly
`margin − 30 ms`. If it dips near zero or `late=` counts appear, raise it.

Measured on loopback (this codebase, debug build): stable 100% fill with
zero dropouts down to `--buffer-ms 25`. Realistic guidance:

| Network                  | suggested --buffer-ms |
|--------------------------|-----------------------|
| Wired Ethernet, idle LAN | 40–60                 |
| Good 5 GHz Wi-Fi         | 100–150 (default)     |
| Congested / 2.4 GHz Wi-Fi| 250–500               |

**Wi-Fi jitter bursts.** Real-world macOS Wi-Fi periodically delays packet
bursts by 70–150 ms (power-save buffering, background AWDL/location scans) —
seen as occasional `margin=…LOW` + `late` spikes + a dropout, every
10–30 s, even when the average margin looks fine. Mitigations, in order of
effectiveness:

1. **Wire the Macs**: Ethernet, or a USB-C/Thunderbolt cable between them
   (creates a direct network link). Buffer can then drop to 40–60 ms and
   dropouts disappear entirely.
2. **Let it adapt (default), or raise `--buffer-ms`**: the sender now
   auto-ratchets the buffer up when receivers report low headroom, so a bursty
   network self-corrects within a few seconds (look for `buffer raised …` in the
   sender log). Each raise is applied as one clean concealed step — never a
   continuous slew (which caused static) and never downward (which dropped
   packets). To skip the climb-from-cold on a known-bad network, set
   `--buffer-ms` high directly (e.g. 250–500); to disable adaptation entirely,
   `--no-adapt`. The 16-bit wire format also reduces the congestion that causes
   bursts in the first place.
3. **Built-in QoS + peer-to-peer** (on by default since v1.1): packets are
   marked voice-class (Wi-Fi WMM priority, exempt from power-save
   buffering) and the AWDL direct Mac-to-Mac link is enabled. If audio gets
   *worse* on your network, try `--no-p2p` on both sides.

Two different "latencies" matter — don't confuse them:

- **Receiver↔receiver skew** (what makes multi-room sound tight): governed
  by clock sync, not the buffer. Measured ~15 µs on loopback, sub-ms on a
  LAN. This is the number that counts, and it's already at the limit of
  what speakers/room acoustics can reveal (sound takes ~3 ms just to travel
  1 m of air).
- **Sender→receiver delay** (the buffer): only perceptible when comparing
  against the sender's *own* speakers, or as lip-sync offset against video.
  At 100–150 ms, lip-sync is on the edge of noticeable; for music in
  another room it is irrelevant.

## Testing

The test suite covers the wire protocol (round-trips incl. the v2 codec byte and
feedback message, truncation/garbage fuzzing, MTU bound), the audio codecs
(Float32 bit-exact, Int16 within half an LSB and clamp-safe), the adaptive
controller (raise-on-distress, holds and never lowers, floor/ceiling clamps,
worst-case aggregation), clock sync (convergence under 4 ms asymmetric
jitter, 10-minute drift tracking, nonsense rejection), the jitter buffer
(reordering, dedup, late-drop, concurrency), the timeline renderer
(sample-exact alignment, gaps, overlap accounting), and a full end-to-end
simulation: two clocks with different epochs *and* frequency skew, real wire
encoding, random delay, reordering, duplication and loss — asserting the
receiver reproduces the sent audio **bit-exactly** at the right master-time
position.

```sh
./run-tests.sh        # wraps `swift test` (adds Testing.framework paths
                      # needed when only Command Line Tools are installed)
```

Live system check (real UDP on localhost, no speakers):

```sh
.build/debug/audiosync-send --tone &
.build/debug/audiosync-recv --browse --headless --exit-after 15
```

Healthy output looks like `filled=48000 silent=0 ... (100% fill)` with
`offset` stable in the tens of microseconds.

## Known limitations / future work

- **Output-device latency** isn't compensated: AVAudioEngine reports render
  deadlines, but each device adds its own DAC latency (~5–15 ms, similar
  across MacBooks, so in practice they match closely). A calibration step
  could trim this with `kAudioDevicePropertyLatency`.
- **DAC-drift micro-resampler (done).** Each Mac's DAC crystal runs a few ppm
  off. The receiver no longer corrects this by snapping its render window to
  the master clock (which dropped/repeated a single frame at the correction
  step — a faint periodic seam click). Instead `SyncedPlayer` runs a continuous
  fractional playhead with a gentle servo that micro-resamples (linear
  interpolation, ±0.003 max rate trim ≈ inaudible) so playback locks to the
  local DAC without ever skipping a frame. Same artifact-free technique a
  future buffer-growth scheme would use (stretch samples, never shift packet
  timestamps). Could still upgrade linear → windowed-sinc interpolation.
- **16-bit PCM on the wire** (~1.5 Mbps/receiver) — half the old Float32
  size and perceptually transparent (local `--party` playback stays full
  Float32). Packets are also sized for the codec (~320 frames each), so the
  rate is ~150–200 packets/s/receiver rather than 300 — fewer packets means
  less Wi-Fi airtime, which is what actually keeps a shared network happy
  (each packet costs fixed airtime regardless of size). A perceptual codec
  (Opus: ~20× smaller, with packet-loss concealment) is reserved as a wire
  codec tag (`AudioCodec.opus`) for a future WAN / very-bad-Wi-Fi tier; the
  negotiation seam is already in place.
- ~~No encryption/auth~~ — **optional encryption shipped**: set a password
  (app: the password field; CLI: `--key <passphrase>` on both sides) and
  every packet is sealed with ChaCha20-Poly1305 (HKDF-derived key). Without
  the password a receiver gets zero packets, and a Wi-Fi sniffer sees only
  ciphertext. Measured cost: ~2 µs/packet — no effect on latency or sync.
  Default remains open (no password) for zero-friction home use.
- macOS 13+ only (ScreenCaptureKit audio capture).
