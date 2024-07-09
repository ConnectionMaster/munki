//
//  pkginfolib.swift
//  munki
//
//  Created by Greg Neagle on 7/2/24.
//  functions used by makepkginfo to create pkginfo files

// This implementation drops support for:
//   - pkginfo creation for configuration profiles
//   - pkginfo creation for Apple Update Metadata
//   - special handling of Adobe installers

import Foundation

enum PkgInfoGenerationError: Error {
    case error(description: String)
}

func pkginfoMetadata() -> PlistDict {
    // Helps us record  information about the environment in which the pkginfo was
    // created so we have a bit of an audit trail. Returns a dictionary.
    var metadata = PlistDict()
    metadata["created_by"] = NSUserName()
    metadata["creation_date"] = Date()
    metadata["munki_version"] = getVersion()
    metadata["os_version"] = getOSVersion(onlyMajorMinor: false)
    return metadata
}

func createPkgInfoFromPkg(_ pkgpath: String,
                          options: PkginfoOptions) throws -> PlistDict
{
    // Gets package metadata for the package at pkgpath.
    // Returns pkginfo
    var info = PlistDict()

    if hasValidPackageExt(pkgpath) {
        info = try getPackageMetaData(pkgpath)
        if options.pkg.installerChoices {
            if let installerChoices = getChoiceChangesXML(pkgpath) {
                info["installer_choices_xml"] = installerChoices
            }
        }
        if !pathIsDirectory(pkgpath) {
            // generate and add installer_item_size
            if let attributes = try? FileManager.default.attributesOfItem(atPath: pkgpath) {
                let filesize = (attributes as NSDictionary).fileSize()
                info["installer_item_size"] = Int(filesize / 1024)
            }
            info["installer_item_hash"] = sha256hash(file: pkgpath)
        }
    }
    return info
}

func createInstallsItem(_ itempath: String) -> PlistDict {
    // Creates an item for a pkginfo "installs" array
    // Determines if the item is an application, bundle, Info.plist, or a file or
    // directory and gets additional metadata for later comparison.
    var info = PlistDict()
    if isApplication(itempath) {
        info["type"] = "application"
        if let plist = getBundleInfo(itempath) {
            for key in ["CFBundleName", "CFBundleIdentifier",
                        "CFBundleShortVersionString", "CFBundleVersion"]
            {
                if let value = plist[key] as? String {
                    info[key] = value
                }
            }
            if let minOSVers = plist["LSMinimumSystemVersion"] as? String {
                info["minosversion"] = minOSVers
            } else if let minOSVersByArch = plist["LSMinimumSystemVersionByArchitecture"] as? [String: String] {
                // get the highest/latest of all the minmum os versions
                let minOSVersions = minOSVersByArch.values
                let versions = minOSVersions.map { MunkiVersion($0) }
                if let maxVersion = versions.max() {
                    info["minosversion"] = maxVersion.value
                }
            } else if let minSysVers = plist["SystemVersionCheck:MinimumSystemVersion"] as? String {
                info["minosversion"] = minSysVers
            }
        }
    } else if let plist = getBundleInfo(itempath) {
        // if we can find bundle info and we're not an app
        // we must be a bundle
        info["type"] = "bundle"
        for key in ["CFBundleShortVersionString", "CFBundleVersion"] {
            if let value = plist[key] as? String {
                info[key] = value
            }
        }
    } else if let plist = try? readPlist(itempath) as? PlistDict {
        // we must be a plist
        info["type"] = "plist"
        for key in ["CFBundleShortVersionString", "CFBundleVersion"] {
            if let value = plist[key] as? String {
                info[key] = value
            }
        }
    }
    // help the admin by switching to CFBundleVersion if CFBundleShortVersionString
    // value seems invalid
    if let shortVersionString = info["CFBundleShortVersionString"] as? String {
        let shortVersionStringFirst = String(shortVersionString.first ?? "X")
        if !"0123456789".contains(shortVersionStringFirst) {
            if info["CFBundleVersion"] != nil {
                info["version_comparison_key"] = "CFBundleVersion"
            }
        } else {
            info["version_comparison_key"] = "CFBundleShortVersionString"
        }
    }

    if !info.keys.contains("CFBundleShortVersionString"), !info.keys.contains("CFBundleVersion") {
        // no version keys, so must be either a plist without version info
        // or just a simple file or directory
        info["type"] = "file"
        if pathIsRegularFile(itempath) || pathIsSymlink(itempath) {
            info["md5checksum"] = md5hash(file: itempath)
        }
    }
    if !info.isEmpty {
        info["path"] = itempath
    }
    return info
}

func createPkgInfoForDragNDrop(_ mountpoint: String, options: PkginfoOptions) throws -> PlistDict {
    // processes a drag-n-drop dmg to build pkginfo
    var info = PlistDict()
    var dragNDropItem = ""
    var installsitem = PlistDict()
    if let item = options.dmg.item {
        // specific item given
        dragNDropItem = item
        let itempath = (mountpoint as NSString).appendingPathComponent(dragNDropItem)
        installsitem = createInstallsItem(itempath)
        if installsitem.isEmpty {
            throw PkgInfoGenerationError.error(
                description: "\(dragNDropItem) not found on disk image.")
        }
    } else {
        // no item specified; look for an application at root of
        // mounted dmg
        let filemanager = FileManager.default
        if let filelist = try? filemanager.contentsOfDirectory(atPath: mountpoint) {
            for item in filelist {
                let itempath = (mountpoint as NSString).appendingPathComponent(item)
                if isApplication(itempath) {
                    dragNDropItem = item
                    installsitem = createInstallsItem(itempath)
                    if !installsitem.isEmpty {
                        break
                    }
                }
            }
        }
    }

    if !installsitem.isEmpty {
        var itemsToCopyItem = PlistDict()
        var mountpointPattern = mountpoint
        if !mountpointPattern.hasSuffix("/") {
            mountpointPattern += "/"
        }
        if dragNDropItem.hasPrefix(mountpointPattern) {
            let startIndex = dragNDropItem.index(
                dragNDropItem.startIndex, offsetBy: mountpointPattern.count
            )
            dragNDropItem = String(dragNDropItem[startIndex...])
        }
        var destItem = dragNDropItem
        if let destitemname = options.dmg.destitemname {
            destItem = destitemname
            itemsToCopyItem["destination_item"] = destItem
        }

        let destItemFilename = (destItem as NSString).lastPathComponent
        if let destinationpath = options.dmg.destinationpath {
            installsitem["path"] = (destinationpath as NSString).appendingPathComponent(destItemFilename)
        } else {
            installsitem["path"] = ("/Applications" as NSString).appendingPathComponent(destItemFilename)
        }
        if let name = installsitem["CFBundleName"] as? String {
            info["name"] = name
        } else {
            info["name"] = (dragNDropItem as NSString).deletingPathExtension
        }
        let comparisonKey = installsitem["version_comparison_key"] as? String ?? "CFBundleShortVersionString"
        let version = installsitem[comparisonKey] as? String ?? "0.0.0.0.0"
        if let minOSVers = installsitem["minosversion"] as? String {
            info["minimum_os_version"] = minOSVers
        }
        info["version"] = version
        info["installs"] = [installsitem]
        info["installer_type"] = "copy_from_dmg"
        // build items_to_copy array
        itemsToCopyItem["source_item"] = dragNDropItem
        if let destinationpath = options.dmg.destinationpath {
            itemsToCopyItem["destination_path"] = destinationpath
        } else {
            itemsToCopyItem["destination_path"] = "/Applications"
        }
        if let user = options.dmg.user {
            itemsToCopyItem["user"] = user
        }
        if let group = options.dmg.group {
            itemsToCopyItem["user"] = group
        }
        if let mode = options.dmg.mode {
            itemsToCopyItem["user"] = mode
        }
        info["items_to_copy"] = [itemsToCopyItem]
        info["uninstallable"] = true
        info["uninstall_method"] = "remove_copied_items"

        if let installerTypeRequested = options.type.installerType, installerTypeRequested == .stage_os_installer {
            // TODO: transform this copy_from_dmg item
            // into a staged_os_installer item
        }
    }

    return info
}

func createPkgInfoFromDmg(_ dmgpath: String,
                          options: PkginfoOptions) throws -> PlistDict
{
    // Mounts a disk image if it"s not already mounted
    // Builds pkginfo for the first installer item found at the root level,
    // or a specific one if specified by options.pkgname or options.item
    // Unmounts the disk image if it wasn"t already mounted
    var info = PlistDict()
    let wasAlreadyMounted = diskImageIsMounted(dmgpath)
    var mountpoint = ""
    do {
        mountpoint = try mountdmg(dmgpath, useExistingMounts: true)
    } catch let DiskImageError.error(description) {
        throw PkgInfoGenerationError.error(
            description: "Could not mount \(dmgpath): \(description)")
    }
    guard !mountpoint.isEmpty else {
        throw PkgInfoGenerationError.error(description: "No mountpoint for \(dmgpath)")
    }
    if let pkgname = options.pkg.pkgname {
        // a package was specified
        let pkgpath = (mountpoint as NSString).appendingPathComponent(pkgname)
        info = try createPkgInfoFromPkg(pkgpath, options: options)
        info["package_path"] = pkgname
    } else if options.dmg.item == nil {
        // look for first package at the root of the mounted dmg
        if let filelist = try? FileManager.default.contentsOfDirectory(atPath: mountpoint) {
            for item in filelist {
                if hasValidPackageExt(item) {
                    let pkgpath = (mountpoint as NSString).appendingPathComponent(item)
                    info = try createPkgInfoFromPkg(pkgpath, options: options)
                    break
                }
            }
        }
    }
    if info.isEmpty, options.dmg.item == nil {
        // TODO: check for macOS installer
    }
    if info.isEmpty {
        // maybe this is a drag-n-drop disk image
        if let dragNDropInfo = try? createPkgInfoForDragNDrop(
            mountpoint, options: options
        ) {
            info = dragNDropInfo
        }
    }
    if !info.isEmpty {
        // generate and add installer_item_size
        if let attributes = try? FileManager.default.attributesOfItem(atPath: dmgpath) {
            let filesize = (attributes as NSDictionary).fileSize()
            info["installer_item_size"] = Int(filesize / 1024)
        }
        info["installer_item_hash"] = sha256hash(file: dmgpath)
    }
    // eject the dmg
    if !wasAlreadyMounted {
        unmountdmg(mountpoint)
    }
    return info
}

func readFileOrString(_ fileNameOrString: String) -> String {
    // attempt to read a file with the same name as the input string and return its text,
    // otherwise return the input string
    if let fileText = try? String(contentsOfFile: fileNameOrString, encoding: .utf8) {
        return fileText
    }
    return fileNameOrString
}

func makepkginfo(_ filepath: String?,
                 options: PkginfoOptions) throws -> PlistDict
{
    // Return a pkginfo dictionary for installeritem
    var installeritem = filepath ?? ""
    var pkginfo = PlistDict()

    if !installeritem.isEmpty {
        if !FileManager.default.fileExists(atPath: installeritem) {
            throw PkgInfoGenerationError.error(
                description: "File \(installeritem) does not exist")
        }

        // is this the mountpoint for a mounted disk image?
        if pathIsVolumeMountPoint(installeritem) {
            // Get the disk image path for the mountpoint
            // and use that instead of the original item
            if let dmgPath = diskImageForMountPoint(installeritem) {
                installeritem = dmgPath
            }
        }

        // is this a disk image?
        if hasValidDiskImageExt(installeritem) {
            pkginfo = try createPkgInfoFromDmg(installeritem, options: options)
            if pkginfo.isEmpty {
                throw PkgInfoGenerationError.error(
                    description: "Could not find a supported installer item in \(installeritem)")
            }
            if dmgIsWritable(installeritem), options.hidden.printWarnings {
                printStderr("WARNING: \(installeritem) is a writable disk image. Checksum verification is not supported.")
                pkginfo["installer_item_hash"] = "N/A"
            }
            // is this a package?
        } else if hasValidPackageExt(installeritem) {
            if let installerTypeRequested = options.type.installerType, options.hidden.printWarnings {
                printStderr("WARNING: installer_type requested is \(installerTypeRequested.rawValue). Provided installer item appears to be an Apple pkg.")
            }
            pkginfo = try createPkgInfoFromPkg(installeritem, options: options)
            if pkginfo.isEmpty {
                throw PkgInfoGenerationError.error(
                    description: "\(installeritem) doesn't appear to be a valid installer item.")
            }
            if pathIsDirectory(installeritem), options.hidden.printWarnings {
                printStderr("WARNING: \(installeritem) is a bundle-style package!\nTo use it with Munki, you should encapsulate it in a disk image.")
            }
        } else {
            throw PkgInfoGenerationError.error(
                description: "\(installeritem) is not a supported installer item!")
        }

        // try to generate the correct item location if item was imported from
        // inside the munki repo
        // TODO: remove start of path if it refers to the Munki repo pkgs dir

        // for now, just the filename
        pkginfo["installer_item_location"] = (installeritem as NSString).lastPathComponent

        if let uninstalleritem = options.pkg.uninstalleritem {
            pkginfo["uninstallable"] = true
            pkginfo["uninstall_method"] = "uninstall_package"
            let minMunkiVers = pkginfo["minimum_munki_version"] as? String ?? "0"
            if MunkiVersion(minMunkiVers) > MunkiVersion("6.2") {
                pkginfo["minimum_munki_version"] = "6.2"
            }
            if !FileManager.default.fileExists(atPath: uninstalleritem) {
                throw PkgInfoGenerationError.error(
                    description: "No uninstaller item at \(uninstalleritem)")
            }
            // TODO: remove start of path if it refers to the Munki repo pkgs dir
            // for now, just the filename
            pkginfo["uninstaller_item_location"] = (uninstalleritem as NSString).lastPathComponent
            pkginfo["uninstaller_item_hash"] = sha256hash(file: uninstalleritem)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: uninstalleritem) {
                let filesize = (attributes as NSDictionary).fileSize()
                pkginfo["uninstaller_item_size"] = Int(filesize / 1024)
            }
        }

        // No uninstall method yet?
        // if we have receipts, assume we can uninstall using them
        if !pkginfo.keys.contains("uninstall_method") {
            if let receipts = pkginfo["receipts"] as? [PlistDict] {
                if !receipts.isEmpty {
                    pkginfo["uninstallable"] = true
                    pkginfo["uninstall_method"] = "removepackages"
                }
            }
        }

    } else {
        // no installer item
        if options.type.nopkg {
            pkginfo["installer_type"] = "nopkg"
        }
    }

    if !options.other.catalog.isEmpty {
        pkginfo["catalogs"] = options.other.catalog
    }
    if let description = options.override.description {
        pkginfo["description"] = readFileOrString(description)
    }
    if let displayname = options.override.displayname {
        pkginfo["display_name"] = displayname
    }
    if let name = options.override.name {
        pkginfo["name"] = name
    }
    if let version = options.override.pkgvers {
        pkginfo["version"] = version
    }
    if let category = options.other.category {
        pkginfo["category"] = category
    }
    if let developer = options.other.developer {
        pkginfo["developer"] = developer
    }
    if let iconName = options.other.iconName {
        pkginfo["icon_name"] = iconName
    }

    // process items for installs array
    var installs = [PlistDict]()
    for var file in options.installs.file {
        if file.hasSuffix("/") {
            file.removeLast()
        }
        if FileManager.default.fileExists(atPath: file) {
            let installsItem = createInstallsItem(file)
            installs.append(installsItem)
        } else {
            printStderr("Item \(file) doesn't exist. Skipping.")
        }
    }
    if !installs.isEmpty {
        pkginfo["installs"] = installs
    }
    // add pkginfo scripts if specified
    // TODO: verify scripts start with a shebang line?
    if let installcheckScript = options.script.installcheckScript {
        if let scriptText = try? String(contentsOfFile: installcheckScript, encoding: .utf8) {
            pkginfo["installcheck_script"] = scriptText
        }
    }
    if let uninstallcheckScript = options.script.uninstallcheckScript {
        if let scriptText = try? String(contentsOfFile: uninstallcheckScript, encoding: .utf8) {
            pkginfo["uninstallcheck_script"] = scriptText
        }
    }
    if let postinstallScript = options.script.postinstallScript {
        if let scriptText = try? String(contentsOfFile: postinstallScript, encoding: .utf8) {
            pkginfo["postinstall_script"] = scriptText
        }
    }
    if let preinstallScript = options.script.preinstallScript {
        if let scriptText = try? String(contentsOfFile: preinstallScript, encoding: .utf8) {
            pkginfo["preinstall_script"] = scriptText
        }
    }
    if let postuninstallScript = options.script.postuninstallScript {
        if let scriptText = try? String(contentsOfFile: postuninstallScript, encoding: .utf8) {
            pkginfo["postuninstall_script"] = scriptText
        }
    }
    if let preuninstallScript = options.script.preuninstallScript {
        if let scriptText = try? String(contentsOfFile: preuninstallScript, encoding: .utf8) {
            pkginfo["preuninstall_script"] = scriptText
        }
    }
    if let uninstallScript = options.script.uninstallScript {
        if let scriptText = try? String(contentsOfFile: uninstallScript, encoding: .utf8) {
            pkginfo["uninstall_script"] = scriptText
            pkginfo["uninstall_method"] = "uninstall_script"
            pkginfo["uninstallable"] = true
        }
    }
    // more options and pkginfo bits
    if !installeritem.isEmpty || options.type.nopkg {
        pkginfo["_metadata"] = pkginfoMetadata()
        pkginfo["autoremove"] = options.other.autoremove
        if pkginfo["catalogs"] == nil {
            pkginfo["catalogs"] = ["testing"]
        }
    }
    if let minimumMunkiVersion = options.other.minimumMunkiVersion {
        pkginfo["miminum_munki_version"] = minimumMunkiVersion
    }
    if options.other.onDemand {
        pkginfo["OnDemand"] = true
    }
    if options.force.unattendedInstall {
        pkginfo["unattended_install"] = true
    }
    if options.force.unattendedUninstall {
        pkginfo["unattended_uninstall"] = true
    }
    if let minimumOSVersion = options.other.minimumOSVersion {
        pkginfo["minimum_os_version"] = minimumOSVersion
    }
    if let maximumOSVersion = options.other.maximumOSVersion {
        pkginfo["maximum_os_version"] = maximumOSVersion
    }
    if !options.other.supportedArchitectures.isEmpty {
        let rawValues = options.other.supportedArchitectures.map(\.rawValue)
        pkginfo["supported_architectures"] = rawValues
    }
    if let forceInstallAfterDate = options.force.forceInstallAfterDate {
        pkginfo["force_install_after_date"] = forceInstallAfterDate
    }
    if let restartAction = options.override.restartAction {
        pkginfo["RestartAction"] = restartAction.rawValue
    }
    if !options.other.updateFor.isEmpty {
        pkginfo["update_for"] = options.other.updateFor
    }
    if !options.other.requires.isEmpty {
        pkginfo["update_for"] = options.other.requires
    }
    if !options.other.blockingApplication.isEmpty {
        pkginfo["update_for"] = options.other.blockingApplication
    }
    if let uninstallMethod = options.override.uninstallMethod {
        pkginfo["uninstall_method"] = uninstallMethod
        pkginfo["uninstallable"] = true
    }
    if !options.pkg.installerEnvironment.isEmpty {
        pkginfo["installer_environment"] = options.pkg.installerEnvironmentDict
    }
    if let notes = options.other.notes {
        pkginfo["notes"] = readFileOrString(notes)
    }

    return pkginfo
}
