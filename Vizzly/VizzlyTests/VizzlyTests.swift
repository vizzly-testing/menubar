//
//  VizzlyTests.swift
//  VizzlyTests
//
//  Created by Robert DeLuca on 1/27/26.
//

import Testing
@testable import Vizzly

struct VizzlyTests {

    @Test func parsesSessionStartLogEntry() throws {
        let line = #"{"timestamp":"2026-02-01T15:30:00.123Z","session_start":true,"node_version":"20.11.1","platform":"darwin"}"#
        let entry = LogEntry.parse(line)

        #expect(entry != nil)
        #expect(entry?.level == .info)
        #expect(entry?.message == "Server started")
        #expect(entry?.details == "Node 20.11.1 on darwin")
    }

    @Test func parsesScreenshotDiffAsFailure() throws {
        let line = #"{"timestamp":"2026-02-01T15:30:00.123Z","screenshot":"home-page","status":"failed","diffPercentage":12.75}"#
        let entry = LogEntry.parse(line)

        #expect(entry != nil)
        #expect(entry?.level == .error)
        #expect(entry?.message == "home-page")
        #expect(entry?.details == "12.8% diff")
    }

    @Test func plainTextLogsFallbackToInfo() throws {
        let entry = LogEntry.parse("Server online")

        #expect(entry != nil)
        #expect(entry?.level == .info)
        #expect(entry?.message == "Server online")
    }

    @Test func cliErrorDisplayDetailStripsShellPrefixes() throws {
        let error = CLIError(message: "Failed", detail: "zsh:1: command not found: npx")
        #expect(error.displayDetail == "command not found: npx")
    }

}
