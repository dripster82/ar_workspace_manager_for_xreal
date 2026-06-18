import AppKit
import Foundation
import Network
import Security

extension CharacterSet {
    /// Characters allowed unescaped in an x-www-form-urlencoded value.
    static let formValueAllowed = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}

/// Slack secrets, stored in the shared single-item SecretStore (keys prefixed "slack.").
enum SlackKeychain {
    static func set(_ value: String?, for key: String) { SecretStore.set("slack.\(key)", value) }
    static func get(_ key: String) -> String? { SecretStore.get("slack.\(key)") }
}

/// Opens the system browser for an OAuth authorize URL and catches the redirect on a one-shot
/// localhost HTTP listener, returning the callback's query parameters (e.g. code, state).
@MainActor
final class LoopbackOAuth {
    private var listener: NWListener?
    private var finished = false

    func authorize(_ url: URL, port: UInt16) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { cont in
            do {
                let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
                self.listener = listener
                listener.newConnectionHandler = { [weak self] conn in
                    conn.start(queue: .main)
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                        guard let self, !self.finished,
                              let data, let text = String(data: data, encoding: .utf8),
                              let requestLine = text.split(separator: "\r\n").first else { return }
                        let parts = requestLine.split(separator: " ")
                        guard parts.count >= 2,
                              let comps = URLComponents(string: "http://localhost\(parts[1])") else { return }
                        var params: [String: String] = [:]
                        comps.queryItems?.forEach { params[$0.name] = $0.value }

                        let body = """
                        <html><body style="font-family:-apple-system;text-align:center;padding-top:80px;background:#1a1a1a;color:#eee">
                        <h2>VR Desktop is connected to Slack</h2><p>You can close this tab.</p></body></html>
                        """
                        let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
                            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                        conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in
                            conn.cancel()
                        })
                        self.finished = true
                        self.listener?.cancel()
                        self.listener = nil
                        cont.resume(returning: params)
                    }
                }
                listener.start(queue: .main)
                NSWorkspace.shared.open(url)
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}
