import Foundation

/// Reads the *real* media duration straight from MP4 (fMP4) `mdhd` boxes
/// instead of trusting AVFoundation's `duration`/`timeRange`, which returns
/// 2x the true duration for YouTube DASH fragmented streams.
enum MP4Probe {
    struct TrackInfo {
        let kind: String
        let durationSeconds: Double
    }

    private struct Box {
        let type: String
        let start: Int
        let size: Int
        var headerSize: Int
        var payload: Int { start + headerSize }
    }

    static func trackDurations(fileURL: URL) throws -> [TrackInfo] {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        // The init segment (ftyp + moov) sits at the start of a DASH file and
        // is tiny; 4 MB is more than enough to reach every trak's mdhd.
        let head = handle.readData(ofLength: 4_000_000)
        guard head.count > 8 else { throw ProbeError.tooShort }
        return parseMoov(head)
    }

    private static func parseMoov(_ data: Data) -> [TrackInfo] {
        var result: [TrackInfo] = []
        for moov in children(of: data, rootStart: 0, rootEnd: data.count) where moov.type == "moov" {
            for trak in children(of: data, rootStart: moov.payload, rootEnd: moov.start + moov.size) where trak.type == "trak" {
                var kind: String?
                var timescale: Int64?
                var duration: Int64?
                for mdia in children(of: data, rootStart: trak.payload, rootEnd: trak.start + trak.size) where mdia.type == "mdia" {
                    for box in children(of: data, rootStart: mdia.payload, rootEnd: mdia.start + mdia.size) {
                        if box.type == "hdlr", box.payload + 12 <= box.start + box.size {
                            kind = String(data: data[(box.payload + 8)..<(box.payload + 12)], encoding: .ascii)
                        } else if box.type == "mdhd" {
                            let version = data[box.payload]
                            if version == 1 {
                                timescale = readInt64(data, box.payload + 20)
                                duration = readInt64(data, box.payload + 28)
                            } else {
                                timescale = Int64(readInt32(data, box.payload + 12))
                                duration = Int64(readInt32(data, box.payload + 16))
                            }
                        }
                    }
                }
                guard let kind, let timescale, let duration, timescale > 0 else { continue }
                let seconds = Double(duration) / Double(timescale)
                if seconds > 0 {
                    result.append(TrackInfo(kind: kind, durationSeconds: seconds))
                }
            }
        }
        return result
    }

    private static func children(of data: Data, rootStart: Int, rootEnd: Int) -> [Box] {
        var boxes: [Box] = []
        var off = rootStart
        while off + 8 <= rootEnd {
            let size32 = readInt32(data, off)
            let typeBytes = data[(off + 4)..<(off + 8)]
            let type = String(data: typeBytes, encoding: .ascii) ?? "    "
            var size = Int(size32)
            var headerSize = 8
            if size == 1 {
                size = Int(readInt64(data, off + 8))
                headerSize = 16
            } else if size == 0 {
                size = rootEnd - off
            }
            guard size >= headerSize, off + size <= rootEnd else { break }
            boxes.append(Box(type: type, start: off, size: size, headerSize: headerSize))
            off += size
        }
        return boxes
    }

    private static func readInt32(_ data: Data, _ offset: Int) -> Int32 {
        data.withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: offset, as: Int32.self).bigEndian
        }
    }

    private static func readInt64(_ data: Data, _ offset: Int) -> Int64 {
        data.withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: offset, as: Int64.self).bigEndian
        }
    }
}

enum ProbeError: Error {
    case tooShort
}