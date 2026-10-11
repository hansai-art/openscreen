import CoreMedia
import Foundation

/// Host-clock position shared by screen, microphone, system audio and shutdown.
/// Stop fixes the endpoint when requested, rather than after hardware has stopped saving.
public struct RecordingTimeline {
	private var pausedAt: CMTime?
	private var pausedDuration = CMTime.zero
	private var stoppedAt: CMTime?
	public init() {}
	public var isPaused: Bool { pausedAt != nil }
	public var isStopped: Bool { stoppedAt != nil }
	public var pauseOffset: CMTime { pausedDuration }

	@discardableResult
	public mutating func pause(at time: CMTime) -> Bool {
		guard !isPaused, !isStopped else { return false }
		pausedAt = time
		return true
	}

	@discardableResult
	public mutating func resume(at time: CMTime) -> Bool {
		guard let pausedAt, !isStopped else { return false }
		pausedDuration = CMTimeAdd(pausedDuration, CMTimeMaximum(.zero, CMTimeSubtract(time, pausedAt)))
		self.pausedAt = nil
		return true
	}

	public mutating func stop(at time: CMTime) {
		guard stoppedAt == nil else { return }
		stoppedAt = position(at: time)
	}

	public func position(at time: CMTime) -> CMTime {
		stoppedAt ?? CMTimeSubtract(pausedAt ?? time, pausedDuration)
	}
}

/// A producer is ready after a valid PCM buffer, including a quiet one. Hardware startup
/// cannot report success merely because a capture API accepted its configuration.
// All completion state is protected by lock; callbacks may arrive on hardware/timer queues.
public final class AudioSourceStartupGate: @unchecked Sendable {
	public enum Failure: Error, Equatable, LocalizedError {
		case timedOut
		case stopped
		case captureFailed(String)
		public var errorDescription: String? {
			switch self {
			case .timedOut: return "The microphone did not deliver audio before the startup deadline. Check the selected input and try again."
			case .stopped: return "Microphone startup was stopped."
			case .captureFailed(let message): return message
			}
		}
	}
	private let lock = NSLock()
	private var result: Result<Void, Failure>?
	private var waiters: [CheckedContinuation<Void, Error>] = []
	public init() {}

	public func wait(timeout: TimeInterval) async throws {
		try await withCheckedThrowingContinuation { continuation in
			lock.lock()
			if let result {
				lock.unlock()
				continuation.resume(with: result.mapError { $0 as Error })
				return
			}
			waiters.append(continuation)
			lock.unlock()
			DispatchQueue.global().asyncAfter(deadline: .now() + max(0, timeout)) { [self] in
				settle(.failure(.timedOut))
			}
		}
	}

	public var isCancelled: Bool {
		lock.lock(); defer { lock.unlock() }
		if case .failure? = result { return true }
		return false
	}

	public func sampleReady() { settle(.success(())) }
	public func fail(_ failure: Failure) { settle(.failure(failure)) }
	public func stop() { settle(.failure(.stopped), replacingReady: true) }

	private func settle(_ value: Result<Void, Failure>, replacingReady: Bool = false) {
		lock.lock()
		if result != nil && !replacingReady { lock.unlock(); return }
		result = value
		let pending = waiters
		waiters.removeAll()
		lock.unlock()
		for continuation in pending {
			continuation.resume(with: value.mapError { $0 as Error })
		}
	}
}

/// Converts every presentation/decode timestamp without rewriting PCM or its sample rate.
/// The AVCapture backend supplies CMSyncConvertTime(sessionClock -> hostClock), so genuine
/// source offsets are retained and callback arrival latency never rebases recorded sound.
public func copyAudioSampleBuffer(_ buffer: CMSampleBuffer,
	convertingTime convert: (CMTime) -> CMTime) -> CMSampleBuffer? {
	var count = 0
	guard CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil,
		entriesNeededOut: &count) == noErr, count > 0 else { return nil }
	var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
	guard CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: &timing,
		entriesNeededOut: nil) == noErr else { return nil }
	for index in timing.indices {
		guard timing[index].presentationTimeStamp.isValid else { return nil }
		timing[index].presentationTimeStamp = convert(timing[index].presentationTimeStamp)
		guard timing[index].presentationTimeStamp.isNumeric else { return nil }
		if timing[index].decodeTimeStamp.isValid {
			timing[index].decodeTimeStamp = convert(timing[index].decodeTimeStamp)
		}
	}
	var converted: CMSampleBuffer?
	guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
		sampleBuffer: buffer, sampleTimingEntryCount: count, sampleTimingArray: &timing,
		sampleBufferOut: &converted) == noErr else { return nil }
	return converted
}


/// Kept independent of stdin and capture hardware so EOF cleanup is exercised in tests.
public func runRecordingCommands(readCommand: () -> String?, pause: () -> Void,
	resume: () -> Void, stop: () async -> Void) async {
	while let line = readCommand() {
		switch line.trimmingCharacters(in: .whitespacesAndNewlines) {
		case "pause": pause()
		case "resume": resume()
		case "stop": await stop(); return
		default: break
		}
	}
	await stop()
}



public func startAudioCapture(gate: AudioSourceStartupGate, configure: () throws -> Void,
	start: () -> Void, stop: () -> Void) throws -> Bool {
	guard !gate.isCancelled else { return false }
	try configure()
	guard !gate.isCancelled else { return false }
	start()
	if gate.isCancelled { stop(); return false }
	return true
}


public func startCaptureUnlessStopped(isStopped: () -> Bool, start: () async throws -> Void,
	stop: () async throws -> Void) async throws -> Bool {
	guard !isStopped() else { return false }
	try await start()
	if isStopped() { try await stop(); return false }
	return true
}
