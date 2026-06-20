# MacAudioSync — Claude Design brief

Paste this into Claude Design to generate UI mockups (HTML/CSS) for the whole
app, then we translate the approved screens into SwiftUI. It already reflects
the app's real features and the "Synced Ripples" design language.

---

## The prompt

Design a complete, cohesive UI for **MacAudioSync**, a native macOS app.

**What it does (one line):** Play audio from one Mac on every other Mac in the
room, perfectly in sync — like AirPlay multi-room, but for *any* system audio
(YouTube, Spotify, anything), over local Wi-Fi, with no extra hardware.

**Who uses it:** non-technical Mac users at home, in an office, at a party.
One Mac is the **Sender** (it plays the music); the others are **Receivers**
(they become synced speakers). It must feel effortless and a little magical.

**Platform & constraints**
- Native macOS app, SwiftUI. Design as a single resizable window, ~440–520 pt
  wide, ~620 pt tall. Components must read at this scale.
- Support **light and dark** mode. Use the system font (SF Pro / SF Pro
  Rounded for display) and SF Symbols for iconography.
- Calm, confident, Apple-grade. No clutter, no skeuomorphism, no gradients-for-
  the-sake-of-it. Minimal and *refreshing*.

**Brand & aesthetic**
- Signature motif: **"Synced Ripples"** — concentric sound ripples radiating
  from a luminous core = one source, one sound, in sync everywhere. This motif
  appears in the app icon (done), the logo, the receiver's "searching"
  animation, and the live playing waveform. Lean on it for visual unity.
- Brand gradient: deep indigo `#2E1C8C` → violet `#5C33ED` → azure `#1A8AFF`
  (top-left to bottom-right). Use it sparingly as the hero accent (logo,
  primary button, active states), not everywhere. Surfaces are mostly neutral
  (system materials), letting the gradient pop.
- Motion: physical, soft, never busy. Ripples breathe and travel outward.
  Transitions ~0.2–0.4 s spring. The "searching" loader should feel **organic
  and alive** — like the last loader in the *Organic Loaders.html* file
  (slow, breathing, fluid concentric ripples), the way Apple would animate
  "looking for devices."

**Screens & states to design**

1. **Home / role picker** — the logo (ripple mark on the gradient), app name,
   a one-line tagline, and two large choices: **Send** (this Mac plays the
   music) and **Receive** (this Mac is a speaker). A tiny 3-step "how it
   works" strip. Make the two role cards the clear hero.

2. **Sender** — states: *idle* and *streaming*.
   - A status row (dot + label: "Not streaming" / "Streaming").
   - When streaming: a **fleet view** showing how many Macs are listening
     (e.g., animated speaker chips), and a copyable **join code** card
     (`192.168.x.x:port`) for when discovery is blocked.
   - Settings card: a toggle "Play through this Mac's speakers too (in sync)",
     a latency slider, and an optional password field (lock icon) to encrypt.
   - One big primary **Start / Stop Streaming** button.
   - Collapsible logs.

3. **Receiver** — states: *searching*, *connecting*, *playing*, *error/
   diagnosis*.
   - **Searching** (the hero state): the organic ripple loader, centered, with
     a calm "Looking for a sender…" caption. This is the moment to shine.
   - **Playing**: a flowing waveform driven by the live audio level, a single
     elegant line beneath it ("Locked to the sender within ±NN µs — sound
     itself travels just X in that time"), a small "over Wi-Fi / peer-to-peer"
     transport chip, and a row of four **stat tiles**: Sync (±µs), Ping (ms),
     Buffer (ms), Health (%). Tiles glow subtly when great, warn softly when
     not.
   - **Diagnosis banners** (friendly, not scary): "Couldn't find a sender —
     this network may block discovery. Try Manual Connect or a hotspot." and
     "Found the sender but no audio is getting through — this network blocks
     device-to-device traffic. Use a personal hotspot or a cable."
   - A **Manual Connect** field (paste the sender's join code) and an optional
     password field.
   - One big **Start Listening / Stop** button. Collapsible logs.

4. **Shared components** — design these as a small system: primary button,
   settings card, status row, stat tile (normal / good / warn), diagnosis
   banner, join-code card with Copy, collapsible logs section, an About sheet.

**Deliverables**
- HTML/CSS mockups of each screen and state, in **both light and dark**.
- A component sheet (the shared components above) so they're reusable.
- The organic "searching" ripple loader as a standalone animated component.
- Group cards by: Brand, Home, Sender, Receiver, Components.

Keep it minimal, refreshing, and unmistakably Apple. The whole thing should
feel like the future of effortless multi-room sound.
