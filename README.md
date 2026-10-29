<p align="center">
  <img src="assets/app-icon.png" width="128" height="128" alt="Sidecar On-Screen Keyboard icon">
</p>

# Sidecar On-Screen Keyboard

**An iPad-style keyboard and easier-to-tap Mac window controls for Sidecar.**

Sidecar On-Screen Keyboard makes Mac apps easier to use by touch on your iPad. It combines a familiar on-screen keyboard with enlarged Close, Minimize and Zoom buttons, making typing and managing windows more comfortable.

[**Download the latest release**](https://github.com/danny67999/sidecar-on-screen-keyboard/releases/latest)

## Features

- **Automatic keyboard:** Appears when you tap a supported text field on your selected Sidecar display.
- **Larger window controls:** Tap the native traffic-light cluster once to reveal larger Close, Minimize and Zoom buttons. Choose a larger button to perform its action. The title bar and browser tabs remain available to the app.
- **Two keyboard layouts:** Choose an iPad-style layout with a separate Mac key row, or a compact desktop layout.
- **Mac shortcuts:** Access Command, Option, Control, Shift, Escape, arrows, function keys and a numeric keypad.
- **Modifier combinations:** Hold modifiers while tapping other keys, or tap a modifier to latch it.
- **Hold to repeat:** Hold letters, Backspace or arrow keys for repeated input.
- **Move, resize and dock:** Position the keyboard freely or snap it to the top or bottom of the display.
- **Optional window fitting:** Fit a supported app window around the docked keyboard.
- **Live typing preview:** See text around your cursor above the keyboard when the original text field is covered.
- **Touch editing controls:** Access Undo, Redo, Cut, Copy and Paste, plus an optional editing menu for selected text.
- **Touch app menus:** Browse supported Mac app menus using larger touch targets.
- **Menu-bar switch:** Pause or resume the keyboard and touch helpers without quitting.
- **Appearance options:** Match your Mac's appearance or choose light or dark.
- **Optional dismissal after Return:** Hide the keyboard after Enter; Shift-Enter keeps it open.

## Requirements

- An Apple Silicon Mac running **macOS 27 or later**
- A Sidecar-compatible iPad running **iPadOS 27 or later** for finger interaction
- An active Sidecar connection
- Permission for the app to control your Mac through Accessibility

## Installation

1. Download the app ZIP from [Releases](https://github.com/danny67999/sidecar-on-screen-keyboard/releases/latest).
2. Extract **Sidecar On-Screen Keyboard.app** and move it to Applications.
3. Open the app and follow the Setup Guide.
4. Grant the requested Accessibility permission in System Settings.
5. Connect your iPad using Sidecar and select its display in the app.
6. Tap a supported Mac text field on your iPad to start typing.

The release is **Developer ID signed and notarized by Apple**. Download the app ZIP listed under the release's **Assets**.

## Privacy

The app has no built-in analytics, typing history or clipboard history.

The optional typing preview reads text around the cursor in supported fields and keeps the preview in memory. It clears when the keyboard hides or the preview is disabled. Password and protected fields are excluded.

Copy and paste controls send standard Mac shortcuts without collecting clipboard contents.

## Compatibility

Automatic text-field detection, selection controls, app menus and window fitting depend on the Accessibility support provided by each application.

Window fitting works with supported resizable windows. Full-screen windows and application minimum sizes can limit this behavior.

The keyboard displays US key legends. Your Mac's active input source determines character interpretation. Predictive text, dictation and swipe typing are not included.

## Feedback

Report bugs and compatibility issues through [GitHub Issues](https://github.com/danny67999/sidecar-on-screen-keyboard/issues). Include your macOS and iPadOS versions, the affected application and steps to reproduce the problem.

## Source and license

The source code is available for personal, noncommercial study, use, modification and sharing under the [Noncommercial Source-Available License](LICENSE).

**Commercial use is prohibited without Daniel Hanna's prior written permission. This includes using the app for paid work or business operations, selling it, paid services, and incorporating its code into commercial products.** Redistributed versions and modifications must include their corresponding source under the same license.

[Browse the version 1.0 source](https://github.com/danny67999/sidecar-on-screen-keyboard/tree/v1.0-source-r2) or [download its source ZIP](https://github.com/danny67999/sidecar-on-screen-keyboard/releases/download/v1.0/Sidecar-On-Screen-Keyboard-1.0-source.zip).

These are source-available terms, not an OSI-approved open-source license. Public source does not grant commercial permission. Contact Daniel Hanna through this repository to request separate written terms.

See [Building from source](BUILDING.md), [Security and privacy](SECURITY.md), and [Third-party notices](THIRD_PARTY_NOTICES.md).

This repository provides source code, release downloads, documentation and issue tracking.

*Sidecar On-Screen Keyboard is an independent application and is not affiliated with or endorsed by Apple.*
