import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation
import OpenScreenCaptureCore

/// A microphone owned by the same picker/helper process as the screen take.
/// Unlike SCStream's microphone output, this source starts and proves it has PCM before
/// the screen is allowed to report recording-started. Its timestamps are converted from
/// AVCaptureSession's documented synchronizationClock to the screen/tap host clock.
// Mutable capture configuration/teardown are confined to controlQueue; startup is locked.
final class AVCaptureMicrophone: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
	private let session = AVCaptureSession()
	private let controlQueue = DispatchQueue(label: "app.openscreen.microphone.control")
	private let outputQueue = DispatchQueue(label: "app.openscreen.microphone.samples")
	private let startup = AudioSourceStartupGate()
	private let deviceID: String?
	private let deviceName: String?
	private let onBuffer: (CMSampleBuffer, CMTime) -> Void
	private let onFailure: (String) -> Void
	private var output: AVCaptureAudioDataOutput?
	private var runtimeErrorObserver: NSObjectProtocol?
	// controlQueue only.
	private var stopped = false

	init(deviceID: String?, deviceName: String?, onBuffer: @escaping (CMSampleBuffer, CMTime) -> Void,
		onFailure: @escaping (String) -> Void) {
		self.deviceID = deviceID
		self.deviceName = deviceName
		self.onBuffer = onBuffer
		self.onFailure = onFailure
	}

	func start(timeout: TimeInterval = 3) async throws {
		controlQueue.async { [self] in
			guard !stopped else { startup.stop(); return }
			do {
				let started = try startAudioCapture(gate: startup, configure: { try configure() },
					start: { session.startRunning() }, stop: { session.stopRunning() })
				if started && !session.isRunning {
					startup.fail(.captureFailed("The microphone capture session did not start."))
				}
			} catch {
				startup.fail(.captureFailed(error.localizedDescription))
			}
		}
		// The deadline runs independently of startRunning, which can block in AVFoundation.
		do {
			try await startup.wait(timeout: timeout)
		} catch {
			stop()
			throw error
		}
	}

	/// Teardown is ordered behind startup, never run beside it. No hardware call can hold
	/// the writer's save hostage; the recorder closes its ingestion gate before calling us.
	func stop() {
		startup.stop()
		controlQueue.async { [self] in
			guard !stopped else { return }
			stopped = true
			if let runtimeErrorObserver {
				NotificationCenter.default.removeObserver(runtimeErrorObserver)
				self.runtimeErrorObserver = nil
			}
			output?.setSampleBufferDelegate(nil, queue: nil)
			if session.isRunning { session.stopRunning() }
		}
	}

	private func configure() throws {
		let deviceTypes: [AVCaptureDevice.DeviceType]
		if #available(macOS 14, *) { deviceTypes = [.microphone, .external] }
		else { deviceTypes = [.builtInMicrophone, .externalUnknown] }
		let devices = AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes,
			mediaType: .audio, position: .unspecified).devices
		let choice = microphoneDeviceChoice(deviceID: deviceID, deviceName: deviceName,
			devices: devices.map { (id: $0.uniqueID, name: $0.localizedName) })
		let device: AVCaptureDevice?
		switch choice {
		case .systemDefault: device = AVCaptureDevice.default(for: .audio)
		case .device(let id): device = devices.first { $0.uniqueID == id }
		case .unavailable:
			throw AudioSourceStartupGate.Failure.captureFailed("The selected microphone is unavailable or ambiguous. Select a connected input and try again.")
		}
		guard let device else {
			throw AudioSourceStartupGate.Failure.captureFailed("No microphone input is connected.")
		}
		let input = try AVCaptureDeviceInput(device: device)
		let output = AVCaptureAudioDataOutput()
		output.audioSettings = [
			AVFormatIDKey: kAudioFormatLinearPCM,
			AVLinearPCMIsFloatKey: true,
			AVLinearPCMBitDepthKey: 32,
			AVLinearPCMIsBigEndianKey: false,
			AVLinearPCMIsNonInterleaved: false,
		]
		session.beginConfiguration()
		defer { session.commitConfiguration() }
		guard session.canAddInput(input) else {
			throw AudioSourceStartupGate.Failure.captureFailed("Unable to configure the microphone input.")
		}
		session.addInput(input)
		guard session.canAddOutput(output) else {
			throw AudioSourceStartupGate.Failure.captureFailed("Unable to configure the microphone audio output.")
		}
		session.addOutput(output)
		output.setSampleBufferDelegate(self, queue: outputQueue)
		self.output = output
		runtimeErrorObserver = NotificationCenter.default.addObserver(
			forName: .AVCaptureSessionRuntimeError, object: session, queue: nil
		) { [weak self] notification in
			guard let self else { return }
			let message = (notification.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription
				?? "The microphone capture session failed."
			self.startup.fail(.captureFailed(message))
			self.onFailure(message)
		}
		emit(["event": "microphone-source", "backend": "avcapture", "deviceID": device.uniqueID,
			"deviceName": device.localizedName])
	}

	func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
		from connection: AVCaptureConnection) {
		let callbackHostTime = CMClockGetTime(CMClockGetHostTimeClock())
		guard CMSampleBufferDataIsReady(sampleBuffer), CMSampleBufferGetNumSamples(sampleBuffer) > 0,
			let format = CMSampleBufferGetFormatDescription(sampleBuffer),
			let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
			asbd.mFormatID == kAudioFormatLinearPCM, asbd.mChannelsPerFrame > 0, asbd.mSampleRate > 0,
			let clock = session.synchronizationClock,
			let buffer = copyAudioSampleBuffer(sampleBuffer, convertingTime: {
				CMSyncConvertTime($0, from: clock, to: CMClockGetHostTimeClock())
			})
		else { return }
		startup.sampleReady()
		onBuffer(buffer, callbackHostTime)
	}
}
