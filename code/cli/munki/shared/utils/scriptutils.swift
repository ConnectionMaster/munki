//
//  scriptutils.swift
//  munki
//
//  Created by Greg Neagle on 8/5/24.
//

import Foundation

func createExecutableFile(atPath path: String, withStringContents stringContents: String) -> Bool {
    // Writes string data to path.
    // Returns success or failure as a boolean.
    let data = stringContents.data(using: .utf8)
    return FileManager.default.createFile(
        atPath: path,
        contents: data,
        attributes: [FileAttributeKey.posixPermissions: 0o700]
    )
}

class ScriptRunner: AsyncProcessRunner {
    var remainingOutput = ""

    func linesAndRemainderOf(_ str: String) -> ([String], String) {
        var lines = str.components(separatedBy: "\n")
        var remainder = ""
        if lines.count > 0, !str.hasSuffix("\n") {
            // last line of string did not end with a newline; might be a partial
            remainder = lines.last ?? ""
            lines.removeLast()
        }
        return (lines, remainder)
    }

    override func processOutput(_ str: String) {
        super.processOutput(str)
        let (lines, remainder) = linesAndRemainderOf(remainingOutput + str)
        remainingOutput = remainder
        for line in lines {
            displayInfo(line)
        }
    }
}

func runScript(_ path: String, itemName: String, scriptName: String, suppressError: Bool = false) async -> Int {
    // Runs a script, Returns return code.
    if suppressError {
        displayDetail("Running \(scriptName) for \(itemName)")
    } else {
        displayMinorStatus("Running \(scriptName) for \(itemName)")
    }
    if DisplayOptions.munkistatusoutput {
        // set indeterminate progress bar
        munkiStatusPercent(-1)
    }

    let proc = ScriptRunner(path)
    await proc.run()
    let result = proc.results

    if result.exitcode != 0, !suppressError {
        displayError("Running \(scriptName) for \(itemName) failed.")
        displayError(String(repeating: "-", count: 78))
        for line in result.output.components(separatedBy: .newlines) {
            displayError("    " + line)
        }
        displayError(String(repeating: "-", count: 78))
    } else if !suppressError {
        munkiLog("Running \(scriptName) for \(itemName) was successful.")
    }

    if DisplayOptions.munkistatusoutput {
        // clear indeterminate progress bar
        munkiStatusPercent(0)
    }

    return result.exitcode
}

func runEmbeddedScript(name: String, pkginfo: PlistDict, suppressError: Bool = false) async -> Int {
    // Runs a script embedded in the pkginfo.
    // Returns the result code.

    // get the script text
    let itemName = pkginfo["name"] as? String ?? "<unknown>"
    guard let scriptText = pkginfo[name] as? String else {
        displayError("Missing script \(name) for \(itemName)")
        return -1
    }

    // write the script to a temp file
    guard let tempdir = TempDir.shared.makeTempDir() else {
        displayError("Could not create a temporary directory for \(name)")
        return -1
    }
    let scriptPath = (tempdir as NSString).appendingPathComponent(name)
    if createExecutableFile(atPath: scriptPath, withStringContents: scriptText) {
        return await runScript(scriptPath, itemName: itemName, scriptName: name, suppressError: suppressError)
    } else {
        displayError("Failed to create executable file for \(name)")
        return -1
    }
}

enum ExternalScriptError: Error {
    case general
    case notFound
    case statusError(detail: String)
    case insecurePermissions(detail: String)
}

func verifyFileOnlyWritableByMunkiAndRoot(_ path: String) throws {
    // Check the permissions on a given file path; fail if owner or group
    // does not match the munki process (default: root/admin) or the group is not
    // 'wheel', or if other users are able to write to the file. This prevents
    // escalated execution of arbitrary code.
    let filemanager = FileManager.default
    let thisProcessOwner = NSUserName()
    var attributes: NSDictionary
    do {
        attributes = try filemanager.attributesOfItem(atPath: path) as NSDictionary
    } catch {
        throw ExternalScriptError.statusError(
            detail: "\(path): could not get filesystem attributes")
    }
    let owner = attributes.fileOwnerAccountName()
    let group = attributes.fileGroupOwnerAccountName()
    let mode = attributes.filePosixPermissions()
    if !["root", thisProcessOwner].contains(owner) {
        throw ExternalScriptError.insecurePermissions(
            detail: "\(path) owner is not root or owner of munki process!")
    }
    if !["admin", "wheel"].contains(group) {
        throw ExternalScriptError.insecurePermissions(
            detail: "\(path) group is not in wheel or admin!")
    }
    if UInt16(mode) & S_IWOTH != 0 {
        throw ExternalScriptError.insecurePermissions(
            detail: "\(path) is world writable!")
    }
}

func verifyExecutable(_ path: String) throws {
    // verifies path is executable
    let filemanager = FileManager.default
    var attributes: NSDictionary
    do {
        attributes = try filemanager.attributesOfItem(atPath: path) as NSDictionary
    } catch {
        throw ExternalScriptError.statusError(
            detail: "\(path): could not get filesystem attributes")
    }
    let mode = attributes.filePosixPermissions()
    if Int32(mode) & X_OK == 0 {
        throw ExternalScriptError.statusError(
            detail: "\(path) is not executable")
    }
}

func runExternalScript(_ scriptPath: String, arguments: [String] = [], allowInsecure: Bool = false, timeout: Int = 60) async throws -> CLIResults {
    // Run a script (e.g. preflight/postflight) and return a result.

    if !pathExists(scriptPath) {
        throw ExternalScriptError.notFound
    }
    if !allowInsecure {
        do {
            try verifyFileOnlyWritableByMunkiAndRoot(scriptPath)
        } catch let ExternalScriptError.insecurePermissions(detail) {
            throw ProcessError.error(
                description: "Skipping execution: \(detail)")
        } catch let ExternalScriptError.statusError(detail) {
            throw ProcessError.error(
                description: "Skipping execution: \(detail)")
        }
    }
    do {
        try verifyExecutable(scriptPath)
    } catch let ExternalScriptError.statusError(detail) {
        throw ProcessError.error(
            description: "Skipping execution: \(detail)")
    }

    return try await runCliAsync(scriptPath, arguments: arguments, timeout: timeout)
}
