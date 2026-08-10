//
//  ProjectMetadataScannerTests.swift
//  BeadInventoryTests
//

import XCTest
import SwiftData
import SQLite3
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
        XCTAssertEqual(Set(projects[0].beadUsage.map(\.colorCode)), Set(["A1", "B2"]))
        XCTAssertNil(projects[0].thumbnail)
        XCTAssertNil(projects[0].finishedImage)
        XCTAssertNil(projects[0].patternGrid)
        XCTAssertNil(projects[0].displayThumbnail)
    }

    func test_keeps_same_date_project_usages_together() throws {
        let projectA = UUID()
        let projectB = UUID()
        let storeURL = try makeRawStore(statements: [
            projectInsert(primaryKey: 1, id: projectA, date: 100),
            projectInsert(primaryKey: 2, id: projectB, date: 100),
            usageInsert(primaryKey: 1, projectPrimaryKey: 1, colorCode: "A-1"),
            usageInsert(primaryKey: 2, projectPrimaryKey: 2, colorCode: "B-1"),
            usageInsert(primaryKey: 3, projectPrimaryKey: 1, colorCode: "A-2"),
            usageInsert(primaryKey: 4, projectPrimaryKey: 2, colorCode: "B-2")
        ])

        guard case .success(let projects) = ProjectMetadataScanner.load(storeURL: storeURL) else {
            return XCTFail("metadata scanner should read the fixture")
        }

        XCTAssertEqual(projects.count, 2)
        XCTAssertEqual(projects.first(where: { $0.id == projectA })?.beadUsage.map(\.colorCode), ["A-1", "A-2"])
        XCTAssertEqual(projects.first(where: { $0.id == projectB })?.beadUsage.map(\.colorCode), ["B-1", "B-2"])
    }

    func test_rejects_usage_row_without_id() throws {
        let project = UUID()
        let storeURL = try makeRawStore(statements: [
            projectInsert(primaryKey: 1, id: project, date: 100),
            """
            INSERT INTO ZSDBEADUSAGE
            (Z_PK, ZPROJECT, ZID, ZCOLORCODE, ZBRANDID, ZQUANTITY, ZISDEDUCTED)
            VALUES (1, 1, NULL, 'A-1', NULL, 1, 0)
            """
        ])

        XCTAssertEqual(ProjectMetadataScanner.load(storeURL: storeURL), .failure(.unsupportedStore))
    }

    private func makeRawStore(statements: [String]) throws -> URL {
        let storeURL = storeDir.appendingPathComponent("scanner-fixture-\(UUID().uuidString).store")
        var database: OpaquePointer?
        guard sqlite3_open(storeURL.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "ProjectMetadataScannerTests", code: 1)
        }
        defer { sqlite3_close(database) }

        try execute(
            """
            CREATE TABLE ZSDPROJECTRECORD (
                Z_PK INTEGER PRIMARY KEY, ZID TEXT, ZNAME TEXT, ZDATE REAL, ZTOTALBEADS INTEGER,
                ZBRANDID TEXT, ZISARCHIVED INTEGER, ZPARENTID TEXT, ZISPLANNED INTEGER,
                ZEXECUTEDDATE REAL, ZCOMPLETEDDATE REAL, ZCOLORSYSTEMRAW TEXT
            )
            """,
            database: database
        )
        try execute(
            """
            CREATE TABLE ZSDBEADUSAGE (
                Z_PK INTEGER PRIMARY KEY, ZPROJECT INTEGER, ZID TEXT, ZCOLORCODE TEXT,
                ZBRANDID TEXT, ZQUANTITY INTEGER, ZISDEDUCTED INTEGER
            )
            """,
            database: database
        )
        for statement in statements {
            try execute(statement, database: database)
        }
        return storeURL
    }

    private func projectInsert(primaryKey: Int, id: UUID, date: TimeInterval) -> String {
        """
        INSERT INTO ZSDPROJECTRECORD
        (Z_PK, ZID, ZNAME, ZDATE, ZTOTALBEADS, ZBRANDID, ZISARCHIVED, ZPARENTID, ZISPLANNED, ZEXECUTEDDATE, ZCOMPLETEDDATE, ZCOLORSYSTEMRAW)
        VALUES (\(primaryKey), '\(id.uuidString)', '项目 \(primaryKey)', \(date), 0, NULL, 0, NULL, 1, NULL, NULL, 'MARD')
        """
    }

    private func usageInsert(primaryKey: Int, projectPrimaryKey: Int, colorCode: String) -> String {
        """
        INSERT INTO ZSDBEADUSAGE
        (Z_PK, ZPROJECT, ZID, ZCOLORCODE, ZBRANDID, ZQUANTITY, ZISDEDUCTED)
        VALUES (\(primaryKey), \(projectPrimaryKey), '\(UUID().uuidString)', '\(colorCode)', NULL, 1, 0)
        """
    }

    private func execute(_ statement: String, database: OpaquePointer) throws {
        guard sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "ProjectMetadataScannerTests", code: 2)
        }
    }
}
