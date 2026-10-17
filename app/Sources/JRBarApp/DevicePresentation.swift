import JRBarCore

enum DeviceConnectionLine {
    static func title(device: CoreDevice?, live: Bool) -> String {
        guard live else { return "Monitor not connected" }
        guard let device else { return "Not reported" }
        if device.isPresent { return "Connected" }
        return device.error.flatMap { $0.isEmpty ? nil : $0 } ?? "Not connected"
    }
}
