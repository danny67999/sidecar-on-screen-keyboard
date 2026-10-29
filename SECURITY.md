# Security and privacy

This app uses macOS Accessibility APIs and sends keyboard events to the active app. Grant Accessibility access only to a build you trust. Source availability and Apple notarization do not replace reviewing the behavior of a modified build.

- The app has no built-in analytics, network service, typing history, or clipboard collection.
- The optional typing preview reads the focused field only while enabled and visible, rejects recognized secure/protected fields, and clears its in-memory preview when hidden or disabled. Support depends on the target app's Accessibility information.
- Developer diagnostics are opt-in and contain geometry/gesture metadata, not field contents.
- Signing keys, tokens, account passwords, developer handoffs and local runtime files are not part of this repository.

The release ZIP is Developer ID signed and notarized. Locally compiled or modified versions have a different trust status unless separately signed and notarized.

## Reporting

Use GitHub's private vulnerability reporting if available. Do not put passwords, private text, signing material or personal documents into a public issue. Ordinary compatibility problems can be reported through Issues with the relevant OS versions and application name.
