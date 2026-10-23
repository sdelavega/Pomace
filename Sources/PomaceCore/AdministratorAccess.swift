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

    // uid and chainFloor are explicit test seams. Production always uses uid 0 and /.
    // Tests execute this exact script as the current user in disposable directories.
    static let boundaryScript = #"""
    set -eu
    PATH=/usr/bin:/bin
    fail() { printf '%s\n' "$1" >&2; exit 1; }
    changed='The confirmed compressor changed. Choose it again before using administrator access.'
    unsafe='Administrator access is only used for folders that only administrators can change'
    digest() { /usr/bin/shasum -a 256 "$1" | /usr/bin/cut -d ' ' -f 1; }
    private_dir() {
        case "$1" in /private/tmp/pomace-*) ;; *) fail "$changed" ;; esac
        [ "${1%/*}" = /private/tmp ] || fail "$changed"
        [ -d "$1" ] && [ ! -L "$1" ] || fail "$changed"
        [ "$(/usr/bin/stat -f '%u:%Lp' "$1")" = "$(/usr/bin/id -u):700" ] || fail "$changed"
    }
    directory() {
        [ -d "$1" ] && [ ! -L "$1" ] || fail "$unsafe"
        local owner mode
        read -r owner mode <<< "$(/usr/bin/stat -f '%u %Lp' "$1")"
        [ "$owner" = "$uid" ] || fail "$unsafe"
        (( (8#$mode & 0022) == 0 )) || fail "$unsafe"
        # ACLs can grant directory writes independently of the Unix mode bits.
        local description
        description="$(/bin/ls -lde "$1")"
        [[ "$description" != *$'\n'* ]] || fail "$unsafe"
    }
    targets() {
        local root="$1" uid="$2" floor="$3" p parent physical d found=false
        shift 3
        [ "$(cd -P "$root" && pwd -P)" = "$root" ] || fail "$unsafe"
        for p in "$@"; do
            if [ "$found" = false ]; then
                if [ "$p" = -- ]; then found=true; fi
                continue
            fi
            case "$p" in "$root"/*) ;; *) fail "$unsafe" ;; esac
            [ -f "$p" ] && [ ! -L "$p" ] || fail "$unsafe"
            [ "$(/usr/bin/stat -f '%l' "$p")" = 1 ] || fail "$unsafe"
            parent="${p%/*}"
            physical="$(cd -P "$parent" && pwd -P)/${p##*/}"
            [ "$physical" = "$p" ] || fail "$unsafe"
            case "$physical" in "$root"/*) ;; *) fail "$unsafe" ;; esac
            d="$parent"
            while :; do
                directory "$d"
                [ "$d" != "$floor" ] || break
                [ "$d" != / ] || fail "$unsafe"
                d="${d%/*}"
                [ -n "$d" ] || d=/
            done
        done
        [ "$found" = true ] || fail "$unsafe"
    }
    phase="$1"
    shift
    case "$phase" in
        validate) targets "$@" ;;
        prepare)
            source="$1" expected="$2"
            [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || fail "$changed"
            umask 077
            work="$(/usr/bin/mktemp -d /private/tmp/pomace-XXXXXXXX)"
            trap '/bin/rm -rf "$work"' EXIT
            /bin/cp "$source" "$work/compressor"
            /bin/chmod 500 "$work/compressor"
            [ "$(digest "$work/compressor")" = "$expected" ] || fail "$changed"
            printf '%s\n' "$work"
            trap - EXIT
            ;;
        run)
            work="$1" source="$2" expected="$3" root="$4" uid="$5" floor="$6"
            shift 6
            private_dir "$work"
            [ -f "$work/compressor" ] && [ ! -L "$work/compressor" ] || fail "$changed"
            [ "$(digest "$source")" = "$expected" ] || fail "$changed"
            [ "$(digest "$work/compressor")" = "$expected" ] || fail "$changed"
            targets "$root" "$uid" "$floor" "$@"
            "$work/compressor" "$@"
            ;;
        cleanup) private_dir "$1"; /bin/rm -rf "$1" ;;
        *) exit 2 ;;
    esac
    """#

    static func boundaryArguments(_ arguments: [String]) -> [String] {
        // Privileged mode ignores BASH_ENV and imported functions/options.
        ["-p", "-c", boundaryScript, "pomace"] + arguments
    }

    static func validates(paths: [String], root: String) -> Bool {
        Subprocess.capture("/bin/bash", boundaryArguments(["validate", root, "0", "/", "--"] + paths)).succeeded
    }

    // Arguments are passed as argv, never interpolated into AppleScript source. AppleScript
    // quotes each argument for the shell, including spaces, quotes, and shell metacharacters.
    // No password is supplied, captured, or persisted; macOS owns authorization.
    static let script = """
    on run argv
        set authorizationPrompt to item 1 of argv
        set changedFileMessage to quoted form of (item 2 of argv)
        set command to ""
        set fileChecks to ""
        set checkingFiles to false
        repeat with argument in items 3 thru -1 of argv
            set value to contents of argument
            set quotedArgument to quoted form of value
            if checkingFiles then
                set fileChecks to fileChecks & "if [ ! -f " & quotedArgument & " ] || [ -L " & quotedArgument & " ]; then printf '%s' " & changedFileMessage & " >&2; exit 1; fi; "
            else if value is "--" then
                set checkingFiles to true
            end if
            set command to command & quotedArgument & " "
        end repeat
        set command to fileChecks & command & "2>&1"
        try
            with timeout of 86400 seconds
                return do shell script command with prompt authorizationPrompt with administrator privileges
            end timeout
        on error errorMessage number errorNumber
            error ("POMACE_ADMIN_ERROR:" & errorNumber & ":" & errorMessage) number errorNumber
        end try
    end run
    """

    static func capture(_ binary: String, _ arguments: [String], prompt: String, fileChangedMessage: String) -> CompressorInvocation {
        let output = Subprocess.capture("/usr/bin/osascript", ["-e", script, "--", prompt, fileChangedMessage, binary] + arguments)
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
    var prepare: (@Sendable (String, String) -> CompressorInvocation)?
    var invokePrepared: (@Sendable (String, String, String, String, [String]) -> CompressorInvocation)?
    var cleanup: (@Sendable (String) -> Void)?

    init(isAdministrator: Bool, invoke: @escaping @Sendable (String, [String]) -> CompressorInvocation) {
        self.isAdministrator = isAdministrator
        self.invoke = invoke
    }

    public static let standard = CompressionExecutor(isAdministrator: false) {
        .completed(Subprocess.capture($0, $1))
    }
    public static func administrator(prompt: String, fileChangedMessage: String) -> CompressionExecutor {
        let transport: @Sendable ([String]) -> CompressorInvocation = { arguments in
            AdministratorAccess.capture("/bin/bash", AdministratorAccess.boundaryArguments(arguments),
                                        prompt: prompt, fileChangedMessage: fileChangedMessage)
        }
        var executor = CompressionExecutor(isAdministrator: true) { _, _ in
            .completed(Subprocess.Output(stdout: "", stderr: "An administrator session is required", code: 1))
        }
        executor.prepare = { transport(["prepare", $0, $1]) }
        executor.invokePrepared = { directory, binary, hash, root, arguments in
            transport(["run", directory, binary, hash, root, "0", "/"] + arguments)
        }
        executor.cleanup = { _ = transport(["cleanup", $0]) }
        return executor
    }
}
