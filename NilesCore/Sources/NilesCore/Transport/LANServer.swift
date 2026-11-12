import Foundation
import MCP
import Network
#if os(iOS)
import UIKit
#endif

/// Bonjour identity for the MCP endpoint, advertised only while the listener runs.
public enum NilesBonjour {
    /// The service's base name. The advertised instance qualifies it with the
    /// device name so two Niles instances on one LAN are distinguishable in a
    /// browse — a leftover simulator fixture advertising plain "Niles" once
    /// soaked up a pairing code meant for the real phone.
    public static let baseName = "Niles"
    public static let serviceType = "_niles-mcp._tcp"

    /// Launch arguments that pin screenshot/preview capture fixtures (parsed
    /// alongside these in `Niles/ContentView.swift`).
    static let captureFixtureArguments = [
        "-UIWideLayout", "-UIHomeFixtures", "-UIActivityFixtures",
    ]

    /// True when the app launched with a capture-fixture argument. A capture
    /// instance must never advertise: a fixture visible in a browse as "Niles"
    /// can impersonate a real endpoint and capture pairing codes.
    public static var isCaptureFixture: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return captureFixtureArguments.contains { arguments.contains($0) }
    }

    /// The device-qualified instance name, e.g. `Niles (Matthew's iPhone)`.
    /// Derived from the device's current name, so it stays stable across
    /// relaunches — it only changes if the user renames the device.
    public static var instanceName: String {
        #if os(iOS)
        let deviceName = UIDevice.current.name
        #elseif os(macOS)
        let deviceName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #else
        let deviceName = ""
        #endif
        return deviceName.isEmpty ? baseName : "\(baseName) (\(deviceName))"
    }

    /// The name a LANServer should advertise, or nil for a capture fixture —
    /// fixtures may serve locally but never advertise. This is LANServer's
    /// default, so fixture hygiene holds even if a caller forgets to opt out.
    public static var advertisedInstanceName: String? {
        isCaptureFixture ? nil : instanceName
    }

    /// Discovery keys agents read to use the server without out-of-band
    /// documentation: the MCP endpoint path, the pairing protocol version,
    /// and the code-capable flag (absent on pre-pairing builds).
    static let txtEntries = [
        "mcp": "/mcp",
        "pairing": "v1",
        "code": "1",
    ]

    /// Encodes entries as a NetService TXT record: one length byte followed by
    /// that many bytes of `key=value`, keys sorted so the record is
    /// deterministic (and testable).
    static func txtRecord(_ entries: [String: String]) -> Data {
        var out = Data()
        for (key, value) in entries.sorted(by: { $0.key < $1.key }) {
            let entry = "\(key)=\(value)"
            precondition(entry.utf8.count <= 255, "TXT entry \(entry) exceeds the 255-byte record limit")
            out.append(UInt8(entry.utf8.count))
            out.append(contentsOf: entry.utf8)
        }
        return out
    }

    /// The TXT record advertised with the MCP service.
    static var serviceTXT: Data { txtRecord(txtEntries) }
}

/// Thrown when the server cannot be constructed (e.g. an invalid port).
public enum LANServerError: Error, Equatable {
    case invalidPort(UInt16)
}

/// Accepts LAN connections and serves them through the MCP gateway.
///
/// Owns the `NWListener` and one task per connection. Session, auth, and MCP logic
/// live in the gateway; this layer only moves bytes. Niles serves while the app is
/// foregrounded: `stop()` cancels the listener (which unregisters any advertised
/// service) and closes every connection, so the LAN server's lifetime is exactly
/// the app's visible lifetime.
public actor LANServer {

    public enum State: Sendable, Equatable {
        case idle
        case running(port: UInt16)
        case stopped
        case failed(String)
    }

    /// The fixed port the approved pairing screen advertises (`http://<host>:8901/mcp`).
    public static let defaultPort: UInt16 = 8901

    private let gateway: MCPGateway
    private let pairingService: PairingService?
    private let port: UInt16
    private let bonjourName: String?
    private let bonjourType: String?
    private var listener: NWListener?
    private var connectionRunners: [UUID: HTTPConnectionRunner] = [:]

    public private(set) var state: State = .idle

    public init(
        gateway: MCPGateway,
        pairingService: PairingService? = nil,
        port: UInt16 = LANServer.defaultPort,
        bonjourName: String? = NilesBonjour.advertisedInstanceName,
        bonjourType: String? = NilesBonjour.serviceType
    ) {
        self.gateway = gateway
        self.pairingService = pairingService
        self.port = port
        self.bonjourName = bonjourName
        self.bonjourType = bonjourType
    }

    /// Starts accepting connections. Idempotent while already listening.
    public func start() async throws {
        guard listener == nil else { return }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw LANServerError.invalidPort(port)
        }
        let listener = try NWListener(using: parameters, on: endpointPort)

        // Advertising lives with the listener: cancelling it unregisters the service,
        // so `_niles-mcp._tcp` disappears the moment serving stops. Both a name and
        // a type are required — a nil name (capture fixture) means no registration
        // at all, never a default-named one. The TXT record tells agents where the
        // MCP and pairing endpoints live without out-of-band documentation. The
        // app's Info.plist declares the type in NSBonjourServices (local-network prompt).
        if let bonjourName, let bonjourType {
            listener.service = NWListener.Service(
                name: bonjourName,
                type: bonjourType,
                txtRecord: NilesBonjour.serviceTXT
            )
        }

        listener.stateUpdateHandler = { [weak self] listenerState in
            Task { await self?.listenerStateChanged(listenerState) }
        }
        listener.newConnectionHandler = { [gateway, pairingService] connection in
            let runner = HTTPConnectionRunner(connection: connection, gateway: gateway, pairing: pairingService)
            Task { await self.serve(runner) }
        }

        listener.start(queue: DispatchQueue(label: "com.gerstman.niles.listener"))
        self.listener = listener
        state = .running(port: port)
    }

    /// The sessions currently connected through the gateway, for the app UI.
    public func sessionInfos() async -> [MCPGateway.SessionInfo] {
        await gateway.sessionInfos()
    }

    /// Stops accepting connections, closes every client connection, and tears down
    /// gateway sessions. Idempotent.
    public func stop() async {
        listener?.cancel()
        listener = nil
        for runner in connectionRunners.values {
            runner.cancel()
        }
        connectionRunners.removeAll()
        await gateway.stop()
        state = .stopped
    }

    private func serve(_ runner: HTTPConnectionRunner) async {
        let identifier = UUID()
        connectionRunners[identifier] = runner
        await runner.run()
        connectionRunners.removeValue(forKey: identifier)
    }

    private func listenerStateChanged(_ listenerState: NWListener.State) {
        switch listenerState {
        case .ready:
            state = .running(port: port)
        case .failed(let error):
            // The listener is dead (port conflict, interface gone) — clear it so a
            // later start() can try again, and surface the cause.
            state = .failed(String(describing: error))
            listener = nil
        case .cancelled:
            // A listener that failed then cancelled keeps the failure cause;
            // a normally-cancelled one reports .stopped.
            if case .failed = state {} else { state = .stopped }
        case .waiting:
            break  // transient (e.g. interface selection); the listener recovers on its own
        case .setup:
            break
        @unknown default:
            break
        }
    }
}
