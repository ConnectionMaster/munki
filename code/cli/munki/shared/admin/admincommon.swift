//
//  admincommon.swift
//  munki
//
//  Created by Greg Neagle on 6/27/24.
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

import Foundation

let ADMIN_BUNDLE_ID = "com.googlecode.munki.munkiimport" as CFString

func adminPref(_ pref_name: String) -> Any? {
    /* Return an admin preference. Since this uses CFPreferencesCopyAppValue,
     Preferences can be defined several places. Precedence is:
     - MCX/configuration profile
     - ~/Library/Preferences/ByHost/com.googlecode.munki.munkiimport.XXXXXX.plist
     - ~/Library/Preferences/com.googlecode.munki.munkiimport.plist
     - /Library/Preferences/com.googlecode.munki.munkiimport.plist
     - .GlobalPreferences defined at various levels (ByHost, user, system)
     But typically these preferences are _not_ managed and are stored in the
     user's preferences (~/Library/Preferences/com.googlecode.munki.munkiimport.plist)
     */
    return CFPreferencesCopyAppValue(pref_name as CFString, ADMIN_BUNDLE_ID)
}

func leftPad(_ str: String, _ count: Int) -> String {
    if str.count < count {
        return String(repeating: " ", count: count - str.count) + str
    }
    return str
}
