import SwiftUI

@main
struct LeapmotorHAApp: App {
    var body: some Scene {
        WindowGroup { VehicleHome() }
    }
}

private struct VehicleHome: View {
    @State private var address = ""
    @State private var token = ""
    @State private var credentials: Credentials?
    @State private var vehicles: [VehicleStatus] = []
    @State private var selectedID = ""
    @State private var loaded = false
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var hasSnapshot = false

    var body: some View {
        NavigationStack {
            Form {
                Section("车况") {
                    if vehicles.count > 1 {
                        Picker("车辆", selection: $selectedID) {
                            ForEach(vehicles) { Text($0.vehicle.name).tag($0.id) }
                        }
                    }
                    if let selected = vehicles.first(where: { $0.id == selectedID }) {
                        if vehicles.count == 1 { Text(selected.vehicle.name).font(.headline) }
                        if !selected.vehicle.available {
                            Text("车辆集成未加载").foregroundStyle(.secondary)
                        }
                        ForEach(Metric.allCases) { metric in
                            LabeledContent(metric.title, value: metric.display(selected.metrics[metric]))
                        }
                        LabeledContent(
                            "HA 实体最后更新",
                            value: selected.lastUpdated?.formatted(date: .abbreviated, time: .shortened) ?? "不可用"
                        )
                    } else {
                        Text(hasSnapshot ? "没有找到零跑车辆，请检查 HA 集成配置。" : "连接 Home Assistant 后显示车况。")
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage {
                    Section("连接提示") { Text(errorMessage).foregroundStyle(.red) }
                }

                Section {
                    TextField("https://ha.example.com", text: $address)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("长期访问令牌", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("连接并保存") { Task { await connect() } }
                    if credentials != nil {
                        Button("清除已保存连接", role: .destructive, action: forget)
                    }
                } header: {
                    Text("Home Assistant")
                } footer: {
                    Text("令牌保存在 iOS 钥匙串。已保存的地址可以留空令牌重新连接。")
                }
                .disabled(busy)
            }
            .navigationTitle("零跑 HA")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if busy {
                        ProgressView().accessibilityLabel("正在连接")
                    } else {
                        Button {
                            Task { await refresh() }
                        } label: {
                            Label("刷新车况", systemImage: "arrow.clockwise")
                        }
                        .disabled(credentials == nil)
                    }
                }
            }
            .refreshable { await refresh() }
            .task {
                guard !loaded else { return }
                loaded = true
                do {
                    credentials = try Credentials.load()
                    address = credentials?.address ?? ""
                    await refresh()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    @MainActor
    private func connect() async {
        let newAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let newToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedToken = credentials?.address == newAddress ? credentials?.token : nil
        await load(Credentials(address: newAddress, token: newToken.isEmpty ? storedToken ?? "" : newToken), save: true)
    }

    @MainActor
    private func refresh() async {
        guard let credentials else { return }
        await load(credentials, save: false)
    }

    @MainActor
    private func load(_ candidate: Credentials, save: Bool) async {
        guard !busy else { return }
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            let endpoint = try HomeAssistant.endpoint(for: candidate.address)
            guard !candidate.token.isEmpty else { throw ConnectionError.missingToken }
            let result = try await HomeAssistant(endpoint: endpoint, token: candidate.token).loadVehicles()
            try Task.checkCancellation()
            if save {
                try candidate.save()
                if credentials?.address != candidate.address { selectedID = "" }
                credentials = candidate
                address = candidate.address
                token = ""
            }
            vehicles = result
            hasSnapshot = true
            if !vehicles.contains(where: { $0.id == selectedID }) {
                selectedID = vehicles.first?.id ?? ""
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func forget() {
        do {
            try Credentials.remove()
            credentials = nil
            token = ""
            address = ""
            vehicles = []
            selectedID = ""
            hasSnapshot = false
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
