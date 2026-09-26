//
//  ArtworkCacheTests.swift
//  LyricalTests
//
//  The cache key doubles as a filename, so key derivation is a security boundary,
//  not just a lookup detail. Eviction is the other half: this directory grows
//  forever otherwise, and "oldest" has to mean least recently *used*.
//

import XCTest
@testable import Lyrical

@MainActor
final class ArtworkCacheTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        // Per-test temp directory — the real ~/Library/Caches is never touched.
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lyrical-artwork-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    // MARK: - Key derivation

    func testHashIsTheLastPathComponent() {
        let url = URL(string: "https://i.scdn.co/image/ab67616d0000b273abc")!
        XCTAssertEqual(ArtworkCache.hash(from: url), "ab67616d0000b273abc")
    }

    func testHashStripsNonAlphanumerics() {
        let url = URL(string: "https://i.scdn.co/image/ab-67_616d.b273")!
        XCTAssertEqual(ArtworkCache.hash(from: url), "ab67616db273")
    }

    func testHashRejectsEmptyLastComponent() {
        XCTAssertNil(ArtworkCache.hash(from: URL(string: "https://i.scdn.co/")!))
        XCTAssertNil(ArtworkCache.hash(from: URL(string: "https://i.scdn.co/image/---")!))
    }

    func testHashRejectsTraversal() {
        XCTAssertNil(ArtworkCache.hash(from: URL(fileURLWithPath: "/tmp/cache").appendingPathComponent("..")))

        // Percent-encoded so Foundation hands us the whole traversal as one component.
        let encoded = URL(string: "https://i.scdn.co/image/%2E%2E%2F%2E%2E%2Fetc%2Fpasswd")!
        XCTAssertEqual(ArtworkCache.hash(from: encoded), "etcpasswd",
                       "traversal must flatten to a single safe filename")
    }

    func testHashRejectsOverlongComponent() {
        let url = URL(string: "https://i.scdn.co/image/\(String(repeating: "a", count: 129))")!
        XCTAssertNil(ArtworkCache.hash(from: url))
    }

    // MARK: - Round trip

    func testStoreThenReadRoundTripsAnImage() async throws {
        let data = try makeImageData(width: 8, height: 8)
        let cache = ArtworkCache(directory: directory)

        await cache.store(data, forHash: "abc123")
        let image = await cache.image(forHash: "abc123")

        XCTAssertEqual(image?.size, NSSize(width: 8, height: 8))
    }

    func testMissReturnsNil() async {
        let cache = ArtworkCache(directory: directory)
        let image = await cache.image(forHash: "nothinghere")

        XCTAssertNil(image)
    }

    func testDiskTierServesASecondCacheOverTheSameDirectory() async throws {
        let data = try makeImageData(width: 12, height: 12)
        let writer = ArtworkCache(directory: directory)
        await writer.store(data, forHash: "shared")

        // A fresh instance has an empty NSCache, so a hit here can only be the disk tier.
        let reader = ArtworkCache(directory: directory)
        let image = await reader.image(forHash: "shared")

        XCTAssertEqual(image?.size, NSSize(width: 12, height: 12))
    }

    func testReadTouchesModificationDateSoLRUMeansLeastRecentlyUsed() async throws {
        let data = try makeImageData()
        let writer = ArtworkCache(directory: directory)
        await writer.store(data, forHash: "touched")

        let stale = Date(timeIntervalSince1970: 1_700_000_000)
        try setModificationDate(stale, forHash: "touched")

        let reader = ArtworkCache(directory: directory)
        _ = await reader.image(forHash: "touched")

        XCTAssertGreaterThan(try modificationDate(forHash: "touched"), stale)
    }

    func testCorruptFileIsAMissAndIsRemoved() async throws {
        let file = directory.appendingPathComponent("broken")
        try Data("not an image".utf8).write(to: file)

        let cache = ArtworkCache(directory: directory)
        let image = await cache.image(forHash: "broken")

        XCTAssertNil(image)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - Eviction

    func testTrimEnforcesMaxFilesKeepingTheMostRecent() async throws {
        let cache = ArtworkCache(directory: directory, maxFiles: 3, maxBytes: .max)
        try await storeFiles(count: 5, into: cache)

        await cache.trim()

        XCTAssertEqual(try remainingFiles(), ["hash2", "hash3", "hash4"])
    }

    func testTrimEnforcesMaxBytes() async throws {
        let data = try makeImageData(width: 32, height: 32)
        // Room for two files and no more.
        let cache = ArtworkCache(directory: directory, maxFiles: 100, maxBytes: data.count * 2)
        try await storeFiles(count: 5, into: cache, data: data)

        await cache.trim()

        XCTAssertEqual(try remainingFiles(), ["hash3", "hash4"])
    }

    func testTrimIsANoOpUnderBudget() async throws {
        let cache = ArtworkCache(directory: directory, maxFiles: 10, maxBytes: .max)
        try await storeFiles(count: 3, into: cache)

        await cache.trim()
        await cache.trim()

        XCTAssertEqual(try remainingFiles(), ["hash0", "hash1", "hash2"])
    }

    // MARK: - Helpers

    /// Stores `count` files and stamps explicit, well-separated modification dates so
    /// eviction order never depends on filesystem timestamp granularity.
    private func storeFiles(count: Int, into cache: ArtworkCache, data: Data? = nil) async throws {
        let payload = try data ?? makeImageData()
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        for index in 0..<count {
            await cache.store(payload, forHash: "hash\(index)")
        }
        for index in 0..<count {
            try setModificationDate(base.addingTimeInterval(Double(index) * 3600), forHash: "hash\(index)")
        }
    }

    private func remainingFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    private func setModificationDate(_ date: Date, forHash hash: String) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: directory.appendingPathComponent(hash).path)
    }

    private func modificationDate(forHash hash: String) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent(hash).path)
        return try XCTUnwrap(attributes[.modificationDate] as? Date)
    }

    private func makeImageData(width: Int = 8, height: Int = 8) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemPink.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()

        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }
}
