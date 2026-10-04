import Foundation
import Darwin
import XCTest
@testable import CinevaCacheValidation

final class ArtworkByteReceiverTests: XCTestCase {
  private func receive(_ path: String, limit: Int = 4096, probe:ArtworkProtocolProbe? = nil) async throws -> Data {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ArtworkResponseProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let request=NSMutableURLRequest(url:URL(string:"https://artwork.invalid/\(path)")!)
    if let probe { URLProtocol.setProperty(probe,forKey:"probe",in:request) }
    return try await ArtworkByteReceiver.receive(request as URLRequest, session: session, limit: limit)
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
  func testChunkedImageKeepsByteOrderAtExactLimit() async throws {
    let count=1048576+137, started=ProcessInfo.processInfo.systemUptime
    let data=try await receive("large-chunks",limit:count)
    let elapsed=(ProcessInfo.processInfo.systemUptime-started)*1000
    XCTAssertEqual(data.count,count)
    XCTAssertTrue(data.enumerated().allSatisfy { $0.element==UInt8($0.offset%251) })
    print(String(format:"ARTWORK_RECEIVE chunked_bytes=%d elapsed_ms=%.3f",count,
      elapsed))
  }
  func testChunkReceiverBeforeAfterMicrobenchmark() async throws {
    let configuration=URLSessionConfiguration.ephemeral
    configuration.protocolClasses=[ArtworkResponseProtocol.self]
    let session=URLSession(configuration:configuration)
    defer { session.invalidateAndCancel() }
    let request=URLRequest(url:URL(string:"https://artwork.invalid/large-chunks")!)
    let count=ArtworkResponseProtocol.largePayload.count // Initialize fixture outside the clock.
    var oldElapsed:[Double]=[],newElapsed:[Double]=[],oldCPU:[Double]=[],newCPU:[Double]=[]
    for round in 0..<3 {
      for legacy in round%2==0 ? [true,false] : [false,true] {
        let cpuStarted=clock(),started=ProcessInfo.processInfo.systemUptime
        let data:Data
        if legacy { data=try await LegacyArtworkByteReceiver.receive(request,session:session,limit:count) }
        else { data=try await ArtworkByteReceiver.receive(request,session:session,limit:count) }
        let elapsed=(ProcessInfo.processInfo.systemUptime-started)*1000
        let cpu=Double(clock()-cpuStarted)/Double(CLOCKS_PER_SEC)*1000
        // Stop both clocks before asserting payload size and byte integrity.
        XCTAssertEqual(data.count,count)
        XCTAssertEqual(data,ArtworkResponseProtocol.largePayload)
        if legacy { oldElapsed.append(elapsed); oldCPU.append(cpu) }
        else { newElapsed.append(elapsed); newCPU.append(cpu) }
      }
    }
    func median(_ values:[Double])->Double { values.sorted()[values.count/2] }
    print(String(format:"ARTWORK_RECEIVE_BENCH baseline=db4cdc3 bytes=%d n=3 legacy_median_ms=%.3f chunk_median_ms=%.3f legacy_process_cpu_ms=%.3f chunk_process_cpu_ms=%.3f includes=URLProtocol_not_CDN",
      count,median(oldElapsed),median(newElapsed),median(oldCPU),median(newCPU)))
  }
  func testMultiChunkOverflowIsRejected() async {
    do { _=try await receive("large-chunks",limit:65536); XCTFail("Accepted multi-chunk overflow") }
    catch { XCTAssertEqual((error as? URLError)?.code,.dataLengthExceedsMaximum) }
  }
  func testCancellationDuringTransferStopsUnderlyingTask() async {
    let probe=ArtworkProtocolProbe()
    let task=Task { try await self.receive("slow",limit:16_000_000,probe:probe) }
    var started=false
    for _ in 0..<200 {
      if probe.started.wait(timeout:.now()) == .success { started=true; break }
      try? await Task.sleep(nanoseconds:5_000_000)
    }
    XCTAssertTrue(started,"Fixture started the actual response")
    task.cancel()
    do { _=try await task.value; XCTFail("Cancelled transfer succeeded") } catch {}
    XCTAssertEqual(probe.stopped.wait(timeout:.now()+1),.success)
  }
  func testCancelledConsumerStopsReceiving() async {
    let task = Task { try await self.receive("chunked", limit: 16_000_000) }
    task.cancel()
    do { _ = try await task.value; XCTFail("Cancelled read succeeded") } catch {}
  }
}

private final class ArtworkProtocolProbe: @unchecked Sendable {
  let started=DispatchSemaphore(value:0),stopped=DispatchSemaphore(value:0)
}

private final class ArtworkResponseProtocol: URLProtocol, @unchecked Sendable {
  static let largePayload=Data((0..<(1048576+137)).map { UInt8($0%251) })
  private let lock=NSLock()
  private var cancelled=false
  override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "artwork.invalid" }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let path = request.url!.lastPathComponent
    var headers = ["Content-Type": path == "html" ? "text/html" : "image/jpeg"]
    if path == "declared" { headers["Content-Length"] = "16000001" }
    let response = HTTPURLResponse(url: request.url!, statusCode: path == "error" ? 403 : 200,
      httpVersion: "HTTP/1.1", headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if path=="large-chunks" {
      let size=Self.largePayload.count
      for start in stride(from:0,to:size,by:65536) {
        let end=min(size,start+65536)
        client?.urlProtocol(self,didLoad:Self.largePayload.subdata(in:start..<end))
      }
      client?.urlProtocolDidFinishLoading(self); return
    }
    if path=="slow" {
      (URLProtocol.property(forKey:"probe",in:request) as? ArtworkProtocolProbe)?.started.signal()
      client?.urlProtocol(self,didLoad:Data(repeating:42,count:1024))
      DispatchQueue.global().asyncAfter(deadline:.now()+0.2) { [self] in
        lock.lock(); let cancelled=self.cancelled; lock.unlock()
        guard !cancelled else { return }
        client?.urlProtocol(self,didLoad:Data(repeating:42,count:1024))
        client?.urlProtocolDidFinishLoading(self)
      }
      return
    }
    client?.urlProtocol(self, didLoad: Data(repeating: 42, count: path == "chunked" ? 8192 : 1024))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {
    lock.lock(); cancelled=true; lock.unlock()
    (URLProtocol.property(forKey:"probe",in:request) as? ArtworkProtocolProbe)?.stopped.signal()
  }
}

// Exact pre-change receive implementation from db4cdc3, test-only. Compare
// receive completion and process CPU; fixture delivery is included, not CDN.
private enum LegacyArtworkByteReceiver {
  static func receive(_ request: URLRequest, session: URLSession, limit: Int) async throws -> Data {
    let (bytes, response) = try await session.bytes(for: request)
    defer { bytes.task.cancel() }
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
      response.expectedContentLength <= Int64(limit),
      let mime = response.mimeType?.lowercased(),
      mime.hasPrefix("image/") || mime == "application/octet-stream" else { throw URLError(.badServerResponse) }
    return try await withTaskCancellationHandler {
      var data = Data()
      data.reserveCapacity(min(limit, max(0, Int(response.expectedContentLength))))
      for try await byte in bytes {
        if data.count % 16384 == 0 { try Task.checkCancellation() }
        guard data.count < limit else { throw URLError(.dataLengthExceedsMaximum) }
        data.append(byte)
      }
      try Task.checkCancellation()
      return data
    } onCancel: { bytes.task.cancel() }
  }
}
