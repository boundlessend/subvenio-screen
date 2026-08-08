# ScreenFilter - architecture decisions

Why the app is built the way it is. What it does and how to use it lives in
[README.md](README.md); this file records the decisions and the reasoning behind
them, so they do not have to be rediscovered later.

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

macOS has no public backdrop filter, so a transparent window cannot transform
what is under it. The three levels and what each can do are described in
[README.md](README.md#the-constraint-that-shapes-everything); this section holds
only the decisions that followed from that constraint.

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
   prerequisite if that ever changes.
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
- Target architecture: universal binary (Apple Silicon + Intel). The code is
  written portably, but see "Deferred" about testing on Intel.

## Testing strategy

Unit tests cover only the deterministic parts: gamma table generation, manifest
validation and the uniform buffer layout. Everything else in this app is
rendering, and rendering is verified by eye and by the system: window geometry
through `CGWindowListCopyWindowInfo`, gamma through
`CGGetDisplayTransferByTable`, capture through the app's own os.Logger output.

Level 3 has one non-obvious trap: `sharingType = .none` hides the overlay from
`screencapture`, so a screenshot can never confirm that the effect is drawn.

## Deferred

Questions consciously postponed. Not forgotten, just not needed yet.

1. **Versioning and release cadence.** `scripts/release.sh` builds and packages;
   tags are SemVer and set by hand. Revisit before making the repository public.
2. **Testing on a real Intel Mac.** A universal binary is stated as a goal, but
   without an Intel machine the compatibility is unverifiable. The README claims
   Apple Silicon and says why.
3. **Displays with different scale and refresh rate.** Retina next to non-Retina,
   60 Hz next to 120 Hz - each needs its own render target and its own timing.
   Affects the architecture of levels 2 and 3; to be worked out when independent
   presets per display are implemented.
4. **An icon of its own.** The status item borrows an SF Symbol and the app
   bundle has no `AppIcon`, which is visible in Login Items and in the Screen
   Recording list.
5. **Project name.** `screen-filter` is a working title. Pick a real one before
   opening the sources.
