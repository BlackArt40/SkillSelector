import Foundation
import OSLog

public enum AppLogCategory: String, Codable, Hashable, Sendable {
    case scanning
    case persistence
    case operations

}

public struct AppDiagnostic: Codable, Hashable, Sendable {
    public let timestamp: Date
    public let category: AppLogCategory
    public let code: String
    public let message: String

    public init(
        timestamp: Date = Date(),
        category: AppLogCategory,
        code: String,
        message: String
    ) {
        self.timestamp = timestamp
        self.category = category
        self.code = code
        self.message = message
    }
}

public final class DiagnosticStore: @unchecked Sendable {
    public static let shared = DiagnosticStore()

    private let lock = NSLock()
    private let capacity: Int
    private let subsystem: String
    private var events: [AppDiagnostic] = []

    /// - Parameter subsystem: OSLog subsystem for emitted events. The app
    ///   layer owns its identifier and passes it here.
    public init(capacity: Int = 200, subsystem: String = "com.skillselector.app") {
        self.capacity = max(1, capacity)
        self.subsystem = subsystem
    }

    public func record(
        category: AppLogCategory,
        code: String,
        message: String,
        redactor: Redactor = Redactor()
    ) {
        let event = AppDiagnostic(
            category: category,
            code: redactor.redact(code),
            message: redactor.redact(message)
        )
        lock.lock()
        events.append(event)
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
        lock.unlock()
        DiagnosticLogger.write(event, subsystem: subsystem)
    }

    public func recent() -> [AppDiagnostic] {
        lock.lock()
        let result = events
        lock.unlock()
        return result
    }
}

public enum DiagnosticLogger {
    static func write(_ event: AppDiagnostic, subsystem: String) {
        let message = "[\(event.code)] \(event.message)"
        Logger(subsystem: subsystem, category: event.category.rawValue)
            .info("\(message, privacy: .public)")
    }
}
