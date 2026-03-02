#!/usr/bin/env swift

import Foundation
import Darwin
import Virtualization
import ObjectiveC

print("=== Virtualization Private API Dump (macOS 26.3 Tahoe) ===")
print("Date: \(Date())")
print("Framework loaded successfully\n")

// Get every class loaded in the runtime
var count: UInt32 = 0
guard let classList = objc_copyClassList(&count) else {
    fatalError("Failed to get class list")
}
defer { free(classList) }

for i in 0..<Int(count) {
    let cls = classList[i]
    let className = String(cString: class_getName(cls))

    // Only show classes we care about (VZ*, AVP*, etc.)
    if className.contains("VZ") || className.contains("AVP") || className.contains("Virtualization") || className.contains("PL011") || className.contains("SEP") {
        print("=== Class: \(className) ===")

        // Instance methods
        var methodCount: UInt32 = 0
        if let methods = class_copyMethodList(cls, &methodCount) {
            for j in 0..<Int(methodCount) {
                let selector = method_getName(methods[j])
                print("  - \(String(cString: sel_getName(selector)))")
            }
            free(methods)
        }

        // Class methods (from meta-class)
        if let metaClass = object_getClass(cls) {
            var classMethodCount: UInt32 = 0
            if let classMethods = class_copyMethodList(metaClass, &classMethodCount) {
                for j in 0..<Int(classMethodCount) {
                    let selector = method_getName(classMethods[j])
                    print("  + \(String(cString: sel_getName(selector)))")
                }
                free(classMethods)
            }
        }
        print("")
    }
}

print("=== Dump finished. Copy everything above and paste it back here. ===")
