import Foundation

/// How the BLE manager reacts when a link that did come up then fails (service or characteristic
/// discovery, the `PROTOCOL_VERSION` read, pairing). A drive should survive a hiccup, so these retry.
/// Protocol refusals (unsupported version, missing required characteristics, write size too small)
/// are final: retrying would only repeat them.
public enum ReconnectPolicy {
    /// Consecutive failed attempts after which the app stops and shows the error, so a wrong
    /// passkey or a dongle that keeps refusing does not loop forever.
    public static let maxConsecutiveFailures = 8

    public static let baseDelay: TimeInterval = 1
    public static let maxDelay: TimeInterval = 15

    /// Delay before the next attempt. 1 s with no recent failures, then doubling up to 15 s.
    public static func delay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return baseDelay }
        let exponent = min(failures, 10) // keeps the shift from overflowing; the cap applies long before
        return min(baseDelay * Double(1 << exponent), maxDelay)
    }

    public static func shouldGiveUp(afterFailures failures: Int) -> Bool {
        failures >= maxConsecutiveFailures
    }
}
