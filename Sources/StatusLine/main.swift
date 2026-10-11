import Foundation
import UsageCore

// usagebar-statusline: UsageBar's Claude Code status line command.
//
//   usagebar-statusline
//       Reads Claude Code's status line JSON on stdin, saves its rate limits
//       for UsageBar, and prints `<model> · 5h N% · wk N%`. Always exits 0:
//       a failing status line command blanks Claude Code's status line.
//
//   usagebar-statusline install <settings.json> [--replace]
//       Points that settings file's `statusLine` at this executable, after
//       backing the file up.

enum Usage {
    static let text = """
        usage: usagebar-statusline                                 (Claude Code pipes status line JSON in)
               usagebar-statusline install <settings.json> [--replace]

        """
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case nil:
    StatusLineCommand.run()
    exit(0)
case "install":
    exit(Installer.run(Array(arguments.dropFirst())))
case "-h", "--help":
    print(Usage.text, terminator: "")
    exit(0)
default:
    FileHandle.standardError.write(Data(Usage.text.utf8))
    exit(64)
}
