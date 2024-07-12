//
//  plistutils.swift
//  munki
//
//  Created by Greg Neagle on 6/27/24.
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

import Foundation

enum PlistError: Error {
    case readError(description: String)
    case writeError(description: String)
}

func deserialize(_ data: Data?) throws -> Any? {
    if data != nil {
        do {
            let dataObject = try PropertyListSerialization.propertyList(
                from: data!,
                options: PropertyListSerialization.MutabilityOptions.mutableContainers,
                format: nil
            )
            return dataObject
        } catch {
            throw PlistError.readError(description: "\(error)")
        }
    }
    return nil
}

func readPlist(fromFile filepath: String) throws -> Any? {
    return try deserialize(NSData(contentsOfFile: filepath) as Data?)
}

func readPlist(fromData data: Data) throws -> Any? {
    return try deserialize(data)
}

func readPlist(fromString string: String) throws -> Any? {
    return try deserialize(string.data(using: String.Encoding.utf8))
}

func serialize(_ plist: Any) throws -> Data {
    do {
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: PropertyListSerialization.PropertyListFormat.xml,
            options: 0
        )
        return plistData
    } catch {
        throw PlistError.writeError(description: "\(error)")
    }
}

func writePlist(_ dataObject: Any, toFile filepath: String) throws {
    do {
        let data = try serialize(dataObject) as NSData
        if !(data.write(toFile: filepath, atomically: true)) {
            throw PlistError.writeError(description: "write failed")
        }
    } catch {
        throw PlistError.writeError(description: "\(error)")
    }
}

func plistToData(_ dataObject: Any) throws -> Data {
    return try serialize(dataObject)
}

func plistToString(_ dataObject: Any) throws -> String {
    do {
        let data = try serialize(dataObject)
        return String(data: data, encoding: String.Encoding.utf8)!
    } catch {
        throw PlistError.writeError(description: "\(error)")
    }
}
