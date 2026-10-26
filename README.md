# Sonotexta

**Dictation for macOS that stays out of your way.** Press a key, speak, and the
text lands in whatever app you're typing in — cleaned up, translated or
reformatted if you want it to be.

Sonotexta is free and open source. It runs fully offline with on-device speech
engines, or with cloud engines and AI providers using **your own API keys**.
No account, no subscription, no telemetry.

<a href="https://buymeacoffee.com/stanelych"><img src="https://img.shields.io/badge/Buy%20me%20a%20coffee-%E2%98%95-FFDD00?style=for-the-badge&logo=buymeacoffee&logoColor=black" alt="Buy me a coffee"></a>

> Sonotexta started as a paid app. It's now a gift to the community. If it
> saves you time, a coffee keeps it going — and pull requests are just as
> welcome.

---

## Features

- **Works in every app.** Lives in the menu bar; a small floating pill shows
  the live waveform and transcript while you speak, then pastes the result
  into the frontmost app.
- **Globe key or any shortcut.** Tap to start/stop, or hold to talk and
  release to finish.
- **On-device speech engines** — nothing leaves your Mac:
  - Apple Speech (built in, no download)
  - Whisper via [WhisperKit](https://github.com/argmaxinc/WhisperKit) (99+ languages, several model sizes)
  - NVIDIA Parakeet TDT v2/v3 and Parakeet Live (streaming) via [FluidAudio](https://github.com/FluidInference/FluidAudio)
  - Qwen3-ASR 0.6B (experimental)
- **Cloud speech engines with your own key:** OpenAI Realtime, Deepgram
  Nova-3, ElevenLabs Scribe.
- **AI cleanup with your own key — or fully local:** OpenAI, Anthropic,
  Gemini, Groq, OpenRouter, Ollama (local) and Ollama Cloud. Built-in presets
  (Clean & Correct, Professional, Bullet Points, Summary, Action Items, …) or
  write your own prompt. A vocabulary list teaches it your product names and
  homophones.
- **Translation.** Dictate in one language, deliver in another — via OpenAI,
  DeepL or Apple Translate.
- **Profiles per app and per contact.** Sonotexta can detect who you're
  writing to in Messages, Teams, Slack and similar apps and switch engine,
  language, tone and cleanup automatically.
- **Automatic updates** via [Sparkle](https://sparkle-project.org).

API keys are stored in the macOS Keychain. Audio only leaves your Mac when
you pick a cloud engine, and then it goes straight to the provider you chose.

## Install

Download the latest signed and notarized build from
[Releases](https://github.com/stanleyswiss/Sonotexta/releases), drag
**Sonotexta.app** to Applications and launch it. On first run, grant
**Microphone** and **Accessibility** access (Accessibility is needed to paste
into other apps). Updates arrive automatically.

Requirements: macOS 15 or later. Apple Silicon is strongly recommended for
the on-device engines.

## Build from source

1. Install a recent Xcode (the project is developed with Xcode 27).
2. Clone the repo and open `VoiceFlow.xcodeproj`. (The project and folders
   still use the app's old working name, *VoiceFlow*.)
3. Signing: either let Xcode sign to run locally, or create
   `Config/Signing.local.xcconfig` (gitignored) containing
   `DEVELOPMENT_TEAM = <your Team ID>`.
4. Select the **VoiceFlow** scheme and run.

A locally built app uses the same bundle identifier as the release build.
If you also have the released app installed, macOS keeps one set of
Microphone/Accessibility permissions for both. Change the bundle identifier
in your local build if you want to keep them apart.

### Tests

```bash
xcodebuild -scheme VoiceFlow -configuration Debug -destination 'platform=macOS,arch=arm64' test -only-testing:VoiceFlowTests
```

Run the unit tests only. The UI test target launches the app under the
shared bundle identifier and can mess up the permissions of an installed
copy.

## Contributing

Issues and pull requests are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).
Contributors are asked to sign a short [Contributor License Agreement](CLA.md)
on their first pull request; a bot walks you through it.

## License

Sonotexta is licensed under the **GNU General Public License v3.0** — see
[LICENSE](LICENSE). You're free to use, study, modify and share it. If you
distribute a modified version, you must publish its source under the same
license.

**Commercial licensing.** If your company wants to ship Sonotexta (or code
from it) in a closed-source product, or needs terms other than the GPL,
a commercial license is available — see [COMMERCIAL.md](COMMERCIAL.md).

## Acknowledgements

Sonotexta builds on excellent open-source work:

| Project | License |
| --- | --- |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) — Parakeet and Qwen3 on Core ML (modified copy in `FluidAudio-local/`) | Apache-2.0 |
| [WhisperKit](https://github.com/argmaxinc/WhisperKit) | MIT |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | MIT |
| [swift-transformers](https://github.com/huggingface/swift-transformers), [swift-jinja](https://github.com/huggingface/swift-jinja) | Apache-2.0 |
| [swift-collections](https://github.com/apple/swift-collections), [swift-crypto](https://github.com/apple/swift-crypto), [swift-asn1](https://github.com/apple/swift-asn1), [swift-argument-parser](https://github.com/apple/swift-argument-parser) | Apache-2.0 |
| [yyjson](https://github.com/ibireme/yyjson) | MIT |

Models are downloaded on demand from their publishers and keep their own
licenses.
