import EventSource
import Foundation
import JSONSchema

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

package enum HTTP {
    package enum Method: String {
        case get = "GET"
        case post = "POST"
    }
}

extension URLSession {
    package func fetch<T: Decodable>(
        _ method: HTTP.Method,
        url: URL,
        headers: [String: String] = [:],
        body: Data? = nil,
        dateDecodingStrategy: JSONDecoder.DateDecodingStrategy = .deferredToDate
    ) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.addValue("application/json", forHTTPHeaderField: "Accept")

        for (key, value) in headers {
            request.addValue(value, forHTTPHeaderField: key)
        }

        if let body {
            request.httpBody = body
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        debugLogRequest(request)

        let (responseData, response): (Data, URLResponse)
        do {
            (responseData, response) = try await self.data(for: request)
        } catch {
            debugLogError(error, request: request)
            throw error
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            debugLogInvalidResponse(response, request: request)
            throw URLSessionError.invalidResponse
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = dateDecodingStrategy

        debugLogResponse(httpResponse, data: responseData, request: request)

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            if let errorString = String(data: responseData, encoding: .utf8) {
                throw URLSessionError.httpError(statusCode: httpResponse.statusCode, detail: errorString)
            }
            throw URLSessionError.httpError(statusCode: httpResponse.statusCode, detail: "Invalid response")
        }

        do {
            return try decoder.decode(T.self, from: responseData)
        } catch {
            throw URLSessionError.decodingError(detail: error.localizedDescription)
        }
    }

    package func fetchStream<T: Decodable & Sendable>(
        _ method: HTTP.Method,
        url: URL,
        headers: [String: String] = [:],
        body: Data? = nil,
        dateDecodingStrategy: JSONDecoder.DateDecodingStrategy = .deferredToDate
    ) -> AsyncThrowingStream<T, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @Sendable in
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = dateDecodingStrategy

                do {
                    var request = URLRequest(url: url)
                    request.httpMethod = method.rawValue
                    request.addValue("application/json", forHTTPHeaderField: "Accept")

                    for (key, value) in headers {
                        request.addValue(value, forHTTPHeaderField: key)
                    }

                    if let body {
                        request.httpBody = body
                        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
                    }

                    debugLogRequest(request)

                    let (responseData, response): (Data, URLResponse)
                    do {
                        (responseData, response) = try await self.data(for: request)
                    } catch {
                        debugLogError(error, request: request)
                        throw error
                    }

                    guard let httpResponse = response as? HTTPURLResponse else {
                        debugLogInvalidResponse(response, request: request)
                        throw URLSessionError.invalidResponse
                    }

                    debugLogResponse(httpResponse, data: responseData, request: request)

                    guard (200 ..< 300).contains(httpResponse.statusCode) else {
                        if let errorString = String(data: responseData, encoding: .utf8) {
                            throw URLSessionError.httpError(statusCode: httpResponse.statusCode, detail: errorString)
                        }
                        throw URLSessionError.httpError(statusCode: httpResponse.statusCode, detail: "Invalid response")
                    }

                    var buffer = responseData

                    while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                        let chunk = buffer[..<newlineIndex]
                        buffer = buffer[buffer.index(after: newlineIndex)...]

                        if !chunk.isEmpty {
                            let decoded = try decoder.decode(T.self, from: chunk)
                            continuation.yield(decoded)
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    package func fetchEventStream<T: Decodable & Sendable>(
        _ method: HTTP.Method,
        url: URL,
        headers: [String: String] = [:],
        body: Data? = nil
    ) -> AsyncThrowingStream<T, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @Sendable in
                do {
                    var request = URLRequest(url: url)
                    request.httpMethod = method.rawValue
                    request.addValue("text/event-stream", forHTTPHeaderField: "Accept")

                    for (key, value) in headers {
                        request.addValue(value, forHTTPHeaderField: key)
                    }

                    if let body {
                        request.httpBody = body
                        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
                    }

                    debugLogRequest(request)

                    #if canImport(FoundationNetworking)
                        let asyncBytes: AsyncThrowingStream<UInt8, Error>
                        let response: URLResponse
                        do {
                            (asyncBytes, response) = try await self.linuxBytes(for: request)
                        } catch {
                            debugLogError(error, request: request)
                            throw error
                        }
                    #else
                        let asyncBytes: URLSession.AsyncBytes
                        let response: URLResponse
                        do {
                            (asyncBytes, response) = try await self.bytes(for: request)
                        } catch {
                            debugLogError(error, request: request)
                            throw error
                        }
                    #endif

                    guard let httpResponse = response as? HTTPURLResponse else {
                        debugLogInvalidResponse(response, request: request)
                        throw URLSessionError.invalidResponse
                    }

                    debugLogResponse(httpResponse, data: nil, request: request)

                    guard (200 ..< 300).contains(httpResponse.statusCode) else {
                        var errorData = Data()
                        for try await byte in asyncBytes {
                            errorData.append(byte)
                        }
                        if let errorString = String(data: errorData, encoding: .utf8) {
                            throw URLSessionError.httpError(statusCode: httpResponse.statusCode, detail: errorString)
                        }
                        throw URLSessionError.httpError(statusCode: httpResponse.statusCode, detail: "Invalid response")
                    }

                    let decoder = JSONDecoder()

                    for try await event in asyncBytes.events {
                        guard let data = event.data.data(using: .utf8) else { continue }
                        if let decoded = try? decoder.decode(T.self, from: data) {
                            continuation.yield(decoded)
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

#if canImport(FoundationNetworking)
    private extension URLSession {
        func linuxBytes(for request: URLRequest) async throws -> (AsyncThrowingStream<UInt8, Error>, URLResponse) {
            let delegate = LinuxBytesDelegate()
            let delegateQueue = OperationQueue()
            delegateQueue.maxConcurrentOperationCount = 1

            let session = URLSession(
                configuration: self.configuration,
                delegate: delegate,
                delegateQueue: delegateQueue
            )

            let byteStream = AsyncThrowingStream<UInt8, Error> { continuation in
                delegate.attach(
                    continuation,
                    session: session
                )
            }

            let response = try await delegate.start(
                request: request,
                session: session
            )

            return (byteStream, response)
        }
    }

    private final class LinuxBytesDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private var responseContinuation: CheckedContinuation<URLResponse, Error>?
        private var byteContinuation: AsyncThrowingStream<UInt8, Error>.Continuation?
        private weak var task: URLSessionDataTask?
        private weak var session: URLSession?

        func attach(
            _ continuation: AsyncThrowingStream<UInt8, Error>.Continuation,
            session: URLSession
        ) {
            byteContinuation = continuation
            self.session = session
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.task?.cancel()
                self.session?.invalidateAndCancel()
            }
        }

        func start(
            request: URLRequest,
            session: URLSession
        ) async throws -> URLResponse {
            try await withCheckedThrowingContinuation { continuation in
                responseContinuation = continuation
                let task = session.dataTask(with: request)
                self.task = task
                task.resume()
            }
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
        ) {
            if let continuation = responseContinuation {
                continuation.resume(returning: response)
                responseContinuation = nil
            }
            completionHandler(.allow)
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive data: Data
        ) {
            guard let continuation = byteContinuation else { return }
            for byte in data {
                continuation.yield(byte)
            }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: (any Error)?
        ) {
            if let continuation = responseContinuation {
                if let error {
                    continuation.resume(throwing: error)
                } else if let response = task.response {
                    continuation.resume(returning: response)
                } else {
                    continuation.resume(throwing: URLSessionError.invalidResponse)
                }
                responseContinuation = nil
            }

            if let error {
                byteContinuation?.finish(throwing: error)
            } else {
                byteContinuation?.finish()
            }
            byteContinuation = nil

            session.invalidateAndCancel()
        }
    }
#endif

enum URLSessionError: Error, CustomStringConvertible {
    case invalidResponse
    case httpError(statusCode: Int, detail: String)
    case decodingError(detail: String)

    var description: String {
        switch self {
        case .invalidResponse:
            return "Invalid response"
        case .httpError(let statusCode, let detail):
            return "HTTP error (Status \(statusCode)): \(detail)"
        case .decodingError(let detail):
            return "Decoding error: \(detail)"
        }
    }
}

private func debugLogRequest(_ request: URLRequest) {
    #if DEBUG
    guard let url = request.url else { return }
    let method = request.httpMethod ?? "GET"
    let headers = debugRedactedHeaders(request.allHTTPHeaderFields ?? [:])
    let bodyCount = request.httpBody?.count ?? 0
    print("[AnyLanguageModel][HTTP] request method=\(method) url=\(url.absoluteString) headers=\(headers) bodyBytes=\(bodyCount)")
    #endif
}

private func debugLogResponse(_ response: HTTPURLResponse, data: Data?, request: URLRequest) {
    #if DEBUG
    let url = request.url?.absoluteString ?? "unknown"
    let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
    let length = data?.count ?? 0
    print("[AnyLanguageModel][HTTP] response url=\(url) status=\(response.statusCode) contentType=\(contentType) bodyBytes=\(length)")
    #endif
}

private func debugLogInvalidResponse(_ response: URLResponse, request: URLRequest) {
    #if DEBUG
    let url = request.url?.absoluteString ?? "unknown"
    print("[AnyLanguageModel][HTTP] invalid response url=\(url) type=\(type(of: response))")
    #endif
}

private func debugLogError(_ error: Error, request: URLRequest) {
    #if DEBUG
    let url = request.url?.absoluteString ?? "unknown"
    print("[AnyLanguageModel][HTTP] error url=\(url) error=\(error)")
    #endif
}

private func debugRedactedHeaders(_ headers: [String: String]) -> [String: String] {
    #if DEBUG
    let sensitiveKeys = [
        "authorization",
        "x-api-key",
        "api-key",
        "x-goog-api-key",
        "anthropic-api-key"
    ]
    var redacted: [String: String] = [:]
    for (key, value) in headers {
        if sensitiveKeys.contains(key.lowercased()) {
            redacted[key] = "<redacted>"
        } else {
            redacted[key] = value
        }
    }
    return redacted
    #else
    return [:]
    #endif
}
