import SwiftUI
import UniformTypeIdentifiers

/// Wraps backup JSON so it can be saved with the system file exporter (Files, iCloud Drive, …),
/// which reports success. That lets MONO record when a backup was really saved.
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
