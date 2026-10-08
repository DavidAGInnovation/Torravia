import Foundation

struct HeadlessOptions {
    var port: Int?
    var allowsLAN = false
    var webUIDirectory: URL?
    var tokenFileURL: URL?

    static func parse(_ arguments: [String]) throws -> HeadlessOptions {
        var result = HeadlessOptions()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--headless": break
            case "--allow-lan": result.allowsLAN = true
            case "--webui-port", "--webui-directory", "--token-file":
                index += 1
                guard index < arguments.count, !arguments[index].hasPrefix("--") else {
                    throw failure("Missing value for \(argument).")
                }
                if argument == "--webui-port" {
                    guard let port = Int(arguments[index]), (1024...65535).contains(port) else {
                        throw failure("Browser control port must be between 1024 and 65535.")
                    }
                    result.port = port
                } else {
                    let path = (arguments[index] as NSString).expandingTildeInPath
                    guard path.hasPrefix("/") else { throw failure("Use an absolute path for \(argument).") }
                    if argument == "--token-file" { result.tokenFileURL = URL(fileURLWithPath: path) }
                    else { result.webUIDirectory = URL(fileURLWithPath: path, isDirectory: true) }
                }
            default: throw failure("Unknown option: \(argument). Use --help for usage.")
            }
            index += 1
        }
        return result
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "Torravia.Headless", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static let help = """
    Usage: /Applications/Torravia.app/Contents/MacOS/Torravia --headless [options]
      --webui-port PORT       Override the saved browser port (1024–65535).
      --allow-lan             Allow connections from other devices; default is loopback.
      --webui-directory PATH  Serve a Torravia-compatible frontend with index.html.
      --token-file PATH       Write the private token to a readable sandbox-permitted path.
      --help                  Show this help.
    Keeps the existing queue, download location, RSS rules, and HTTPS settings.
    The private access token is written to headless-token in the queue's State directory.
    Stop with Ctrl-C or SIGTERM. Close the desktop app before starting headless mode.
    """
}
