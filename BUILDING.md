# Building from source

This source is available under the repository's [noncommercial source-available license](LICENSE). Commercial use, including using the app for paid work, requires prior written permission from Daniel Hanna. Redistributed versions must include corresponding source under the same terms.

## Requirements

- An Apple Silicon Mac running macOS 27 or later.
- Xcode with the macOS 27 SDK and command-line tools installed.
- The included zsh build script. There are no third-party package dependencies.

## Build

From the repository root:

```sh
zsh build.sh
```

The app is created at `build/Sidecar On-Screen Keyboard.app`. Icon files are generated in `build/icon-assets`. Nothing is installed automatically, and the script does not grant Accessibility permission.

The default build is ad hoc signed for development. It does not carry the project's Developer ID signature or Apple notarization ticket. For a build that already has those, use the app ZIP from Releases.

For a separate development identity and preferences domain:

```sh
SIDECAR_BUNDLE_ID=local.example.SidecarKeyboard.Dev zsh build.sh
```

Open your build, grant its requested Accessibility permission yourself, then select your connected Sidecar display.

## Checks and previews

```sh
'build/Sidecar On-Screen Keyboard.app/Contents/MacOS/SidecarKeys' --self-test
'build/Sidecar On-Screen Keyboard.app/Contents/MacOS/SidecarKeys' --recognition-smoke-test
mkdir -p build/previews
'build/Sidecar On-Screen Keyboard.app/Contents/MacOS/SidecarKeys' --render-previews "$PWD/build/previews"
```

The built-in checks cover focus rules, layouts, geometry, modifiers, repeat, preview privacy guards, suggestion ranges/cancellation, handwriting state and pause behavior. Physical Sidecar and cross-app behavior still need hands-on testing.

`--diagnostics` optionally writes geometry, gesture counters and focus metadata to `runtime.json` beside the compiled source tree. It does not record typed text or clipboard values. Diagnostics are disabled during normal launches. Generated files are excluded from Git. `--handwriting-pad` opens the real pad directly for developer interaction checks without opening Settings.

## Distribution signing

Code is public; the project's signing keys and account credentials are not. Another person's build cannot use the official Developer ID identity without its private key.

A distributor who has permission under the license can use their own installed signing identity:

```sh
SIDECAR_SIGN_IDENTITY='Developer ID Application: Your Name (YOURTEAMID)' \
SIDECAR_HARDENED_RUNTIME=1 zsh build.sh
```

Public distribution of a changed build requires its own signing and notarization. This repository contains no signing keys, certificates with private keys, provisioning profiles, or notarization account credentials.
