//
//  PlistManager.swift
//  Filos
//
//  Created by lunginspector on 7/25/26.
//

import SwiftUI
import Combine
import CoreFoundation

final class PlistManager: ObservableObject {
    static let shared = PlistManager()
    
    @Published var plistArray: [PlistItem] = []
    @Published var url: URL = URL.documentsDirectory.appendingPathComponent("oops")
    @Published var isWritable = false
    @Published private(set) var isRootDictionary = true
    var remotePath: String? = nil
    
    init() {}
    
    func loadPlistItems(data: Data? = nil) -> Bool {
        let plistData: Data
        if let data {
            plistData = data
        } else {
            guard let loadedData = try? Data(contentsOf: url) else {
                plistArray = [PlistItem(key: "Root", value: [], isExpanded: true)]
                isRootDictionary = false
                return false
            }
            plistData = loadedData
        }

        guard let rootValue = try? PropertyListSerialization.propertyList(
            from: plistData,
            options: [],
            format: nil
        ) else {
            plistArray = [PlistItem(key: "Root", value: [], isExpanded: true)]
            isRootDictionary = false
            return false
        }

        isRootDictionary = rootValue is [String: Any]
        let rootItem = PlistItem(key: "Root", value: rootValue, isExpanded: true)
        plistArray = [rootItem]
        if isRootDictionary {
            plistArray[0].dictVal.sort { $0.key < $1.key }
        }
        return true
    }

    func writePlistItems(newItem: PlistItem? = nil, delItem: PlistItem? = nil) -> Bool {
        guard isRootDictionary else {
            print("(fm) cannot edit a plist whose root is not a dictionary")
            return false
        }
        if let newItem {
            let res = replacePlistItem(items: &plistArray, newItem: newItem)
            if !res {
                print("(fm) failed to write plist: couldn't find \(newItem.key) in dictionary.")
            }
        }
        
        if let delItem {
            let res = deletePlistItem(items: &plistArray, target: delItem)
            if !res {
                print("(fm) failed to write plist: couldn't find \(delItem.key) in dictionary.")
            }
        }
        
        var dictToWrite: [String : Any] = [:]
        
        for item in plistArray[0].dictVal {
            dictToWrite[item.key] = item.getRawValue()
        }
    
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: dictToWrite, format: .binary, options: 0)
            try data.write(to: url)
            if let remotePath {
                let localURL = url
                Task {
                    let ok = await AirliftBridge.shared.writeBack(localURL: localURL, remotePath: remotePath)
                    if !ok { await MainActor.run { Alertinator.shared.alert(title: "Airlift write failed", body: "The local snapshot was updated, but writing it back to the device failed. Check the Airlift log.") } }
                }
            }
            return true
        } catch {
            print("(fm) failed to write plist: \(error.localizedDescription)")
        }
        return false
    }
    
    // not a huge fan of any of this...
    func replacePlistItem(items: inout [PlistItem], newItem: PlistItem) -> Bool {
        for item in items.indices {
            if items[item].id == newItem.id {
                items[item] = newItem
                return true
            }
            
            if replacePlistItem(items: &items[item].dictVal, newItem: newItem) {
                return true
            }
        }
        return false
    }
    
    func deletePlistItem(items: inout [PlistItem], target: PlistItem) -> Bool {
        for item in items.indices {
            if items[item].id == target.id {
                items.removeAll() { $0.id == target.id }
                return true
            }
            
            if deletePlistItem(items: &items[item].dictVal, target: target) {
                return true
            }
        }
        return false
    }
}

struct PlistItem: Identifiable {
    var id = UUID()
    var key: String
    var rawVal: Any?
    var type: PlistItemType = .unknown
    var index: Int?
    var isExpanded: Bool
    
    var stringVal: String = ""
    var boolVal: Bool = false
    var dictVal: [PlistItem] = []
    
    init(key: String, value: Any, isExpanded: Bool = false) {
        self.key = key
        self.rawVal = value
        self.isExpanded = isExpanded
        self.type = Self.resolveType(for: value)

        // PropertyListSerialization represents plist booleans and numbers as NSNumber.
        // CFBoolean must be detected by CoreFoundation type ID before numeric handling:
        // otherwise true/false can be treated as integer 1/0 by Swift bridging.
        if let number = value as? NSNumber {
            if CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() {
                self.boolVal = number.boolValue
                self.stringVal = number.boolValue ? "true" : "false"
            } else {
                self.stringVal = number.stringValue
            }
        } else {
            switch value {
            case let v as String:
                self.stringVal = v
            case let v as Data:
                self.stringVal = v.base64EncodedString()
            case let v as [String: Any]:
                self.dictVal = v.map { PlistItem(key: $0.key, value: $0.value) }
                    .sorted(by: { $0.key < $1.key })
                self.stringVal = v.description
            case let v as [Any]:
                self.dictVal = v.enumerated().map { index, element in
                    var newItem = PlistItem(key: "Item \(index)", value: element)
                    newItem.index = index
                    return newItem
                }
                self.stringVal = v.description
            default:
                break
            }
        }
    }

    private static func resolveType(for value: Any) -> PlistItemType {
        if let number = value as? NSNumber {
            if CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() {
                return .bool
            }
            let objcType = String(cString: number.objCType)
            return ["f", "d"].contains(objcType) ? .double : .int
        }

        switch value {
        case is String: return .string
        case is Data: return .data
        case is [String: Any]: return .dict
        case is [Any]: return .array
        default: return .unknown
        }
    }

    func getRawValue() -> Any {
        switch type {
        case .string: return stringVal
        case .int: return Int(stringVal) ?? 0
        case .double: return Double(stringVal) ?? 0
        case .bool: return boolVal
        // case .data: return Data(stringVal.utf8)
        case .data: return rawVal ?? Data()
        case .dict:
            var rawDict = [String : Any]()
            for item in dictVal {
                rawDict[item.key] = item.getRawValue()
            }
            return rawDict
        case .array:
            var rawArray = [Any]()
            for item in dictVal {
                rawArray.append(item.getRawValue())
            }
            return rawArray
        case .unknown: return rawVal ?? ""
        }
    }
}

enum PlistItemType: String, CaseIterable {
    case string, int, double, bool, data, dict, array, unknown
    
    var label: String {
        switch self {
        case .string: return "String"
        case .int: return "Integer"
        case .double: return "Double"
        case .bool: return "Boolean"
        case .data: return "Data"
        case .dict: return "Dictionary"
        case .array: return "Array"
        default: return "Unknown"
        }
    }
}
