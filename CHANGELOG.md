# Changelog

Notable changes per release. Versions follow [SemVer](https://semver.org), and
every release from 1.1.0 on ships as a disk image on the
[Releases](https://github.com/boundlessend/subvenio-screen/releases) page.

## 2.1.0

### Added

- **The effect steps aside for full screen video.** While a player or a browser
  plays a video in full screen on the effect's display, the effect leaves the
  screen and comes back when full screen ends. A pause does not bring it back
  over the stopped frame, and an editor or a terminal in full screen keeps the
  effect: only an app that keeps the display awake counts as playing, which is
  what IINA, Chrome and Safari do while a video runs. Level 3 stops reading the
  screen for that time. Safari does not mark a looping video that way, so the
  effect stays over such a clip.
- **A switch keeps the effect over full screen video**, for whoever wants the
  grain on the film too. It is on the Display tab and off by default.

## 2.0.0

### Changed

- **The bundle identifier is now `dev.boundlessend.SubvenioScreen`.** The old one
  carried a second pseudonym into a project published under one name. macOS keys
  the sandbox container, the Screen Recording grant, the settings and the launch
  item to that identifier, so this version starts as a fresh install: settings
  are back at their defaults, the permission has to be granted again, and presets
  you wrote yourself stay behind in the old container. Copy them across before
  deleting it:

  ```sh
  open ~/Library/Containers/dev.senya.SubvenioScreen/Data/Library/Application\ Support/SubvenioScreen/Shaders
  ```

- **Pow is gone, and Library Validation is back on.** The animation framework
  bought three transitions in the settings window, and it cost the part of the
  Hardened Runtime that stops a substituted library from being loaded into a
  process holding Screen Recording. The transitions are plain SwiftUI now, the
  entitlement that disabled that check is removed, and the app is 1.6 MB smaller.
- **A second hotkey steps through the presets.** Unassigned by default; record it
  in settings next to the toggle.
- **A preset installs by dropping its folder on the settings window.** The
  shaders folder lives inside the sandbox container, where Finder does not go on
  its own.
- **Errors answer where they were caused.** The settings window shows what the
  menu bar shows, so a toggle that springs back now says why; restoring the
  bundled presets reports its result next to the button instead of in the menu
  bar icon.
- **The window settles for what it can actually do.** With a level 1 preset
  selected, the window picker is disabled rather than merely explained.

### Fixed

- **The settings window went invisible under a level 3 effect.** Capture excluded
  every window of the app instead of only the overlay, so the settings window was
  cut out of the frame that the opaque overlay then drew over it. It stayed
  clickable the whole time, which made it worse.
- **Adding a slider to a preset that was being tuned crashed the app.** Values
  held back for the next write were reused without checking that the preset still
  has that many parameters.
- **An effect no longer went missing when its display came back.** Starting with
  the display unplugged left the app waiting for nothing; a level 3 stream that
  died with the monitor did the same.
- **Window mode read the wrong screen.** The effect took its display from the
  picker and the frame from the window, and dragging that window to another
  monitor left the shader sampling the edge of the first one. The display now
  follows the window.
- **A preset folder without a manifest disappeared silently.** That is what an
  archive unpacked one level too deep looks like, and the app said nothing about
  it. It is listed with the reason now.
- **Deleting a preset while its slider was moving brought its settings back.**
  The pending write did not know the preset was gone.
- **Updating a bundled preset could leave you with neither version.** The old
  folder was deleted before the new one was copied; the replacement is atomic now.
- **A preset with a subfolder inside it stopped being updated, quietly.** Its
  fingerprint could not be computed, and the empty result erased the recorded one
  instead of leaving it alone.
- **Launch at login could be on and look off.** The state where macOS has the
  registration but the user switched it off in Login Items is now named, with a
  button that leads there.
- **The gamma table is reapplied after the screen wakes**, not only after the
  whole system does.
- **"Permission not granted" appeared over the still-open system dialog.** The
  system call reports the state at that moment, not the person's answer.
- **The About panel kept its menu bar.** Closing the settings window used to send
  the app back to the menu bar even with the panel still open, leaving it without
  ⌘W or ⌘Tab.
- **Preset and preview agreed on which preset is selected** when nothing had been
  chosen yet: the picker fell back to the first preset by name, the effect to the
  first free one.
- **VoiceOver reads a slider row once**, not three times.
- **Reduce Motion reaches the settings window.** The overlay and the preview
  already respected it; the window animated regardless.
- **The Russian interface says "дисплей" everywhere**, instead of switching to
  "монитор" in the one place where the display is picked.

### Performance

- **Frames are dropped instead of queued.** A capture frame now waits for the
  previous one to be drawn; the unbounded main-thread queue held IOSurfaces from
  the capture pool and grew latency along with it.
- **A capture frame is released when the GPU is done with it**, not when the draw
  call returns.
- **The capture stream is reconfigured instead of restarted** when the resolution,
  the frame rate or the quality changes: no visible gap, no renegotiation with
  the window server.
- **Queue depth is five and the overlay keeps two drawables**, which is the pair
  Apple recommends for a frame that crosses to the main thread and a layer that
  has to match what is under it.
- **The window tracker lets the system coalesce its timer.**

### Shaders

- **Film Grain and Dust & Scratches measure in points, not pixels.** On a Retina
  display the grain was half the intended size and the dust four times as dense.
- **Halation and Phosphor Terminal spread evenly.** Their offsets were fractions
  of the frame, so the halo was an ellipse on a wide screen and grew with pixel
  density.
- **Chromatic Aberration centres on the effect**, not on the middle of the
  display, which is what it did in window mode.

## 1.7.2

### Changed

- **Released images are signed ad-hoc.** An Apple certificate carries the name
  and the email address it was issued to, it rides inside the binary, and one
  command reads it back out of any image ever shipped. The app itself is the
  same. The cost lands on the eight presets that read the screen: macOS ties
  the Screen Recording permission to a lasting identity, an ad-hoc signature
  has none, so the permission has to be granted again after this update and
  after each one that follows. The nine presets that ask for nothing are
  unaffected.
- **Library Validation is off, and the ad-hoc signature is why.** That part of
  Hardened Runtime wants every embedded framework to carry the app's team id,
  and with an ad-hoc signature nobody has one, so the animation framework was
  refused and the app could not start at all. The rest of Hardened Runtime
  stands, and so does the App Sandbox.

## 1.7.1

### Fixed

- **The icon in the "How this works" window was a square.** It came straight
  out of the asset catalogue, where it is drawn as one; the rounded shape every
  app has in the Dock is a mask macOS applies at display time, and asking the
  system for the icon gets the mask with it.
- **A preset picked while a level 3 effect was starting went nowhere.** Bringing
  up a capture stream takes a moment, and during it the effect counted as
  neither on nor off, so the change was dropped and the stream came up with the
  previous preset: the menu ticked one thing and the screen showed another. The
  same held for the display, the tracked window and the capture quality. The
  toggle in settings had the matching half of the problem, ignoring a click that
  the hotkey would have acted on.
- **A preset could ask for a gamma of zero.** Parameters were validated down to
  the range of every slider while the gamma section next to them was not, so a
  manifest with a zero or an out-of-range point turned the screen into one flat
  colour instead of naming the mistake.
- **Capture failed on displays that report no refresh rate.** Some virtual
  displays answer zero, which made an invalid frame interval; they get sixty now.
- **The window tracker kept polling while the screen slept.** Everything else
  pauses with the screen; this one asked sixty times a second for a rectangle
  nobody could see.

### Changed

- **Building from source no longer needs a developer certificate.** The default
  signature is ad-hoc, which builds on any machine. Working on level 3 still
  wants a real certificate, because the Screen Recording grant is tied to it.

## 1.7.0

### Added

- **A menu bar strip while the settings window is open.** The app turns itself
  into an ordinary one to show that window, and until now it did so with an
  empty bar: no ⌘W, no ⌘Q and no Edit menu, which meant the shader compilation
  error the window lets you select could not be copied out of it.
- **Opening the app again opens its settings.** An app with no Dock icon is
  reached through the menu bar, and a full menu bar hides the icon that reaches
  it; double-clicking the app in Applications did nothing visible. It now brings
  up the settings window, and a second copy started some other way asks the
  running one to show itself instead of quitting silently.
- **How this works** in the menu bar menu: the same explanation the first launch
  shows, for the times it is remembered later than it was read.
- **Slider values can be typed.** Preset descriptions name exact numbers - the
  green phosphor of Phosphor Terminal is a hue of 0.36 - and dragging was the
  only way to aim at them.
- **Links out of the window**: how to write a preset, next to the buttons that
  create one, and what changed between versions, next to the update check.

### Changed

- **Four tabs instead of five.** Placement and Capture both answered where the
  effect lands and what it costs there, and they are Display now; Updates held
  three controls and moved into General. The buttons that manage the whole
  preset collection left the Effect tab for a Presets tab of their own, where
  they no longer read as actions on the one preset being tuned - and the sliders'
  reset button went back to being called "Reset to defaults".
- **The settings window stops at the edge of the screen.** Its height follows
  the tab, and a folder of broken presets has no ceiling: fifteen of them used
  to push the buttons below the bottom edge with no way to reach them. The
  content scrolls now.
- **The menu bar icon says on or off by its shape.** The television it draws has
  a lit screen when the effect is on and an empty one when it is off, instead of
  the whole icon dimming - a dimmed control on macOS means unavailable.
- **Presets and levels explain the space switch.** The line under the preview
  says which levels drop for about a second when you swipe between spaces, and
  which one does not.

### Fixed

- **Colours drifted on wide-gamut displays.** Neither the overlay layer nor the
  capture stream stated a colour space, so the numbers a shader wrote were read
  in the display's: on Display P3 the same tint came out more saturated, and the
  preview and the screen disagreed. Everything states sRGB now.
- **The preview kept animating after Reduce Motion was turned on.** The effect
  on screen stopped, and the settings window said the preset stays still, while
  the picture next to that sentence carried on moving.
- **A crash left the screen tinted.** The gamma table was restored on an orderly
  quit but not on `SIGSEGV` and its neighbours, so a crash with a level 1 preset
  on left the display recoloured until the app was started again.
- **Pressing the hotkey during a level 3 start did nothing.** Starting a capture
  preset is asynchronous, and a second press while it came up was swallowed
  instead of cancelling it.
- **Choosing another display after one was unplugged did not bring the effect
  back.** It waited for a further display event that never had to come.
- **A shader was compiled twice**, once for the preview and once for the screen,
  because the two kept separate pipeline caches.
- **The update check identifies itself and spends fewer requests.** GitHub
  requires a User-Agent, the check now sends one and an `If-None-Match`, and a
  rate-limited answer says so in words instead of "status 403". The last known
  release survives a restart, so a 304 no longer hides an update found earlier.
- **The no-shaders message showed a container path** in the middle of its text.
  It leads to the folder with a button now.
- **Projector pulsed.** Its lamp darkened the whole screen by a quarter: at
  first twice a second, which read as flicker in the band the eye notices most
  and the one that is unsafe for photosensitive people, and then - once the
  wobble was slowed to 0.37 Hz - as breathing every few seconds. Slowing it
  never removed it, because the depth stayed the same. The brightness
  modulation is gone entirely, the Flicker slider with it, and Projector is now
  a steady vignette that stops redrawing once it is on. The other animated
  presets change the screen by two or three percent at most, locally rather
  than all at once.

## 1.6.0

### Added

- **Every preset says what it does.** A line under the preview and a tooltip in
  the menu bar, in English or Russian: "Halation" and "Aperture Grille" told
  nobody anything on their own. The three presets that quantise the picture say
  there that small text becomes hard to read, and Halation says it is the
  expensive one. Slider captions are translated too, while preset names stay in
  one language on purpose - they work like the names of film stocks.
- **A first launch that explains itself.** The app used to open its settings
  window and leave the rest unsaid: which icon in the menu bar is ours, that
  clicking it turns the effect on, and that there is a hotkey. It says so once,
  with the current shortcut in it.
- **New preset from template**, a button that writes a working level 2 preset
  into the shaders folder and shows it in Finder. "Open shaders folder" alone
  assumed you keep the manifest format in your head.
- A shader that does not compile shows the compiler's message under the
  preview. It used to be a line in the log, so the preset looked healthy right
  up until it was turned on.
- Settings say when an animated preset is held still by the system "Reduce
  Motion" setting, instead of letting it look broken.

### Changed

- **The preset that is running follows the file.** Editing a shader on disk
  refreshed the list and the preview but left the screen on the old pipeline,
  so the settings window showed one thing and the display another.
- **A deleted bundled preset stays deleted.** It used to come back on the next
  read of the folder, which made breaking its manifest the only way to be rid
  of it. "Restore bundled presets" still brings them all back.
- Presets are ordered by the name you see rather than by folder name, so
  "Phosphor Terminal" no longer leads the list from inside a folder called
  AmberTerminal.
- On a fresh install the selected preset is a free one. It used to be whatever
  sorted first, which asked for Screen Recording on the first press of the
  hotkey.
- Unplugging a display turns the effect off, as before, and plugging it back in
  brings the effect back: it was not the person who turned it off.
- Window-only mode survives a restart, like every other setting.
- The permission panel names the preset asking for it, and the settings window
  tells you a private repository is why there is nothing to check against.
- Stepping through the preset list is no longer a fresh shader compilation per
  step: the preview caches pipelines the way the overlay already did.
- The hotkey line in the menu opens the tab where the hotkey is recorded,
  failed presets get a heading of their own, "Reset to defaults" is now "Reset
  the sliders" - which is all it ever did - and a slider value shows as many
  decimals as its range deserves.
- A second copy of the app quits at launch instead of adding a second menu bar
  icon and a second gamma table over the same display.
- VoiceOver reads the sliders by name and the menu bar icon by state.

### Fixed

- **Time stood still for every preset that reads the screen.** The clock was
  started for a drawn layer and never for a captured one, so a level 3 shader
  declaring itself animated stayed on frame zero - and then started moving on
  its own after the screen slept. All bundled level 3 presets are still, which
  is why nothing looked wrong.
- The Russian text of the permission panel had drifted from the string in the
  code by one invisible newline and was never shown. The string catalogue is
  now checked against what the compiler actually extracts.

## 1.5.0

### Added

- **Eleven presets, taking the catalogue from six to seventeen.** Free, applied
  in scanout: **Faded Photo** lifts the black and softens the white under a warm
  tint, a photo left in the sun; **Moonlight** is the day-for-night trick from
  film. One drawn layer: **Dust & Scratches** puts film wear over the screen -
  vertical scratches and specks in the gate, each living exactly one film frame -
  which is what Film Grain was missing to read as film rather than as a noisy
  picture; **Projector** breathes the lamp on two mismatched frequencies and
  drops the corners into shadow. Reading the screen: **Phosphor Terminal** pours
  luminance into one phosphor - amber by default, P1 green a slider away -
  **Aperture Grille** gives every third column its own phosphor, **Halation**
  spreads light past the edge of what emits it,
  **Chromatic Aberration** diverges the channels towards the edges, and
  **Halftone**, **1-bit Dither** and **Game Boy** quantise the picture to dots,
  to two shades and to the four DMG greens.
- **The preset list is grouped by rendering level**, in the menu bar and in
  settings alike: Free, One drawn layer, Reads the screen. Seventeen names in a
  row read as a directory listing, and the level is what the choice actually
  turns on - what the preset costs and whether it will ask for the Screen
  Recording permission.

### Changed

- **Settings became five tabs in a toolbar**, the standard shape of a macOS
  preferences window, instead of one page that had grown long enough to push the
  sliders of the selected preset below the fold. The window resizes to whatever
  the current tab needs, and the toolbar is drawn by the system rather than by
  us.
- Menu bar items carry icons: the effect, the hotkey, each preset, settings,
  about and quit. A preset names its own icon through the new `icon` field of
  `manifest.json`, and a preset without one falls back to a symbol for its
  rendering level.
- Parameter names read as words rather than as code: `grainStrength` shows up as
  Grain Strength. The words are the ones the preset author chose, only the
  spacing changed.

### Fixed

- Film grain crawled towards the top left corner instead of flickering in place.
  The noise hash is a function of a fixed grid, and the shader animated it by
  offsetting both coordinates by the elapsed time, which moves the pattern
  rather than replacing it: one pixel per frame, exactly the speed the eye
  tracks best. The frame number is now an axis of the hash instead of an offset,
  and the grain is redrawn 24 times a second like film rather than on every
  refresh.

## 1.4.0

### Added

- **Bundled presets update themselves.** Until now a preset was copied to your
  shaders folder once and never touched again, so a fix shipped with a new
  version never reached anyone who already had the folder. Presets you have not
  edited are now brought up to date; edited ones are recognised by their
  contents and left exactly as they are.
- **Restore bundled presets**, a button in settings that puts the six shipped
  presets back the way they came. The only way out if you edited one and broke
  it.
- **An on-off switch in the settings window.** The effect could only be turned
  on from the menu bar or the hotkey, which is awkward in the one window that
  opens on first launch.

### Changed

- Picking a preset from the menu bar no longer turns the effect on. Choosing is
  choosing: a running effect switches over, a stopped one stays stopped and
  cannot pull up a permission dialog on its own.
- The preview stops animating when the app is not in front, not only when the
  window is hidden. A settings window fully covered by another app used to keep
  drawing.
- Settings no longer claims "no presets available" when the selected preset was
  deleted while others remain. The preset list stays usable.
- A missing GitHub release now reads as a plain statement rather than a red
  error: a private repository and a repository without releases both answer 404,
  and neither is a fault. Scheduled checks also count the attempt, so an
  unreachable GitHub is no longer asked again every hour.

### Fixed

- Moving the effect to another display left the previous one tinted until the
  effect was switched off entirely.
- Turning the effect off while a level 3 preset was still starting could leave
  the capture stream running with no window to draw into, and the app claiming
  the effect was on.
- A failure to read the shaders folder could wipe the saved slider values of
  every preset. Settings are now only pruned against a folder that was read in
  full.
- The signal handler no longer forces exit code 1 on a normal `kill`, and only
  restores the gamma table when the app actually changed it.

## 1.3.0

### Added

- A preview of the selected preset next to the sliders that drive it, running on
  a picture that ships with the app. Even Black and White, the one preset that
  needs Screen Recording, previews without asking for anything.
- Invert and Sepia can be seen before they are turned on: they work through the
  display gamma table, which nothing can sample, so the preview applies the same
  table to the picture itself.

### Changed

- The settings window is one page of four groups instead of a sidebar with a
  preset list.
- The menu bar icon is the app's own silhouette instead of a system symbol.
- Switching a preset, checking for updates and a new version arriving animate
  instead of appearing at once.

## 1.2.0

### Added

- Update check against the GitHub releases page: weekly by default, with daily,
  monthly and never as options, plus a Check now button. The app never downloads
  or installs anything, it opens the release page.
- An About panel with a one-line description.

## 1.1.0

### Changed

- The project is named Subvenio Screen. It shipped briefly as Subvenire Screen
  and before that as ScreenFilter.
- README rewritten as a user-facing page, with the developer material split out
  into DEVELOPMENT.md.

## 1.0.1

### Fixed

- Film grain and VHS noise died out about four minutes in. The hash mixed
  elapsed time into its argument and `sin` ran out of precision; the shaders now
  use an integer hash and the shader clock wraps once a day.

## 1.0.0

First release: six presets across three rendering levels, a global hotkey,
window-scoped mode, per-display selection, user shaders as plugins, launch at
login, English and Russian interface, App Sandbox, and disk images built with
`create-dmg`.
