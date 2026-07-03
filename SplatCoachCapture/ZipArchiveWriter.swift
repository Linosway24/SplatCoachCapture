//
//  ZipArchiveWriter.swift
//  SplatCoachCapture
//
//  Created by Michael Carlino on 7/3/26.
//

import Foundation

struct ZipFileEntry {
    let sourceURL: URL
    let path: String
}

struct ZipDataEntry {
    let path: String
    let data: Data
}

enum ZipArchiveWriter {
    static func write(
        fileEntries: [ZipFileEntry],
        dataEntries: [ZipDataEntry] = [],
        to archiveURL: URL,
        progress: ((Int, Int) -> Void)? = nil
    ) throws {
        var archive = Data()
        var centralDirectory = Data()
        var centralDirectoryEntries = 0
        let totalEntries = fileEntries.count + dataEntries.count
        var completedEntries = 0

        for entry in fileEntries {
            let fileData = try Data(contentsOf: entry.sourceURL)
            appendEntry(
                path: entry.path,
                data: fileData,
                archive: &archive,
                centralDirectory: &centralDirectory,
                entryCount: &centralDirectoryEntries
            )
            completedEntries += 1
            progress?(completedEntries, totalEntries)
        }

        for entry in dataEntries {
            appendEntry(
                path: entry.path,
                data: entry.data,
                archive: &archive,
                centralDirectory: &centralDirectory,
                entryCount: &centralDirectoryEntries
            )
            completedEntries += 1
            progress?(completedEntries, totalEntries)
        }

        let centralDirectoryOffset = UInt32(archive.count)
        archive.append(centralDirectory)

        archive.appendUInt32(0x06054b50)
        archive.appendUInt16(0)
        archive.appendUInt16(0)
        archive.appendUInt16(UInt16(centralDirectoryEntries))
        archive.appendUInt16(UInt16(centralDirectoryEntries))
        archive.appendUInt32(UInt32(centralDirectory.count))
        archive.appendUInt32(centralDirectoryOffset)
        archive.appendUInt16(0)

        try archive.write(to: archiveURL, options: [.atomic])
    }

    private static func appendEntry(
        path: String,
        data: Data,
        archive: inout Data,
        centralDirectory: inout Data,
        entryCount: inout Int
    ) {
        let pathData = Data(path.utf8)
        let crc = CRC32.checksum(data)
        let localHeaderOffset = UInt32(archive.count)
        let dateTime = ZipDateTime(date: Date())

        archive.appendUInt32(0x04034b50)
        archive.appendUInt16(20)
        archive.appendUInt16(0)
        archive.appendUInt16(0)
        archive.appendUInt16(dateTime.time)
        archive.appendUInt16(dateTime.date)
        archive.appendUInt32(crc)
        archive.appendUInt32(UInt32(data.count))
        archive.appendUInt32(UInt32(data.count))
        archive.appendUInt16(UInt16(pathData.count))
        archive.appendUInt16(0)
        archive.append(pathData)
        archive.append(data)

        centralDirectory.appendUInt32(0x02014b50)
        centralDirectory.appendUInt16(20)
        centralDirectory.appendUInt16(20)
        centralDirectory.appendUInt16(0)
        centralDirectory.appendUInt16(0)
        centralDirectory.appendUInt16(dateTime.time)
        centralDirectory.appendUInt16(dateTime.date)
        centralDirectory.appendUInt32(crc)
        centralDirectory.appendUInt32(UInt32(data.count))
        centralDirectory.appendUInt32(UInt32(data.count))
        centralDirectory.appendUInt16(UInt16(pathData.count))
        centralDirectory.appendUInt16(0)
        centralDirectory.appendUInt16(0)
        centralDirectory.appendUInt16(0)
        centralDirectory.appendUInt16(0)
        centralDirectory.appendUInt32(0)
        centralDirectory.appendUInt32(localHeaderOffset)
        centralDirectory.append(pathData)

        entryCount += 1
    }
}

private struct ZipDateTime {
    let date: UInt16
    let time: UInt16

    init(date sourceDate: Date) {
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: sourceDate
        )

        let year = max((components.year ?? 1980) - 1980, 0)
        let month = components.month ?? 1
        let day = components.day ?? 1
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        let second = (components.second ?? 0) / 2

        date = UInt16((year << 9) | (month << 5) | day)
        time = UInt16((hour << 11) | (minute << 5) | second)
    }
}

private enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            if crc & 1 == 1 {
                crc = (crc >> 1) ^ 0xedb88320
            } else {
                crc >>= 1
            }
        }
        return crc
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xff)
            crc = (crc >> 8) ^ table[index]
        }
        return crc ^ 0xffffffff
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }
}
