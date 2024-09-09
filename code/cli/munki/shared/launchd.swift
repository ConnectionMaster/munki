//
//  launchd.swift
//  munki
//
//  Created by Greg Neagle on 8/2/24.
//
//  Copyright 2024 Greg Neagle.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//       https://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.

import Darwin.C
import Foundation

func getSocketFd(_ socketName: String) throws -> [CInt] {
    // Retrieve named socket file descriptors from launchd.
    var fdsCount = 0
    var fds = UnsafeMutablePointer<CInt>.allocate(capacity: 0)
    let originalFds = fds
    let err = launch_activate_socket(
        socketName,
        &fds,
        &fdsCount
    )
    if err != 0 {
        originalFds.deallocate()
        var errorDescription = ""
        switch err {
        case ENOENT:
            errorDescription = "The socket name specified does not exist in the caller's launchd.plist"
        case ESRCH:
            errorDescription = "The calling process is not managed by launchd"
        case EALREADY:
            errorDescription = "The specified socket has already been activated"
        default:
            let errStr = String(cString: strerror(err))
            errorDescription = "Error \(errStr)"
        }
        throw MunkiError("Failed to retrieve sockets from launchd: \(errorDescription)")
    }
    // make sure we clean up these allocations
    defer { fds.deallocate() }
    defer { originalFds.deallocate() }
    // fds is now a pointer to a list of filedescriptors. Transform into Swift array
    let outputFds = UnsafeMutableBufferPointer<CInt>(
        start: fds,
        count: Int(fdsCount)
    )
    return [CInt](outputFds)
}

enum LaunchdJobState {
    case unknown
    case stopped
    case running
}

struct LaunchdJobInfo {
    var state: LaunchdJobState
    var pid: Int?
    var lastExitStatus: Int?
}

func launchdJobInfo(_ jobLabel: String) -> LaunchdJobInfo {
    /// Get info about a launchd job. Returns LaunchdJobInfo.
    var info = LaunchdJobInfo(
        state: .unknown,
        pid: nil,
        lastExitStatus: nil
    )
    let result = runCLI("/bin/launchctl", arguments: ["list"])
    if result.exitcode != 0 || result.output.isEmpty {
        return info
    }
    let lines = result.output.components(separatedBy: .newlines)
    let jobLines = lines.filter {
        $0.hasSuffix("\t\(jobLabel)")
    }
    if jobLines.count != 1 {
        // unexpected number of lines matched our label
        return info
    }
    let infoParts = jobLines[0].components(separatedBy: "\t")
    if infoParts.count != 3 {
        // unexpected number of fields in the line
        return info
    }
    if infoParts[0] == "-" {
        info.pid = nil
        info.state = .stopped
    } else {
        info.pid = Int(infoParts[0])
        info.state = .running
    }
    if infoParts[1] == "-" {
        info.lastExitStatus = nil
    } else {
        info.lastExitStatus = Int(infoParts[1])
    }
    return info
}

func stopLaunchdJob(_ jobLabel: String) throws {
    /// Stop a launchd job
    let result = runCLI("/bin/launchctl", arguments: ["stop", jobLabel])
    if result.exitcode != 0 {
        throw MunkiError("launchctl stop error \(result.exitcode): \(result.error)")
    }
}

func removeLaunchdJob(_ jobLabel: String) throws {
    /// Remove a launchd job by label
    let result = runCLI("/bin/launchctl", arguments: ["remove", jobLabel])
    if result.exitcode != 0 {
        throw MunkiError("launchctl remove error \(result.exitcode): \(result.error)")
    }
}

class LaunchdJob {
    /// launchd job object

    var label: String
    var cleanUpAtExit: Bool
    var stdout: FileHandle?
    var stderr: FileHandle?
    var stdOutPath: String
    var stdErrPath: String
    var plist: PlistDict
    var plistPath: String

    init(
        cmd: [String],
        environmentVars: [String: String]? = nil,
        jobLabel: String? = nil,
        cleanUpAtExit: Bool = true
    ) throws {
        // Initialize our launchd job
        var tmpdir = TempDir.shared.path
        if !cleanUpAtExit {
            // need to use a different tmpdir than the shared one,
            // which will get cleaned up when managedsoftwareupdate
            // exits
            tmpdir = TempDir().path
        }
        guard let tmpdir else {
            throw MunkiError("Could not allocate temp dir for launchd job")
        }
        // label this job
        label = jobLabel ?? "com.googlecode.munki." + UUID().uuidString
        self.cleanUpAtExit = cleanUpAtExit
        stdOutPath = (tmpdir as NSString).appendingPathComponent(label + ".stdout")
        stdErrPath = (tmpdir as NSString).appendingPathComponent(label + ".stderr")
        plistPath = (tmpdir as NSString).appendingPathComponent(label + ".plist")
        plist = [
            "Label": label,
            "ProgramArguments": cmd,
            "StandardOutPath": stdOutPath,
            "StandardErrorPath": stdErrPath,
        ]
        if let environmentVars {
            plist["EnvironmentVariables"] = environmentVars
        }
        // create stdout and stderr files
        guard FileManager.default.createFile(atPath: stdOutPath, contents: nil),
              FileManager.default.createFile(atPath: stdErrPath, contents: nil)
        else {
            throw MunkiError("Could not create stdout/stderr files for launchd job \(label)")
        }
        // write out launchd plist
        do {
            try writePlist(plist, toFile: plistPath)
            // set owner, group and mode to those required
            // by launchd
            try FileManager.default.setAttributes(
                [.ownerAccountID: 0,
                 .groupOwnerAccountID: 0,
                 .posixPermissions: 0o644],
                ofItemAtPath: plistPath
            )
        } catch {
            throw MunkiError("Could not create plist for launchd job \(label): \(error.localizedDescription)")
        }
        // load the job
        let result = runCLI("/bin/launchctl", arguments: ["load", plistPath])
        if result.exitcode != 0 {
            throw MunkiError("launchctl load error for \(label): \(result.exitcode): \(result.error)")
        }
    }

    deinit {
        /// Attempt to clean up
        if cleanUpAtExit {
            if !plistPath.isEmpty {
                _ = runCLI("/bin/launchctl", arguments: ["unload", plistPath])
            }
            try? stdout?.close()
            try? stderr?.close()
            let fm = FileManager.default
            try? fm.removeItem(atPath: plistPath)
            try? fm.removeItem(atPath: stdOutPath)
            try? fm.removeItem(atPath: stdErrPath)
        }
    }

    func start() throws {
        /// Start the launchd job
        let result = runCLI("/bin/launchctl", arguments: ["start", label])
        if result.exitcode != 0 {
            throw MunkiError("Could not start launchd job \(label): \(result.error)")
        }
        // open the stdout and stderr output files and
        // store their file handles for use
        stdout = FileHandle(forReadingAtPath: stdOutPath)
        stderr = FileHandle(forReadingAtPath: stdErrPath)
    }

    func stop() {
        /// Stop the launchd job
        try? stopLaunchdJob(label)
    }

    func info() -> LaunchdJobInfo {
        /// Get info about the launchd job.
        return launchdJobInfo(label)
    }

    func exitcode() -> Int? {
        /// Returns the process exit code, if the job has exited; otherwise,
        /// returns nil
        let info = info()
        if info.state == .stopped {
            return info.lastExitStatus
        }
        return nil
    }
}
