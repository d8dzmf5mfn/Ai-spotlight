import Foundation

/// Auto-detects locally-available AI models. Today this is just Ollama
/// (the dominant local LLM runner on macOS), but the protocol is open
/// so MLX, LM Studio, llama.cpp, etc. can plug in later without
/// changing the UI.
///
/// All methods are async. On a typical Mac, Ollama detection takes
/// <50ms when running, or up to 5s when the host is unreachable
/// (TCP connection refused times out fast on localhost).
public protocol LocalModelDiscovering: Sendable {
    /// Try the given endpoint and return the list of model names. The
    /// URL's host:port is the only thing that matters — the path is
    /// overridden by the implementation (Ollama uses /api/tags, etc.).
    /// Throws on network/parse failure.
    func availableModels(at endpoint: URL) async throws -> [String]
}

public enum DiscoveryError: Error, LocalizedError {
    case httpStatus(Int)
    case invalidResponse
    case unreachable(String)

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let code): return "Server returned HTTP \(code)"
        case .invalidResponse:     return "Response was not in the expected format"
        case .unreachable(let msg): return "Could not reach server: \(msg)"
        }
    }
}

/// Default implementation that talks to a real Ollama server. The
/// Ollama /api/tags endpoint returns a JSON envelope of the form:
///   {"models": [{"name": "gemma2:2b", ...}, ...]}
public final class OllamaDiscovery: LocalModelDiscovering, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func availableModels(at endpoint: URL) async throws -> [String] {
        // Replace any path with the canonical Ollama tags path. Users
        // point at `http://localhost:11434` (root); the implementation
        // takes care of the rest.
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.path = "/api/tags"
        components?.query = nil
        guard let url = components?.url else { throw DiscoveryError.invalidResponse }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw DiscoveryError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw DiscoveryError.httpStatus(http.statusCode)
        }
        let envelope = try JSONDecoder().decode(TagsResponse.self, from: data)
        return envelope.models.map(\.name)
    }

    private struct TagsResponse: Decodable {
        let models: [ModelEntry]
    }
    private struct ModelEntry: Decodable {
        let name: String
    }
}
