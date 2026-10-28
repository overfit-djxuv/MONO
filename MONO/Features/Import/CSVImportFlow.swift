import SwiftUI
import UniformTypeIdentifiers

/// The rows of a picked CSV file, wrapped so a sheet can be presented for them.
struct CSVRecords: Identifiable {
    let id = UUID()
    let rows: [[String]]
}

/// File picker → column mapping and preview sheet. Attach with `.csvImport(isPresented:)` to any screen.
struct CSVImportFlow: ViewModifier {
    @Binding var isPresented: Bool
    @Environment(ErrorCenter.self) private var errors
    @State private var records: CSVRecords?

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $isPresented, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
                switch result {
                case .failure(let e): errors.report(e, doing: "Couldn’t open file")
                case .success(let url):
                    do { records = CSVRecords(rows: try CSVImport.load(from: url)) }
                    catch { errors.report(error, doing: "Can’t import") }
                }
            }
            .sheet(item: $records) { CSVImportView(records: $0.rows) }
    }
}

extension View {
    func csvImport(isPresented: Binding<Bool>) -> some View { modifier(CSVImportFlow(isPresented: isPresented)) }
}
