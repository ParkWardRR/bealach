import CairnCore
import SwiftUI

public struct GarageView: View {
    let vehicleStore: GRDBVehicleStore
    let maintenanceStore: GRDBMaintenanceStore
    let recorder: DriveRecorder
    @State private var vehicles: [Vehicle] = []
    @State private var showAddVehicle = false

    public init(vehicleStore: GRDBVehicleStore, maintenanceStore: GRDBMaintenanceStore, recorder: DriveRecorder) {
        self.vehicleStore = vehicleStore
        self.maintenanceStore = maintenanceStore
        self.recorder = recorder
    }

    private var activeVehicles: [Vehicle] { vehicles.filter { !$0.isArchived } }
    private var archivedVehicles: [Vehicle] { vehicles.filter { $0.isArchived } }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if activeVehicles.isEmpty && archivedVehicles.isEmpty {
                        ContentUnavailableView(
                            "No Vehicles",
                            systemImage: "car.side",
                            description: Text("Add a vehicle to track maintenance and drives.")
                        )
                    } else {
                        ForEach(activeVehicles) { vehicle in
                            NavigationLink(value: vehicle.id) {
                                VehicleCard(
                                    vehicle: vehicle,
                                    isSelected: vehicleStore.selectedVehicleID() == vehicle.id,
                                    maintenanceStore: maintenanceStore
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    vehicleStore.selectVehicle(vehicle.id)
                                    Task { await loadVehicles() }
                                } label: {
                                    Label("Set Active", systemImage: "checkmark.circle")
                                }
                                Button {
                                    Task {
                                        var archived = vehicle
                                        archived.isArchived = true
                                        try? await vehicleStore.saveVehicle(archived)
                                        await loadVehicles()
                                    }
                                } label: {
                                    Label("Archive", systemImage: "archivebox")
                                }
                            }
                        }

                        if !archivedVehicles.isEmpty {
                            DisclosureGroup {
                                ForEach(archivedVehicles) { vehicle in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(vehicle.displayName)
                                                .font(.subheadline)
                                            if let code = vehicle.engineCode {
                                                Text(code)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer()
                                        Button {
                                            Task {
                                                var restored = vehicle
                                                restored.isArchived = false
                                                try? await vehicleStore.saveVehicle(restored)
                                                await loadVehicles()
                                            }
                                        } label: {
                                            Text("Restore")
                                                .font(.caption)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                            } label: {
                                Text("Archived")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Backdrop().ignoresSafeArea())
            .navigationTitle("Garage")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button { showAddVehicle = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .navigationDestination(for: String.self) { vehicleID in
                if let vehicle = vehicles.first(where: { $0.id == vehicleID }) {
                    VehicleProfileView(
                        vehicle: vehicle,
                        vehicleStore: vehicleStore,
                        maintenanceStore: maintenanceStore,
                        recorder: recorder
                    )
                }
            }
            .task { await loadVehicles() }
            .sheet(isPresented: $showAddVehicle) {
                AddVehicleSheet { vehicle in
                    Task {
                        try? await vehicleStore.saveVehicle(vehicle)
                        vehicleStore.selectVehicle(vehicle.id)
                        await loadVehicles()
                    }
                }
            }
        }
    }

    private func loadVehicles() async {
        vehicles = (try? await vehicleStore.listVehicles()) ?? []
    }
}

// MARK: - Vehicle Card

private struct VehicleCard: View {
    let vehicle: Vehicle
    let isSelected: Bool
    let maintenanceStore: GRDBMaintenanceStore
    @State private var latestOdometer: OdometerCorrection?
    @State private var recentEntryCount = 0

    var body: some View {
        Card(accentBorder: isSelected) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.14))
                    Image(systemName: "car.fill")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(vehicle.displayName)
                            .font(.headline)
                        if isSelected {
                            BadgePill(text: "ACTIVE", color: .accentColor)
                        }
                    }
                    if let code = vehicle.engineCode {
                        Text(code)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }

            if latestOdometer != nil || recentEntryCount > 0 {
                Divider()
                MetricGrid {
                    if let odo = latestOdometer {
                        Metric("Odometer", odo.formatted())
                    }
                    if recentEntryCount > 0 {
                        Metric("Services logged", "\(recentEntryCount)")
                    }
                }
            }
        }
        .task {
            latestOdometer = try? await maintenanceStore.latestOdometer(vehicleID: vehicle.id)
            recentEntryCount = ((try? await maintenanceStore.listEntries(vehicleID: vehicle.id)) ?? []).count
        }
    }
}

// MARK: - Add Vehicle Sheet

struct AddVehicleSheet: View {
    let onSave: (Vehicle) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var year: String = ""
    @State private var make: String = ""
    @State private var model: String = ""
    @State private var engineCode: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Year", text: $year)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    TextField("Make", text: $make)
                    TextField("Model", text: $model)
                    TextField("Engine code (optional)", text: $engineCode)
                }
                Section {
                    if let preview = previewName {
                        Text(preview)
                            .font(.headline)
                    }
                }
            }
            .navigationTitle("Add Vehicle")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let y = Int(year), !make.isEmpty, !model.isEmpty else { return }
                        let vehicle = Vehicle(
                            year: y, make: make, model: model,
                            engineCode: engineCode.isEmpty ? nil : engineCode
                        )
                        onSave(vehicle)
                        dismiss()
                    }
                    .disabled(Int(year) == nil || make.isEmpty || model.isEmpty)
                }
            }
        }
    }

    private var previewName: String? {
        guard let y = Int(year), !make.isEmpty, !model.isEmpty else { return nil }
        var parts = ["\(y)", make, model]
        if !engineCode.isEmpty { parts.append("— \(engineCode)") }
        return parts.joined(separator: " ")
    }
}
