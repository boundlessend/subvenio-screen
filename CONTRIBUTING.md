# Contributing

## Before you build

macOS 14 or later, Xcode 16 or later, and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). The
Xcode project is generated from `project.yml` and is not tracked in git.

```sh
make run     # generate, build, launch
make test    # pure transforms, preset installation, every bundled shader
make lint    # the same swiftlint --strict that CI runs
```

CI fails on any lint warning, so run `make lint` before pushing.

## What a change should look like

- One commit per logical change, [Conventional Commits](https://www.conventionalcommits.org)
  for the subject line (`fix(capture): ...`).
- Comments explain decisions, not syntax. The ones already in the code are the
  standard to match.
- New behaviour that is deterministic gets a test; rendering does not. The
  reasoning is in [PLAN.md](PLAN.md#testing-strategy).
- Interface strings go through `String(localized:)` and get a Russian
  translation in `Resources/Localizable.xcstrings`.

## Where the reasoning lives

[PLAN.md](PLAN.md) records why the app is built the way it is: three rendering
levels, the permissions it refuses to ask for, what was rejected and why. Read
the relevant decision before changing something it covers, and update it in the
same commit if the decision itself changes.

## Presets

A new bundled preset needs a folder in `Resources/Shaders`, a description in
both languages, and a rendering level that matches what it actually does. Render
it offline against the preview picture before proposing it: an animated preset
that modulates the brightness of the whole frame is rejected on sight, for the
reason written down in [PLAN.md](PLAN.md#presets).
