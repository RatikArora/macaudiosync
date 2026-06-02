# MacAudioSync

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

## Build

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
.build/release/audiosync-send --capture
```

   - The first run asks for **Screen Recording** permission (that's how
     macOS gates system-audio capture). Grant it to your terminal app in
     System Settings → Privacy & Security → Screen Recording, then run again.
   - Make sure both Macs are on the **same Wi-Fi/LAN**.

**3. On every other Mac (receivers):**

```sh
.build/release/audiosync-recv
```

   That's it — it finds the sender via Bonjour, syncs, and starts playing.
   If discovery is blocked (some networks filter mDNS), connect directly:

```sh
.build/release/audiosync-recv --connect <sender-name>.local:7805
```

**4. Play YouTube / Spotify / anything on the sender Mac.** All Macs play it
   together. Note the sender's *own* speakers play immediately while
   receivers play `--buffer-ms` later — for in-the-same-room listening,
   either mute the sender and add a receiver on the sender Mac too
   (`audiosync-recv --connect 127.0.0.1:7805`), or just use the receivers
   as your speakers.

### Options

```
audiosync-send:
  --capture            stream the Mac's system audio
  --tone [freq]        stream a 440 Hz test tone instead (default mode)
  --port <port>        UDP port (default 7805)
  --buffer-ms <ms>     playback delay budget 20–5000 (default 150):
                       jitter headroom ↑, latency ↑ (see "Latency" below)
  --name <name>        Bonjour service name

audiosync-recv:
  --browse             auto-discover via Bonjour (default)
  --connect host:port  connect to a specific sender
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
   each render pass. The `--buffer-ms` delay budget absorbs network jitter:
   every receiver plays equally "late", which is what keeps them together.

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

47 tests cover the wire protocol (round-trips, truncation/garbage fuzzing,
MTU bound), clock sync (convergence under 4 ms asymmetric jitter, 10-minute
drift tracking, nonsense rejection), the jitter buffer (reordering, dedup,
late-drop, concurrency), the timeline renderer (sample-exact alignment,
gaps, overlap accounting), and a full end-to-end simulation: two clocks with
different epochs *and* frequency skew, real wire encoding, random delay,
reordering, duplication and loss — asserting the receiver reproduces the
sent audio **bit-exactly** at the right master-time position.

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
- **No micro-resampler yet.** Each Mac's DAC crystal runs a few ppm off;
  alignment is recomputed every render window so drift cannot *accumulate*,
  but the correction lands as a repeated/skipped frame at a chunk boundary
  every few tens of seconds (in practice inaudible). The measured `drift
  ppm` from `DriftEstimator` is the input a future resampler (smooth
  rate-matching, Snapcast-style) would use.
- **Uncompressed PCM only** (≈1.5 Mbps/receiver) — trivial for any LAN;
  Opus would cut it 10× if you ever want WAN streaming.
- **No encryption/auth** — anyone on your LAN can listen. Fine at home;
  add DTLS if you care.
- macOS 13+ only (ScreenCaptureKit audio capture).
