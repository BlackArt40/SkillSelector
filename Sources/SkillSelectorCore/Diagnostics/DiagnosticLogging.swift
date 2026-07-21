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
    private var events: [AppDiagnostic] = []

    public init(capacity: Int = 200) {
        self.capacity = max(1, capacity)
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
        DiagnosticLogger.write(event)
    }

    public func recent() -> [AppDiagnostic] {
        lock.lock()
        let result = events
        lock.unlock()
        return result
    }
}

public enum DiagnosticLogger {
    private static let subsystem = "com.skillselector.app"
    private static let scanning = Logger(subsystem: subsystem, category: AppLogCategory.scanning.rawValue)
    private static let persistence = Logger(subsystem: subsystem, category: AppLogCategory.persistence.rawValue)
    private static let operations = Logger(subsystem: subsystem, category: AppLogCategory.operations.rawValue)


    static func write(_ event: AppDiagnostic) {
        let message = "[\(event.code)] \(event.message)"
        logger(for: event.category).info("\(message, privacy: .public)")
    }

    private static func logger(for category: AppLogCategory) -> Logger {
        switch category {
        case .scanning: scanning
        case .persistence: persistence
        case .operations: operations

        }
    }
}
