import BealachCore
import BealachRuntime
import SwiftUI

@main
struct BealachApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            Group {
                if let root = appState.rootDependencies {
                    RootView(
                        session: root.session,
                        vehicleStore: root.vehicleStore,
                        maintenanceStore: root.maintenanceStore,
                        dataPorter: root.dataPorter,
                        enrolmentService: root.enrolmentService,
                        reconciliationStore: root.reconciliationStore
                    )
                } else if let error = appState.launchError {
                    LaunchErrorView(message: error)
                } else {
                    LaunchView()
                }
            }
            .task { await appState.bootstrap() }
        }
    }
}

@MainActor
@Observable
final class AppState {
    var rootDependencies: RootDependencies?
    var launchError: String?

    struct RootDependencies {
        let session: DrivingSession
        let vehicleStore: GRDBVehicleStore
        let maintenanceStore: GRDBMaintenanceStore
        let dataPorter: DataPorter
        let enrolmentService: EnrolmentService
        let reconciliationStore: GRDBReconciliationStore
    }

    func bootstrap() async {
        do {
            let db = try BealachDatabase()
            let vehicleStore = GRDBVehicleStore(db: db)
            let maintenanceStore = GRDBMaintenanceStore(db: db)
            let driveStore = GRDBDriveStore(db: db)
            let reconciliationStore = GRDBReconciliationStore(db: db)
            let dataPorter = DataPorter(db: db, vehicleStore: vehicleStore, maintenanceStore: maintenanceStore)

            let keyProvider: any KeyProvider
            do {
                keyProvider = try SecureEnclaveKeyProvider()
            } catch {
                keyProvider = KeychainSoftwareKeyProvider()
            }
            let identityStore = KeychainIdentityStore()
            let enrolmentService = EnrolmentService(keyProvider: keyProvider, identityStore: identityStore)

            let state = SessionState()
            let ble = BealachBLEManager(state: state)
            let recorder = DriveRecorder(store: driveStore, vehicleStore: vehicleStore)
            let session = DrivingSession(ble: ble, state: state, recorder: recorder)

            rootDependencies = RootDependencies(
                session: session,
                vehicleStore: vehicleStore,
                maintenanceStore: maintenanceStore,
                dataPorter: dataPorter,
                enrolmentService: enrolmentService,
                reconciliationStore: reconciliationStore
            )
        } catch {
            launchError = "Bealach failed to start: \(error.localizedDescription)"
        }
    }
}

struct LaunchView: View {
    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "location.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                Text("Bealach")
                    .font(.title.bold())
                ProgressView()
                    .controlSize(.regular)
            }
        }
    }
}

struct LaunchErrorView: View {
    let message: String

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.red)
                Text(message)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
    }
}
