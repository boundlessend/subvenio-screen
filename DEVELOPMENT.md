# Development

How to build the app and how to write a preset for it. What the app does lives
in [README.md](README.md); why it is built this way, in [PLAN.md](PLAN.md).

## Build

Requires macOS 14 or later, Xcode 16 or later and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). The
Xcode project is generated from `project.yml` and is not tracked in git.

```sh
make run      # generate, build, launch
make test     # pure transforms, preset installation, every bundled shader
make release  # signed Release build packaged as a .dmg in dist/
```

CI additionally runs `swiftlint lint --strict`, so a warning fails the build.
What `.swiftlint.yml` turns off is turned off with the reason next to it.

`make release` needs [create-dmg](https://github.com/sindresorhus/create-dmg)
(`brew install create-dmg`). Releases are versioned by hand: bump
`MARKETING_VERSION` in `project.yml`, tag the commit (`git tag -a v1.1.0`) and
attach the disk image to a GitHub release.

Signing defaults to ad-hoc and needs nothing from you: no developer account, no
certificate. The cost shows up only on level 3 presets, where TCC binds the
Screen Recording grant to team id plus bundle id: an ad-hoc signature changes
from build to build, so the permission has to be granted again after each one. If
you work on capture regularly, pin your own certificate in
`Signing.local.xcconfig` (git-ignored) and the grant survives rebuilds:

```
CODE_SIGN_STYLE = Manual
CODE_SIGN_IDENTITY = <SHA-1 from security find-identity -v -p codesigning>
DEVELOPMENT_TEAM = <your team id>
```

## Layout

```
Sources/            Swift, one file per concern
  main              entry point without a NIB
  AppDelegate       menu bar and window wiring
  MainMenu          the menu bar strip shown while the settings window is open
  SettingsWindow    the settings window: a tab per screen, SwiftUI
  SettingsWindowController  the AppKit window, its toolbar and its sizing
  Preview           the preset preview on the bundled picture
  EffectController  state, backend selection, persistence
  PluginSettings    slider values and per-preset options
  Overlay           overlay window, Metal view, effect lifecycle
  Renderer          Metal device, the draw call, the display link
  Gamma             level 1 backend
  Capture           level 3 backend
  Displays          display identity and the list settings picks from
  Permissions       Screen Recording onboarding and alerts
  Shortcuts         the global hotkey and its default combination
  LaunchAtLogin     registration through SMAppService
  Updates           the release check and its interval
  ShaderPlugin      manifest model, validation, loader and installer
  ShaderPipeline    uniform layout, shader prelude, runtime compilation
  PluginWatcher     FSEvents watch over the plugin folder
  WindowTracking    window-scoped mode
  Logging           os.Logger categories
Tests/              pure transforms, preset installation, bundled shaders
Resources/Shaders/  bundled presets
assets/             images used by the README
scripts/            release packaging and the CI changelog check
project.yml         XcodeGen project definition
Signing.xcconfig    signing defaults, overridable locally
```

Rendering is verified by eye and by the system rather than by unit tests: window
geometry through `CGWindowListCopyWindowInfo`, gamma through
`CGGetDisplayTransferByTable`, capture through the app's own log output:

```sh
log stream --info --debug --predicate 'subsystem == "dev.senya.SubvenioScreen"'
```

One trap worth knowing: the overlay window sets `sharingType = .none`, so a
screenshot can never confirm that the effect is drawn. Render the shader offline
into a texture instead when you need to look at it.

## Writing a shader

Presets live in the app's sandbox container:

```
~/Library/Containers/dev.senya.SubvenioScreen/Data/Library/Application Support/SubvenioScreen/Shaders/
```

Nobody should have to type that, so settings has an "Open shaders folder"
button, and "New preset from template" next to it writes a working level 2
preset there and shows it in Finder.

Bundled presets are copied to that folder on first launch, folder by folder. On
every later launch each bundled preset is fingerprinted (SHA-256 over the folder
contents) and compared with the fingerprint recorded when it was installed: an
untouched copy is replaced by the version shipped with the app, an edited one is
left exactly as it is, and one that is gone stays gone - deleting a preset is a
decision, not an accident to repair. "Restore bundled presets" in settings puts
them all back regardless. The folder is watched, so a new or edited preset is
picked up without a restart, and an edit to the preset currently on screen
restarts the effect on the new version.

A preset is a folder with `manifest.json` and, for levels 2 and 3,
`shader.metal`:

```json
{
  "name": "Scanlines",
  "description": {
    "en": "The lines of a CRT over the screen, with the corners in shadow.",
    "ru": "Строки кинескопа поверх экрана, углы уходят в тень."
  },
  "level": 2,
  "icon": "line.3.horizontal",
  "animated": false,
  "parameters": [
    {
      "name": "scanlineStrength",
      "title": { "ru": "Сила строк" },
      "min": 0, "max": 1, "default": 0.22
    }
  ]
}
```

Parameter names must be plain identifiers, `min` must be below `max`, and the
default must lie between them: the name becomes a shader macro and the range
becomes a slider, so both are validated before anything is compiled.

`description` is one sentence about what the preset does, shown under the
preview and as the tooltip in the menu bar. `title` is the caption of a slider;
without one it is assembled from the parameter name, so `grainStrength` reads as
Grain Strength. Both accept either a plain string or an object of language code
to text, and the app picks the language of the interface. A language it cannot
find leaves the description out and the caption assembled from the name, rather
than showing text in a language nobody asked for - which is why the bundled
presets carry `en` and `ru` descriptions but only `ru` captions.

`icon` is an SF Symbols name shown next to the preset in the menu bar. It is
optional, and a name the system does not know falls back to a symbol for the
rendering level, so a typo costs a generic icon rather than an error.

`level` decides more than the backend: the menu and the settings picker group
presets by it, under Free, One drawn layer and Reads the screen. A preset lands
in the group its level names, without saying anything about it.

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
- `u.resolution`, `u.scale`, `u.time` - time wraps once a day
- `u.sourceOrigin`, `u.sourceSize` - which slice of the display frame this
  overlay shows, and `overlay_source_uv(in.uv, u)` to sample it
- `overlay_hash(float2)` and `overlay_hash3(float3)` for noise,
  `overlay_sampler` for level 3 textures

Both hashes read a fixed grid, so animating one by adding time to its
coordinates slides the pattern across the screen instead of replacing it. Give
the frame number an axis of its own: `overlay_hash3(float3(in.position.xy,
floor(u.time * 24.0)))`.

Level 2 shaders must output premultiplied alpha. Level 3 shaders receive the
captured frame as `texture2d<float> source [[texture(0)]]` and return opaque
pixels.

Level 1 presets carry a `gamma` section instead of a shader:

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

A manifest that does not parse or names a level that is not supported shows up
in the menu and in the settings window with the actual error text instead of
being skipped silently. A shader that does not compile is only found when
something builds a pipeline from it, which the preview does as soon as the
preset is selected: the compiler's message appears under the preview. For the
bundled presets `make test` compiles them all, so a broken one never reaches a
release.
