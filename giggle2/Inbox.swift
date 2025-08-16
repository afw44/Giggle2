//
//  Realtime.swift
//  giggle2
//
//  Created by Alexander Weiss on 14/08/2025.
//
import Foundation
import Combine

final class Realtime: ObservableObject {
    @Published var isRed: Bool = false
    @Published var connectedGentId: String?

    private var task: URLSessionWebSocketTask?

    func connect(as gentId: String) {
        connectedGentId = gentId
        // Fetch current state once for initial render
        Task { await fetchCurrentState(for: gentId) }

        // Open WS for live updates
        var comps = URLComponents(string: "\(BASE_WS)/ws")!
        comps.queryItems = [URLQueryItem(name: "user_id", value: gentId)]
        guard let url = comps.url else { return }
        task?.cancel()
        let ws = URLSession.shared.webSocketTask(with: url)
        task = ws
        ws.resume()
        receive()
    }

    private func fetchCurrentState(for gentId: String) async {
        guard let url = URL(string: "\(BASE_HTTP)/gent/\(gentId)/state") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let red = obj["red"] as? Bool {
                await MainActor.run { self.isRed = red }
            }
        } catch {
            // ignore for this minimal demo
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let s)):
                if let data = s.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let type = obj["type"] as? String, type == "state",
                   let red = obj["red"] as? Bool {
                    DispatchQueue.main.async { self.isRed = red }
                }
            default: break
            }
            self.receive()
        }
    }
}
