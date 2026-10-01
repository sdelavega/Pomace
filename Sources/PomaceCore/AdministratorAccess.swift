import Foundation

/// Interactive elevation is limited to the locations offered by the app. It never
/// relaxes SafetyRules and is never used by scheduled sweeps.
public enum AdministratorAccess {
    private static let locations = ["/Applications", "/opt/homebrew", "/usr/local"]

    public static func supports(root: String) -> Bool {
        let path = canonical(root)
        return locations.contains { contains(path, in: $0) }
    }

    static func permits(path: String, root: String) -> Bool {
        let resolved = canonical(path)
        return supports(root: root) && contains(resolved, in: canonical(root))
            && locations.contains { contains(resolved, in: $0) }
    }

    static func canInspectResourceFork(at path: String) -> Bool {
        let size = getxattr(path, "com.apple.ResourceFork", nil, 0, 0, XATTR_SHOWCOMPRESSION)
        // An absent fork is safe; a denied/failed metadata probe is not evidence of absence.
        return size >= 0 || errno == ENOATTR
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardized.path
    }

    private static func contains(_ path: String, in root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    // Arguments are passed as argv, never interpolated into AppleScript source. AppleScript
    // quotes each argument for the shell, including spaces, quotes, and shell metacharacters.
    // No password is supplied, captured, or persisted; macOS owns authorization.
    static let script = """
    on run argv
        set command to ""
        set fileChecks to ""
        set checkingFiles to false
        repeat with argument in argv
            set value to contents of argument
            set quotedArgument to quoted form of value
            if checkingFiles then
                set fileChecks to fileChecks & "if [ ! -f " & quotedArgument & " ] || [ -L " & quotedArgument & " ]; then printf '%s' 'A selected path is no longer a regular file.' >&2; exit 1; fi; "
            else if value is "--" then
                set checkingFiles to true
            end if
            set command to command & quotedArgument & " "
        end repeat
        set command to fileChecks & command & "2>&1"
        try
            with timeout of 86400 seconds
                return do shell script command with prompt "Pomace needs administrator access to modify the selected Homebrew or application files." with administrator privileges
            end timeout
        on error errorMessage number errorNumber
            error ("POMACE_ADMIN_ERROR:" & errorNumber & ":" & errorMessage) number errorNumber
        end try
    end run
    """

    static func capture(_ binary: String, _ arguments: [String]) -> CompressorInvocation {
        let output = Subprocess.capture("/usr/bin/osascript", ["-e", script, "--", binary] + arguments)
        return interpret(output)
    }

    static func interpret(_ output: Subprocess.Output) -> CompressorInvocation {
        guard !output.succeeded,
              let marker = output.stderr.range(of: "POMACE_ADMIN_ERROR:") else { return .completed(output) }
        let detail = output.stderr[marker.upperBound...]
        let number = detail.prefix { $0 != ":" }
        if number == "-128" { return .authorizationCancelled }
        // Preserve the actual macOS/tool explanation, omitting our protocol marker.
        let message = detail.dropFirst(number.count + 1)
        return .completed(Subprocess.Output(stdout: output.stdout, stderr: String(message), code: output.code))
    }
}

enum CompressorInvocation: Sendable {
    case completed(Subprocess.Output)
    case authorizationCancelled
}

/// Dependency boundary for tests: production callers select standard or interactive access.
public struct CompressionExecutor: Sendable {
    public let isAdministrator: Bool
    let invoke: @Sendable (String, [String]) -> CompressorInvocation

    init(isAdministrator: Bool, invoke: @escaping @Sendable (String, [String]) -> CompressorInvocation) {
        self.isAdministrator = isAdministrator
        self.invoke = invoke
    }

    public static let standard = CompressionExecutor(isAdministrator: false) {
        .completed(Subprocess.capture($0, $1))
    }
    public static let administrator = CompressionExecutor(isAdministrator: true) {
        AdministratorAccess.capture($0, $1)
    }
}
