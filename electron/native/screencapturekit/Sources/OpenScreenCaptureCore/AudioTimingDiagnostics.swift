import CoreMedia
import Foundation

/// Callback and ingestion stamps are metadata only. Queue wait uses raw host time;
/// PCM lag uses the same pause-normalized clock domain as the writer timeline.
public struct AudioDeliveryTiming {
	public let callbackHostTime: CMTime
	public let ingestionHostTime: CMTime
	public let callbackTimelineTime: CMTime
	public let ingestionTimelineTime: CMTime
	public init(callbackHostTime: CMTime, ingestionHostTime: CMTime,
		callbackTimelineTime: CMTime, ingestionTimelineTime: CMTime) {
		self.callbackHostTime = callbackHostTime
		self.ingestionHostTime = ingestionHostTime
		self.callbackTimelineTime = callbackTimelineTime
		self.ingestionTimelineTime = ingestionTimelineTime
	}
}

/// Queue-confined, bounded metadata. Negative PTS lag is retained so a clock offset is
/// distinguishable from delayed delivery; no sample values are stored here.
struct AudioTimingDiagnostics {
	private(set) var bufferCount = 0
	private var previousCallbackHost: Double?
	private var previousIngestionHost: Double?
	private var deliveredEndFrame: Int64?
	private var minCallbackLag: Double?
	private var maxCallbackLag: Double?
	private var minIngestionLag: Double?
	private var maxIngestionLag: Double?
	private var maxQueueWait = 0.0
	private var minQueueWait: Double?
	private var maxCallbackGap = 0.0
	private var maxIngestionGap = 0.0
	private var ptsHoleFrames: Int64 = 0
	private var ptsOverlapFrames: Int64 = 0
	private var callbackLagBuckets = [Int](repeating: 0, count: 4)
	private var ingestionLagBuckets = [Int](repeating: 0, count: 4)
	private var anomalies: [[String: Any]] = []
	private var anomalyOverflow = 0
	private let sampleRate = 48_000.0
	private let maximumAnomalies = 100
	private var lastCursorReason = "none"
	private var lastBufferStart: Double?
	private var lastBufferEnd: Double?
	private var lastCallbackTimeline: Double?
	private var lastIngestionTimeline: Double?
	private var lastQueueWait: Double?
	private var lastNormalizedPTSStart: Double?
	private var lastNormalizedPTSEnd: Double?
	private var lastPauseOffset: Double?

	mutating func recordBuffer(startFrame: Int64, endFrame: Int64, endTime: CMTime,
		anchor: CMTime, timing: AudioDeliveryTiming?) {
		bufferCount += 1
		let previousEnd = deliveredEndFrame ?? 0
		if startFrame > previousEnd {
			ptsHoleFrames += startFrame - previousEnd
			if startFrame - previousEnd >= 960 {
				append(["kind": "pts-hole", "startSeconds": seconds(previousEnd), "endSeconds": seconds(startFrame)])
			}
		} else if let previous = deliveredEndFrame, startFrame < previous {
			let overlapEnd = min(previous, endFrame)
			if overlapEnd > startFrame {
				ptsOverlapFrames += overlapEnd - startFrame
				if overlapEnd - startFrame >= 48 {
					append(["kind": "pts-overlap", "startSeconds": seconds(startFrame), "endSeconds": seconds(overlapEnd)])
				}
			}
		}
		deliveredEndFrame = max(deliveredEndFrame ?? endFrame, endFrame)
		lastBufferStart = seconds(startFrame)
		lastBufferEnd = seconds(endFrame)
		lastNormalizedPTSEnd = CMTimeGetSeconds(endTime)
		lastNormalizedPTSStart = CMTimeGetSeconds(endTime) - seconds(endFrame - startFrame)
		guard let timing,
			timing.callbackHostTime.isNumeric, timing.ingestionHostTime.isNumeric,
			timing.callbackTimelineTime.isNumeric, timing.ingestionTimelineTime.isNumeric else { return }
		let callbackHost = CMTimeGetSeconds(timing.callbackHostTime)
		let ingestionHost = CMTimeGetSeconds(timing.ingestionHostTime)
		let wait = ingestionHost - callbackHost
		let callbackLag = CMTimeGetSeconds(CMTimeSubtract(timing.callbackTimelineTime, endTime))
		let ingestionLag = CMTimeGetSeconds(CMTimeSubtract(timing.ingestionTimelineTime, endTime))
		guard [callbackHost, ingestionHost, wait, callbackLag, ingestionLag].allSatisfy({ $0.isFinite }) else { return }
		lastPauseOffset = CMTimeGetSeconds(CMTimeSubtract(timing.callbackHostTime, timing.callbackTimelineTime))
		let callbackAt = CMTimeGetSeconds(CMTimeSubtract(timing.callbackTimelineTime, anchor))
		let ingestionAt = CMTimeGetSeconds(CMTimeSubtract(timing.ingestionTimelineTime, anchor))
		lastCallbackTimeline = callbackAt; lastIngestionTimeline = ingestionAt; lastQueueWait = wait
		minQueueWait = min(minQueueWait ?? wait, wait); maxQueueWait = max(maxQueueWait, wait)
		minCallbackLag = min(minCallbackLag ?? callbackLag, callbackLag)
		maxCallbackLag = max(maxCallbackLag ?? callbackLag, callbackLag)
		minIngestionLag = min(minIngestionLag ?? ingestionLag, ingestionLag)
		maxIngestionLag = max(maxIngestionLag ?? ingestionLag, ingestionLag)
		callbackLagBuckets[bucket(callbackLag)] += 1; ingestionLagBuckets[bucket(ingestionLag)] += 1
		if let previousCallbackHost {
			let gap = callbackHost - previousCallbackHost
			maxCallbackGap = max(maxCallbackGap, gap)
			if gap > 0.25 { append(["kind": "callback-gap", "atSeconds": callbackAt, "gapSeconds": gap]) }
		}
		if let previousIngestionHost { maxIngestionGap = max(maxIngestionGap, ingestionHost - previousIngestionHost) }
		previousCallbackHost = callbackHost; previousIngestionHost = ingestionHost
		if wait > 0.25 || wait < -0.001 { append(["kind": "queue-wait", "atSeconds": ingestionAt, "seconds": wait]) }
		if callbackLag > 0.25 || callbackLag < -0.05 {
			append(["kind": "callback-pts-lag", "atSeconds": callbackAt, "seconds": callbackLag])
		}
		if ingestionLag > 0.25 || ingestionLag < -0.05 {
			append(["kind": "ingestion-pts-lag", "atSeconds": ingestionAt, "seconds": ingestionLag])
		}
	}

	mutating func recordEmission(startFrame: Int64, endFrame: Int64, reason: String, lacksPendingPCM: Bool) {
		lastCursorReason = reason
		if lacksPendingPCM {
			// Extend an existing run without allocating a dictionary on every 10 ms tick.
			if let index = anomalies.lastIndex(where: { $0["kind"] as? String == "uncovered-emitted" }),
				anomalies[index]["reason"] as? String == reason,
				let end = anomalies[index]["endSeconds"] as? Double, abs(end - seconds(startFrame)) < 1 / sampleRate {
				anomalies[index]["endSeconds"] = seconds(endFrame)
				return
			}
			append(["kind": "uncovered-emitted", "startSeconds": seconds(startFrame),
				"endSeconds": seconds(endFrame), "reason": reason], coalescing: true)
		}
	}

	mutating func recordDrop(startFrame: Int64, endFrame: Int64, cursor: Int64, hostFrame: Int64) {
		// This is the latest cursor advance, not necessarily the emit that replaced this
		// older span. Keep the label explicit rather than infer an unsupported cause.
		var event: [String: Any] = ["kind": "late-drop", "startSeconds": seconds(startFrame),
			"endSeconds": seconds(endFrame), "cursorSeconds": seconds(cursor),
			"hostTimelineSeconds": seconds(hostFrame), "lastCursorAdvanceReason": lastCursorReason]
		event["lastBufferStartSeconds"] = lastBufferStart; event["lastBufferEndSeconds"] = lastBufferEnd
		event["callbackTimelineSeconds"] = lastCallbackTimeline; event["ingestionTimelineSeconds"] = lastIngestionTimeline
		event["queueWaitSeconds"] = lastQueueWait
		append(event, coalescing: true)
	}

	func report() -> [String: Any] {
		var result: [String: Any] = ["bufferCount": bufferCount, "maxQueueWaitSeconds": maxQueueWait,
			"maxCallbackGapSeconds": maxCallbackGap, "maxIngestionGapSeconds": maxIngestionGap,
			"ptsHoleSeconds": seconds(ptsHoleFrames), "ptsOverlapSeconds": seconds(ptsOverlapFrames),
			"callbackLagBucketCounts": callbackLagBuckets, "ingestionLagBucketCounts": ingestionLagBuckets,
			"lagBucketUpperBoundsSeconds": [0.05, 0.25, 1.0], "anomalyLimit": maximumAnomalies,
			"anomalies": anomalies, "anomalyOverflowCount": anomalyOverflow]
		result["minQueueWaitSeconds"] = minQueueWait
		result["minCallbackLagSeconds"] = minCallbackLag; result["maxCallbackLagSeconds"] = maxCallbackLag
		result["minIngestionLagSeconds"] = minIngestionLag; result["maxIngestionLagSeconds"] = maxIngestionLag
		result["lastBufferStartSeconds"] = lastBufferStart; result["lastBufferEndSeconds"] = lastBufferEnd
		result["lastNormalizedPTSStartSeconds"] = lastNormalizedPTSStart; result["lastNormalizedPTSEndSeconds"] = lastNormalizedPTSEnd
		result["lastPauseOffsetSeconds"] = lastPauseOffset
		if let end = lastNormalizedPTSEnd, let offset = lastPauseOffset { result["lastConvertedHostPTSEndSeconds"] = end + offset }
		result["lastCallbackHostTimeSeconds"] = previousCallbackHost; result["lastIngestionHostTimeSeconds"] = previousIngestionHost
		result["lastCallbackTimelineSeconds"] = lastCallbackTimeline; result["lastIngestionTimelineSeconds"] = lastIngestionTimeline
		return result
	}

	private func seconds(_ frame: Int64) -> Double { Double(frame) / sampleRate }
	private func bucket(_ value: Double) -> Int { value <= 0.05 ? 0 : value <= 0.25 ? 1 : value <= 1 ? 2 : 3 }
	private mutating func append(_ event: [String: Any], coalescing: Bool = false) {
		if coalescing, let kind = event["kind"] as? String, let start = event["startSeconds"] as? Double,
			let index = anomalies.lastIndex(where: { $0["kind"] as? String == kind }) {
			let previous = anomalies[index]
			if let end = previous["endSeconds"] as? Double, abs(end - start) < 1 / sampleRate,
				previous["reason"] as? String == event["reason"] as? String,
				previous["lastCursorAdvanceReason"] as? String == event["lastCursorAdvanceReason"] as? String {
				anomalies[index]["endSeconds"] = event["endSeconds"]
				return
			}
		}
		if anomalies.count == maximumAnomalies { anomalies.removeFirst(); anomalyOverflow += 1 }
		anomalies.append(event)
	}
}
