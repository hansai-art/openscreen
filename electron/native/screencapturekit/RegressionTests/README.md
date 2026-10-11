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
