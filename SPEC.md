# NoiseLoom — specification

**Tagline:** Generate white, pink and brown noise plus rain-like textures for focus and sleep, with a timer and menu bar control.

**Category:** Audio

**Inspired by (paid):** Dark Noise ($19.99 /year)

**Frameworks:** SwiftUI, AppKit, AVFoundation, MediaPlayer, ServiceManagement

**Donation URL (Support button):** https://ko-fi.com/leodavidai

## Spec

What the paid app does: Dark Noise is an ambient sound app with a Mac version. The Mac App Store shows it as free with a Pro tier at 19.99 dollars, and the listing shows a 4.8 star rating from about 3,700 ratings, which is strong demand for background sound apps. Competitors such as Endel and Noisli are also subscription based. The listing does not state billing periods, and we treat the Pro price as a yearly subscription. Our clean-room NoiseLoom synthesizes everything in code, so it needs no sound files and no network.

Feature set: generators for white, pink, brown and blue noise, a filtered rain-like texture and a soft wind-like texture, each with its own volume slider so up to three can be mixed, a master volume, a sleep timer with presets (15, 30, 60, 120 minutes, or off) that fades out over the last 30 seconds, saved mixes called scenes that the user can name, and play and pause from the menu bar and from the media keys. About 350 to 500 lines.

UI spec: a MenuBarExtra in window style titled with a waveform icon that animates subtly while playing. The panel has a play and pause button, a master volume slider, rows for each generator with an enable checkbox and slider, a timer picker with a countdown label when active, and a scene picker with Save Scene and Delete. Settings window: default scene, fade durations, launch at login, resume last scene on launch. Empty state: with no saved scenes, the picker offers three built-in scenes named Focus, Sleep and Rain. State: when the timer ends, the panel shows Stopped by timer.

Technical approach: AVAudioEngine with an AVAudioSourceNode per generator, whose render block fills float buffers. White noise uses a fast random generator. Pink noise uses the Voss-McCartney method or a three-pole filter approximation. Brown noise integrates white noise with a leak and scaling to avoid drift. Blue noise differentiates white noise. Rain is band-passed pink noise with sparse random amplitude bursts, and wind is low-passed noise modulated by a slow random LFO. Smooth parameter changes to avoid clicks by interpolating volume per sample. Mix in a mixer node and apply master volume. The sleep timer uses a Timer and ramps the mixer output volume to zero over the last seconds before stopping the engine. Register media key commands via MPRemoteCommandCenter for play and pause, and set Now Playing info so the system shows the controls. Persist scenes as JSON in UserDefaults. Launch at login via SMAppService. No permissions are needed.

Edge cases: audio route changes such as unplugging headphones stop the engine, so restart on the AVAudioEngineConfigurationChange notification. Prevent clipping by keeping the sum of enabled generator gains under a ceiling and soft limiting with tanh. Pausing should fade for about 200 milliseconds to avoid pops. If another app takes over media keys, the remote commands may not fire, which is acceptable and should be noted in settings. Timer countdown should keep correct time after sleep, so store an end date and not a remaining interval. Deleting the active scene falls back to the default scene. Keep render blocks free of allocation and locking for glitch free playback.
