import Foundation
import Synchronization

/// Serves canned responses to the catalog installer, so its tests run the real URLSession
/// delegate (redirect refusal, chunked bodies, cancellation) without reaching the network.
///
/// Routes are keyed by absolute URL. Each test uses its own repository name, so tests that
/// run in parallel never share a route.
final class FixtureURLProtocol: URLProtocol {
  enum Route: Sendable {
    /// A 200 whose body arrives in chunks. `declaresLength` sends a `Content-Length` header.
    case body(Data, declaresLength: Bool = true)
    /// A 200 that sends its first chunk and then never finishes, until the task is cancelled.
    case stall(first: Data)
    case redirect(to: URL)
    case status(Int)
  }

  private static let routes = Mutex<[String: Route]>([:])
  private static let started = Mutex<Set<String>>([])
  private static let stopped = Mutex<Set<String>>([])

  static func serve(_ route: Route, at url: URL) {
    routes.withLock { $0[url.absoluteString] = route }
  }

  static func wasStarted(_ url: URL) -> Bool { started.withLock { $0.contains(url.absoluteString) } }
  static func wasStopped(_ url: URL) -> Bool { stopped.withLock { $0.contains(url.absoluteString) } }

  static func configuration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FixtureURLProtocol.self]
    return configuration
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url, let route = Self.routes.withLock({ $0[url.absoluteString] }) else {
      client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
      return
    }
    _ = Self.started.withLock { $0.insert(url.absoluteString) }
    switch route {
    case let .body(data, declaresLength):
      let headers = declaresLength ? ["Content-Length": "\(data.count)"] : [:]
      respond(url, status: 200, headers: headers)
      let chunk = 1 << 20
      for offset in stride(from: 0, to: data.count, by: chunk) {
        client?.urlProtocol(self, didLoad: data.subdata(in: offset..<min(offset + chunk, data.count)))
      }
      client?.urlProtocolDidFinishLoading(self)
    case let .stall(first):
      respond(url, status: 200, headers: [:])
      client?.urlProtocol(self, didLoad: first)
    case let .redirect(target):
      let response = HTTPURLResponse(
        url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
      client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
    case let .status(code):
      respond(url, status: code, headers: [:])
      client?.urlProtocolDidFinishLoading(self)
    }
  }

  override func stopLoading() {
    guard let url = request.url else { return }
    _ = Self.stopped.withLock { $0.insert(url.absoluteString) }
  }

  private func respond(_ url: URL, status: Int, headers: [String: String]) {
    let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
  }
}
