// Walker — turn command-line paths into a list of files to scan.

import Foundation

struct FileSpec {
    let id: Int
    let display: String      // what we print
    let url: URL?            // nil => stdin
}

enum WalkError: Error { case notDirectory(String) }

func collectFiles(options: Options) throws -> [FileSpec] {
    var specs: [FileSpec] = []
    var nextID = 0
    let fm = FileManager.default

    func globMatch(_ name: String) -> Bool {
        guard !options.includeGlobs.isEmpty else { return true }
        return options.includeGlobs.contains { fnmatchErrnoFree($0, name) }
    }

    func excluded(_ path: String, isDir: Bool) -> Bool {
        let name = (path as NSString).lastPathComponent
        return options.excludeGlobs.contains { glob in
            fnmatchErrnoFree(glob, name) || fnmatchErrnoFree(glob, path)
        }
    }

    func addRegularFile(url: URL, display: String, explicit: Bool) {
        guard globMatch(display) else { return }
        // Oversized and unreadable files are skipped silently during walks,
        // like grep skips binaries; an explicit command-line file gets one line.
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size > options.maxFileBytes {
            if explicit {
                FileHandle.standardError.write("fmgrep: \(display): file is larger than --max-file-bytes\n".data(using: .utf8)!)
            }
            return
        }
        specs.append(FileSpec(id: nextID, display: display, url: url))
        nextID += 1
    }

    func walk(dir url: URL, prefix: String) {
        guard let entries = try? fm.contentsOfDirectory(atPath: url.path) else { return }
        for name in entries.sorted() {
            let child = url.appendingPathComponent(name)
            let display = prefix.isEmpty ? name : prefix + "/" + name
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: child.path, isDirectory: &isDir) else { continue }

            // Never follow symlinks (avoids cycles and duplicated work).
            if let type = try? (child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink), type == true { continue }

            if isDir.boolValue {
                guard options.recursive else { continue }
                if excluded(child.path, isDir: true) { continue }
                walk(dir: child, prefix: display)
            } else {
                if excluded(child.path, isDir: false) { continue }
                addRegularFile(url: child, display: display, explicit: false)
            }
        }
    }

    if options.paths.isEmpty {
        // grep convention: no files means read stdin.
        specs.append(FileSpec(id: nextID, display: "(standard input)", url: nil))
        return specs
    }

    for path in options.paths {
        if path == "-" {
            specs.append(FileSpec(id: nextID, display: "(standard input)", url: nil))
            nextID += 1
            continue
        }
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            FileHandle.standardError.write("fmgrep: \(path): No such file or directory\n".data(using: .utf8)!)
            continue
        }
        if isDir.boolValue {
            guard options.recursive else {
                FileHandle.standardError.write("fmgrep: \(path): Is a directory (use -r)\n".data(using: .utf8)!)
                continue
            }
            // GNU grep -r DIR prints paths including DIR; mirror that.
            walk(dir: url, prefix: path.hasSuffix("/") ? String(path.dropLast()) : path)
        } else {
            addRegularFile(url: url, display: path, explicit: true)
        }
    }
    return specs
}

/// fnmatch(3) returns 0 on success, nonzero (FNM_NOMATCH) on failure.
/// FNM_PATHNAME off so `*` can cross directories in whole-path patterns.
private func fnmatchErrnoFree(_ pattern: String, _ string: String) -> Bool {
    fnmatch(pattern, string, 0) == 0
}
