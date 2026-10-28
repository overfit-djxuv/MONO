import Foundation

/// Reads the expiry of the provisioning profile this build was signed with.
/// Only present on builds installed from Xcode; nil in the simulator and on App Store builds.
enum ProfileInfo {
    static var expiry: Date? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }
        return expiry(fromProfile: data)
    }

    /// The profile is a signed envelope around an XML plist; the plist is found by its markers.
    static func expiry(fromProfile data: Data) -> Date? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8)), start.lowerBound < end.upperBound else { return nil }
        let plist = data.subdata(in: start.lowerBound..<end.upperBound)
        let dict = try? PropertyListSerialization.propertyList(from: plist, options: [], format: nil) as? [String: Any]
        return dict?["ExpirationDate"] as? Date
    }

    enum Status: Equatable {
        case ok(daysLeft: Int)
        case soon(daysLeft: Int)   // renewal job should have run by now
        case expired

        var isWarning: Bool { if case .ok = self { return false } else { return true } }
    }

    static func status(expiry: Date, now: Date = .now) -> Status {
        let seconds = expiry.timeIntervalSince(now)
        if seconds <= 0 { return .expired }
        let days = Int(seconds / 86_400)
        return days <= 2 ? .soon(daysLeft: days) : .ok(daysLeft: days)
    }
}
