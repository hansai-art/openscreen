## Summary

A local macOS patch based on v2.0.0 still loses already-delivered microphone and system-audio spans under audio-queue backpressure. The level meter moves and the resulting MP4 contains audio, but decoded output has gaps during known test speech. This report is **experimental evidence from a modified build**, not a claim that current upstream main reproduces it.

Environment: macOS 26.6.2, Apple Silicon arm64, built-in microphone, full-display capture at 2880×1800, microphone + system audio + webcam. Local build: `2.0.1-hans.5`; capture was stopped manually.

## Measured result

- Audio duration: 186.219979 s, 48 kHz stereo. Video duration: 186.116667 s.
- Nine middle intervals contain exactly zero on both decoded channels for at least 20 ms.
- Longest middle zero interval: 140.397313–152.626667 s (12.229354 s).
- Known speech windows intersect gaps of 0.597958 s, 0.997354 s, and 2.914708 s.
- Native discarded-span diagnostics: microphone 14.669250 s, system 12.409417 s. These counters are not themselves proof of audible gaps; the independent PCM analysis above is.
- Maximum audioQueue wait: microphone 8.952128 s, system 8.951205 s.
- System callback lag stayed near 21 ms; microphone callback lag additionally reached 2.909080 s.

## Experiments and limits

1. Independent AVCaptureSession microphone and explicit buffer conversion made microphone samples available, but did not establish reliable capture under load.
2. A one-second missing-data watermark retained a 350 ms synthetic late callback. Hardware runs of 832.44 s without webcam and 126.08 s with webcam had no middle zero interval >=20 ms. This did not generalize to the later 186 s run above.
3. Pre-anchor buffering removed the initial silent interval in the final test, but the middle gaps remained.

A separate apparent automatic-stop incident was caused by closing the captured Chrome window (`SCStream -3815`, source gone). Another short test hit disk full (`AVFoundation -11807`, POSIX 28). A 1.3 s take was tester-induced manual stop. None of these establishes a two-second product auto-stop regression.

## Source-review hypothesis, not a verified fix

In the local `AudioTrackMixer`, the FIFO callback carries `callbackTimelineTime`, but drain advancement also reads execution-time `clock()`. With a long worker queue, an early queued callback can advance the missing-data watermark beyond later callbacks already waiting in the same FIFO. Those packets then arrive behind `emittedEndFrame` and are discarded. Timer ticks and timeline-start handling need the same event-clock ordering audit.

A useful regression would queue ~9 seconds of continuous, nonzero source packets while advancing the processing clock, replay the FIFO, and require zero discarded frames/no silent replacement. A producer-time timer snapshot should not overtake queued packet work. This fix has **not** been implemented or validated. Microphone producer stalls also remain a separate concern.

## Expected behavior / reproduction aid

Already-delivered FIFO buffers should survive downstream encoding/queue stalls without silently being replaced by missing-data silence. Capture both sources plus webcam under concurrent load; export native timing diagnostics; decode the original MP4 and check actual speech windows, rather than relying on the level meter or dropped-span counters alone.

No personal recordings, full desktop diagnostics, API keys, or private paths are attached. The [sanitized metric-only evidence](macos-audio-gap-2026-10-11.json) accompanies this report. Related historical issue #709 had a different confirmed Int24 decoder cause; this report should not be treated as reopening that diagnosis.
