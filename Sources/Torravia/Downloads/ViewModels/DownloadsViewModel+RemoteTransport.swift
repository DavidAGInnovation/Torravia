import Foundation
import Network

@MainActor
extension DownloadsViewModel {
    func startRemoteControl() {
        let host: NWEndpoint.Host = remoteAllowsLAN ? .ipv4(.any) : "127.0.0.1"
        let port = NWEndpoint.Port(rawValue: UInt16(min(max(remotePort, 1024), 65535)))!
        do {
            let useHTTPS = preferences.remoteControlUsesHTTPS
            let scheme = useHTTPS ? "https" : "http"
            let hostname = useHTTPS && remoteAllowsLAN
                ? try RemoteTLSConfiguration.hostname(preferences.remoteControlHostname) : nil
            let parameters = try RemoteTLSConfiguration.parameters(useHTTPS: useHTTPS, identity: preferences.remoteControlTLSIdentity)
            // Completed HTTP connections can keep this port in TIME_WAIT.
            // Allow certificate/transport changes to restart on the same port.
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: host, port: port)
            let listener = try NWListener(using: parameters)
            remoteListener = listener
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor [weak self, weak listener] in
                    guard let self, let listener, self.remoteListener === listener else { return }
                    switch state {
                    case .ready:
                        guard let port = listener.port else { return }
                        self.remoteControlError = nil
                        self.remoteControlURL = URL(string: "\(scheme)://127.0.0.1:\(port)/")
                        self.remoteControlLANURLs = self.remoteAllowsLAN
                            ? RemoteNetworkAddresses.ipv4().compactMap { URL(string: "\(scheme)://\($0):\(port)/") } : []
                        if let hostname, let url = URL(string: "\(scheme)://\(hostname):\(port)/") {
                            self.remoteControlLANURLs.insert(url, at: 0)
                        }
                    case .failed(let error):
                        self.remoteControlError = "Browser control could not start: \(error.localizedDescription). Try another port."
                        self.remoteControlURL = nil; self.remoteControlLANURLs = []
                        listener.cancel()
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                Task { @MainActor [weak self, weak listener] in
                    guard let self, let listener, self.remoteListener === listener,
                          self.remoteConnections.count < 32 else { connection.cancel(); return }
                    let key = ObjectIdentifier(connection)
                    self.remoteConnections[key] = connection
                    connection.stateUpdateHandler = { [weak self] state in
                        if case .cancelled = state {
                            Task { @MainActor [weak self] in self?.remoteConnections.removeValue(forKey: key) }
                        }
                    }
                    RemoteRequestReader(connection: connection) { [weak self] result in
                        Task { @MainActor [weak self] in
                            guard let self, self.remoteListener === listener else { connection.cancel(); return }
                            switch result {
                            case .failure(let error):
                                self.sendRemoteResponse(status: "400 Bad Request", contentType: "text/plain", body: error.localizedDescription, connection: connection)
                            case .success(let request):
                                var hosts: Set<String> = ["127.0.0.1", "localhost"]
                                if self.remoteAllowsLAN { hosts.formUnion(RemoteNetworkAddresses.ipv4()) }
                                if let hostname { hosts.insert(hostname) }
                                guard request.isTrusted(hosts: hosts, port: Int(listener.port?.rawValue ?? 0), scheme: scheme), let raw = request.rawString else {
                                    self.sendRemoteResponse(status: "403 Forbidden", contentType: "text/plain", body: "Host or origin is not allowed", connection: connection)
                                    return
                                }
                                await self.handleRemoteRequest(raw, connection: connection)
                            }
                        }
                    }.start()
                }
            }
            listener.start(queue: DispatchQueue(label: "Torravia.RemoteListener"))
        } catch {
            remoteControlURL = nil
            remoteControlLANURLs = []
            remoteControlError = "Browser control could not start: \(error.localizedDescription)"
        }
    }
}
