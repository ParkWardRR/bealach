import Foundation

public struct Vehicle: Codable, Identifiable, Sendable, Equatable, Hashable {
    public let id: String
    public var year: Int
    public var make: String
    public var model: String
    public var engineCode: String?
    public var vin: String?
    public var isArchived: Bool
    public var category: Category
    public var identificationSource: IdentificationSource
    public var identificationConfidence: Confidence

    public init(
        id: String = UUID().uuidString,
        year: Int,
        make: String,
        model: String,
        engineCode: String? = nil,
        vin: String? = nil,
        isArchived: Bool = false,
        category: Category = .personal,
        identificationSource: IdentificationSource = .manual,
        identificationConfidence: Confidence = .confirmed
    ) {
        self.id = id
        self.year = year
        self.make = make
        self.model = model
        self.engineCode = engineCode
        self.vin = vin
        self.isArchived = isArchived
        self.category = category
        self.identificationSource = identificationSource
        self.identificationConfidence = identificationConfidence
    }

    public var displayName: String {
        var parts = ["\(year)", make, model]
        if let code = engineCode, !code.isEmpty {
            parts.append("— \(code)")
        }
        return parts.joined(separator: " ")
    }

    public var firmwareEngineProfileID: String? {
        guard let code = engineCode?.uppercased(), !code.isEmpty else { return nil }
        let brand = make.lowercased()
        switch (brand, code) {
        case ("bmw", "N20"), ("bmw", "N26"): return "bmw-n20"
        case ("bmw", "B58"):                 return "bmw-b58"
        default: return nil
        }
    }

    // MARK: - Types

    public enum Category: String, Codable, Sendable, Equatable, Hashable {
        case personal
        case rental
    }

    public enum IdentificationSource: String, Codable, Sendable, Equatable, Hashable {
        case manual
        case obdVIN
        case userCorrected
    }

    public enum Confidence: String, Codable, Sendable, Equatable, Hashable {
        case confirmed
        case candidate
        case ambiguous
    }
}

public struct VehicleAssignment: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let dongleID: String
    public let vehicleID: String
    public var assignedAt: Date
    public var endedAt: Date?
    public var source: AssignmentSource

    public init(
        id: String = UUID().uuidString,
        dongleID: String,
        vehicleID: String,
        assignedAt: Date = Date(),
        endedAt: Date? = nil,
        source: AssignmentSource = .manual
    ) {
        self.id = id
        self.dongleID = dongleID
        self.vehicleID = vehicleID
        self.assignedAt = assignedAt
        self.endedAt = endedAt
        self.source = source
    }

    public var isActive: Bool { endedAt == nil }

    public enum AssignmentSource: String, Codable, Sendable, Equatable {
        case manual
        case obdDetected
        case vinMatched
    }
}
