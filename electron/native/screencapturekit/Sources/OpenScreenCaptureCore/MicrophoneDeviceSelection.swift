import Foundation

/// Chromium decorates USB labels with a vendor/product suffix; AVFoundation does not.
/// Resolve IDs first and only accept unambiguous names, never a substring match.
public func resolveMicrophoneDeviceID(
	deviceID: String?,
	deviceName: String?,
	devices: [(id: String, name: String)]
) -> String? {
	// Chromium's default entry must use the OS default, even with a stale saved name.
	if deviceID?.trimmingCharacters(in: .whitespacesAndNewlines) == "default" { return nil }
	if let id = deviceID?.trimmingCharacters(in: .whitespacesAndNewlines),
		devices.contains(where: { $0.id == id }) {
		return id
	}
	guard let name = deviceName?.trimmingCharacters(in: .whitespacesAndNewlines),
		!name.isEmpty else { return nil }
	let exact = devices.filter { $0.name == name }
	if exact.count == 1 { return exact[0].id }
	if !exact.isEmpty { return nil }
	let normalized = name.replacingOccurrences(
		of: #" \([0-9a-fA-F]{4}:[0-9a-fA-F]{4}\)$"#,
		with: "",
		options: .regularExpression
	)
	guard normalized != name else { return nil }
	let matches = devices.filter { $0.name == normalized }
	return matches.count == 1 ? matches[0].id : nil
}


public enum MicrophoneDeviceChoice: Equatable {
	case systemDefault
	case device(String)
	case unavailable
}

public func microphoneDeviceChoice(deviceID: String?, deviceName: String?,
	devices: [(id: String, name: String)]) -> MicrophoneDeviceChoice {
	let id = deviceID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
	let name = deviceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
	if id == "default" || (id.isEmpty && name.isEmpty) { return .systemDefault }
	guard let selected = resolveMicrophoneDeviceID(deviceID: id, deviceName: name, devices: devices)
	else { return .unavailable }
	return .device(selected)
}
