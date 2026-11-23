import Foundation

/// The device's own name for wording ("iPhone" or "iPad"), so iPad users don't read "this iPhone".
/// Read from the hardware model rather than UIDevice, so it works outside the main actor too.
enum Device {
    static let name: String = name(forModel: model)

    static func name(forModel model: String) -> String {
        model.hasPrefix("iPad") ? "iPad" : "iPhone"
    }

    private static var model: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
