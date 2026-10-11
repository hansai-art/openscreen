This harness exercises the real capture core with PCM fixtures, a controlled host clock,
and hardware-operation closures. It does not start a recording or request permissions.
It supports Command Line Tools hosts where `swift test` cannot import XCTest.

```sh
electron/native/screencapturekit/RegressionTests/run.sh
swift build --package-path electron/native/screencapturekit --product openscreen-screencapturekit-helper -c release -j 2
```

The XCTest regressions remain in `Tests/OpenScreenCaptureCoreTests` for Xcode/CI.
A passing harness proves timing, cancellation, source selection and mixing logic; it does
not prove actual hardware capture. Verify microphone-only, system-only and simultaneous
capture in the packaged app, including camera on/off, before calling the recording fix accepted.

The 24 standalone cases include six timing-diagnostic regressions: pause-normalized PTS
lag versus raw-host queue wait, the 100-record ring with overflow totals, exact late-drop
intervals and latest emit context, a single finish summary with duplicate-PTS context,
continuous pre-anchor PCM without false overlaps, and an older drop whose latest emit
context is explicitly distinguished from its cause. Capture
diag metadata does not store PCM. The one-second watermark and frozen stop endpoint remain
unchanged; a warning reports possible audio gaps rather than equating discarded spans with
lost speech.

Six additional startup cases bring the harness to30 regressions: preserve705 ms of
pre-anchor speech with gain applied once; trim negative PTS without rebasing; register
both cached sources before watermark drain; retain original callback/ingestion stamps;
bound each owned Float pre-roll to96,000 stereo frames and512 packets with eviction
counters; and release/reject startup PCM on cancellation before the first video frame.
The hardware producers and one-second live watermark are unchanged.
