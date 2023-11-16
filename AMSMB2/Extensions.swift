//
//  Extensions.swift
//  AMSMB2
//
//  Created by Amir Abbas Mousavian.
//  Copyright © 2018 Mousavian. Distributed under MIT license.
//

import Foundation
import SMB2

extension Optional {
    func unwrap() throws -> Wrapped {
        guard let self = self else {
            throw POSIXError(.ENODATA, description: "Invalid/Empty data.")
        }
        return self
    }
}

extension Optional where Wrapped: SMB2Context {
    func unwrap() throws -> SMB2Context {
        guard let self = self, self.fileDescriptor >= 0 else {
            throw POSIXError(.ENOTCONN, description: "SMB2 server not connected.")
        }
        return self
    }
}

extension POSIXError {
    static func throwIfError<Number: SignedInteger>(_ result: Number, description: String?) throws {
        guard result < 0 else { return }
        let errno = Int32(-result)
        let errorDesc = description.map { "Error code \(errno): \($0)" }
        throw POSIXError(.init(errno), description: errorDesc)
    }

    static func throwIfErrorStatus(_ status: UInt32) throws {
        if status & SMB2_STATUS_SEVERITY_MASK == SMB2_STATUS_SEVERITY_ERROR {
            let errorNo = nterror_to_errno(status)
            let description = nterror_to_str(status).map(String.init(cString:))
            try POSIXError.throwIfError(-errorNo, description: description)
        }
    }

    init(_ code: POSIXError.Code, description: String?) {
        let userInfo: [String: Any] =
            description.map({ [NSLocalizedFailureReasonErrorKey: $0] }) ?? [:]
        self = POSIXError(code, userInfo: userInfo)
    }
}

extension POSIXErrorCode {
    init(_ code: Int32) {
        self = POSIXErrorCode(rawValue: code) ?? .ECANCELED
    }
}

protocol EmptyInitializable {
    init()
}

extension Bool: EmptyInitializable { }

extension Dictionary where Key == URLResourceKey {
    private func value<T>(forKey key: Key) -> T? {
        return self[key] as? T
    }

    private func value<T>(forKey key: Key) -> T where T: EmptyInitializable {
        return self[key] as? T ?? T.init()
    }

    public var name: String? { 
        return self.value(forKey: .nameKey)
    }

    public var path: String? {
        return value(forKey: .pathKey)
    }

    public var fileResourceType: URLFileResourceType? {
        return value(forKey: .fileResourceTypeKey)
    }

    public var isDirectory: Bool {
        return value(forKey: .isDirectoryKey)
    }

    public var isRegularFile: Bool {
        return value(forKey: .isRegularFileKey)
    }

    public var isSymbolicLink: Bool {
        return value(forKey: .isSymbolicLinkKey)
    }

    public var fileSize: Int64? {
        return value(forKey: .fileSizeKey)
    }

    public var attributeModificationDate: Date? {
        return value(forKey: .attributeModificationDateKey)
    }

    public var contentModificationDate: Date? {
        return value(forKey: .contentModificationDateKey)
    }

    public var contentAccessDate: Date? {
        return value(forKey: .contentAccessDateKey)
    }

    public var creationDate: Date? {
        return value(forKey: .creationDateKey)
    }
}

extension Array where Element == [URLResourceKey: Any] {
    func sortedByPath(_ comparison: ComparisonResult) -> [[URLResourceKey: Any]] {
        return sorted {
            guard let firstPath = $0.path, let secPath = $1.path else {
                return false
            }
            return firstPath.localizedStandardCompare(secPath) == comparison
        }
    }

    var overallSize: Int64 {
        return reduce(
            0,
            { (result, value) -> Int64 in
                guard value.isRegularFile else { return result }
                return result + (value.fileSize ?? 0)
            })
    }
}

extension Array where Element == SMB2Share {
    func map(enumerateHidden: Bool) -> [(name: String, comment: String)] {
        var shares = self
        if enumerateHidden {
            shares = shares.filter { $0.props.type == .diskTree }
        } else {
            shares = shares.filter { !$0.props.isHidden && $0.props.type == .diskTree }
        }
        return shares.map { ($0.name, $0.comment) }
    }
}

extension Date {
    init(_ timespec: timespec) {
        self.init(
            timeIntervalSince1970: TimeInterval(timespec.tv_sec) + TimeInterval(
                timespec.tv_nsec / 1000) / TimeInterval(USEC_PER_SEC))
    }
}

extension Data {
    init<T: FixedWidthInteger>(value: T) {
        var value = value.littleEndian
        let bytes = Swift.withUnsafeBytes(of: &value) { Array($0) }
        self.init(bytes)
    }

    mutating func append<T: FixedWidthInteger>(value: T) {
        append(Data(value: value))
    }

    init(value uuid: UUID) {
        self.init([
            uuid.uuid.3, uuid.uuid.2, uuid.uuid.1, uuid.uuid.0,
            uuid.uuid.5, uuid.uuid.4, uuid.uuid.7, uuid.uuid.6,
            uuid.uuid.8, uuid.uuid.9, uuid.uuid.10, uuid.uuid.11,
            uuid.uuid.12, uuid.uuid.13, uuid.uuid.14, uuid.uuid.15,
        ])
    }

    mutating func append(value uuid: UUID) {
        append(Data(value: uuid))
    }

    func scanValue<T: FixedWidthInteger>(offset: Int, as: T.Type) -> T? {
        guard count >= offset + MemoryLayout<T>.size else { return nil }
        return T(littleEndian: withUnsafeBytes { $0.load(fromByteOffset: offset, as: T.self) })
    }

    func scanInt<T: FixedWidthInteger>(offset: Int, as: T.Type) -> Int? {
        return scanValue(offset: offset, as: T.self).map(Int.init)
    }
}

extension String {
    var canonical: String {
        return trimmingCharacters(in: .init(charactersIn: "/\\"))
    }
}

extension Stream {
    func withOpenStream(_ handler: () throws -> Void) rethrows {
        let shouldCloseStream = streamStatus == .notOpen
        if streamStatus == .notOpen {
            open()
        }
        defer {
            if shouldCloseStream {
                close()
            }
        }
        try handler()
    }
}

extension InputStream {
    func readData(maxLength length: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: length)
        let result = read(&buffer, maxLength: buffer.count)
        if result < 0 {
            throw streamError ?? POSIXError(.EIO, description: "Unknown stream error.")
        } else {
            return Data(buffer.prefix(result))
        }
    }
}

extension OutputStream {
    func write<DataType: DataProtocol>(_ data: DataType) throws -> Int {
        var buffer = Array(data)
        let result = write(&buffer, maxLength: buffer.count)
        if result < 0 {
            throw streamError ?? POSIXError(.EIO, description: "Unknown stream error.")
        } else {
            return result
        }
    }
}

func asyncHandler(_ continuation: CheckedContinuation<Void, Error>) -> (_ error: Error?) -> Void {
    return { error in
        if let error = error {
            continuation.resume(throwing: error)
            return
        }
        continuation.resume(returning: ())
    }
}

func asyncHandler<T>(_ continuation: CheckedContinuation<T, Error>) -> (Result<T, Error>) -> Void {
    return { result in
        continuation.resume(with: result)
    }
}
