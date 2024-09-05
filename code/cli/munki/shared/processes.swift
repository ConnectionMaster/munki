//
//  processes.swift
//  munki
//
//  Created by Greg Neagle on 8/5/24.
//

import Foundation

func getRunningProcesses() -> [String] {
    // returns a list of paths of running processes
    let procList = UNIXProcessList()
    var processPaths = [String]()
    for proc in procList {
        if proc.pid != 0,
           let data = argumentData(for: proc.pid)
        {
            let args = (try? parseArgumentData(data)) ?? []
            if !args.isEmpty {
                processPaths.append(args[0])
            }
        }
    }
    return processPaths
}

func runningProcessesWithPids() -> [(pid: Int32, path: String)] {
    // returns a list of tuples containing the pid and executable path
    // of running processes
    let procList = UNIXProcessList()
    var processTuples = [(Int32, String)]()
    for proc in procList {
        if proc.pid != 0,
           let data = argumentData(for: proc.pid)
        {
            let args = (try? parseArgumentData(data)) ?? []
            if !args.isEmpty {
                processTuples.append((pid: proc.pid, path: args[0]))
            }
        }
    }
    return processTuples
}

func isAppRunning(_ appName: String) -> Bool {
    // Tries to determine if the application in appname is currently
    // running
    displayDetail("Checking if \(appName) is running...")
    let procList = getRunningProcesses()
    var matchingItems = [String]()
    if appName.hasPrefix("/") {
        // search by exact path
        matchingItems = procList.filter { $0 == appName }
    } else if appName.hasSuffix(".app") {
        // search by filename
        let searchName = "/" + appName + "/Contents/MacOS/"
        matchingItems = procList.filter { $0.contains(searchName) }
    } else {
        // check executable name
        matchingItems = procList.filter { $0.hasSuffix("/" + appName) }
    }
    if matchingItems.isEmpty {
        // try adding '.app' to the name and check again
        let searchName = "/" + appName + ".app/Contents/MacOS/"
        matchingItems = procList.filter { $0.contains(searchName) }
    }
    if !matchingItems.isEmpty {
        // it's running!
        displayDebug1("Matching process list: \(matchingItems)")
        displayDebug1("\(appName) is running!")
        return true
    }
    // if we get here, we have no evidence that appname is running
    return false
}

func blockingApplicationsRunning(_ pkginfo: PlistDict) -> Bool {
    // Returns true if any application in the blocking_applications list
    // is running or, if there is no blocking_applications list, if any
    // application in the installs list is running.
    var appNames = [String]()
    if let blockingApplications = pkginfo["blocking_applications"] as? [String] {
        appNames = blockingApplications
    } else {
        // if no blocking_applications specified, get appnames
        // from 'installs' list if it exists
        if let installs = pkginfo["installs"] as? [PlistDict] {
            let apps = installs.filter {
                $0["type"] as? String ?? "" == "application"
            }
            appNames = apps.map {
                ($0["path"] as? NSString)?.lastPathComponent ?? ""
            }.filter { !$0.isEmpty }
        }
    }
    displayDebug1("Checking for \(appNames)")
    let runningApps = appNames.filter { isAppRunning($0) }
    if !runningApps.isEmpty {
        let itemName = pkginfo["name"] as? String ?? "<unknown>"
        displayDetail("Blocking apps for \(itemName) are running:")
        displayDetail("    \(runningApps)")
        return true
    }
    return false
}

func pythonScriptRunning(_ scriptName: String) -> Int32? {
    // Returns ProcessID for a running python script matching the scriptName
    // as long as the pid is not the same as ours
    // this is used to see if the managedsoftwareupdate script is already running
    let ourPid = ProcessInfo().processIdentifier
    let processTuples = runningProcessesWithPids()
    for item in processTuples {
        if item.pid == ourPid {
            continue
        }
        let executable = (item.path as NSString).lastPathComponent
        if executable.contains("python") || executable.contains("Python") {
            // get all the args for this pid
            if var args = executableAndArgsForPid(item.pid) {
                // first value is executable path, drop it
                // next value is command, drop it
                args = Array(args.dropFirst(2))
                // drop leading args that start with a hyphen
                args = Array(args.drop(while: { $0.hasPrefix("-") }))
                if args[0].hasSuffix(scriptName) {
                    return item.pid
                }
            }
        }
    }
    return nil
}

func executableRunning(_ name: String) -> Int32? {
    // Returns Process ID for a running executable matching the name
    // as long as it isn't our pid
    let ourPid = ProcessInfo().processIdentifier
    let processTuples = runningProcessesWithPids()
    for item in processTuples {
        if item.pid == ourPid {
            continue
        }
        if name.hasPrefix("/") {
            // full path, so exact comparison
            if item.path == name {
                return item.pid
            }
        } else {
            // does executable path end with the name?
            if item.path.hasSuffix(name) {
                return item.pid
            }
        }
    }
    return nil
}

func anotherManagedsoftwareupdateInstanceRunning() -> Int32? {
    // A Python version of managedsoftwareupdate might be running,
    // or a compiled version
    if let pid = executableRunning("managedsoftwareupdate") {
        return pid
    }
    if let pid = pythonScriptRunning(".managedsoftwareupdate.py") {
        return pid
    }
    if let pid = pythonScriptRunning("managedsoftwareupdate.py") {
        return pid
    }
    if let pid = pythonScriptRunning("managedsoftwareupdate") {
        return pid
    }
    return nil
}
