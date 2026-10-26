# Contributing to Sonotexta

Thanks for helping out. A few notes keep things smooth:

- **Open an issue first** for anything bigger than a small fix, so we can
  agree on the approach before you invest the time.
- **Keep pull requests focused.** One change per PR, with a short description
  of what it does and how you tested it.
- **Run the unit tests** before opening a PR:

  ```bash
  xcodebuild -scheme VoiceFlow -configuration Debug -destination 'platform=macOS,arch=arm64' test -only-testing:VoiceFlowTests
  ```

  Don't run the UI test target on a machine where Sonotexta is installed — it
  shares the bundle identifier and can break that copy's permissions.
- **No secrets in commits.** API keys live in the Keychain at runtime; never
  add keys, signing identities or `.p8` files to the repo.
- **Match the surrounding style** of the file you're editing.

## Contributor License Agreement

Sonotexta is offered under the GPL-3.0 and, separately, under a commercial
license (see [COMMERCIAL.md](COMMERCIAL.md)). To keep that possible, every
contributor signs the [Contributor License Agreement](CLA.md) once. You keep
the copyright in your work; the CLA lets the project include it in both
licenses. A bot comments on your first pull request with a one-click way to
sign.
