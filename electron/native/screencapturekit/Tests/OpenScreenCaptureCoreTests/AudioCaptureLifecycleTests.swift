import CoreMedia
import XCTest
import OpenScreenCaptureCore

final class AudioCaptureLifecycleTests: XCTestCase {
	func testStopFreezesTheTimelineBeforeSlowSourceShutdown() {
		var timeline = RecordingTimeline()
		timeline.stop(at: CMTime(seconds: 12, preferredTimescale: 48_000))
		XCTAssertEqual(CMTimeGetSeconds(timeline.position(at: CMTime(seconds: 42, preferredTimescale: 48_000))), 12, accuracy: 0.00001)
		timeline.stop(at: CMTime(seconds: 42, preferredTimescale: 48_000))
		XCTAssertEqual(CMTimeGetSeconds(timeline.position(at: CMTime(seconds: 43, preferredTimescale: 48_000))), 12, accuracy: 0.00001)
	}

	func testPauseOffsetAndStopUseTheSameHostClock() {
		var timeline = RecordingTimeline()
		XCTAssertTrue(timeline.pause(at: CMTime(seconds: 10, preferredTimescale: 48_000)))
		XCTAssertEqual(CMTimeGetSeconds(timeline.position(at: CMTime(seconds: 20, preferredTimescale: 48_000))), 10, accuracy: 0.00001)
		XCTAssertTrue(timeline.resume(at: CMTime(seconds: 15, preferredTimescale: 48_000)))
		timeline.stop(at: CMTime(seconds: 22, preferredTimescale: 48_000))
		XCTAssertEqual(CMTimeGetSeconds(timeline.position(at: CMTime(seconds: 100, preferredTimescale: 48_000))), 17, accuracy: 0.00001)
		XCTAssertFalse(timeline.resume(at: CMTime(seconds: 101, preferredTimescale: 48_000)))
	}

	func testMicrophoneStartupCannotSucceedWithoutASample() async {
		let gate = AudioSourceStartupGate()
		do {
			try await gate.wait(timeout: 0.02)
			XCTFail("A silent producer without buffers must not report recording-ready")
		} catch {
			XCTAssertEqual(error as? AudioSourceStartupGate.Failure, .timedOut)
		}
	}

	func testAQuietButValidMicrophoneSampleUnblocksStartup() async throws {
		let gate = AudioSourceStartupGate()
		gate.sampleReady()
		try await gate.wait(timeout: 0.02)
		gate.sampleReady()
		gate.stop()
	}

	func testCancellationStopsWaitingWithoutDoubleCompletion() async {
		let gate = AudioSourceStartupGate()
		gate.stop()
		gate.sampleReady()
		do {
			try await gate.wait(timeout: 0.02)
			XCTFail("A stopped source must not start a recording")
		} catch {
			XCTAssertEqual(error as? AudioSourceStartupGate.Failure, .stopped)
		}
	}
	func testInputEOFStopsAndFinalizesTheRecordingOnce() async {
		var commands = ["pause", "resume"]
		var stopCount = 0
		await runRecordingCommands(readCommand: { commands.isEmpty ? nil : commands.removeFirst() },
			pause: {}, resume: {}, stop: { stopCount += 1 })
		XCTAssertEqual(stopCount, 1)
	}

	func testExplicitStopDoesNotReadFurtherCommandsOrStopTwice() async {
		var commands = ["stop", "resume"]
		var stopCount = 0
		var resumeCount = 0
		await runRecordingCommands(readCommand: { commands.isEmpty ? nil : commands.removeFirst() },
			pause: {}, resume: { resumeCount += 1 }, stop: { stopCount += 1 })
		XCTAssertEqual(stopCount, 1)
		XCTAssertEqual(resumeCount, 0)
	}

	func testCancellationBeforeOrDuringConfigurationDoesNotStartHardware() throws {
		for cancelBefore in [true, false] {
			let gate = AudioSourceStartupGate()
			if cancelBefore { gate.stop() }
			var hardwareStarts = 0
			let started = try startAudioCapture(gate: gate, configure: { gate.stop() },
				start: { hardwareStarts += 1 }, stop: {})
			XCTAssertFalse(started)
			XCTAssertEqual(hardwareStarts, 0)
		}
	}
	func testCancellationWhileStartingClosesHardware() throws {
		let gate = AudioSourceStartupGate()
		var hardwareStops = 0
		let started = try startAudioCapture(gate: gate, configure: {}, start: { gate.stop() },
			stop: { hardwareStops += 1 })
		XCTAssertFalse(started)
		XCTAssertEqual(hardwareStops, 1)
	}

	func testScreenCancellationDuringAsyncStartupCompensatesCapture() async throws {
		var stopped = false
		var cleanupCount = 0
		let started = try await startCaptureUnlessStopped(isStopped: { stopped },
			start: { stopped = true }, stop: { cleanupCount += 1 })
		XCTAssertFalse(started)
		XCTAssertEqual(cleanupCount, 1)
	}

}
