import Foundation
import os

/// Centralized `os.Logger` subsystems — one per module, all sharing the bundle subsystem.
/// Importing this gives every module the same logging conventions.
public enum AppLog {
    public static let subsystem = "com.agentsmith.app"

    public static let watcher    = Logger(subsystem: subsystem, category: "Watcher")
    public static let triage     = Logger(subsystem: subsystem, category: "Triage")
    public static let classifier = Logger(subsystem: subsystem, category: "Classifier")
    public static let filer      = Logger(subsystem: subsystem, category: "Filer")
    public static let ledger     = Logger(subsystem: subsystem, category: "Ledger")
    public static let smith      = Logger(subsystem: subsystem, category: "Smith")
    public static let app        = Logger(subsystem: subsystem, category: "App")
}
