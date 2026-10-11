# Media exchange acceptance, 2026-10-12

## Scope

The installed macOS test build is `2.0.1-hans.7`, based on the v2.0.0 local branch. The clean upstream feature port is commit `89021f07c1de3bda17e4c6b25996100e340ec355`, based on main `2896c1f7b9ad46cf53419e6edd360da2d2d80ac3`. The upstream port has separate tests and retains its newer media-clock and project-vocabulary behavior. It does not include the local native recording experiments.

## Installed application

Using a newly synthesized, non-private 7.058-second Mandarin video through the native macOS UI:

- Exported original M4A audio, PCM24 WAV, and AAC M4A. All three files decoded successfully. Stream-copy encoded AAC bytes exactly match the input track.
- Original M4A: 16 kHz mono, 7.058 seconds, 68,239 bytes. WAV: PCM24, 16 kHz mono, 7.104 seconds, 341,130 bytes. Compressed M4A: AAC, 16 kHz mono, 7.104 seconds, 68,590 bytes. The decoded formats include AAC padding; compression does not guarantee a smaller result than an already-compressed original.
- Imported WAV and M4A through the new audio button. They are audio assets with independent timeline audio regions, not video clips.
- Ran local Whisper on the video, obtained Traditional Chinese text with the complete 0-7.03 second phrase span, and exported source SRT and timeline SRT.
- Imported the exported source SRT after replacement confirmation. The transcript text and phrase boundaries survived the round trip and were saved in the project.
- Ran AGY through the installed UI on the imported WAV, obtained three Traditional Chinese phrases, and exported its source SRT.
- Enabled automatic transcription temporarily and imported a new neutral video. AGY started without clicking recognition and saved three Traditional Chinese phrases. Audio imports remain manual, as the preference explicitly targets new videos. Automatic transcription was switched off again after acceptance.

Whisper's installed first run was substantially slower than the earlier 2.698/7.506-second production-manager tests. The installed run used automatic language detection and AAC input; the earlier tests specified Chinese and used WAV. The exact backend and inference duration were not captured for the slow run. No latency guarantee or confirmed cause is claimed. The real Whisper homophone error was retained in the evidence rather than silently corrected. AGY also had failed exploratory runs before the successful adapter/UI route; no universal cloud reliability claim is made.

The app passed `codesign --verify --deep --strict`. The recorder helper's signed bytes remain unchanged from the preceding installation. Existing encrypted credentials were preserved. MCP startup requested macOS Keychain authorization after ad-hoc re-signing; the MCP server was temporarily stopped for local file/STT GUI acceptance. No Keychain access or credential protection was bypassed.

## Automated validation

- Local installed-source branch: 318 files, 4,350 tests passed, one skipped.
- Independent source review: 14 selected files, 157 tests passed; no remaining blocking findings.
- Clean upstream port: 118 focused tests passed; application/test TypeScript checks, changed-file Biome, i18n, docs, attribution generation, and production Vite build passed.
- Upstream full suite: 4,687 passed, one failed, four skipped. The first-render wait in `LeftPanel.copyMessage.test.tsx` exceeded its existing wait limit during the full run and first isolated run. A clean main control and a final unchanged-feature-file run both passed 3/3. Diagnostic timing was 206/56/49 ms; neither production code nor the test's timeout was changed. The full-suite result is not represented as green.

GMI was not live-retested and is not claimed to work. Its historical failures and the unresolved native audio-gap experiments are recorded separately. Windows/Linux GUI acceptance has not been performed.
