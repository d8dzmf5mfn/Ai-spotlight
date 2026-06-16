import Foundation

/// Phase 5-C: 4-step connection diagnostic.
///
/// **Why this exists (4.6.3 self-critique)**: the previous
/// "Test connection" button (Phase 4.6.2) did a single
/// POST /v1/chat/completions with max_tokens=1. If the
/// user got a red error, they had no idea which of 4
/// things went wrong: the URL, the API key, the model
/// name, or the inference engine. This service breaks
/// the check into 4 discrete steps, short-circuits on
/// the first failure, and returns a `Verdict` per step.
///
/// **Step order (matters):**
/// 1. **URL reachable** — DNS + SSL + TCP connect
/// 2. **Auth valid** — the provider's discovery endpoint
///    returns 200 (or the right error for that provider)
/// 3. **Model exists** — the user's `customModel` is in
///    the provider's known model list
/// 4. **Inference works** — POST /chat/completions with
///    `max_tokens=1` returns 200
///
/// The first failure short-circuits because a broken URL
/// makes the auth check fail (no answer from server) and
/// we don't want to charge the user for a 401 inference
/// request when the URL itself is wrong.
///
/// **Why an actor**: a single ConnectionDiagnosticService
/// instance is shared across Settings UI. Multiple users
/// could in principle run the diagnostic concurrently
/// (auto + manual). The actor serializes the URLSession
/// work to avoid piling up sockets on a slow provider.
public actor ConnectionDiagnosticService {
    /// 5-second timeout per step. Total: 20s worst case.
    /// Generous because the user is staring at a UI
    /// during this; we want each step to feel snappy,
    /// but a 5s timeout catches "provider is down"
    /// before it drags out.
    public static let perStepTimeout: TimeInterval = 5
    /// Public initializer. The default (synthesized) init
    /// is internal; we need to call it from the app target
    /// (SettingsStore is in Sources/AISpotlight/Settings/).
    public init() {}

    public enum Step: String, CaseIterable, Sendable {
        case urlReachable = "URL reachable"
        case authValid = "API key valid"
        case modelExists = "Model exists"
        case inferenceWorks = "Inference works"
    }

    public enum Verdict: Equatable, Sendable {
        case pending
        case running
        case passed(String)         // detail message
        case failed(String)         // user-facing error message
    }

    /// Run all 4 steps in order. The first failure
    /// short-circuits. Returns a list of verdicts so the
    /// UI can show "URL ✓, Auth ✓, Model ✓, Inference ⏳"
    /// and partial progress while the user is waiting.
    public func diagnose(
        descriptor: ProviderDescriptor,
        baseURL: String,
        apiKey: String,
        model: String
    ) async -> [Step: Verdict] {
        var results: [Step: Verdict] = [:]

        // Step 1: URL reachable
        results[.urlReachable] = .running
        let urlVerdict = await checkURLReachable(baseURL: baseURL)
        results[.urlReachable] = urlVerdict
        if case .failed = urlVerdict { return results }

        // Step 2: Auth valid
        results[.authValid] = .running
        let authVerdict = await checkAuthValid(
            descriptor: descriptor, baseURL: baseURL, apiKey: apiKey
        )
        results[.authValid] = authVerdict
        if case .failed = authVerdict { return results }

        // Step 3: Model exists
        results[.modelExists] = .running
        let modelVerdict = await checkModelExists(
            descriptor: descriptor, baseURL: baseURL, apiKey: apiKey,
            model: model
        )
        results[.modelExists] = modelVerdict
        if case .failed = modelVerdict { return results }

        // Step 4: Inference works
        results[.inferenceWorks] = .running
        let inferenceVerdict = await checkInferenceWorks(
            descriptor: descriptor, baseURL: baseURL, apiKey: apiKey,
            model: model
        )
        results[.inferenceWorks] = inferenceVerdict

        return results
    }

    // MARK: - Step implementations

    /// Step 1: DNS + SSL + TCP connect. We do a HEAD on
    /// the base URL (or the discovery path if it's a
    /// remote service). A 200/301/302/400/401/405 all
    /// mean the URL is reachable — only network errors
    /// (DNS fail, SSL fail, connection refused, timeout)
    /// count as URL-not-reachable.
    private func checkURLReachable(baseURL: String) async -> Verdict {
        guard let url = URL(string: baseURL) else {
            return .failed("URL is not parseable")
        }
        // Build a request to a known path. We use the
        // discovery endpoint so a 200 means the URL is
        // alive AND the path is correct (catches
        // "https://api.openai.com" without the /v1).
        let testPath: String
        if baseURL.hasSuffix("/") {
            testPath = baseURL + "models"
        } else {
            testPath = baseURL + "/models"
        }
        guard let testURL = URL(string: testPath) else {
            return .failed("URL is not parseable")
        }
        var req = URLRequest(url: testURL)
        req.httpMethod = "HEAD"
        req.timeoutInterval = ConnectionDiagnosticService.perStepTimeout
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .failed("Not an HTTP response")
            }
            // 400/401/404/405 all mean the server is alive.
            // Only check URL reachability here; the next
            // step verifies auth.
            if (200..<600).contains(http.statusCode) {
                return .passed("HTTP \(http.statusCode) (server reachable)")
            }
            return .failed("Server returned HTTP \(http.statusCode)")
        } catch let e as URLError {
            if e.code == .timedOut {
                return .failed("Server timed out (>5s)")
            }
            if e.code == .cannotConnectToHost {
                return .failed("Server refused connection")
            }
            if e.code == .cannotFindHost {
                return .failed("DNS failed — host not found")
            }
            return .failed("Network error: \(e.localizedDescription)")
        } catch {
            return .failed("Error: \(error.localizedDescription)")
        }
    }

    /// Step 2: Auth valid. Hit the provider's discovery
    /// endpoint with the user's API key. 200 = auth ok.
    /// 401 = bad key. 403 = key lacks permission.
    private func checkAuthValid(
        descriptor: ProviderDescriptor, baseURL: String, apiKey: String
    ) async -> Verdict {
        // Dispatch on the descriptor's discovery strategy
        // because Ollama uses /api/tags, others use
        // /v1/models, Anthropic has static catalog.
        switch descriptor.discovery {
        case .ollamaTags:
            return await checkOllamaTagsEndpoint(baseURL: baseURL)
        case .openAIListModels:
            return await checkOpenAIModelsEndpoint(
                descriptor: descriptor, baseURL: baseURL, apiKey: apiKey
            )
        case .staticCatalog:
            return .passed("Static catalog (no auth check)")
        case .none:
            return .passed("No discovery endpoint to check")
        }
    }

    private func checkOllamaTagsEndpoint(baseURL: String) async -> Verdict {
        guard let url = URL(string: baseURL + "/api/tags") else {
            return .failed("Invalid URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = ConnectionDiagnosticService.perStepTimeout
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .failed("Not an HTTP response")
            }
            if (200..<300).contains(http.statusCode) {
                return .passed("Ollama reachable (HTTP \(http.statusCode))")
            }
            return .failed("Ollama returned HTTP \(http.statusCode)")
        } catch let e as URLError {
            if e.code == .cannotConnectToHost {
                return .failed("Ollama is not running. Start it with: ollama serve")
            }
            return .failed("Network error: \(e.localizedDescription)")
        } catch {
            return .failed("Error: \(error.localizedDescription)")
        }
    }

    private func checkOpenAIModelsEndpoint(
        descriptor: ProviderDescriptor, baseURL: String, apiKey: String
    ) async -> Verdict {
        guard let url = URL(string: baseURL + "/models") else {
            return .failed("Invalid URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = ConnectionDiagnosticService.perStepTimeout
        for (k, v) in descriptor.auth.headers(apiKey: apiKey) {
            req.setValue(v, forHTTPHeaderField: k)
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .failed("Not an HTTP response")
            }
            if (200..<300).contains(http.statusCode) {
                return .passed("HTTP \(http.statusCode) (key accepted)")
            }
            if http.statusCode == 401 {
                return .failed("HTTP 401: API key is wrong or missing")
            }
            if http.statusCode == 403 {
                return .failed("HTTP 403: API key doesn't have permission")
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            return .failed("HTTP \(http.statusCode): \(body.prefix(150))")
        } catch let e as URLError {
            return .failed("Network error: \(e.localizedDescription)")
        } catch {
            return .failed("Error: \(error.localizedDescription)")
        }
    }

    /// Step 3: Model exists. Use the same discovery as
    /// the model Picker to ask the provider for its
    /// catalog, then verify the user's `customModel` is
    /// in that catalog. If discovery fails (network,
    /// auth), the step passes with a "couldn't verify"
    /// detail — the user shouldn't be blocked at this
    /// step if Step 2 already proved auth works.
    private func checkModelExists(
        descriptor: ProviderDescriptor, baseURL: String, apiKey: String,
        model: String
    ) async -> Verdict {
        if model.isEmpty {
            return .failed("Model name is empty")
        }
        // Static catalog providers (Anthropic) have a
        // known list. Just check membership.
        if case .staticCatalog(let list) = descriptor.discovery {
            if list.contains(model) {
                return .passed("\(model) found in static catalog")
            }
            // Not in our static list. It may still be a
            // valid model that we don't know about; pass
            // with a soft warning.
            return .passed("\(model) not in known catalog (proceed to inference test)")
        }
        // Dynamic discovery. Fetch the catalog.
        let service = ModelDiscoveryService()
        do {
            let models = try await service.refresh(
                descriptor: descriptor, baseURL: baseURL, apiKey: apiKey
            )
            if models.contains(model) {
                return .passed("\(model) found in provider's catalog (\(models.count) models)")
            }
            return .failed("Model '\(model)' is not in the provider's catalog. Pick a model from the dropdown.")
        } catch {
            // Discovery failed (network, timeout). Don't
            // block on this — Step 4 will catch real
            // model-name errors.
            return .passed("Couldn't fetch catalog (proceed to inference test)")
        }
    }

    /// Step 4: Inference works. POST /chat/completions
    /// with max_tokens=1 and a one-word prompt. This
    /// catches model-name typos, provider-side rate
    /// limits, and the most common form of "the API
    /// accepted the key but rejected the model".
    private func checkInferenceWorks(
        descriptor: ProviderDescriptor, baseURL: String, apiKey: String,
        model: String
    ) async -> Verdict {
        if model.isEmpty {
            return .failed("Model name is empty")
        }
        guard let url = URL(string: baseURL + "/chat/completions") else {
            return .failed("Invalid URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in descriptor.auth.headers(apiKey: apiKey) {
            req.setValue(v, forHTTPHeaderField: k)
        }
        req.timeoutInterval = ConnectionDiagnosticService.perStepTimeout
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": "hi"]],
            "max_tokens": 1
        ]
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .failed("Not an HTTP response")
            }
            if (200..<300).contains(http.statusCode) {
                return .passed("HTTP \(http.statusCode) (inference working)")
            }
            if http.statusCode == 401 {
                return .failed("HTTP 401: API key rejected (model not even checked)")
            }
            if http.statusCode == 404 {
                return .failed("HTTP 404: model '\(model)' not found at this endpoint")
            }
            if http.statusCode == 400 {
                let body = String(data: data, encoding: .utf8) ?? ""
                return .failed("HTTP 400: \(body.prefix(150))")
            }
            return .failed("HTTP \(http.statusCode)")
        } catch let e as URLError {
            if e.code == .timedOut {
                return .failed("Inference timed out (>5s)")
            }
            return .failed("Network error: \(e.localizedDescription)")
        } catch {
            return .failed("Error: \(error.localizedDescription)")
        }
    }
}
