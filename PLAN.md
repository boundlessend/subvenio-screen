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

1. **Purpose and reach.** A tool written for its author, published as source
   under the BSD 3-Clause license: permissive like MIT, with the extra clause
   that keeps the author's name out of endorsements for derived work. Without a
   license file at all, a public repository would be readable and nothing else.
   Not on the Mac App Store: the sandbox is on regardless, but the store would
   add review to a project whose point is the code.
2. **Effect area.** One global hotkey for the whole display, plus a mode where
   the effect only covers the area of a chosen window. A hotkey per display was
   in this decision from the start and moved to Deferred instead of being built:
   it only means anything once several displays can carry different effects at
   once, which is deferred itself.
3. **Effect catalogue.** Not a fixed list of presets but an engine with support
   for user shaders as plugins. The ready-made filters are the first presets on
   top of the engine, not hardcoded features.
4. **Shader format.** Metal (MSL) only to start. On current macOS a CIKernel
   compiles down to Metal anyway, and MSL covers everything CIKernel does plus
   geometry. CIKernel support arrives when a concrete shader turns out to be
   markedly simpler in it.
5. **UI and configuration.** A menu bar icon for quickly switching presets plus
   a separate settings window for hotkeys, shaders and per-display and
   per-window rules. The window is the standard macOS preferences shape: tabs in
   a toolbar, one screen each, with the window resizing to whatever the current
   tab needs. It began as one scrolling page, which worked while there were four
   groups; the fifth pushed the sliders of the selected preset below the fold,
   and tuning grain while the preview sits off-screen is the one thing this
   window exists to make easy. The toolbar itself is drawn by the system through
   `NSWindow.toolbarStyle = .preference`, so the tabs cost no drawing code and
   behave like every other preferences window on the machine.

   **Four tabs, and each answers one question.** It was five, split by mechanism
   rather than by question: Placement and Capture both described where the
   effect lands and what it costs there, and Updates held three controls of its
   own. They are Display and General now. The Effect tab lost the other half of
   its load in the same move: the buttons that manage the preset collection -
   the folder, the template, restoring the bundled ones, and the list of presets
   that failed to load - stood next to the sliders of one preset and read as
   actions on it. They live on a Presets tab, and the sliders' reset button
   could go back to being called "Reset to defaults" instead of the "Reset the
   sliders" it was renamed to under the pressure of that neighbourhood.

   **The window never grows past the screen.** Its height follows the tab, and
   the list of presets that failed to load has no ceiling: fifteen broken
   folders pushed the buttons below the bottom edge, where nothing could reach
   them. The content sits in an `NSScrollView` now, so the window stops at the
   working area of the screen and the rest arrives by scrolling.

   **A menu bar app still needs a menu bar.** The window makes the app `.regular`
   while it is open, and without `NSApp.mainMenu` that left a bar with nothing
   in it: no ⌘W, no ⌘Q, and no Edit menu, which meant the shader compilation
   error the window deliberately lets you select could not be copied. The menu
   is assembled in code, because there is no NIB to carry it.
20. **Presets are grouped by rendering level, not sorted by name.** Seventeen
    names in a row read as a directory listing, and the name of a preset says
    nothing about what picking it will cost. The level does: free, one drawn
    layer, or a request for the Screen Recording permission. The menu bar uses
    `NSMenuItem.sectionHeader`, which macOS 14 draws itself, and the settings
    picker uses the same three headings, so both lists answer the same question
    in the same order. The headings name the cost rather than the mechanism -
    "Reads the screen", not "ScreenCaptureKit" - because the cost is what the
    choice turns on.
21. **A preset describes itself, and its texts are localised while its name is
    not.** A name is all a preset used to say, and "Halation" or "Aperture
    Grille" says nothing about what picking it does; the manifest now carries a
    `description` shown under the preview and as the menu tooltip, and each
    parameter an optional `title` for its slider. Both take either a plain
    string or an object of language code to text. Names stay in one language
    deliberately: they work like the names of film stocks or filters, and
    "Зерно плёнки" beside VHS and Game Boy would read as a half-translated
    list. A missing language yields no description and a caption assembled from
    the parameter name rather than text in a language nobody asked for.
16. **The preview runs on a bundled picture, not on the screen.** Reading the
    real screen for a thumbnail would demand the Screen Recording permission in
    the one window that is supposed to explain the permissions, and would demand
    it for the nine presets that need nothing today. The picture is drawn to
    carry what the presets act on: a full brightness range for gamma and
    clipping, colour for tint and desaturation, and fine texture for grain and
    scanlines. Levels 2 and 3 preview through the same shader and the same Metal
    layer as the real effect, so what the window shows is what the screen gets.
    Level 1 lands in scanout and cannot be sampled, so the preview applies the
    same table to the picture itself.
17. **The preview ticks only while someone is there to see it.** A closed or
    minimised window costs nothing, measured: 2.6% of a core with an animated
    preset visible, 0.0% once the window is gone. Visibility alone turned out not
    to be enough: macOS does not mark a window occluded when another application
    covers it completely, so the tick also stops whenever the app is not the
    active one. Settings left open behind someone else's work now costs the same
    as settings closed.
18. **Turning a level 1 effect off restores every display, not only ours.**
    `CGSetDisplayTransferByTable` writes one display, but the public API to undo
    it is `CGDisplayRestoreColorSyncSettings`, which resets all of them to their
    ColorSync profiles. Anything another program had set - Night Shift, f.lux, a
    custom calibration - goes back to the profile until that program applies it
    again. There is no per-display public counterpart, and leaving the screen
    tinted is worse, so this is accepted and recorded rather than worked around.
19. **Bundled presets are updated by fingerprint, not by version number.** A
    preset is copied into the user's folder once, and a fix shipped later has to
    reach the copy: the noise bug of 1.0.1 would otherwise still be sitting in
    every folder created before it. On each launch the app compares a SHA-256 of
    the folder's contents with the one recorded when it installed that preset. A
    match means nobody edited it and it can be replaced; a mismatch means the
    user's work is in there and it is left alone. A version field in the manifest
    would need every preset author to maintain it honestly, and would still not
    tell edited copies from untouched ones. A recorded fingerprint with no folder
    behind it means the preset was deleted on purpose, so it is not put back:
    otherwise a preset nobody wants returns on every launch, and the only way to
    be rid of it is to break it.
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
15. **Update check without an update framework.** One request to the GitHub
    releases API, a version comparison, and a menu entry - the app never
    downloads or installs anything, it opens the release page. The interval is a
    setting (weekly by default), and the check also runs hourly on a timer
    because an app that stays open for weeks would otherwise only ever check at
    launch. A scheduled failure goes to the log and no further: waking someone up
    over a network error nobody asked about is exactly what decision 11 forbids.
    A manual check does show its error, because that one was asked for.
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
22. **The icon says on or off by its shape, not by its opacity.** The menu bar
    icon is a television; the effect being on fills its screen and the effect
    being off leaves it as an outline. It used to be one icon dimmed through
    `appearsDisabled`, and a dimmed control on macOS means unavailable, not
    turned off. The two assets share their geometry down to the coordinate, so
    switching between them changes the screen of the set and nothing else.
23. **Opening the app again opens its settings.** An app with no Dock icon and
    no window is reached through the menu bar, and a menu bar that has run out
    of room hides the icon that reaches it. Double-clicking the app is what
    people try next, and Launch Services does not start a second process for
    that - it sends `applicationShouldHandleReopen`, which now opens the
    settings window. A second copy started some other way still exists: it asks
    the running one to show itself over a distributed notification and quits,
    because two copies mean two gamma tables on one display.
24. **Colour spaces are stated, not inherited.** The overlay layer, the preview
    layer and the capture stream all declare sRGB. Left unstated, the numbers a
    shader writes are read in the colour space of the display: the same tint
    came out more saturated on Display P3, the preview and the screen disagreed,
    and "honest black and white" depended on which monitor was plugged in.
25. **The gamma table is restored on a crash too.** The signal handler covers
    `SIGSEGV`, `SIGABRT`, `SIGILL`, `SIGBUS` and `SIGFPE` alongside the orderly
    `SIGTERM`, `SIGINT` and `SIGHUP`. A crash used to leave the screen tinted
    until the app was launched again, and the handler was already written.
    The price is worth stating plainly: `CGDisplayRestoreColorSyncSettings` is
    not async-signal-safe, so on the orderly signals the trade is free, while on
    the crash signals a fault raised inside the allocator can deadlock the
    handler instead of restoring anything. The failure mode there is a hung
    process rather than a crash report. A tinted screen that outlives the app is
    the more likely accident of the two, so the handler stays; if the hang is
    ever observed, the crash signals come back out.

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
  Carbon underneath, so it pulls in no Accessibility requirement. Also
  [Pow](https://github.com/EmergeTools/Pow) - transitions SwiftUI has no
  equivalent for, used in three places in the settings window and nowhere else.
  Its effects fire on an event instead of running in a loop, so they cost the
  overlay nothing. Both are pinned to an exact version, because
  `Package.resolved` lives inside the generated `.xcodeproj` and is not in git.
- Apple Silicon only. A universal binary was the original goal, but there is no
  Intel machine to verify it on, and an untested architecture is a claim rather
  than support.

## Testing strategy

Unit tests cover only the deterministic parts: gamma table generation, manifest
validation and the uniform buffer layout. Everything else here is rendering, and
rendering is checked against the system rather than against a mock - the tools
for that are listed in [DEVELOPMENT.md](DEVELOPMENT.md#layout).

Two exceptions earn their place. Installing the bundled presets is the only code
that writes into a folder somebody else owns, and a mistake there wipes work
silently, so its five cases are covered against a temporary defaults domain and
a directory standing in for the bundle. And every bundled shader is compiled
through the real prelude, because a shader is otherwise only compiled when
someone turns the preset on - which is too late to find out in a release. The
same test insists each preset has a description in the current language.

SwiftLint runs in CI with `--strict`. Its default rules were already silent on
this code, so nothing was reshaped to satisfy it; the handful of rules turned
off in `.swiftlint.yml` carry their reason next to them.

A shader is worth rendering offline into a texture before trusting it on screen.
That is how the noise bug was caught: the hash mixed elapsed time into its
argument, `sin` ran out of precision, and grain vanished four minutes in. On
screen it looked like the effect fading out; offline the variance across the
frame was measurably zero.

The same method caught the sequel. The integer hash that replaced `sin` was
still animated by adding time to its coordinates, which slides the pattern
instead of regenerating it: the grain crawled towards the top left at a pixel
per frame, slow enough to look deliberate. Rendering two frames offline and
comparing them under every small shift showed a 100% match at (-1, -1), which is
the kind of answer an eye cannot give.

## Presets

Seventeen presets ship. Each one was written as a real fragment function and
rendered offline against the bundled preview picture before it got a folder, so
nothing here was accepted on the strength of a description. The rendering level
is the first thing to look at: it decides what the effect costs, whether it asks
for anything, and which group of the menu it lands in. Which preset sits at
which level is the table in [README.md](README.md#the-presets).

Halftone, 1-bit Dither and Game Boy quantise the screen to two shades or four,
which makes small text hard to read. They are effects to look at rather than to
work under, and the README says so rather than the menu: a preset that warns
about itself every time it is opened is a preset nobody picks twice.

**An animated preset must not modulate the brightness of the whole screen at
all.** Fast, that reads as flicker - the band the eye notices most, and the band
that is unsafe for photosensitive people, the same reason interlaced fields were
rejected below. Slow, it reads as breathing, which is no easier to sit in front
of for an hour and no easier to ignore. Slowing such an effect down does not fix
it, because the depth survives the change: Projector's lamp darkened the whole
frame by a quarter at 1.75 Hz, and by exactly the same quarter after the
frequencies dropped to 0.37 Hz. Its lamp is steady now and the preset is a
static vignette. Whatever moves has to move locally, the way grain, line noise
and scratches do. Both halves are measurable: render the shader offline over ten
seconds, and look at how far the average alpha moves between two frames at 60 Hz
and at how far it travels across the whole run. The animated presets step under
0.02 per frame and never move the whole frame at once.

**Only level 1 survives a space switch.** Swiping between spaces drops the
overlay for about a second, and no window setting brings it back. The window is
never ordered out - polled at 125 Hz across several switches it stayed onscreen
at alpha 1 in every sample - and no other window rises above it, so nothing is
covering it either. macOS builds the transition in the compositor, out of
per-space surfaces, and ordinary windows are not composited into it. A probe of
four stripes at screenSaver, assistiveTechHigh, shielding and cursor levels lost
all four the same way, which is as high as window levels go. Gamma holds
throughout, because `CGSetDisplayTransferByTable` is applied on scanout, after
everything the compositor did. So an always-on effect means a level 1 preset,
and levels 2 and 3 blink on every space switch by construction. This belongs in
the README rather than in a warning next to each preset, for the same reason the
quantising presets carry theirs there.

**A level 2 layer cannot dim one channel.** The overlay composites through a
single alpha, so a coloured mask that leaves one channel alone and darkens the
other two is impossible there. Anything per-channel is level 3 by construction,
which is why Aperture Grille is not the cheap effect it looks like.

**Green Phosphor is a slider, not a preset.** A second terminal differing from
the first by one colour vector would be two folders maintained as one. Phosphor
Terminal takes a hue instead: the colour is built on the hue circle at a fixed
saturation, amber at 0.09 and P1 green at 0.36, and the name stopped saying
amber once it could say both. The folder is still `AmberTerminal`, because
renaming it would leave the old one behind in everybody's shaders folder and
show the preset twice; `Grayscale` holding "Black and White" is the same case.

Rejected on purpose:

- **Interlaced fields.** Indistinguishable from Scanlines on a still frame, and
  its whole point is flicker at 50 Hz, which tires the eyes and is unsafe for
  photosensitive people. The app respects "Reduce Motion" precisely to avoid
  that class of effect.
- **Phosphor burn-in.** The ghost accumulates over minutes, which means keeping
  an averaged frame in memory across launches. That is a subsystem, not a filter.
- **Composite NTSC.** Honest chroma modulation costs several render passes, and
  a cheap imitation is indistinguishable from VHS, which already ships.
- **Film stock profiles such as Kodachrome.** Colour curves demand level 3 to
  produce what the eye reads as a tint, and tints are free at level 1.

## Deferred

Questions consciously postponed. Not forgotten, just not needed yet.

1. **Independent presets per display.** One effect on one display today. Several
   at once means a window, a `CaptureController` and a display link per screen,
   which is also where displays with different scale and refresh rate stop being
   free: `CADisplayLink` already follows the screen its view is on, but each
   render target would need its own. **A hotkey per display** belongs here: with
   one effect at a time, a second hotkey would only move that effect to another
   screen, which the settings window already does.
2. **Capturing only the window in window-scoped mode.** Level 3 captures the
   whole display and crops in the shader. `SCStreamConfiguration.sourceRect` plus
   `updateConfiguration` would capture just the window instead, at the cost of
   reconfiguring the stream on every move. Worth doing if the window mode ever
   feels heavy; the crop itself is free today.
