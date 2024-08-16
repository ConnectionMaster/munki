//
//  download.swift
//  munki
//
//  Created by Greg Neagle on 8/15/24.
//

import Foundation

func baseName(_ str: String) -> String {
    // Return a basename string.
    // Examples:
    //    "http://foo/bar/path/foo.dmg" => "foo.dmg"
    //    "/path/foo.dmg" => "foo.dmg"

    if let url = URL(string: str) {
        return url.lastPathComponent
    } else {
        return (str as NSString).lastPathComponent
    }
}

func getDownloadCachePath(_ urlString: String) -> String {
    // For a URL, return the path that the download should cache to.
    //
    // Returns a string.
    return managedInstallsDir(subpath: "Cache/" + baseName(urlString))
}

func enoughDiskSpaceFor(
    _ item: PlistDict,
    installList: [PlistDict] = [],
    uninstalling: Bool = false,
    warn: Bool = true,
    precaching: Bool = false
) -> Bool {
    // Determine if there is enough disk space to download and install
    // the installer item.

    // fudgefactor is 100MB
    let fudgefactor = 102_400 // KBytes
    var alreadyDownloadedSize = 0
    if let installerItemLocation = item["installer_item_location"] as? String {
        let downloadedPath = getDownloadCachePath(installerItemLocation)
        if pathExists(downloadedPath) {
            alreadyDownloadedSize = getSize(downloadedPath) / 1024 // KBytes
        }
    }
    var installerItemSize = item["installer_item_size"] as? Int ?? 0 // KBytes
    var installedSize = item["installed_size"] as? Int ?? installerItemSize // KBytes
    if uninstalling {
        installedSize = 0
        installerItemSize = 0
        if let uninstallerItemSize = item["uninstaller_item_size"] as? Int {
            installerItemSize = uninstallerItemSize // KBytes
        }
    }
    let diskSpaceNeeded = installerItemSize - alreadyDownloadedSize + installedSize + fudgefactor

    var diskSpace = availableDiskSpace() // KBytes
    for additionalItem in installList {
        // subtract space needed for other items that are to be installed
        diskSpace -= (additionalItem["installed_size"] as? Int ?? 0)
    }

    if diskSpaceNeeded > diskSpace, !precaching {
        // try to clear space by deleting some precached items
        // TODO: uncache(diskSpaceNeeded - diskSpace)
        // now re-calc
        diskSpace = availableDiskSpace()
        for additionalItem in installList {
            // subtract space needed for other items that are to be installed
            diskSpace -= (additionalItem["installed_size"] as? Int ?? 0)
        }
    }

    if diskSpace >= diskSpaceNeeded {
        return true
    }

    // we don't have enough space
    if warn {
        let itemName = item["name"] as? String ?? "<unknown>"
        if uninstalling {
            displayWarning("There is insufficient disk space to download the uninstaller for \(itemName)")
        } else {
            displayWarning("There is insufficient disk space to download and install \(itemName)")
        }
        displayWarning("\(Int(diskSpaceNeeded / 1024))MB needed, \(Int(diskSpace / 1024))MB available")
    }
    return false
}

func downloadInstallerItem(
    _ item: PlistDict,
    installInfo: PlistDict,
    uninstalling: Bool = false,
    precaching: Bool = false
) throws -> Bool {
    // Downloads an (un)installer item.
    // Returns true if the item was downloaded,
    // false if it was already cached.
    // Thows an error if there are issues

    let downloadItemKey = if uninstalling, item.keys.contains("uninstaller_item_location") {
        "uninstaller_item_location"
    } else {
        "installer_item_location"
    }
    let itemHashKey = if uninstalling, item.keys.contains("uninstaller_item_location") {
        "uninstaller_item_hash"
    } else {
        "installer_item_hash"
    }
    guard let location = item[downloadItemKey] as? String else {
        throw FetchError.download(
            errorCode: -1,
            description: "No \(downloadItemKey) in pkginfo"
        )
    }

    // pkginfos support two keys that can essentially override the
    // normal URL generation for Munki repo items. But they are not
    // commonly used.
    let alternatePkgURL: String = if let packageCompleteURL = item["PackageCompleteURL"] as? String {
        packageCompleteURL
    } else if let packageURL = item["PackageURL"] as? String {
        composedURLWithBase(packageURL, adding: location)
    } else {
        ""
    }

    let pkgName = baseName(location)
    displayDebug2("Package name is: \(pkgName)")
    if !alternatePkgURL.isEmpty {
        displayDebug2("Download URL is: \(alternatePkgURL)")
    }

    let destinationPath = getDownloadCachePath(location)
    displayDebug2("Downloading to: \(destinationPath)")

    if !pathExists(destinationPath) {
        // check to see if there is enough free space to download and install
        let installList = installInfo["managed_installs"] as? [PlistDict] ?? []
        if !enoughDiskSpaceFor(
            item,
            installList: installList,
            uninstalling: uninstalling,
            precaching: precaching
        ) {
            throw FetchError.download(
                errorCode: -1,
                description: "Insufficient disk space to download and install \(pkgName)"
            )
        }
    }
    displayDetail("Downloading \(pkgName) from \(location)")
    let downloadMessage = "Downloading \(pkgName)..."
    let expectedHash = item[itemHashKey] as? String
    if alternatePkgURL.isEmpty {
        return try fetchMunkiResource(
            kind: .package,
            name: pkgName,
            destinationPath: destinationPath,
            message: downloadMessage,
            resume: true,
            expectedHash: expectedHash,
            verify: true,
            pkginfo: item
        )
    } else {
        // use alternatePkgURL
        return try fetchMunkiResourceByURL(
            alternatePkgURL,
            destinationPath: destinationPath,
            message: downloadMessage,
            resume: true,
            expectedHash: expectedHash,
            verify: true,
            pkginfo: item
        )
    }
}

let ICON_HASHES_PLIST_NAME = "_icon_hashes.plist"

func cleanUpIconsDir(keepList: [String] = []) {
    // Remove any cached/downloaded icons that aren't in the list of ones
    // to keep
    let itemsToKeep = keepList + [ICON_HASHES_PLIST_NAME]
    let iconsDir = managedInstallsDir(subpath: "icons")
    let filemanager = FileManager.default
    let dirEnum = filemanager.enumerator(atPath: iconsDir)
    while let file = dirEnum?.nextObject() as? String {
        let fullPath = (iconsDir as NSString).appendingPathComponent(file)
        if !pathIsDirectory(fullPath) {
            if !itemsToKeep.contains(file) {
                try? filemanager.removeItem(atPath: fullPath)
            }
        } else if let dirContents = try? filemanager.contentsOfDirectory(atPath: fullPath),
                  dirContents.isEmpty
        {
            // remove any empty directories as well
            try? filemanager.removeItem(atPath: fullPath)
        }
    }
}

func getIconHashes() -> [String: String] {
    // Attempts to download the dictionary of compiled icon hashes
    let iconsHashesPlist = managedInstallsDir(subpath: "icons/\(ICON_HASHES_PLIST_NAME)")
    do {
        _ = try fetchMunkiResource(
            kind: .icon,
            name: ICON_HASHES_PLIST_NAME,
            destinationPath: iconsHashesPlist,
            message: "Getting list of available icons"
        )
        return try readPlist(fromFile: iconsHashesPlist) as? [String: String] ?? [:]
    } catch {
        displayDebug1("Error while retreiving icon hashes: \(error.localizedDescription)")
        return [String: String]()
    }
}

func downloadIcons(_ itemList: [PlistDict]) {
    // Attempts to download icons (actually image files) for items in
    // itemList
    var iconsToKeep = [String]()
    let iconsDir = managedInstallsDir(subpath: "icons")
    let iconHashes = getIconHashes()

    for item in itemList {
        var iconName = item["icon_name"] as? String ?? item["name"] as? String ?? "<unknown>"
        if (iconName as NSString).pathExtension.isEmpty {
            iconName += ".png"
        }
        iconsToKeep.append(iconName)
        let serverHash: String = if let iconHash = item["icon_hash"] as? String {
            iconHash
        } else {
            iconHashes[iconName] ?? "<noserverhash>"
        }
        let iconPath = (iconsDir as NSString).appendingPathComponent(iconName)
        var localHash = "<nolocalhash>"
        if pathIsRegularFile(iconPath) {
            // have we already downloaded it? If so get the local hash
            if let data = try? getXattr(named: XATTR_SHA, atPath: iconPath) {
                localHash = String(data: data, encoding: .utf8) ?? "<nolocalhash>"
            } else {
                // get hash and also store for future use
                localHash = storeCachedChecksum(toPath: iconPath) ?? "<nolocalhash>"
            }
        }
        let iconSubDir = (iconPath as NSString).deletingLastPathComponent
        if !pathIsDirectory(iconSubDir) {
            let success = createMissingDirs(iconSubDir)
            if !success {
                displayError("Could not create \(iconSubDir)")
                continue
            }
        }
        if serverHash != localHash {
            // hashes don't match, so download the icon
            if !iconHashes.isEmpty, !iconHashes.keys.contains(iconName) {
                // if we have a dict of icon hashes, and the icon name is not
                // in that dict, then there's no point in attempting to
                // download this icon
                continue
            }
            let itemName = item["display_name"] as? String ?? item["name"] as? String ?? "<unknown>"
            do {
                _ = try fetchMunkiResource(
                    kind: .icon,
                    name: iconName,
                    destinationPath: iconPath,
                    message: "Getting icon \(iconName) for \(itemName)..."
                )
                _ = storeCachedChecksum(toPath: iconPath)
            } catch {
                displayDebug1("Error when retrieving icon \(iconName) from the server: \(error.localizedDescription)")
            }
        }
    }
    cleanUpIconsDir(keepList: iconsToKeep)
}

func downloadClientResources() {
    // Download client customization resources (if any).

    // Munki's preferences can specify an explicit name
    // under ClientResourcesFilename
    // if that doesn't exist, use the primary manifest name as the
    // filename. If that fails, try site_default.zip

    // build a list of resource names to request from the server
    var filenames = [String]()
    if let resourcesName = pref("ClientResourcesFilename") as? String {
        if (resourcesName as NSString).pathExtension.isEmpty {
            filenames.append(resourcesName + ".zip")
        } else {
            filenames.append(resourcesName)
        }
    } else {
        // TODO: make a better way to retrieve the current manifest name
        if let manifestName = Report.shared.retrieve(key: "ManifestName") as? String {
            filenames.append(manifestName + ".zip")
        }
    }
    filenames.append("site_default.zip")

    let resourceDir = managedInstallsDir(subpath: "client_resources")
    // make sure local resource directory exists
    if !pathIsDirectory(resourceDir) {
        let success = createMissingDirs(resourceDir)
        if !success {
            displayError("Could not create \(resourceDir)")
            return
        }
    }
    let resourceArchivePath = (resourceDir as NSString).appendingPathComponent("custom.zip")
    let message = "Getting client resources..."
    var downloadedResourcePath = ""
    for filename in filenames {
        do {
            _ = try fetchMunkiResource(
                kind: .clientResource,
                name: filename,
                destinationPath: resourceArchivePath,
                message: message
            )
            downloadedResourcePath = resourceArchivePath
            break
        } catch {
            displayDebug1("Could not retrieve client resources with name \(filename): \(error.localizedDescription)")
        }
    }
    if downloadedResourcePath.isEmpty {
        // make sure we don't have an old custom.zip hanging around
        if pathExists(resourceArchivePath) {
            do {
                try FileManager.default.removeItem(atPath: resourceArchivePath)
            } catch {
                displayError("Could not remove stale \(resourceArchivePath): \(error.localizedDescription)")
            }
        }
    }
}

func downloadCatalog(_ catalogName: String) -> String {
    // Attempt to download a catalog from the Munki server, Returns the path to
    // the downloaded catalog file
    let catalogPath = managedInstallsDir(subpath: "catalogs/\(catalogName)")
    displayDetail("Getting catalog \(catalogName)...")
    let message = "Retrieving catalog \(catalogName)..."
    do {
        _ = try fetchMunkiResource(
            kind: .catalog,
            name: catalogName,
            destinationPath: catalogPath,
            message: message
        )
        return catalogPath
    } catch {
        displayError("Could not retrieve catalog \(catalogName) from server: \(error.localizedDescription)")
    }
    return ""
}

// TODO: precaching support (in progress)

private func getInstallInfo() -> PlistDict {
    // Get the install info from InstallInfo.plist
    let installInfoPlist = managedInstallsDir(subpath: "InstallInfo.plist")
    return (try? readPlist(fromFile: installInfoPlist) as? PlistDict) ?? PlistDict()
}

private func itemsToPrecache(_ installInfo: PlistDict) -> [PlistDict] {
    // Returns a list of items from InstallInfo.plist's optional_installs
    // that have precache=true and (installed=false or needs_update=true)
    func boolValueFor(_ item: PlistDict, key: String) -> Bool {
        return item[key] as? Bool ?? false
    }
    if let optionalInstalls = installInfo["optional_installs"] as? [PlistDict] {
        return optionalInstalls.filter {
            ($0["precache"] as? Bool ?? false) &&
                (($0["installed"] as? Bool ?? false) ||
                    ($0["needs_update"] as? Bool ?? false))
        }
    }
    return [PlistDict]()
}

func precache() {
    // Download any applicable precache items into our Cache folder
    displayInfo("###   Beginning precaching session   ###")
    let installInfo = getInstallInfo()
    for item in itemsToPrecache(installInfo) {
        do {
            _ = try downloadInstallerItem(
                item, installInfo: installInfo, precaching: true
            )
        } catch {
            let itemName = item["name"] as? String ?? "<unknown>"
            displayWarning("Failed to precache the installer for \(itemName) because \(error.localizedDescription)")
        }
    }
    displayInfo("###   Ending precaching session   ###")
}

func uncache(_: Int) {
    // Discard precached items to free up space for managed installs
    let installInfo = getInstallInfo()

    // make a list of names of precachable items
    let precachableItems = itemsToPrecache(installInfo).filter {
        $0["installer_item_location"] != nil
    }.map {
        $0["installer_item_location"] as? String ?? ""
    }.map {
        ($0 as NSString).lastPathComponent
    }
    if precachableItems.isEmpty {
        return
    }

    let cacheDir = managedInstallsDir(subpath: "Cache")
    let itemsInCache = (try? FileManager.default.contentsOfDirectory(atPath: cacheDir)) ?? [String]()
    // now filter our list to items actually downloaded
    let precachedItems = precachableItems.filter {
        itemsInCache.contains($0)
    }
    if precachedItems.isEmpty {
        return
    }

    // more to do here
}
