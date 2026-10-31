// fmgrep — grep with meaning, powered by Apple's on-device Foundation Model.

import Foundation

var options: Options
do {
    options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
} catch let error as OptError {
    switch error {
    case .message(let message):
        FileHandle.standardError.write("fmgrep: \(message)\n".data(using: .utf8)!)
        exit(2)
    case .exit(let code):
        exit(code)
    }
} catch {
    FileHandle.standardError.write("fmgrep: \(error)\n".data(using: .utf8)!)
    exit(2)
}

// Drain stdin up front when it is one of the inputs.
if options.paths.isEmpty || options.paths.contains("-") {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    stdinText = String(data: data, encoding: .utf8)
        ?? String(data: data, encoding: .isoLatin1)
        ?? ""
}

do {
    try requireAvailableModel()
} catch {
    FileHandle.standardError.write("fmgrep: \(error)\n".data(using: .utf8)!)
    exit(2)
}
prewarmModel()

let files: [FileSpec]
do {
    files = try collectFiles(options: options)
} catch {
    FileHandle.standardError.write("fmgrep: \(error)\n".data(using: .utf8)!)
    exit(2)
}

if options.stats {
    reportStats(options: options, files: files)
    exit(0)
}

if files.isEmpty {
    exit(options.invert ? 0 : 1)
}

let code = await runScan(options: options, files: files)
exit(code)
