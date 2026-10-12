// Provenance: cairn-ios-companion-app @ a7d02d8, Sources/CairnCore/Models/MaintenanceStore.swift
// Renamed Cairn* → Bealach* for Bealach.

import Foundation

public protocol MaintenanceStore: Sendable {
    // MARK: - Maintenance entries

    func listEntries(vehicleID: String) async throws -> [MaintenanceEntry]
    func saveEntry(_ entry: MaintenanceEntry) async throws
    func deleteEntry(_ id: String) async throws

    // MARK: - Odometer corrections

    func listOdometerCorrections(vehicleID: String) async throws -> [OdometerCorrection]
    func saveOdometerCorrection(_ correction: OdometerCorrection) async throws
    func deleteOdometerCorrection(_ id: String) async throws
    func latestOdometer(vehicleID: String) async throws -> OdometerCorrection?

    // MARK: - Annotations

    func annotations(forTarget targetID: String) async throws -> [Annotation]
    func listAnnotations(vehicleID: String?) async throws -> [Annotation]
    func saveAnnotation(_ annotation: Annotation) async throws
    func deleteAnnotation(_ id: String) async throws
}
