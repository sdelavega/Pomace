import Foundation
import PackagePlugin

@main
struct CompileStrings: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let catalog = URL(fileURLWithPath: target.directory.string)
            .appending(path: "Resources/Localizable.xcstrings")
        let output = context.pluginWorkDirectoryURL.appending(path: "Resources")
        // A prebuild command lets SwiftPM discover and copy whole .lproj directories,
        // preserving locale paths instead of flattening individual generated files.
        return [.prebuildCommand(
            displayName: "Compile Localizable.xcstrings with plural rules",
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["xcstringstool", "compile", catalog.path,
                        "--output-directory", output.path,
                        "--format", "stringsAndStringsdict"],
            outputFilesDirectory: output
        )]
    }
}
