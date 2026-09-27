import Foundation
import XCTest
@testable import CinevaCacheValidation

final class ArtworkByteReceiverTests: XCTestCase {
  private func receive(_ path: String, limit: Int = 4096) async throws -> Data {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ArtworkResponseProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    return try await ArtworkByteReceiver.receive(URLRequest(url: URL(string: "https://artwork.invalid/\(path)")!), session: session, limit: limit)
  }
  func testRejectsDeclaredOversizeBeforeBody() async {
    do { _ = try await receive("declared"); XCTFail("Accepted oversized Content-Length") } catch {}
  }
  func testRejectsUnknownLengthBodyAtByteBudget() async {
    do { _ = try await receive("chunked"); XCTFail("Accepted oversized streamed body") } catch {}
  }
  func testRejectsHTMLAndHTTPError() async {
    for path in ["html", "error"] {
      do { _ = try await receive(path); XCTFail("Accepted \(path)") } catch {}
    }
  }
  func testAcceptsBoundedImageResponse() async throws {
    let data = try await receive("image")
    XCTAssertEqual(data.count, 1024)
  }
  func testCancelledConsumerStopsReceiving() async {
    let task = Task { try await self.receive("chunked", limit: 16_000_000) }
    task.cancel()
    do { _ = try await task.value; XCTFail("Cancelled read succeeded") } catch {}
  }
}

private final class ArtworkResponseProtocol: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "artwork.invalid" }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let path = request.url!.lastPathComponent
    var headers = ["Content-Type": path == "html" ? "text/html" : "image/jpeg"]
    if path == "declared" { headers["Content-Length"] = "16000001" }
    let response = HTTPURLResponse(url: request.url!, statusCode: path == "error" ? 403 : 200,
      httpVersion: "HTTP/1.1", headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(repeating: 42, count: path == "chunked" ? 8192 : 1024))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
