import Foundation

public struct MaintenanceEntry: Codable, Identifiable, Sendable, Equatable, Hashable {
    public let id: String
    public var vehicleID: String
    public var category: MaintenanceCategory
    public var performedAt: Date
    public var createdAt: Date

    public var title: String
    public var notes: String?
    public var cost: Decimal?
    public var currencyCode: String?
    public var shop: String?
    public var odometerKm: Int?
    public var partNumbers: [String]

    public init(
        id: String = UUID().uuidString,
        vehicleID: String,
        category: MaintenanceCategory,
        performedAt: Date,
        createdAt: Date = Date(),
        title: String,
        notes: String? = nil,
        cost: Decimal? = nil,
        currencyCode: String? = nil,
        shop: String? = nil,
        odometerKm: Int? = nil,
        partNumbers: [String] = []
    ) {
        self.id = id
        self.vehicleID = vehicleID
        self.category = category
        self.performedAt = performedAt
        self.createdAt = createdAt
        self.title = title
        self.notes = notes
        self.cost = cost
        self.currencyCode = currencyCode
        self.shop = shop
        self.odometerKm = odometerKm
        self.partNumbers = partNumbers
    }

    public var formattedCost: String? {
        guard let cost else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode ?? "USD"
        return formatter.string(from: cost as NSDecimalNumber)
    }
}

public enum MaintenanceCategory: String, Codable, Sendable, CaseIterable, Hashable {
    case oilChange
    case brakes
    case tires
    case battery
    case coolant
    case transmission
    case sparkPlugs
    case airFilter
    case belts
    case suspension
    case exhaust
    case electrical
    case bodywork
    case inspection
    case other

    public var displayName: String {
        switch self {
        case .oilChange: "Oil Change"
        case .brakes: "Brakes"
        case .tires: "Tires"
        case .battery: "Battery"
        case .coolant: "Coolant"
        case .transmission: "Transmission"
        case .sparkPlugs: "Spark Plugs"
        case .airFilter: "Air Filter"
        case .belts: "Belts"
        case .suspension: "Suspension"
        case .exhaust: "Exhaust"
        case .electrical: "Electrical"
        case .bodywork: "Bodywork"
        case .inspection: "Inspection"
        case .other: "Other"
        }
    }

    public var systemImage: String {
        switch self {
        case .oilChange: "drop.fill"
        case .brakes: "circle.circle"
        case .tires: "circle.dashed"
        case .battery: "battery.100"
        case .coolant: "thermometer.medium"
        case .transmission: "gearshape.2"
        case .sparkPlugs: "bolt.fill"
        case .airFilter: "wind"
        case .belts: "arrow.triangle.2.circlepath"
        case .suspension: "arrow.up.arrow.down"
        case .exhaust: "smoke.fill"
        case .electrical: "bolt.circle"
        case .bodywork: "car.side"
        case .inspection: "checklist"
        case .other: "wrench.and.screwdriver"
        }
    }
}
