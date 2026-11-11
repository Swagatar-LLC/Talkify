import Foundation

/// One HTTPS fetch for the installer: the response, then the body in the chunks it arrives in.
///
/// Built on a data task with its own delegate rather than `URLSession.bytes`, because the
/// delegate is the only place a redirect can be refused before it is followed, and because
/// chunks hash far faster than a byte-at-a-time sequence over 600 MB.
enum CatalogFetch {
  enum Event: Sendable {
    case response(HTTPURLResponse)
    case data(Data)
  }

  /// A fresh session per fetch, with no cache and no cookies, so nothing Talkify downloads
  /// leaves a copy outside the model folder and no request carries state from another.
  static func liveConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    return configuration
  }

  /// The request starts at once. Ending the iteration early, or cancelling the task that
  /// iterates, cancels it.
  static func events(
    for url: URL,
    configuration: URLSessionConfiguration,
    allowRedirect: @escaping @Sendable (URL) -> Bool
  ) -> AsyncThrowingStream<Event, any Error> {
    AsyncThrowingStream { continuation in
      let delegate = Delegate(continuation: continuation, allowRedirect: allowRedirect)
      let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
      let task = session.dataTask(with: URLRequest(url: url))
      continuation.onTermination = { _ in
        task.cancel()
        // The session holds its delegate strongly until it is invalidated.
        session.invalidateAndCancel()
      }
      task.resume()
    }
  }

  /// Every stored property is an immutable `Sendable` value, so sharing it with the
  /// session's delegate queue is safe; `NSObject` only stops the compiler proving it.
  private final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let continuation: AsyncThrowingStream<Event, any Error>.Continuation
    let allowRedirect: @Sendable (URL) -> Bool

    init(
      continuation: AsyncThrowingStream<Event, any Error>.Continuation,
      allowRedirect: @escaping @Sendable (URL) -> Bool
    ) {
      self.continuation = continuation
      self.allowRedirect = allowRedirect
    }

    func urlSession(
      _ session: URLSession,
      task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse,
      newRequest request: URLRequest,
      completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
      guard let target = request.url, allowRedirect(target) else {
        // Finish first, so the cancellation that follows cannot report itself instead.
        continuation.finish(throwing: CatalogInstallError.redirectRefused(request.url))
        completionHandler(nil)
        task.cancel()
        return
      }
      completionHandler(request)
    }

    func urlSession(
      _ session: URLSession,
      dataTask: URLSessionDataTask,
      didReceive response: URLResponse,
      completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
      guard let http = response as? HTTPURLResponse else {
        continuation.finish(throwing: URLError(.badServerResponse))
        completionHandler(.cancel)
        return
      }
      continuation.yield(.response(http))
      completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
      continuation.yield(.data(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
      continuation.finish(throwing: error)
    }
  }
}
