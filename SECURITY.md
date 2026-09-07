# Security

## Reporting a vulnerability

Report privately through GitHub: open a draft advisory at
[Security → Advisories](https://github.com/boundlessend/subvenio-screen/security/advisories/new).
Expect a first answer within a week. Please do not open a public issue for
anything that could be used against someone running the app.

## What the app can reach

- **Screen Recording**, and only for the eight presets that read the screen.
  Frames live in memory until they are drawn: nothing is written to disk and
  nothing leaves the machine.
- **The network**, for one request: the GitHub releases API, to learn whether a
  newer version exists. The app never downloads or installs anything by itself.
- **Its own sandbox container**, where the shaders folder lives.

The app runs inside the App Sandbox with the Hardened Runtime on, and holds no
entitlement beyond `app-sandbox` and `network.client`.

## Presets are code

A preset is a Metal fragment function that this app compiles and runs on your
GPU. The sandbox keeps a preset away from your files and the network, but a
preset can draw anything over your whole screen and spend as much GPU time as it
likes. Read a shader before you drop it in, the same way you would read a script.

## Disk images

Releases carry an ad-hoc signature and are not notarized, so the signature says
nothing about who built the image. Each release note carries the SHA-256 of the
disk image; compare it before opening:

```sh
shasum -a 256 "Subvenio Screen 1.7.2.dmg"
```

## Supported versions

Fixes go into the next release from `main`. Older versions get nothing.
