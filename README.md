# Subvenire Screen

A lightweight macOS menu bar app that lays visual effects over everything on
screen - scanlines, film grain, VHS, sepia, honest black and white - and
toggles them with a global hotkey.

Effects are plugins, not a fixed list: a shader is a folder with a manifest and
a Metal fragment function, and it shows up in the menu the moment you save it,
without rebuilding the app.

The repository is private for now.

## The constraint that shapes everything

macOS has no public backdrop filter. A transparent window **cannot** transform
what is underneath it: `CALayer.backgroundFilters` and `compositingFilter` only
affect the window's own content, and `NSVisualEffectView` does blur and vibrancy
and nothing else. Without reading pixels you can draw **over** the screen, never
**through** it.

So Subvenire Screen has three rendering levels, and every plugin declares which one
it needs.

| Level | Mechanism | Can do | Cost | Permission |
|-------|-----------|--------|------|------------|
| 1 | `CGSetDisplayTransferByTable` | per-channel work: tint, gamma, inversion, clipping | none, applied in scanout | none |
| 2 | transparent overlay window + Metal | anything drawn on top: scanlines, vignette, grain, bands | one composited layer | none |
| 3 | ScreenCaptureKit + Metal | anything that must read the screen: black and white, aberration, bloom | real, scales with resolution and refresh rate | Screen Recording |

Two consequences worth knowing:

- Level 1 lands after compositing, so it covers the cursor, the menu bar and the
  Dock for free, and cannot be confined to a window.
- Honest black and white needs level 3. A gamma table scales channels
  separately and cannot mix them, which is exactly what luminance requires.

## Features

- Menu bar app, no Dock icon, state restored between launches. Left click
  toggles the effect, right click (or control click) opens the menu.
- Global hotkey via Carbon, so no Accessibility permission is required.
- Shader plugins loaded from disk and watched with FSEvents: save a file and the
  list updates itself. Broken plugins show up with the actual error text.
- Settings window: preset list, per-preset parameter sliders that reach the
  running effect live, capture size and frame rate limits, display picker,
  hotkey recorder, launch at login.
- Window-scoped mode: the effect follows one window as it moves and resizes.
- Problems are reported in the menu bar, not by stealing focus with a modal
  dialog. The icon changes and the menu carries the detail.
- Animation pauses when the screen sleeps, and respects the system
  "reduce motion" setting.
- English and Russian interface.

## Requirements

- macOS 14.0 or later
- Apple Silicon only
- Xcode 16 or later, and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
  (`brew install xcodegen`)

## Build

The Xcode project is generated from `project.yml` and is not tracked in git.

```sh
make run      # generate, build, launch
make test     # unit tests for the pure parts
make release  # signed Release build packaged as a .dmg in dist/
```

Signing defaults to automatic and needs nothing from you. TCC binds the Screen
Recording grant to team id plus bundle id, so a stable signature keeps the
permission across rebuilds where an ad-hoc one would lose it every time. To pin
your own certificate, create `Signing.local.xcconfig` (git-ignored):

```
CODE_SIGN_STYLE = Manual
CODE_SIGN_IDENTITY = <SHA-1 from security find-identity -v -p codesigning>
DEVELOPMENT_TEAM = <your team id>
```

## Install

`make release` produces `dist/Subvenire Screen <version>.dmg` (built with
[create-dmg](https://github.com/sindresorhus/create-dmg), `brew install
create-dmg`). Open it and drag the app onto Applications.

Releases are versioned by hand: SemVer starting at 1.0.0, tagged in git
(`git tag -a v1.0.0 -m "..."`). There is no auto-update mechanism; a new version
means downloading a new disk image.

Builds are not notarised, which is a deliberate choice for a personal tool. A
disk image downloaded through a browser carries the quarantine flag, and
Gatekeeper refuses to open an unnotarised app outright. Either right click the
app and choose Open, confirm once in Privacy & Security, or clear the flag:

```sh
xattr -d com.apple.quarantine "/Applications/Subvenire Screen.app"
```

Copying the image over AirDrop or a local network keeps the flag as well;
copying it with `scp` or `rsync` does not set it in the first place.

## Writing a shader

Plugins live in the app's sandbox container:

```
~/Library/Containers/dev.senya.SubvenireScreen/Data/Library/Application Support/SubvenireScreen/Shaders/
```

Nobody should have to type that, so settings has an "Open shaders folder"
button. Bundled presets are copied there on first launch, folder by folder, and
existing folders are never overwritten - delete a folder to get the bundled
version back. The folder is watched, so a new or edited plugin is picked up
without a restart.

A plugin is a folder with `manifest.json` and, for levels 2 and 3,
`shader.metal`:

```json
{
  "name": "Scanlines",
  "level": 2,
  "animated": false,
  "parameters": [
    { "name": "scanlineStrength", "min": 0, "max": 1, "default": 0.22 }
  ]
}
```

Parameter names must be plain identifiers, `min` must be below `max`, and the
default must lie between them: the name becomes a shader macro and the range
becomes a slider, so both are validated before anything is compiled.

`shader.metal` holds only the fragment function. The engine prepends a prelude
with the vertex function, the uniform struct and shared helpers, and turns
manifest parameters into named macros, so the shader reads `scanlineStrength`
rather than `u.params[0]`:

```metal
fragment float4 overlay_fragment(VertexOut in [[stage_in]],
                                 constant Uniforms &u [[buffer(0)]]) {
    float scan = fract(in.position.y / (3.0 * u.scale)) < 0.5 ? scanlineStrength : 0.0;
    return float4(0.0, 0.0, 0.0, saturate(scan));
}
```

Available in every shader:

- `in.uv` - normalised coordinates of this overlay, origin top left
- `in.position` - pixel coordinates
- `u.resolution`, `u.scale`, `u.time`
- `u.sourceOrigin`, `u.sourceSize` - which slice of the display frame this
  overlay shows, and `overlay_source_uv(in.uv, u)` to sample it
- `overlay_hash(float2)` for noise, `overlay_sampler` for level 3 textures

Level 2 shaders must output premultiplied alpha. Level 3 shaders receive the
captured frame as `texture2d<float> source [[texture(0)]]` and return opaque
pixels.

Level 1 plugins carry a `gamma` section instead of a shader:

```json
{
  "name": "Sepia",
  "level": 1,
  "gamma": {
    "tint": [1.0, 0.88, 0.72],
    "gamma": 1.0,
    "invert": false,
    "blackPoint": 0.04,
    "whitePoint": 0.96
  }
}
```

A manifest that does not parse, a shader that does not compile, or a level that
is not supported shows up in the menu and in the settings window with the actual
error text instead of being skipped silently.

## Permissions

- **Screen Recording** is requested lazily, the first time a level 3 preset is
  turned on by hand, behind an explanation screen of the app's own. Refusing
  leaves levels 1 and 2 fully working. On autostart the app never asks: a
  level 3 preset simply stays off until you turn it on yourself.
- **Accessibility** is never requested. The global hotkey uses Carbon
  `RegisterEventHotKey`, and window tracking polls `CGWindowList` - one lookup
  by window id measures at 0.08 ms, which is 0.5% of a core at 60 Hz.

Frames from screen capture only live in memory until they are drawn. Nothing is
written to disk and nothing leaves the machine, as `PrivacyInfo.xcprivacy`
declares.

## Known limits

- One effect on one display at a time. The target display is selectable, but
  independent presets on several monitors at once are not implemented.
- Level 1 cannot be confined to a window, by nature.
- The overlay window uses `sharingType = .none`, so it is invisible to
  screenshots and to other apps' screen capture. That also closes half of the
  level 3 feedback loop.
- Level 3 always captures the whole display, even in window-scoped mode.
  `SCStreamConfiguration.sourceRect` would fix that but needs macOS 14.
- The app has no icon of its own yet.

## Layout

```
Sources/            Swift, one file per concern
  AppDelegate       menu bar and window wiring
  EffectController  state, backend selection, persistence
  Overlay           overlay window, Metal view, renderer, capture lifecycle
  Gamma             level 1 backend
  Capture           level 3 backend
  ShaderPlugin      manifest model, validation and loader
  ShaderPipeline    uniform layout, shader prelude, runtime compilation
  PluginWatcher     FSEvents watch over the plugin folder
  WindowTracking    window-scoped mode
  Logging           os.Logger categories
Tests/              gamma tables, manifest validation, uniform layout
Resources/Shaders/  bundled presets
scripts/release.sh  Release build into dist/
project.yml         XcodeGen project definition
Signing.xcconfig    signing defaults, overridable locally
```

Architecture decisions and the reasoning behind them live in [PLAN.md](PLAN.md).
