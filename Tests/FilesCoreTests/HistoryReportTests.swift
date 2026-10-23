import XCTest
@testable import FilesCore

final class HistoryReportTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func record(_ action: FileAction, state: OperationState = .completed,
                        source: String = "/Inbox/receipt.pdf", destination: String? = "/Filed/receipt.pdf",
                        issue: String? = nil, createdAt: Date? = nil) -> OperationRecord {
        let fingerprint = FileFingerprint(deviceID: 991, fileID: 992, size: 12, permissions: 0o640,
                                          createdAt: start, modifiedAt: start, contentHash: "EXCLUDED_CONTENT_HASH",
                                          tags: ["EXCLUDED_TAG"])
        var result = OperationRecord(id: UUID(), rowID: UUID(), folderID: UUID(), ruleID: UUID(),
                                     action: action, sourcePath: source, destinationPath: destination,
                                     before: fingerprint, after: fingerprint,
                                     previousTags: ["EXCLUDED_OLD_TAG"],
                                     previousTagMetadata: Data("EXCLUDED_TAG_METADATA".utf8),
                                     ledgerKey: "EXCLUDED_LEDGER", ruleSignature: "EXCLUDED_RULE",
                                     createdAt: createdAt ?? start, finishedAt: start.addingTimeInterval(2),
                                     state: state, issue: issue)
        result.stagingPath = "/EXCLUDED_STAGING"
        result.undoStagingPath = "/EXCLUDED_UNDO_STAGING"
        result.recoveryPath = "/EXCLUDED_RECOVERY"
        return result
    }

    func testSearchStateActionAndInclusiveCreatedDatePreserveVisibleOrder() {
        let newer = record(.copy(to: "/Filed"), source: "/Inbox/Récéipt.pdf", createdAt: start.addingTimeInterval(20))
        let middle = record(.copy(to: "/Filed"), state: .interrupted,
                            source: "/Inbox/receipt-2.pdf", createdAt: start.addingTimeInterval(10))
        let older = record(.move(to: "/Filed"), source: "/Inbox/receipt-3.pdf", createdAt: start)
        let records = [newer, middle, older]

        XCTAssertEqual(HistoryFilter(searchText: "RECÉIPT").apply(to: records).map(\.id), [newer.id, middle.id, older.id])
        let combined = HistoryFilter(searchText: "receipt", states: [.completed], actions: [.copy],
                                     createdFrom: start.addingTimeInterval(20),
                                     createdThrough: start.addingTimeInterval(20))
        XCTAssertEqual(combined.apply(to: records).map(\.id), [newer.id])
        XCTAssertEqual(HistoryFilter(searchText: "move").apply(to: records).map(\.id), [older.id])
        XCTAssertEqual(HistoryFilter(states: [.interrupted]).apply(to: records).map(\.id), [middle.id])
    }

    func testResetEmptySetsAndReversedDatesHaveUnambiguousSemantics() {
        let first = record(.tag("secret"), createdAt: start.addingTimeInterval(1))
        let second = record(.zipArchive(to: "/Filed"), createdAt: start)
        let records = [first, second]
        XCTAssertEqual(HistoryFilter().apply(to: records).map(\.id), [first.id, second.id])
        XCTAssertTrue(HistoryFilter(states: []).apply(to: records).isEmpty)
        XCTAssertTrue(HistoryFilter(actions: []).apply(to: records).isEmpty)
        XCTAssertTrue(HistoryFilter(createdFrom: start.addingTimeInterval(2),
                                    createdThrough: start).apply(to: records).isEmpty)
        XCTAssertEqual(HistoryFilter(actions: [.zipArchive], createdThrough: start).apply(to: records).map(\.id), [second.id])
    }

    func testEveryStateAndActionKindCanBeSelectedWithoutReordering() {
        let states: [OperationState] = [.intent, .completed, .failed, .interrupted, .undoIntent, .undone]
        let actions: [FileAction] = [.copy(to: "/out"), .move(to: "/out"), .rename(to: "new.txt"),
                                     .tag("private"), .zipArchive(to: "/out")]
        let stateRecords = states.enumerated().map { index, state in
            record(.copy(to: "/out"), state: state, createdAt: start.addingTimeInterval(Double(states.count - index)))
        }
        for (state, expected) in zip(states, stateRecords) {
            XCTAssertEqual(HistoryFilter(states: [state]).apply(to: stateRecords).map(\.id), [expected.id])
        }
        let actionRecords = actions.enumerated().map { index, action in
            record(action, createdAt: start.addingTimeInterval(Double(actions.count - index)))
        }
        for (action, expected) in zip(actions, actionRecords) {
            let kind = HistoryActionKind(action)
            XCTAssertEqual(HistoryFilter(actions: [kind]).apply(to: actionRecords).map(\.id), [expected.id])
        }
        XCTAssertEqual(HistoryFilter(searchText: "zip").apply(to: actionRecords).map(\.id), [actionRecords[4].id])
    }

    func testVersionedJSONContainsOnlyReviewedFieldsAndExactStrings() throws {
        let first = record(.tag("EXCLUDED_TAG_VALUE"), source: "/Inbox/Café, \"one\".pdf",
                           destination: nil, issue: "TOKEN=EXCLUDED_RAW_DIAGNOSTIC\nprivate path")
        let second = record(.copy(to: "/Filed"), source: "/Inbox/second.pdf")
        let report = HistoryReport(records: [first, second])
        let data = try report.jsonData()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "records"])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        let rows = try XCTUnwrap(object["records"] as? [[String: Any]])
        XCTAssertEqual(rows.compactMap { $0["operationID"] as? String }, [first.id.uuidString, second.id.uuidString])
        XCTAssertEqual(rows[0]["sourcePath"] as? String, first.sourcePath)
        XCTAssertEqual(rows[0]["issue"] as? String,
                       "This action could not be confirmed. Inspect source and result paths before retrying.")
        XCTAssertEqual(rows[0]["action"] as? String, "Tag")
        let allowed = Set(["operationID", "state", "action", "sourcePath", "destinationPath",
                           "createdAt", "finishedAt", "issue"])
        XCTAssertTrue(rows.allSatisfy { Set($0.keys).isSubset(of: allowed) })
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        for forbidden in ["EXCLUDED_CONTENT_HASH", "EXCLUDED_TAG", "EXCLUDED_TAG_VALUE",
                          "EXCLUDED_LEDGER", "EXCLUDED_RULE", "EXCLUDED_STAGING",
                          "EXCLUDED_UNDO_STAGING", "EXCLUDED_RECOVERY", "EXCLUDED_TAG_METADATA",
                          "EXCLUDED_RAW_DIAGNOSTIC"] {
            XCTAssertFalse(json.contains(forbidden), "Leaked \(forbidden)")
        }
    }

    func testCSVQuotesSeparatorsAndDefendsFormulaPrefixes() throws {
        let cases = ["=1+1", "+cmd", "-cmd", "@cmd", "\t=cmd", "\r=cmd", "\n=cmd",
                     "  =cmd", "\u{00A0}=cmd", "\u{200B}=cmd", "＝cmd", "＋cmd", "－cmd", "＠cmd"]
        for value in cases {
            let row = record(.copy(to: "/Filed"), source: value, issue: value)
            let csv = try XCTUnwrap(String(data: HistoryReport(records: [row]).csvData(), encoding: .utf8))
            XCTAssertTrue(csv.contains("\"'\(value)\""), "Unsafe CSV field for \(value.debugDescription)")
        }
        let special = record(.copy(to: "/Filed"), source: " /Inbox/Café, \"one\".pdf\r\nnext",
                             destination: "/Filed/a,b.pdf", issue: "TOKEN=EXCLUDED_CSV_DIAGNOSTIC")
        let csv = try XCTUnwrap(String(data: HistoryReport(records: [special]).csvData(), encoding: .utf8))
        XCTAssertTrue(csv.hasPrefix("operation_id,state,action,source_path,destination_path,created_at,finished_at,issue\r\n"))
        XCTAssertTrue(csv.contains("\"' /Inbox/Café, \"\"one\"\".pdf\r\nnext\""))
        XCTAssertTrue(csv.contains("\"/Filed/a,b.pdf\""))
        XCTAssertFalse(csv.contains("EXCLUDED_CSV_DIAGNOSTIC"))
        XCTAssertTrue(csv.hasSuffix("\r\n"))
    }

    func testEmptyReportStillHasVersionAndCSVHeader() throws {
        let report = HistoryReport(records: [])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: report.jsonData()) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual((object["records"] as? [Any])?.count, 0)
        XCTAssertEqual(String(data: report.csvData(), encoding: .utf8),
                       "operation_id,state,action,source_path,destination_path,created_at,finished_at,issue\r\n")
    }
}
