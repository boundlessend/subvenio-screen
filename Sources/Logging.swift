import os

/// unified logging вместо NSLog: категории видно в Console.app по подсистеме,
/// уровни отделяют штатное от аварийного
enum Log {
    private static let subsystem = "dev.senya.SubvenioScreen"

    static let plugins = Logger(subsystem: subsystem, category: "plugins")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let gamma = Logger(subsystem: subsystem, category: "gamma")
    static let effects = Logger(subsystem: subsystem, category: "effects")
    static let overlay = Logger(subsystem: subsystem, category: "overlay")
}
