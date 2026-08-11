# Changelog

Notable changes per release. Versions follow [SemVer](https://semver.org), and
each one ships as a disk image on the
[Releases](https://github.com/boundlessend/subvenio-screen/releases) page.

## Unreleased

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
  **Aperture Grille** gives every third column its
  own phosphor, **Halation** spreads light past the edge of what emits it,
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
