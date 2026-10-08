import Foundation

public enum SHA1 {
    nonisolated public static func hash(data: Data) -> Data {
        var message = data

        let originalLengthBits = UInt64(message.count * 8)
        message.append(0x80)

        while (message.count % 64) != 56 {
            message.append(0x00)
        }

        var lengthBigEndian = originalLengthBits.bigEndian
        withUnsafeBytes(of: &lengthBigEndian) { message.append(contentsOf: $0) }

        var h0: UInt32 = 0x67452301
        var h1: UInt32 = 0xEFCDAB89
        var h2: UInt32 = 0x98BADCFE
        var h3: UInt32 = 0x10325476
        var h4: UInt32 = 0xC3D2E1F0

        let chunkCount = message.count / 64
        for chunkIndex in 0..<chunkCount {
            let chunkStart = chunkIndex * 64
            var words = [UInt32](repeating: 0, count: 80)

            for i in 0..<16 {
                let offset = chunkStart + (i * 4)
                let value = (UInt32(message[offset]) << 24)
                    | (UInt32(message[offset + 1]) << 16)
                    | (UInt32(message[offset + 2]) << 8)
                    | UInt32(message[offset + 3])
                words[i] = value
            }

            for i in 16..<80 {
                let value = words[i - 3] ^ words[i - 8] ^ words[i - 14] ^ words[i - 16]
                words[i] = value << 1 | value >> 31
            }

            var a = h0
            var b = h1
            var c = h2
            var d = h3
            var e = h4

            for i in 0..<80 {
                var f: UInt32 = 0
                var k: UInt32 = 0

                switch i {
                case 0..<20:
                    f = (b & c) | ((~b) & d)
                    k = 0x5A827999
                case 20..<40:
                    f = b ^ c ^ d
                    k = 0x6ED9EBA1
                case 40..<60:
                    f = (b & c) | (b & d) | (c & d)
                    k = 0x8F1BBCDC
                default:
                    f = b ^ c ^ d
                    k = 0xCA62C1D6
                }

                let temp = ((a << 5) | (a >> 27)) &+ f &+ e &+ k &+ words[i]
                e = d
                d = c
                c = (b << 30) | (b >> 2)
                b = a
                a = temp
            }

            h0 &+= a
            h1 &+= b
            h2 &+= c
            h3 &+= d
            h4 &+= e
        }

        var digest = Data()
        for value in [h0, h1, h2, h3, h4] {
            var bigEndian = value.bigEndian
            withUnsafeBytes(of: &bigEndian) { digest.append(contentsOf: $0) }
        }
        return digest
    }
}

