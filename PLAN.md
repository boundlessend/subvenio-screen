# Subvenio Screen - architecture decisions

Why the app is built the way it is. What it does lives in [README.md](README.md)
and how to build it in [DEVELOPMENT.md](DEVELOPMENT.md); this file records the
decisions and the reasoning behind them, so they do not have to be rediscovered
later.

## Scope

In: visual effects over the screen, hotkey toggling, a user shader engine.

Deliberately out, to keep the scope from creeping:

- OS themes, wallpapers, boot screens, screensavers;
- replacing or restyling the Dock and the menu bar;
- recording video with the effect applied;
- a virtual camera and webcam filters;
- a game launcher and emulators.

RetroMac does all of the above. We build the effect layer only.

## Why three rendering levels

macOS has no public backdrop filter. A transparent window **cannot** transform
what is underneath it: `CALayer.backgroundFilters` and `compositingFilter` only
affect the window's own content, and `NSVisualEffectView` does blur and vibrancy
and nothing else. Without reading pixels you can draw **over** the screen, never
**through** it. Hence three levels, and every preset declares which one it needs.

| Level | Mechanism | Can do | Cost | Permission |
|-------|-----------|--------|------|------------|
| 1 | `CGSetDisplayTransferByTable` | per-channel work: tint, gamma, inversion, clipping | none, applied in scanout | none |
| 2 | transparent overlay window + Metal | anything drawn on top: scanlines, vignette, grain, bands | one composited layer | none |
| 3 | ScreenCaptureKit + Metal | anything that must read the screen: black and white, aberration, bloom | real, scales with resolution and refresh rate | Screen Recording |

Level 1 lands after compositing, so it covers the cursor, the menu bar and the
Dock for free, and cannot be confined to a window.

**Levels combine.** Most retro effects are reachable without capturing the
screen: "old TV" is a tint at level 1 plus scanlines and a vignette at level 2.
Level 3 is only needed where an effect must read the original pixels.

**Level 3 must exclude the app's own windows** through `SCContentFilter`.
Otherwise the overlay ends up inside its own capture and the result is a
feedback loop: a black screen or flicker. This is an architectural requirement,
not an implementation detail. `sharingType = .none` on the overlay window closes
the same loop from the other side.

**Honest black and white.** Mixing colour channels is impossible with a
per-channel gamma table. The options were level 3 (public, at the cost of the
Screen Recording permission) and the private `CGSSetDisplayTransferMatrix`
(nearly free and display-wide, but a private API can break on any new macOS). We
took the first. The second stays acceptable as an optional "fast black and
white" with an explicit warning in the UI, never as the foundation.

## Decisions

1. **Purpose and reach.** A private repository for personal use for now. No Mac
   App Store. The repository goes public later.
2. **Effect area.** Three tiers: one global hotkey for the whole display, extra
   hotkeys configurable per display, and a separate mode where the effect only
   covers the area of a chosen window.
3. **Effect catalogue.** Not a fixed list of presets but an engine with support
   for user shaders as plugins. The ready-made filters are the first presets on
   top of the engine, not hardcoded features.
4. **Shader format.** Metal (MSL) only to start. On current macOS a CIKernel
   compiles down to Metal anyway, and MSL covers everything CIKernel does plus
   geometry. CIKernel support arrives when a concrete shader turns out to be
   markedly simpler in it.
5. **UI and configuration.** A menu bar icon for quickly switching presets plus
   a separate settings window for hotkeys, shaders and per-display and
   per-window rules.
6. **Cursor and system elements.** A configurable option per preset. At level 3
   a cursor drawn inside the frame lags by the whole capture-shader-output
   delay, and that reads as a laggy mouse, so the default is the system cursor
   above the effect. At level 1 the cursor falls under the effect for free.
7. **Persistence.** The last enabled effect and its settings survive restarts
   (`UserDefaults`, costs nothing).
8. **Difference from the alternatives.** A deliberate reinvention: the value is
   in owning the code and in learning, not in a feature RetroMac, RetroVisor or
   Black Light 3 lack.
9. **Distribution.** Apple notarisation is not needed for a personal tool.
   Hardened Runtime is on regardless, since it costs nothing and is a
   prerequisite if that ever changes. Releases are disk images built with
   `create-dmg`, versioned by hand from 1.0.0 and tagged in git. No Sparkle: an
   update framework has to be maintained, signed and hosted, which is more work
   than downloading a new image once in a while.
10. **Load budget.** No fixed CPU/GPU percentage up front. The levers are
    exposed instead: capture buffer scale and a frame rate cap, both global
    settings rather than per-preset, because they describe the machine and not
    the effect.
11. **Errors reach the user through the menu bar.** A background app without a
    window has no right to interrupt someone else's work with a modal dialog.
    Modal alerts are left for what the user asked for directly: the permission
    onboarding and the detail behind a status item.
12. **Concurrency.** `SWIFT_STRICT_CONCURRENCY = targeted`, and the UI layer is
    isolated for real: `AppDelegate`, `EffectController` and `OverlayController`
    are `@MainActor`. Capture frames arrive on the ScreenCaptureKit queue and
    reach the main thread through `DispatchQueue.main.async` plus
    `MainActor.assumeIsolated` - the queue preserves frame order, `Task` does
    not. `@unchecked Sendable` is left only where the boundary is held by a
    contract rather than by the compiler: `CapturedFrame`, `CaptureController`
    and `FrameSink`.
13. **Deployment target macOS 14.** Ventura support was dropped to get that
    isolation (`MainActor.assumeIsolated`) and `CADisplayLink`, which ties the
    animation tick to the display the overlay actually sits on instead of a
    fixed 60 Hz timer.
14. **App Sandbox is on**, even though the Mac App Store is not the plan. It
    costs nothing here, which was measured rather than assumed: inside the
    sandbox the gamma table still applies, ScreenCaptureKit still runs (the TCC
    grant follows the signature, not the container), the Carbon hotkey still
    fires and `SMAppService` still registers. The shaders folder moves into the
    container, and the "Open shaders folder" button leads there, so putting a
    shader in by hand works the same way. Existing preferences are migrated into
    the container by the system on first launch.

## System permissions

The project should require the minimum of permissions, so the choice of API is
not free here:

- **Screen Recording** - only for level 3. Requested lazily, on the first manual
  use of such a shader. Never requested on autostart.
- **Accessibility** - avoided entirely:
  - global hotkeys go through Carbon `RegisterEventHotKey`, which needs no
    Accessibility. `NSEvent.addGlobalMonitorForEvents` does, so we do not use
    it;
  - the "under a specific window" mode tracks a foreign window by polling
    `CGWindowList`. Measured at 0.08 ms per lookup by window id, which is 0.5%
    of a core at 60 Hz - cheaper than asking for another permission.

## Stack

- Swift, AppKit for the overlay windows and the menu bar, SwiftUI for the
  settings window.
- System frameworks by default: Core Graphics (gamma LUT), Metal,
  ScreenCaptureKit, ServiceManagement (launch at login), FSEvents (watching the
  plugin folder), os.Logger.
- Targeted third-party dependencies are acceptable when they cover a meaningful
  chunk of work. In use:
  [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) - it
  records combinations in the UI and checks conflicts out of the box, and uses
  Carbon underneath, so it pulls in no Accessibility requirement. Pinned to an
  exact version, because `Package.resolved` lives inside the generated
  `.xcodeproj` and is not in git.
- Apple Silicon only. A universal binary was the original goal, but there is no
  Intel machine to verify it on, and an untested architecture is a claim rather
  than support.

## Testing strategy

Unit tests cover only the deterministic parts: gamma table generation, manifest
validation and the uniform buffer layout. Everything else here is rendering, and
rendering is checked against the system rather than against a mock - the tools
for that are listed in [DEVELOPMENT.md](DEVELOPMENT.md#layout).

A shader is worth rendering offline into a texture before trusting it on screen.
That is how the noise bug was caught: the hash mixed elapsed time into its
argument, `sin` ran out of precision, and grain vanished four minutes in. On
screen it looked like the effect fading out; offline the variance across the
frame was measurably zero.

## Deferred

Questions consciously postponed. Not forgotten, just not needed yet.

1. **Independent presets per display.** One effect on one display today. Several
   at once means a window, a `CaptureController` and a display link per screen,
   which is also where displays with different scale and refresh rate stop being
   free: `CADisplayLink` already follows the screen its view is on, but each
   render target would need its own.
2. **Capturing only the window in window-scoped mode.** Level 3 captures the
   whole display and crops in the shader. `SCStreamConfiguration.sourceRect` plus
   `updateConfiguration` would capture just the window instead, at the cost of
   reconfiguring the stream on every move. Worth doing if the window mode ever
   feels heavy; the crop itself is free today.
