import CoreMedia
import Foundation

/// Owns decoded PCM, never an AVCapture buffer-pool reference. Each source retains at
/// most two seconds of stereo Float plus 512 small timing records while video starts.
struct AudioPreRoll {
	struct Packet {
		var frames: [Float]
		var presentationTime: CMTime
		let timing: AudioDeliveryTiming?
		var frameCount: Int { frames.count / 2 }
	}
	private static let frameLimit = 96_000
	private static let packetLimit = 512
	private var packets: [Packet] = []
	private var pendingFrames = 0
	private var peakPendingBytes = 0
	private var peakPendingPackets = 0
	private var evictedFrames = 0
	private var evictedPackets = 0
	private var replayedFrames = 0
	private var cancelledFrames = 0
	private var maxReplayTimelineWait = 0.0
	private var firstEvictedPTS: Double?
	private var lastEvictedPTSEnd: Double?

	mutating func append(frames: [Float], presentationTime: CMTime, timing: AudioDeliveryTiming?) {
		var packet = Packet(frames: frames, presentationTime: presentationTime, timing: timing)
		// Clip an oversized callback before storing it, keeping its actual tail timestamp.
		if packet.frameCount > Self.frameLimit {
			let count = packet.frameCount - Self.frameLimit
			noteEviction(count, at: packet.presentationTime)
			packet.frames = Array(packet.frames.suffix(Self.frameLimit * 2))
			packet.presentationTime = CMTimeAdd(packet.presentationTime, duration(count))
		}
		packets.append(packet); pendingFrames += packet.frameCount
		while packets.count > Self.packetLimit || pendingFrames > Self.frameLimit {
			let count = packets.count > Self.packetLimit
				? packets[0].frameCount : min(packets[0].frameCount, pendingFrames - Self.frameLimit)
			noteEviction(count, at: packets[0].presentationTime)
			pendingFrames -= count
			if count == packets[0].frameCount {
				packets.removeFirst(); evictedPackets += 1
			} else {
				packets[0].frames.removeFirst(count * 2)
				packets[0].presentationTime = CMTimeAdd(packets[0].presentationTime, duration(count))
			}
		}
		peakPendingBytes = max(peakPendingBytes, pendingFrames * 2 * MemoryLayout<Float>.size)
		peakPendingPackets = max(peakPendingPackets, packets.count)
	}

	mutating func take(at timelineTime: CMTime) -> [Packet] {
		let result = packets
		for packet in result {
			if let timing = packet.timing, timelineTime.isNumeric, timing.ingestionTimelineTime.isNumeric {
				maxReplayTimelineWait = max(maxReplayTimelineWait,
					CMTimeGetSeconds(CMTimeSubtract(timelineTime, timing.ingestionTimelineTime)))
			}
		}
		replayedFrames += pendingFrames
		packets = []; pendingFrames = 0
		return result
	}

	mutating func cancel() {
		cancelledFrames += pendingFrames
		packets = []; pendingFrames = 0
	}

	func report() -> [String: Any] {
		var result: [String: Any] = ["pendingFrames": pendingFrames, "pendingPackets": packets.count,
			"frameLimit": Self.frameLimit, "packetLimit": Self.packetLimit,
			"peakPendingBytes": peakPendingBytes, "peakPendingPackets": peakPendingPackets,
			"evictedFrames": evictedFrames, "evictedPackets": evictedPackets,
			"replayedFrames": replayedFrames, "cancelledFrames": cancelledFrames,
			"maxReplayTimelineWaitSeconds": maxReplayTimelineWait]
		result["firstEvictedPTSStartSeconds"] = firstEvictedPTS
		result["lastEvictedPTSEndSeconds"] = lastEvictedPTSEnd
		return result
	}

	private func duration(_ count: Int) -> CMTime { CMTime(value: CMTimeValue(count), timescale: 48_000) }
	private mutating func noteEviction(_ count: Int, at time: CMTime) {
		evictedFrames += count
		if firstEvictedPTS == nil { firstEvictedPTS = CMTimeGetSeconds(time) }
		lastEvictedPTSEnd = CMTimeGetSeconds(CMTimeAdd(time, duration(count)))
	}
}
