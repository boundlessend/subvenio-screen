# ScreenFilter - architecture decisions

A lightweight macOS app that lays visual filters and effects (old TV, black and
white, VHS and so on) over everything on screen, toggled by a hotkey.

This is not an implementation plan but a record of the decisions behind the
architecture and the scope of the project. The work breakdown lives in
[PRD.md](PRD.md), the user-facing description in [README.md](README.md).

## Scope

In: visual effects over the screen, hotkey toggling, a user shader engine.

Deliberately out, to keep the scope from creeping:

- OS themes, wallpapers, boot screens, screensavers;
- replacing or restyling the Dock and the menu bar;
- recording video with the effect applied;
- a virtual camera and webcam filters;
- a game launcher and emulators.

RetroMac does all of the above. We build the effect layer only.

## Rendering architecture

The defining macOS constraint: a transparent window over the screen **cannot**
apply a filter to what is underneath it. There is no public backdrop filter API
in AppKit: `CALayer.backgroundFilters` and `compositingFilter` only work inside
their own window, and `NSVisualEffectView` only does blur and vibrancy. Without
capturing pixels you can only draw **over** the screen, never **transform** what
is already on it.

Hence three rendering levels rather than two. Every shader plugin declares which
level it runs on.

### Level 1: gamma LUT (`CGDisplaySetTransferByTable`)

- Can do: per-channel transforms - colour tint, inversion, gamma, black and
  white point clipping.
- Cannot do: channel mixing (black and white, sepia), spatial effects.
- Cost: none, applied in scanout after compositing.
- Permissions: none.
- Covers the entire display including the cursor, the menu bar and the Dock.
- Known limit: does not work with some DisplayLink adapters or with an iPad over
  Sidecar.

### Level 2: alpha overlay (a transparent window on top)

- Can do: anything drawn on top - scanlines, vignette, grain and noise, colour
  film, shadow mask, flicker.
- Cannot do: change what is underneath the window.
- Cost: low, one transparent layer in the compositor.
- Permissions: none.
- Window requirements: `ignoresMouseEvents = true`, level `.screenSaver` or
  above, excluded from screen capture (see feedback loop protection).

### Level 3: ScreenCaptureKit + Metal

- Can do: everything else - black and white, chromatic aberration, barrel
  distortion, bloom from bright content, phosphor decay.
- Cost: real, grows with resolution and refresh rate.
- Permissions: Screen Recording.
- Hard requirement: `SCContentFilter` excluding the app's own windows.
  Otherwise the overlay ends up inside its own capture and the result is a
  feedback loop: a black screen or flicker. This is an architectural
  requirement, not an implementation detail.

### The important consequence: levels combine

Most retro effects are reachable without capturing the screen. "Old TV" is a
tint at level 1 plus scanlines and a vignette at level 2. Level 3 is only needed
where an effect must read the original pixels.

### On black and white specifically

Honest black and white requires mixing colour channels, and a gamma LUT is
per-channel and cannot do it. The options were:

1. level 3 (screen capture) - public and reliable, at the cost of the Screen
   Recording permission;
2. the private `CGSSetDisplayTransferMatrix` - nearly free and display-wide, but
   a private API can break on any new macOS.

We took the first path. The second stays acceptable as an optional "fast black
and white" with an explicit warning in the UI, but never as the foundation.

## Decisions

1. **Purpose and reach.** A private repository for personal use for now. No Mac
   App Store. The repository goes public later.
2. **Effect area.** Three tiers:
   - one global hotkey: effect on every connected display;
   - extra hotkeys, configurable per display;
   - a separate mode: effect only in the area under a specific window.
3. **Effect catalogue.** Not a fixed list of presets but an engine with support
   for user shaders as plugins. The ready-made filters (black and white, old TV)
   are the first presets on top of the engine, not hardcoded features.
4. **Shader format.** Metal (MSL) only to start. On current macOS a CIKernel
   compiles down to Metal anyway, and MSL covers everything CIKernel does plus
   geometry. A double plugin loader does not pay for itself on day one.
   CIKernel support arrives when a concrete shader turns out to be markedly
   simpler in it.
5. **UI and configuration.** A menu bar icon for quickly switching presets plus
   a separate settings window for hotkeys, shaders and per-display and
   per-window rules.
6. **Cursor and system elements.** A configurable option per preset. The
   important caveat: at level 3 a cursor drawn inside the frame lags by the
   whole capture-shader-output delay, and that reads as a laggy mouse. The
   option carries an honest warning in the UI; the default is the system cursor
   above the effect. At level 1 the cursor falls under the effect for free and
   without delay.
7. **Persistence.** The last enabled effect and its settings survive restarts
   (`UserDefaults`, costs nothing).
8. **Difference from the alternatives.** A deliberate reinvention: the value is
   in owning the code and in learning, not in a feature RetroMac, RetroVisor or
   Black Light 3 lack.
9. **Distribution.** Apple notarisation is not needed. Decided, not revisited.
10. **Load budget.** No fixed CPU/GPU percentage up front. We look at the
    situation and optimise separately if a particular level or shader turns out
    to be heavy. Known levers: lowering the capture rate, scaling the buffer,
    skipping frames on a static screen.

## System permissions

The project should require the minimum of permissions, so the choice of API is
not free here:

- **Screen Recording** - only for level 3. Requested lazily, on the first use of
  such a shader rather than at launch. Before the system Privacy & Security
  dialog we show an onboarding screen of our own explaining why it is needed.
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
  ScreenCaptureKit, ServiceManagement (launch at login).
- Targeted third-party dependencies are acceptable when they cover a meaningful
  chunk of work. In use:
  [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) - it
  records combinations in the UI and checks conflicts out of the box, and uses
  Carbon underneath, so it pulls in no Accessibility requirement.
- Target architecture: universal binary (Apple Silicon + Intel). The code is
  written portably, but see "Deferred" about testing on Intel.

## Definition of done for the MVP

The MVP was considered done when:

- the app lives in the menu bar;
- one level 2 shader (scanlines plus vignette) lands on the main display;
- one global hotkey turns the effect on and off;
- clicks pass through the overlay: mouse and keyboard reach the apps below;
- state is restored after a restart.

Check: press the hotkey, see the effect, work in another app through it, press
the hotkey again, confirm the effect is gone and the screen is back to normal.

## Deferred

Questions consciously postponed. Not forgotten, just not needed yet.

1. **Versioning and release cadence.** Revisit before making the repository
   public.
2. **Testing on a real Intel Mac.** A universal binary is stated as a goal, but
   without an Intel machine the compatibility is unverifiable. Decide what to
   honestly claim in the README: either find something to test on, or claim
   Apple Silicon only.
3. **Displays with different scale and refresh rate.** Retina next to non-Retina,
   60 Hz next to 120 Hz - each needs its own render target and its own timing.
   Affects the architecture of levels 2 and 3; to be worked out when independent
   presets per display are implemented.
4. **Project name.** `screen-filter` is a working title. Pick a real one before
   opening the sources.
