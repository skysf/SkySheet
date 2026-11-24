import Foundation
import SkySheetCore

/// 打开工作簿后的共同起点。保留原包或 CSV 的写法，以便保存时核对；字体测量由各平台的界面负责。
public struct LoadedWorkbook: Sendable {
    public var workbook: Workbook
    /// 和模型来自同一次读取；自动保存拿它识别其他程序随后写入的内容。
    public let originalData: Data
    public let source: XLSXSource?
    public let csvFormat: CSVFormat?
    public let recalcCache: RecalcCache

    public init(contentsOf url: URL, typeName: String? = nil) throws {
        try self.init(data: Data(contentsOf: url), url: url, typeName: typeName)
    }

    public init(data: Data, url: URL, typeName: String? = nil, history: WorkbookHistory? = nil) throws {
        originalData = data
        if Self.isDelimitedText(url: url, typeName: typeName) {
            let csv = try CSVReader.read(data, sheetName: url.deletingPathExtension().lastPathComponent)
            let previous = try history?.latestWorkbook(matching: data)
            workbook = previous?.workbook ?? csv.workbook
            source = previous?.source
            csvFormat = csv.format
        } else {
            let document = try XLSXReader.readDocument(data)
            workbook = document.workbook
            source = document.source
            csvFormat = nil
        }
        recalcCache = RecalcCache()
        Recalculator.recalculate(&workbook, options: RecalcOptions(cache: recalcCache))
    }

    public static func isDelimitedText(url: URL? = nil, typeName: String?) -> Bool {
        if let typeName, typeName.contains("separated-values") || typeName.contains("delimited") { return true }
        return ["csv", "tsv", "txt"].contains(url?.pathExtension.lowercased() ?? "")
    }
}
