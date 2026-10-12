import Foundation

public struct Vehicle: Codable, Identifiable, Sendable, Equatable, Hashable {
    public let id: String
    public var year: Int
    public var make: String
    public var model: String
    public var engineCode: String?
    public var isArchived: Bool

    public init(
        id: String = UUID().uuidString,
        year: Int,
        make: String,
        model: String,
        engineCode: String? = nil,
        isArchived: Bool = false
    ) {
        self.id = id
        self.year = year
        self.make = make
        self.model = model
        self.engineCode = engineCode
        self.isArchived = isArchived
    }

    public var displayName: String {
        var parts = ["\(year)", make, model]
        if let code = engineCode, !code.isEmpty {
            parts.append("— \(code)")
        }
        return parts.joined(separator: " ")
    }

    /// The firmware engine profile id to declare to the dongle for this vehicle, derived
    /// from `make` and `engineCode`. `nil` when there is no profile the firmware is known
    /// to ship — the dongle's own discovery chain is left to pick (VIN pattern, default).
    ///
    /// Known profiles are tracked in `cairn-esp32-device-firmware/engines/*.yaml`. Keep
    /// this mapping deliberately conservative: an unknown profile written to the dongle
    /// is logged and does nothing, so adding one here is cheap but silently wrong is bad.
    public var firmwareEngineProfileID: String? {
        guard let code = engineCode?.uppercased(), !code.isEmpty else { return nil }
        let brand = make.lowercased()
        switch (brand, code) {
        case ("bmw", "N20"), ("bmw", "N26"): return "bmw-n20"
        case ("bmw", "B58"):                 return "bmw-b58"
        default: return nil
        }
    }
}

public struct VehicleAssignment: Codable, Sendable, Equatable {
    public let dongleID: String
    public let vehicleID: String

    public init(dongleID: String, vehicleID: String) {
        self.dongleID = dongleID
        self.vehicleID = vehicleID
    }
}
