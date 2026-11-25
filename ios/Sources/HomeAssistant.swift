import Foundation

struct Vehicle: Decodable, Identifiable {
    let entryID: String
    let deviceID: String
    let name: String
    let available: Bool

    var id: String { entryID }

    enum CodingKeys: String, CodingKey {
        case entryID = "entry_id"
        case deviceID = "device_id"
        case name, available
    }
}

enum Metric: String, CaseIterable, Identifiable {
    case battery, range, chargingState = "charging_state"

    var id: Self { self }

    var title: String {
        switch self {
        case .battery: return "电量"
        case .range: return "剩余续航"
        case .chargingState: return "充电状态"
        }
    }

    func display(_ state: EntityState?) -> String {
        guard let state, !["unknown", "unavailable"].contains(state.value) else {
            return "不可用"
        }
        switch self {
        case .chargingState:
            switch state.value {
            case "charging": return "充电中"
            case "plugged": return "已插枪"
            case "unplugged": return "未插枪"
            default: return "未知"
            }
        case .battery, .range:
            return [state.value, state.attributes.unit].compactMap { $0 }.joined(separator: " ")
        }
    }
}

struct EntityState: Decodable {
    struct Attributes: Decodable {
        let unit: String?

        enum CodingKeys: String, CodingKey {
            case unit = "unit_of_measurement"
        }
    }

    let entityID: String
    let value: String
    let attributes: Attributes
    let lastUpdated: String

    var updatedAt: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions.insert(.withFractionalSeconds)
        if let date = formatter.date(from: lastUpdated) { return date }
        formatter.formatOptions.remove(.withFractionalSeconds)
        return formatter.date(from: lastUpdated)
    }

    enum CodingKeys: String, CodingKey {
        case entityID = "entity_id"
        case value = "state"
        case attributes
        case lastUpdated = "last_updated"
    }
}

struct VehicleStatus: Identifiable {
    let vehicle: Vehicle
    let metrics: [Metric: EntityState]

    var id: String { vehicle.id }
    var lastUpdated: Date? { metrics.values.compactMap(\.updatedAt).max() }
}

struct HomeAssistant {
    let endpoint: URL
    let token: String

    static func endpoint(for address: String) throws -> URL {
        guard var url = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else {
            throw ConnectionError.invalidAddress
        }
        url.scheme = "wss"
        url.path = "/api/websocket"
        guard let endpoint = url.url else { throw ConnectionError.invalidAddress }
        return endpoint
    }

    func loadVehicles() async throws -> [VehicleStatus] {
        // An ephemeral session avoids persisting cookies or credentials from the HA connection.
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
        let socket = session.webSocketTask(with: endpoint)
        socket.maximumMessageSize = 16 * 1024 * 1024
        defer {
            socket.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }
        socket.resume()
        return try await withThrowingTaskGroup(of: [VehicleStatus].self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await readVehicles(from: socket)
                } onCancel: {
                    socket.cancel(with: .goingAway, reason: nil)
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(20))
                throw ConnectionError.timeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw ConnectionError.protocolError }
            return result
        }
    }

    private func readVehicles(from socket: URLSessionWebSocketTask) async throws -> [VehicleStatus] {
        let hello = try await receive(Header.self, from: socket)
        guard hello.type == "auth_required" else { throw ConnectionError.protocolError }
        try await send(["type": "auth", "access_token": token], to: socket)
        let auth = try await receive(Header.self, from: socket)
        if auth.type == "auth_invalid" { throw ConnectionError.authentication }
        guard auth.type == "auth_ok" else { throw ConnectionError.protocolError }

        let list = try await command("leapmotor/vehicles/list", id: 1, as: VehicleList.self, on: socket)
        guard !list.vehicles.isEmpty else { return [] }
        let registry = try await command(
            "config/entity_registry/list", id: 2, as: [RegistryEntity].self, on: socket
        )
        let states = try await command("get_states", id: 3, as: [EntityState].self, on: socket)
        let byID = Dictionary(states.map { ($0.entityID, $0) }, uniquingKeysWith: { first, _ in first })

        return list.vehicles.map { vehicle in
            var metrics: [Metric: EntityState] = [:]
            if vehicle.available, !vehicle.deviceID.isEmpty {
                for entry in registry where entry.platform == "leapmotor" && entry.deviceID == vehicle.deviceID {
                    guard entry.entityID.hasPrefix("sensor."),
                          let metric = entry.metric,
                          let state = byID[entry.entityID] else { continue }
                    metrics[metric] = state
                }
            }
            return VehicleStatus(vehicle: vehicle, metrics: metrics)
        }
    }

    private func command<T: Decodable>(
        _ type: String, id: Int, as _: T.Type, on socket: URLSessionWebSocketTask
    ) async throws -> T {
        try await send(["id": id, "type": type], to: socket)
        let reply = try await receive(Reply<T>.self, from: socket)
        guard reply.type == "result", reply.id == id else { throw ConnectionError.protocolError }
        guard reply.success, let result = reply.result else {
            throw ConnectionError.commandFailed(type, reply.error?.code)
        }
        return result
    }

    private func send(_ body: [String: Any], to socket: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: body)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func receive<T: Decodable>(_ type: T.Type, from socket: URLSessionWebSocketTask) async throws -> T {
        let data: Data
        switch try await socket.receive() {
        case .string(let text): data = Data(text.utf8)
        case .data(let bytes): data = bytes
        @unknown default: throw ConnectionError.protocolError
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch is DecodingError {
            throw ConnectionError.protocolError
        }
    }

    private struct Header: Decodable { let type: String }
    private struct VehicleList: Decodable { let vehicles: [Vehicle] }
    private struct Reply<T: Decodable>: Decodable {
        struct Failure: Decodable { let code: String }
        let type: String
        let id: Int
        let success: Bool
        let result: T?
        let error: Failure?
    }

    private struct RegistryEntity: Decodable {
        let entityID: String
        let deviceID: String?
        let platform: String
        let translationKey: String?
        let uniqueID: String?

        var metric: Metric? {
            if let translationKey, let metric = Metric(rawValue: translationKey) { return metric }
            return Metric.allCases.first { uniqueID?.hasSuffix("_" + $0.rawValue) == true }
        }

        enum CodingKeys: String, CodingKey {
            case entityID = "entity_id"
            case deviceID = "device_id"
            case platform
            case translationKey = "translation_key"
            case uniqueID = "unique_id"
        }
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

enum ConnectionError: LocalizedError {
    case invalidAddress, missingToken, authentication, protocolError, timeout
    case commandFailed(String, String?)

    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "请输入 Home Assistant 的 HTTPS 根地址，例如 https://ha.example.com。"
        case .missingToken: return "请输入 Home Assistant 长期访问令牌。"
        case .authentication: return "Home Assistant 拒绝了访问令牌，请检查令牌是否正确或已撤销。"
        case .protocolError: return "Home Assistant 返回了无法识别的响应。"
        case .timeout: return "连接 Home Assistant 超时。"
        case let .commandFailed(command, code):
            return "Home Assistant 请求失败：\(command)（\(code ?? "无错误代码")）。"
        }
    }
}
