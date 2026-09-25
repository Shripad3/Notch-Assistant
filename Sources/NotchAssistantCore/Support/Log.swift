import os

/// View with: log stream --level info --predicate 'subsystem == "dev.shripad.NotchAssistant"'
public enum Log {
    public static let subsystem = "dev.shripad.NotchAssistant"
    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let coordinator = Logger(subsystem: subsystem, category: "coordinator")
    public static let speech = Logger(subsystem: subsystem, category: "speech")
    public static let intelligence = Logger(subsystem: subsystem, category: "intelligence")
    public static let tools = Logger(subsystem: subsystem, category: "tools")
}
