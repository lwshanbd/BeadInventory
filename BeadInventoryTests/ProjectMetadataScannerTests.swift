//
//  ProjectMetadataScannerTests.swift
//  BeadInventoryTests
//

import XCTest
import SwiftData
@testable import BeadInventory

final class ProjectMetadataScannerTests: XCTestCase {
    private var storeDir: URL!

    override func setUpWithError() throws {
        storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-metadata-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: storeDir)
    }

    func test_loads_project_metadata_and_usages_without_image_data() throws {
        let storeURL = storeDir.appendingPathComponent("metadata.store")
        let configuration = ModelConfiguration(url: storeURL, cloudKitDatabase: .none)
        let container = try ModelContainer(
            for: SDBrand.self, SDBrandStock.self, SDProjectRecord.self,
            SDBeadUsage.self, SDCustomColor.self, SDHistoryRecord.self, SDColorScheme.self,
            configurations: configuration
        )
        let context = ModelContext(container)
        let project = SDProjectRecord(
            name: "只读元数据",
            totalBeads: 42,
            isPlanned: true,
            thumbnail: Data(repeating: 0xA5, count: 512 * 1024),
            finishedImage: Data(repeating: 0x5A, count: 512 * 1024),
            beadUsages: [
                SDBeadUsage(colorCode: "A1", quantity: 12),
                SDBeadUsage(colorCode: "B2", quantity: 30, isDeducted: true)
            ]
        )
        context.insert(project)
        try context.save()

        let result = ProjectMetadataScanner.load(storeURL: storeURL)
        guard case .success(let projects) = result else {
            return XCTFail("metadata scanner should read a SwiftData SQLite store: \(result)")
        }
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects[0].id, project.id)
        XCTAssertEqual(projects[0].name, "只读元数据")
        XCTAssertEqual(projects[0].totalBeads, 42)
        XCTAssertEqual(projects[0].beadUsage.map(\.colorCode), ["A1", "B2"])
        XCTAssertNil(projects[0].thumbnail)
        XCTAssertNil(projects[0].finishedImage)
        XCTAssertNil(projects[0].patternGrid)
        XCTAssertNil(projects[0].displayThumbnail)
    }
}
