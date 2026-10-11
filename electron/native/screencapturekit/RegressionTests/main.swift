import AudioToolbox
import CoreMedia
import Foundation

private final class Sink: MixedAudioSink {
	var buffers: [CMSampleBuffer] = []
	var isReadyForMoreMediaData: Bool { true }
	func append(_ sampleBuffer: CMSampleBuffer) -> Bool { buffers.append(sampleBuffer); return true }
}

private func require(_ condition: Bool, _ message: String) throws {
	if !condition { throw NSError(domain: "CaptureAudioRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private func source(seconds: Double, at: Double, left: Float, right: Float) throws -> CMSampleBuffer {
	var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
		mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
		mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
	var format: CMAudioFormatDescription?
	try require(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr, "fixture format")
	var l = [Float](repeating: left, count: Int(seconds * 48_000))
	var r = [Float](repeating: right, count: l.count)
	return try l.withUnsafeMutableBytes { lb in
		try r.withUnsafeMutableBytes { rb in
			let list = AudioBufferList.allocate(maximumBuffers: 2); defer { free(list.unsafeMutablePointer) }
			list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(lb.count), mData: lb.baseAddress)
			list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(rb.count), mData: rb.baseAddress)
			guard let buffer = makeAudioSampleBuffer(copying: UnsafePointer(list.unsafeMutablePointer), format: format!, hostTime: CMClockConvertHostTimeToSystemUnits(CMTime(seconds: at, preferredTimescale: 48_000))) else { throw NSError(domain: "fixture", code: 1) }
			return buffer
		}
	}
}

@main struct CaptureAudioRegression {
	static func main() async {
		var failures: [String] = []
		func check(_ name: String, _ run: () throws -> Void) {
			do { try run(); print("PASS: \(name)") } catch { failures.append(name); print("FAIL: \(name): \(error.localizedDescription)") }
		}
		check("default UID overrides stale device name") {
			try require(resolveMicrophoneDeviceID(deviceID: "default", deviceName: "USB", devices: [(id: "usb", name: "USB")]) == nil, "default unexpectedly selected USB")
		}
		check("stop snapshot excludes shutdown delay") {
			var timeline = RecordingTimeline(); timeline.stop(at: CMTime(seconds: 12, preferredTimescale: 48_000))
			try require(CMTimeGetSeconds(timeline.position(at: CMTime(seconds: 42, preferredTimescale: 48_000))) == 12, "stop added thirty seconds of saving time")
			timeline.stop(at: CMTime(seconds: 43, preferredTimescale: 48_000))
			try require(CMTimeGetSeconds(timeline.position(at: CMTime(seconds: 44, preferredTimescale: 48_000))) == 12, "second stop moved the endpoint")
		}
		check("pause and stop share one host clock") {
			var timeline = RecordingTimeline(); _ = timeline.pause(at: CMTime(seconds: 10, preferredTimescale: 48_000)); _ = timeline.resume(at: CMTime(seconds: 15, preferredTimescale: 48_000)); timeline.stop(at: CMTime(seconds: 22, preferredTimescale: 48_000))
			try require(CMTimeGetSeconds(timeline.position(at: CMTime(seconds: 100, preferredTimescale: 48_000))) == 17, "pause offset or endpoint wrong")
		}
		check("clock conversion preserves PCM and duration") {
			let original = try source(seconds: 0.02, at: 1, left: 0.25, right: -0.25)
			guard let converted = copyAudioSampleBuffer(original, convertingTime: { CMTimeAdd($0, CMTime(seconds: 10, preferredTimescale: 48_000)) }) else { throw NSError(domain: "convert", code: 1) }
			try require(abs(CMTimeGetSeconds(converted.presentationTimeStamp) - 11) < 0.00001, "source timebase was not mapped to host clock")
			try require(CMSampleBufferGetNumSamples(converted) == 960 && CMSampleBufferDataIsReady(converted), "converted buffer lost PCM")
			try require(abs(CMTimeGetSeconds(original.presentationTimeStamp) - 1) < 0.00001, "conversion mutated producer buffer")
			let list = AudioBufferList.allocate(maximumBuffers: 2); defer { free(list.unsafeMutablePointer) }
			var block: CMBlockBuffer?
			try require(CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(converted,
				bufferListSizeNeededOut: nil, bufferListOut: list.unsafeMutablePointer,
				bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: 2),
				blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
				flags: 0, blockBufferOut: &block) == noErr, "converted PCM unavailable")
			try require(list[0].mData!.load(as: Float.self) == 0.25 && list[1].mData!.load(as: Float.self) == -0.25, "clock conversion changed PCM values")

		}
		check("invalid source clock is rejected before startup") {
			let original = try source(seconds: 0.02, at: 1, left: 0.25, right: -0.25)
			try require(copyAudioSampleBuffer(original, convertingTime: { _ in .invalid }) == nil, "invalid clock reached mixer")
		}
		check("two nonzero sources and quiet tail retain timestamps and full length") {
			let sink = Sink(); var now = CMTime(seconds: 10, preferredTimescale: 48_000)
			let mixer = AudioTrackMixer(input: sink, includesSystemAudio: true, includesMicrophone: true, microphoneGain: 1, clock: { now })
			mixer.beginTimeline(at: now)
			mixer.ingest(try source(seconds: 0.1, at: 10, left: 0.5, right: 0), from: .system)
			mixer.ingest(try source(seconds: 0.1, at: 10, left: 0, right: 0.25), from: .microphone)
			now = CMTime(seconds: 12, preferredTimescale: 48_000); mixer.finish(atSourceTime: now)
			let count = sink.buffers.reduce(0) { $0 + CMSampleBufferGetNumSamples($1) }
			try require(count == 96_000, "quiet tail truncated or length changed")
			var expected = 10.0; var audible = [false, false]
			for buffer in sink.buffers {
				try require(abs(CMTimeGetSeconds(buffer.presentationTimeStamp) - expected) < 0.00001, "mixed chunks not contiguous")
				expected += Double(CMSampleBufferGetNumSamples(buffer)) / 48_000
				if let block = CMSampleBufferGetDataBuffer(buffer) {
					var pcm = [Int16](repeating: 0, count: CMSampleBufferGetNumSamples(buffer) * 2)
					_ = pcm.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
					for i in pcm.indices where pcm[i] != 0 { audible[i % 2] = true }
				}
			}
			try require(audible == [true, true], "one source was silent after mix")
		}
		let missing = AudioSourceStartupGate()
		do { try await missing.wait(timeout: 0.02); failures.append("startup timeout"); print("FAIL: startup without PCM reported ready") }
		catch { print("PASS: startup without PCM has a finite error") }
		let ready = AudioSourceStartupGate(); ready.sampleReady()
		do { try await ready.wait(timeout: 0.02); ready.sampleReady(); ready.stop(); print("PASS: valid quiet PCM opens startup gate once") }
		catch { failures.append("startup ready"); print("FAIL: valid PCM refused: \(error)") }
		let stopped = AudioSourceStartupGate(); stopped.stop(); stopped.sampleReady()
		do { try await stopped.wait(timeout: 0.02); failures.append("startup stopped"); print("FAIL: stopped source started") }
		catch { print("PASS: stopped source cannot become ready") }
		var commands = ["pause", "resume"]
		var stoppedCount = 0
		await runRecordingCommands(readCommand: { commands.isEmpty ? nil : commands.removeFirst() },
			pause: {}, resume: {}, stop: { stoppedCount += 1 })
		if stoppedCount == 1 { print("PASS: stdin EOF finalizes the recording once") }
		else { failures.append("stdin EOF"); print("FAIL: stdin EOF abandoned the writer") }
		commands = ["stop", "resume"]; stoppedCount = 0
		var resumeCount = 0
		await runRecordingCommands(readCommand: { commands.isEmpty ? nil : commands.removeFirst() },
			pause: {}, resume: { resumeCount += 1 }, stop: { stoppedCount += 1 })
		if stoppedCount == 1 && resumeCount == 0 { print("PASS: explicit stop does not finalize twice or resume") }
		else { failures.append("explicit stop"); print("FAIL: explicit stop consumed further commands") }
		check("explicit missing microphone cannot silently select default") {
			try require(microphoneDeviceChoice(deviceID: "missing", deviceName: "Missing", devices: [(id: "builtin", name: "Built-in")]) == .unavailable, "missing input silently defaulted")
			try require(microphoneDeviceChoice(deviceID: "browser-hash", deviceName: "Same", devices: [(id: "one", name: "Same"), (id: "two", name: "Same")]) == .unavailable, "ambiguous name silently defaulted")
			try require(microphoneDeviceChoice(deviceID: "default", deviceName: "Missing", devices: []) == .systemDefault, "default entry rejected")
		}
		check("stop before start never opens microphone hardware") {
			let gate = AudioSourceStartupGate(); gate.stop()
			var hardwareStarts = 0
			let started = try startAudioCapture(gate: gate, configure: {}, start: { hardwareStarts += 1 }, stop: {})
			try require(!started && hardwareStarts == 0, "cancelled source started microphone")
		}
		check("cancel during configure never opens microphone hardware") {
			let gate = AudioSourceStartupGate(); var hardwareStarts = 0
			let started = try startAudioCapture(gate: gate, configure: { gate.stop() }, start: { hardwareStarts += 1 }, stop: {})
			try require(!started && hardwareStarts == 0, "cancel while configuring opened microphone")
		}
		check("cancel during hardware start closes the microphone") {
			let gate = AudioSourceStartupGate(); var hardwareStops = 0
			let started = try startAudioCapture(gate: gate, configure: {}, start: { gate.stop() }, stop: { hardwareStops += 1 })
			try require(!started && hardwareStops == 1, "cancelled in-flight start leaked microphone")
		}
		var screenStopped = false; var screenCleanup = 0
		do {
			let started = try await startCaptureUnlessStopped(isStopped: { screenStopped },
				start: { screenStopped = true }, stop: { screenCleanup += 1 })
			try require(!started && screenCleanup == 1, "SCK completed startup after stop without compensating cleanup")
			print("PASS: screen stop during async start compensates hardware capture")
		} catch { failures.append("screen start cancel"); print("FAIL: screen start cancel: \(error.localizedDescription)") }
		do {
			var screenStarts = 0
			let started = try await startCaptureUnlessStopped(isStopped: { true },
				start: { screenStarts += 1 }, stop: {})
			try require(!started && screenStarts == 0, "already stopped screen started hardware")
			print("PASS: screen stopped before startup never opens hardware")
		} catch { failures.append("screen pre-cancel"); print("FAIL: screen pre-cancel") }
		if !failures.isEmpty { print("FAILED: \(failures.joined(separator: ", "))"); exit(1) }
		print("17 capture audio regressions passed")
	}
}
