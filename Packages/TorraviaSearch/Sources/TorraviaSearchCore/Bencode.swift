import Foundation

public enum BencodeError: Error {
    case invalidFormat
    case unsupported
}

public enum Bencode: Equatable {
    case integer(Int)
    case string(Data)
    case list([Bencode])
    case dictionary([String: Bencode])
    case binaryDictionary([Data: Bencode])

    nonisolated public static func decode(data: Data) throws -> Bencode {
        var index = data.startIndex
        let value = try parseValue(data: data, index: &index)
        guard index == data.endIndex else { throw BencodeError.invalidFormat }
        return value
    }

    nonisolated private static func parseValue(data: Data, index: inout Data.Index) throws -> Bencode {
        guard index < data.endIndex else { throw BencodeError.invalidFormat }
        let byte = data[index]
        switch byte {
        case ASCII.i.rawValue:
            index = data.index(after: index)
            return try parseInteger(data: data, index: &index)
        case ASCII.l.rawValue:
            index = data.index(after: index)
            return try parseList(data: data, index: &index)
        case ASCII.d.rawValue:
            index = data.index(after: index)
            return try parseDictionary(data: data, index: &index)
        case ASCII.zero.rawValue...ASCII.nine.rawValue:
            return try parseString(data: data, index: &index)
        default:
            throw BencodeError.invalidFormat
        }
    }

    nonisolated private static func parseInteger(data: Data, index: inout Data.Index) throws -> Bencode {
        var sign: Int = 1
        var magnitude: UInt64 = 0
        var encounteredDigit = false

        guard index < data.endIndex else { throw BencodeError.invalidFormat }

        if data[index] == ASCII.hyphen.rawValue {
            sign = -1
            index = data.index(after: index)
        }

        guard index < data.endIndex else { throw BencodeError.invalidFormat }
        if data[index] == ASCII.zero.rawValue {
            index = data.index(after: index)
            if index < data.endIndex,
               data[index] >= ASCII.zero.rawValue,
               data[index] <= ASCII.nine.rawValue {
                throw BencodeError.invalidFormat
            }
            if index < data.endIndex, data[index] == ASCII.e.rawValue {
                if sign < 0 { throw BencodeError.invalidFormat }
                index = data.index(after: index)
                return .integer(0)
            }
            throw BencodeError.invalidFormat
        }

        while index < data.endIndex {
            let byte = data[index]
            if byte == ASCII.e.rawValue {
                if !encounteredDigit { throw BencodeError.invalidFormat }
                if sign < 0 {
                    if magnitude == UInt64(Int.max) + 1 {
                        index = data.index(after: index)
                        return .integer(Int.min)
                    }
                    guard magnitude <= UInt64(Int.max) else { throw BencodeError.invalidFormat }
                    index = data.index(after: index)
                    return .integer(-Int(magnitude))
                }
                guard magnitude <= UInt64(Int.max) else { throw BencodeError.invalidFormat }
                index = data.index(after: index)
                return .integer(Int(magnitude))
            }
            guard byte >= ASCII.zero.rawValue, byte <= ASCII.nine.rawValue else { throw BencodeError.invalidFormat }
            encounteredDigit = true
            let digit = UInt64(byte - ASCII.zero.rawValue)
            let (multiplied, multiplyOverflow) = magnitude.multipliedReportingOverflow(by: 10)
            let (updated, addOverflow) = multiplied.addingReportingOverflow(digit)
            guard !multiplyOverflow, !addOverflow else { throw BencodeError.invalidFormat }
            magnitude = updated
            index = data.index(after: index)
        }

        throw BencodeError.invalidFormat
    }

    nonisolated private static func parseString(data: Data, index: inout Data.Index) throws -> Bencode {
        var length = 0
        var encounteredColon = false
        let firstDigitIndex = index
        while index < data.endIndex {
            let byte = data[index]
            if byte == ASCII.colon.rawValue {
                index = data.index(after: index)
                encounteredColon = true
                break
            }
            guard byte >= ASCII.zero.rawValue, byte <= ASCII.nine.rawValue else { throw BencodeError.invalidFormat }
            if index == firstDigitIndex,
               byte == ASCII.zero.rawValue,
               data.index(after: index) < data.endIndex,
               data[data.index(after: index)] != ASCII.colon.rawValue {
                throw BencodeError.invalidFormat
            }
            let digit = Int(byte - ASCII.zero.rawValue)
            let (multiplied, multiplyOverflow) = length.multipliedReportingOverflow(by: 10)
            let (updated, addOverflow) = multiplied.addingReportingOverflow(digit)
            guard !multiplyOverflow, !addOverflow else { throw BencodeError.invalidFormat }
            length = updated
            index = data.index(after: index)
        }

        guard encounteredColon else { throw BencodeError.invalidFormat }
        guard data.distance(from: index, to: data.endIndex) >= length else { throw BencodeError.invalidFormat }

        let start = index
        index = data.index(index, offsetBy: length)
        let slice = data[start..<index]
        return .string(Data(slice))
    }

    nonisolated private static func parseList(data: Data, index: inout Data.Index) throws -> Bencode {
        var items: [Bencode] = []
        while index < data.endIndex {
            if data[index] == ASCII.e.rawValue {
                index = data.index(after: index)
                return .list(items)
            }
            let value = try parseValue(data: data, index: &index)
            items.append(value)
        }
        throw BencodeError.invalidFormat
    }

    nonisolated private static func parseDictionary(data: Data, index: inout Data.Index) throws -> Bencode {
        var dict: [Data: Bencode] = [:]
        while index < data.endIndex {
            if data[index] == UInt8(ascii: "e") {
                index = data.index(after: index)
                var text: [String: Bencode] = [:]
                for (key, value) in dict {
                    guard let decoded = String(data: key, encoding: .utf8) else { return .binaryDictionary(dict) }
                    text[decoded] = value
                }
                return .dictionary(text)
            }
            let keyValue = try parseString(data: data, index: &index)
            guard case let .string(keyData) = keyValue else { throw BencodeError.invalidFormat }
            let value = try parseValue(data: data, index: &index)
            guard !dict.keys.contains(keyData) else { throw BencodeError.invalidFormat }
            dict[keyData] = value
        }
        throw BencodeError.invalidFormat
    }

    nonisolated public func encode() -> Data {
        switch self {
        case let .integer(value):
            return Data("i\(value)e".utf8)
        case let .string(data):
            var encoded = Data("\(data.count):".utf8)
            encoded.append(data)
            return encoded
        case let .list(items):
            var encoded = Data("l".utf8)
            for item in items {
                encoded.append(item.encode())
            }
            encoded.append(Data("e".utf8))
            return encoded
        case let .dictionary(dict):
            return Bencode.binaryDictionary(Dictionary(uniqueKeysWithValues: dict.map { (Data($0.key.utf8), $0.value) })).encode()
        case let .binaryDictionary(dict):
            var encoded = Data("d".utf8)
            for keyData in dict.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
                encoded.append(Data("\(keyData.count):".utf8))
                encoded.append(keyData)
                if let value = dict[keyData] {
                    encoded.append(value.encode())
                }
            }
            encoded.append(Data("e".utf8))
            return encoded
        }
    }
}

private enum ASCII: UInt8 {
    case i = 0x69
    case l = 0x6C
    case d = 0x64
    case e = 0x65
    case zero = 0x30
    case nine = 0x39
    case hyphen = 0x2D
    case colon = 0x3A
}
