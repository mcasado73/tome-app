import Foundation

actor SessionStore {
    private let sessionsDirectory: URL
    private var currentFile: URL?
    private var fileHandle: FileHandle?
    private let encoder = JSONEncoder()

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        sessionsDirectory = appSupport.appendingPathComponent("Tome/sessions", isDirectory: true)

        try? FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)

        encoder.dateEncodingStrategy = .iso8601
    }

    func startSession() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let filename = "session_\(formatter.string(from: Date())).jsonl"
        currentFile = sessionsDirectory.appendingPathComponent(filename)

        FileManager.default.createFile(atPath: currentFile!.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: currentFile!)
    }

    func appendRecord(_ record: SessionRecord) {
        guard let fileHandle else { return }

        do {
            let data = try encoder.encode(record)
            fileHandle.seekToEndOfFile()
            fileHandle.write(data)
            fileHandle.write("\n".data(using: .utf8)!)
        } catch {
            print("SessionStore: failed to write record: \(error)")
        }
    }

    /// Closes the session file and returns its URL, so a caller that decides the
    /// session was a false start can delete it.
    @discardableResult
    func endSession() -> URL? {
        try? fileHandle?.close()
        fileHandle = nil
        let ended = currentFile
        currentFile = nil
        return ended
    }

    func discard(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    var sessionsDirectoryURL: URL { sessionsDirectory }
}
