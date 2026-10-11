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

private func capturedPCM(_ sink: Sink) -> [Int16] {
	var result: [Int16] = []
	for buffer in sink.buffers {
		guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
		var chunk = [Int16](repeating: 0, count: CMSampleBufferGetNumSamples(buffer) * 2)
		_ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
		result.append(contentsOf: chunk)
	}
	return result
}

private func exactSource(frames: Int, atFrame: Int64, left: Float, right: Float) throws -> CMSampleBuffer {
	let buffer = try source(seconds: Double(frames) / 48_000, at: Double(atFrame) / 48_000, left: left, right: right)
	try require(CMSampleBufferGetNumSamples(buffer) == frames, "fixture frame count")
	return copyAudioSampleBuffer(buffer, convertingTime: { _ in CMTime(value: atFrame, timescale: 48_000) })!
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
		check("continuous sources delayed 350ms preserve captured audio") {
			let sink = Sink(); var now = CMTime(seconds: 10, preferredTimescale: 48_000)
			let mixer = AudioTrackMixer(input: sink, includesSystemAudio: true, includesMicrophone: true, microphoneGain: 1, clock: { now })
			mixer.beginTimeline(at: now); var held: [Int] = []
			func deliver(_ step: Int) throws {
				let at = 10 + Double(step) / 100
				let pts = CMTime(value: CMTimeValue(480_000 + step * 480), timescale: 48_000)
				let system = try source(seconds: 0.01, at: at, left: 0.5, right: 0)
				let mic = try source(seconds: 0.01, at: at, left: 0, right: 0.25)
				mixer.ingest(copyAudioSampleBuffer(system, convertingTime: { _ in pts })!, from: .system)
				mixer.ingest(copyAudioSampleBuffer(mic, convertingTime: { _ in pts })!, from: .microphone)
			}
			for step in 0..<200 {
				mixer.tick()
				if (50..<85).contains(step) { held.append(step) }
				else {
					if step == 85 { for captured in held { try deliver(captured) } }
					try deliver(step)
				}
				now = CMTimeAdd(now, CMTime(value: 480, timescale: 48_000))
			}
			mixer.finish(atSourceTime: now)
			var pcm: [Int16] = []
			for buffer in sink.buffers {
				if let block = CMSampleBufferGetDataBuffer(buffer) {
					var chunk = [Int16](repeating: 0, count: CMSampleBufferGetNumSamples(buffer) * 2)
					_ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
					pcm.append(contentsOf: chunk)
				}
			}
			let delayed = pcm[(24_000 * 2)..<(40_800 * 2)]
			print("late-delivery proof: zero samples=\(delayed.filter { $0 == 0 }.count), system drop=\(mixer.deliveryReport(for: .system).droppedSeconds), mic drop=\(mixer.deliveryReport(for: .microphone).droppedSeconds), system undelivered=\(mixer.deliveryReport(for: .system).undeliveredSeconds)")
			try require(delayed.allSatisfy { abs($0) > 1_000 }, "350 ms of continuously captured audio became zero")
			try require(pcm.count == 192_000, "stop flush changed two-second duration")
			for (index, buffer) in sink.buffers.enumerated() {
				try require(CMSampleBufferGetNumSamples(buffer) == 480, "mixed chunk size changed")
				try require(buffer.presentationTimeStamp == CMTime(value: CMTimeValue(480_000 + index * 480), timescale: 48_000), "watermark shifted timestamps")
			}
			try require(mixer.deliveryReport(for: .system).droppedSeconds == 0 && mixer.deliveryReport(for: .microphone).droppedSeconds == 0, "late but in-bound packets were discarded")
		}
		check("timing diagnostics separate pause-normalized lag from raw queue wait") {
			let sink = Sink(); var now = CMTime(seconds: 10.02, preferredTimescale: 48_000)
			let mixer = AudioTrackMixer(input: sink, includesSystemAudio: true, includesMicrophone: false, microphoneGain: 1, clock: { now })
			mixer.beginTimeline(at: CMTime(seconds: 10, preferredTimescale: 48_000))
			let timing = AudioDeliveryTiming(callbackHostTime: CMTime(seconds: 110.04, preferredTimescale: 48_000), ingestionHostTime: CMTime(seconds: 110.44, preferredTimescale: 48_000), callbackTimelineTime: CMTime(seconds: 10.04, preferredTimescale: 48_000), ingestionTimelineTime: CMTime(seconds: 10.44, preferredTimescale: 48_000))
			mixer.ingest(try source(seconds: 0.02, at: 10, left: 0.5, right: 0.5), from: .system, timing: timing)
			let report = mixer.timingReport(for: .system)
			try require(abs((report["maxQueueWaitSeconds"] as? Double ?? -1) - 0.4) < 0.0001, "queue wait used pause-normalized or PCM clock")
			try require(abs((report["maxCallbackLagSeconds"] as? Double ?? -1) - 0.02) < 0.0001, "callback lag mixed raw and normalized domains")
			try require(abs((report["maxIngestionLagSeconds"] as? Double ?? -1) - 0.42) < 0.0001, "ingestion lag hid scheduling delay")
			now = CMTime(value: 481_920, timescale: 48_000); mixer.finish(atSourceTime: now)
			try require(sink.buffers.reduce(0) { $0 + CMSampleBufferGetNumSamples($1) } == 1920, "diagnostics changed duration")
		}
		check("bounded diagnostics retain totals and negative clock offsets") {
			let sink = Sink(); var now = CMTime(seconds: 10, preferredTimescale: 48_000)
			let mixer = AudioTrackMixer(input: sink, includesSystemAudio: true, includesMicrophone: false, microphoneGain: 1, clock: { now }); mixer.beginTimeline(at: now)
			for step in 0..<400 {
				let at = 10 + Double(step) * 0.05; now = CMTime(seconds: at + 0.01, preferredTimescale: 48_000)
				let callback = CMTime(seconds: at - 0.04, preferredTimescale: 48_000)
				let timing = AudioDeliveryTiming(callbackHostTime: callback, ingestionHostTime: now, callbackTimelineTime: callback, ingestionTimelineTime: now)
				let buffer = try source(seconds: 0.01, at: at, left: 0.25, right: 0.25)
				let exact = copyAudioSampleBuffer(buffer, convertingTime: { _ in CMTime(value: CMTimeValue(480_000 + step * 2400), timescale: 48_000) })!
				mixer.ingest(exact, from: .system, timing: timing)
			}
			let report = mixer.timingReport(for: .system)
			try require((report["bufferCount"] as? Int) == 400, "bounded ring lost aggregate count")
			try require((report["anomalies"] as? [[String: Any]])?.count == 100, "diagnostic storage is not bounded at 100")
			try require((report["anomalyOverflowCount"] as? Int ?? 0) > 200, "overflow was silently lost")
			try require((report["minCallbackLagSeconds"] as? Double ?? 0) < -0.049, "negative clock offset was clamped")
			try require(abs((report["ptsHoleSeconds"] as? Double ?? -1) - 15.96) < 0.0001, "PTS holes lost their total")
		}
		check("late drop diagnostics retain exact timeline interval and emit reason") {
			let sink = Sink(); var now = CMTime(seconds: 10.1, preferredTimescale: 48_000)
			let mixer = AudioTrackMixer(input: sink, includesSystemAudio: true, includesMicrophone: false, microphoneGain: 1, clock: { now }); mixer.beginTimeline(at: CMTime(seconds: 10, preferredTimescale: 48_000))
			mixer.ingest(try source(seconds: 0.1, at: 10, left: 0.5, right: 0.5), from: .system)
			now = CMTime(seconds: 12, preferredTimescale: 48_000); mixer.tick()
			mixer.ingest(try source(seconds: 0.2, at: 10.5, left: 0.5, right: 0.5), from: .system)
			now = CMTime(seconds: 12.01, preferredTimescale: 48_000); mixer.tick()
			let anomalies = mixer.timingReport(for: .system)["anomalies"] as? [[String: Any]] ?? []
			guard let drop = anomalies.first(where: { $0["kind"] as? String == "late-drop" }) else { throw NSError(domain: "diag", code: 1, userInfo: [NSLocalizedDescriptionKey: "late PCM had no interval diagnostic"]) }
			try require(abs((drop["startSeconds"] as? Double ?? -1) - 0.5) < 0.0001 && abs((drop["endSeconds"] as? Double ?? -1) - 0.7) < 0.0001, "late PCM interval was rebased or lost")
			try require(drop["lastCursorAdvanceReason"] as? String == "missing-watermark", "late drop lost latest emit context")
		}
		check("diagnostics emit once at finish and preserve duplicate context") {
			let sink = Sink(); var now = CMTime(seconds: 10.1, preferredTimescale: 48_000); var events: [[String: Any]] = []
			let mixer = AudioTrackMixer(input: sink, includesSystemAudio: true, includesMicrophone: false, microphoneGain: 1, clock: { now }, timingEventHandler: { events.append($0) }); mixer.beginTimeline(at: CMTime(seconds: 10, preferredTimescale: 48_000))
			let first = try source(seconds: 0.1, at: 10, left: 0.5, right: 0.5)
			mixer.ingest(first, from: .system); mixer.ingest(first, from: .system)
			now = CMTime(value: 489_600, timescale: 48_000); mixer.ingest(try source(seconds: 0.1, at: 10.1, left: 0.5, right: 0.5), from: .system)
			try require(events.isEmpty, "diagnostics emitted on a live callback")
			mixer.finish(atSourceTime: now); mixer.finish(atSourceTime: now)
			try require(events.filter { $0["event"] as? String == "audio-timing" }.count == 1, "timing summary was missing or repeated")
			try require(events.filter { $0["code"] as? String == "audio-source-late-dropped" }.count == 1, "supplied PCM discard was hidden or warning repeated")
			let anomalies = mixer.timingReport(for: .system)["anomalies"] as? [[String: Any]] ?? []
			try require(anomalies.contains { $0["kind"] as? String == "pts-overlap" }, "duplicate source span was mislabeled as unique missing speech")
			try require(sink.buffers.reduce(0) { $0 + CMSampleBufferGetNumSamples($1) } == 9600, "diagnostics changed media duration")
		}
		check("continuous pre-anchor PCM does not create a false duplicate diagnostic") {
			let sink = Sink(); let now = CMTime(value: 480_000, timescale: 48_000)
			let mixer = AudioTrackMixer(input: sink, includesSystemAudio: true, includesMicrophone: false, microphoneGain: 1, clock: { now }); mixer.beginTimeline(at: now)
			for pts in [470_400, 475_200] {
				let buffer = try source(seconds: 0.1, at: Double(pts) / 48_000, left: 0.25, right: 0.25)
				mixer.ingest(copyAudioSampleBuffer(buffer, convertingTime: { _ in CMTime(value: CMTimeValue(pts), timescale: 48_000) })!, from: .system)
			}
			let report = mixer.timingReport(for: .system)
			try require(report["ptsOverlapSeconds"] as? Double == 0, "continuous pre-roll was diagnosed as repeated PCM")
			try require(report["ptsHoleSeconds"] as? Double == 0, "continuous pre-roll introduced a source hole")
			try require((report["anomalies"] as? [[String: Any]] ?? []).allSatisfy { $0["kind"] as? String != "pts-overlap" }, "pre-anchor false overlap event persisted")
		}
		check("late-drop reason is explicitly latest emit context rather than claimed cause") {
			let sink = Sink(); var now = CMTime(value: 484_800, timescale: 48_000)
			let mixer = AudioTrackMixer(input: sink, includesSystemAudio: true, includesMicrophone: false, microphoneGain: 1, clock: { now }); mixer.beginTimeline(at: CMTime(value: 480_000, timescale: 48_000))
			mixer.ingest(try source(seconds: 0.1, at: 10, left: 0.5, right: 0.5), from: .system)
			now = CMTime(value: 576_000, timescale: 48_000); mixer.tick()
			mixer.ingest(try source(seconds: 0.2, at: 11, left: 0.5, right: 0.5), from: .system)
			mixer.ingest(try source(seconds: 0.2, at: 10.5, left: 0.5, right: 0.5), from: .system)
			now = CMTime(value: 586_080, timescale: 48_000); mixer.tick()
			let anomalies = mixer.timingReport(for: .system)["anomalies"] as? [[String: Any]] ?? []
			guard let drop = anomalies.first(where: { $0["kind"] as? String == "late-drop" }) else { throw NSError(domain: "diag", code: 1, userInfo: [NSLocalizedDescriptionKey: "late interval did not produce diagnostics"]) }
			try require(drop["cursorAdvanceReason"] == nil, "latest covered emit was mislabeled as the older span's causal reason")
			try require(drop["lastCursorAdvanceReason"] as? String == "all-sources-covered", "latest emit context was not retained truthfully")
		}
		check("pre-anchor speech retains its first705ms and applies microphone gain once") {
			let sink = Sink(); let now = CMTime(value: 514_080, timescale: 48_000)
			let mixer = AudioTrackMixer(input: sink, includesSystemAudio: false, includesMicrophone: true, microphoneGain: 1.4, clock: { now })
			mixer.ingest(try exactSource(frames: 33_840, atFrame: 480_000, left: 0.25, right: 0.25), from: .microphone)
			mixer.beginTimeline(at: CMTime(value: 480_000, timescale: 48_000)); mixer.finish(atSourceTime: now)
			let pcm = capturedPCM(sink)
			try require(pcm.count == 68_160, "pre-roll shifted or extended the710ms take")
			try require(pcm.prefix(67_680).allSatisfy { abs(Int($0) - 11_468) <= 1 }, "first705ms lost or microphone gain applied twice")
			try require(pcm.suffix(480).allSatisfy { $0 == 0 }, "pre-roll fabricated sound beyond captured PTS")
			try require(sink.buffers.first?.presentationTimeStamp == CMTime(value: 480_000, timescale: 48_000), "pre-roll moved the video origin")
		}
		check("pre-anchor negative PCM trims at video zero without losing positive speech") {
			let sink = Sink(); let now = CMTime(value: 489_600, timescale: 48_000)
			let mixer = AudioTrackMixer(input: sink, includesSystemAudio: true, includesMicrophone: false, microphoneGain: 1, clock: { now })
			mixer.ingest(try exactSource(frames: 9600, atFrame: 475_200, left: 0.5, right: 0.5), from: .system)
			mixer.beginTimeline(at: CMTime(value: 480_000, timescale: 48_000)); mixer.finish(atSourceTime: now)
			let pcm = capturedPCM(sink)
			try require(pcm.prefix(9600).allSatisfy { abs($0) > 1000 }, "positive half of pre-anchor PCM was discarded")
			try require(pcm.count == 19_200 && pcm.suffix(9600).allSatisfy { $0 == 0 }, "negative PCM rebased or tail length changed")
			try require(abs(mixer.deliveryReport(for: .system).trimmedSeconds - 0.1) < 0.00001 && mixer.deliveryReport(for: .system).droppedSeconds == 0, "negative PCM was mislabeled as late loss")
		}
		check("both pre-roll sources register before watermark drains delayed startup") {
			let sink = Sink(); let now = CMTime(value: 547_200, timescale: 48_000)
			let mixer = AudioTrackMixer(input: sink, includesSystemAudio: true, includesMicrophone: true, microphoneGain: 1, clock: { now })
			for i in 0..<14 {
				let pts = Int64(480_000 + i * 4800)
				mixer.ingest(try exactSource(frames: 4800, atFrame: pts, left: 0.5, right: 0), from: .system)
				mixer.ingest(try exactSource(frames: 4800, atFrame: pts, left: 0, right: 0.25), from: .microphone)
			}
			mixer.beginTimeline(at: CMTime(value: 480_000, timescale: 48_000)); mixer.finish(atSourceTime: now)
			let pcm = capturedPCM(sink)
			try require(pcm.count == 134_400 && pcm.allSatisfy { abs($0) > 1000 }, "replay drained too early and replaced retained PCM with zeros")
			try require(mixer.deliveryReport(for: .system).droppedSeconds == 0 && mixer.deliveryReport(for: .microphone).droppedSeconds == 0, "batch replay late-dropped captured speech")
		}
		check("pre-roll replay preserves original callback and ingestion timing") {
			let sink = Sink(); let now = CMTime(value: 547_200, timescale: 48_000)
			let mixer = AudioTrackMixer(input: sink, includesSystemAudio: true, includesMicrophone: false, microphoneGain: 1, clock: { now })
			let timing = AudioDeliveryTiming(callbackHostTime: CMTime(value: 5_281_920, timescale: 48_000), ingestionHostTime: CMTime(value: 5_282_400, timescale: 48_000), callbackTimelineTime: CMTime(value: 481_920, timescale: 48_000), ingestionTimelineTime: CMTime(value: 482_400, timescale: 48_000))
			mixer.ingest(try exactSource(frames: 960, atFrame: 480_000, left: 0.5, right: 0.5), from: .system, timing: timing)
			mixer.beginTimeline(at: CMTime(value: 480_000, timescale: 48_000))
			let report = mixer.timingReport(for: .system)
			try require(abs((report["maxQueueWaitSeconds"] as? Double ?? -1) - 0.01) < 0.00001, "replay wait was forged into callback queue wait")
			try require(abs((report["maxIngestionLagSeconds"] as? Double ?? -1) - 0.03) < 0.00001, "replay time was forged into PCM ingestion lag")
			try require(abs((mixer.preRollReport(for: .system)["maxReplayTimelineWaitSeconds"] as? Double ?? -1) - 1.35) < 0.00001, "startup replay wait was hidden instead of reported separately")
		}
		check("pre-roll byte and packet caps evict oldest PCM with explicit counters") {
			let sink = Sink(); let now = CMTime(value: 624_000, timescale: 48_000)
			let mixer = AudioTrackMixer(input: sink, includesSystemAudio: true, includesMicrophone: false, microphoneGain: 1, clock: { now })
			mixer.ingest(try exactSource(frames: 144_000, atFrame: 480_000, left: 0.5, right: 0.5), from: .system)
			let report = mixer.preRollReport(for: .system)
			try require(report["pendingFrames"] as? Int == 96_000 && report["evictedFrames"] as? Int == 48_000 && (report["peakPendingBytes"] as? Int ?? Int.max) <= 768_000, "two-second owned PCM limit was not enforced")
			mixer.beginTimeline(at: CMTime(value: 528_000, timescale: 48_000)); mixer.finish(atSourceTime: now)
			try require(capturedPCM(sink).count == 192_000 && capturedPCM(sink).allSatisfy { abs($0) > 1000 }, "retained tail was rebased or corrupted")
			let tiny = AudioTrackMixer(input: Sink(), includesSystemAudio: true, includesMicrophone: false, microphoneGain: 1, clock: { now })
			for i in 0..<600 { tiny.ingest(try exactSource(frames: 1, atFrame: Int64(480_000 + i), left: 0.5, right: 0.5), from: .system) }
			let capped = tiny.preRollReport(for: .system)
			try require(capped["pendingPackets"] as? Int == 512 && capped["evictedPackets"] as? Int == 88 && capped["evictedFrames"] as? Int == 88, "metadata packet cap did not report discarded spans")
		}
		check("cancel before first video releases pre-roll and rejects later queued audio") {
			let sink = Sink(); let now = CMTime(value: 489_600, timescale: 48_000)
			let mixer = AudioTrackMixer(input: sink, includesSystemAudio: true, includesMicrophone: false, microphoneGain: 1, clock: { now })
			mixer.ingest(try exactSource(frames: 4800, atFrame: 480_000, left: 0.5, right: 0.5), from: .system)
			try require(mixer.preRollReport(for: .system)["pendingFrames"] as? Int == 4800, "cancel fixture did not retain real PCM")
			mixer.cancelPreRoll()
			mixer.ingest(try exactSource(frames: 4800, atFrame: 484_800, left: 0.5, right: 0.5), from: .system)
			mixer.beginTimeline(at: CMTime(value: 480_000, timescale: 48_000)); mixer.finish(atSourceTime: now)
			try require(mixer.preRollReport(for: .system)["pendingFrames"] as? Int == 0 && sink.buffers.isEmpty, "cancel leaked PCM or allowed an empty ghost recording")
		}
		if !failures.isEmpty { print("FAILED: \(failures.joined(separator: ", "))"); exit(1) }
		print("30 capture audio regressions passed")
	}
}
