import Foundation
import SkySheetCore

/// xl/workbook.xml（设计 7.2 节）：只改 `<sheets>`（增、删、改名、排序、隐藏）、`<definedNames>`、`<calcPr>`，
/// 以及跟着 sheet 位置走的 activeTab。其余照抄。
enum WorkbookWriter {
    /// CT_Workbook 里子元素的先后。
    static let order = ["fileVersion", "fileSharing", "workbookPr", "workbookProtection", "bookViews", "sheets",
                        "functionGroups", "externalReferences", "definedNames", "calcPr", "oleSize",
                        "customWorkbookViews", "pivotCaches", "smartTagPr", "smartTagTypes", "webPublishing",
                        "fileRecoveryPr", "webPublishObjects", "extLst"]

    /// 一张 sheet 在新包里的条目：模型里的 sheet 和它在 workbook 关系里的 id。
    struct Entry {
        let sheet: Sheet
        let relationshipID: String
    }

    /// `<sheets>` 里的一项：我们读了的工作表按 sheetId 认；别的（图表 sheet 等）按它在原文件里的位置认，原文照抄。
    private enum Slot: Hashable {
        case sheet(Int)
        case other(Int)
    }

    /// 在原来的 workbook.xml 上改。`existing` 是原包里有部件的 sheet（编号）；`recalculate` 为真时加 fullCalcOnLoad。
    /// 什么都不用改返回 nil：部件原字节照抄。
    static func patch(_ original: XMLFragments, part: String, entries: [Entry], workbook: Workbook, baseline: Workbook?,
                      existing: Set<Int>, recalculate: Bool) throws(XLSXWriteError) -> Data? {
        var document = original
        guard let sheetsRaw = document.child("sheets")?.raw, var list = XMLFragments(Data(sheetsRaw.utf8)) else {
            throw XLSXWriteError.unreadablePart(part)
        }
        let p = document.prefix
        let relationshipPrefix = document.prefix(forNamespace: OOXML.relationships)
        let baselineSheets = Dictionary(baseline?.sheets.map { ($0.id, $0) } ?? [], uniquingKeysWith: { first, _ in first })
        let live = Set(entries.map(\.sheet.id))

        // 原来的顺序。别的条目跟在它前面那张（还在的）工作表后面走。
        var originalSlots: [Slot] = []
        var raws: [Slot: String] = [:]
        var followers: [Int?: [Slot]] = [:]
        var anchor: Int?
        for (position, child) in list.children.enumerated() {
            if let id = XMLFragments.attribute("sheetId", in: child.raw).flatMap({ Int($0) }), existing.contains(id) {
                originalSlots.append(.sheet(id))
                raws[.sheet(id)] = child.raw
                if live.contains(id) { anchor = id }
            } else {
                originalSlots.append(.other(position))
                raws[.other(position)] = child.raw
                followers[anchor, default: []].append(.other(position))
            }
        }
        var slots = followers[nil] ?? []
        for entry in entries {
            slots.append(.sheet(entry.sheet.id))
            slots += followers[entry.sheet.id] ?? []
        }

        let entryByID = Dictionary(entries.map { ($0.sheet.id, $0) }, uniquingKeysWith: { first, _ in first })
        let finalRaws = slots.map { slot -> String in
            guard case .sheet(let id) = slot, let entry = entryByID[id] else { return raws[slot] ?? "" }
            guard var raw = raws[slot] else { return sheetElement(entry, p, relationshipPrefix) }
            let old = baselineSheets[id]
            if old?.name != entry.sheet.name {
                raw = XMLFragments.settingAttribute("name", to: entry.sheet.name, in: raw)
            }
            if old?.visibility != entry.sheet.visibility {
                raw = XMLFragments.settingAttribute("state", to: state(entry.sheet.visibility), in: raw)
            }
            return raw
        }
        var changed = false
        let sheetsChanged = finalRaws != list.children.map(\.raw)
        if sheetsChanged {
            list.children = finalRaws.map { XMLFragments.Child(name: "sheet", raw: $0) }
            document.set("sheets", raw: String(decoding: list.serialized(), as: UTF8.self), order: order)
            changed = true
        }

        let position = Dictionary(slots.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let names = workbook.definedNames
        if names != (baseline?.definedNames ?? []) || (sheetsChanged && names.contains { $0.sheetIndex != nil }) {
            let raw = definedNames(names, p) { index in
                workbook.sheets.indices.contains(index) ? position[.sheet(workbook.sheets[index].id)] : nil
            }
            document.set("definedNames", raw: raw, order: order)
            changed = true
        }

        if recalculate {
            let raw = document.child("calcPr")?.raw ?? "<\(p)calcPr/>"
            if XMLFragments.attribute("fullCalcOnLoad", in: raw) != "1" {
                document.set("calcPr", raw: XMLFragments.settingAttribute("fullCalcOnLoad", to: "1", in: raw), order: order)
                changed = true
            }
        }

        if sheetsChanged, let viewsRaw = document.child("bookViews")?.raw, var views = XMLFragments(Data(viewsRaw.utf8)) {
            let firstVisible = slots.firstIndex { slot in
                guard case .sheet(let id) = slot else { return false }
                return entryByID[id]?.sheet.visibility == .visible
            } ?? 0
            /// 原来第 n 个现在排第几；那张删了（或者当前页签被隐藏了）就落到第一张看得见的。
            func moved(_ old: Int, mustBeVisible: Bool) -> Int {
                guard originalSlots.indices.contains(old), let now = position[originalSlots[old]] else { return firstVisible }
                if mustBeVisible, case .sheet(let id) = originalSlots[old], entryByID[id]?.sheet.visibility != .visible {
                    return firstVisible
                }
                return now
            }
            for index in views.children.indices where views.children[index].name == "workbookView" {
                var tag = views.children[index].raw
                let active = XMLFragments.attribute("activeTab", in: tag).flatMap { Int($0) } ?? 0
                let newActive = moved(active, mustBeVisible: true)
                if newActive != active {
                    tag = XMLFragments.settingAttribute("activeTab", to: String(newActive), in: tag)
                }
                if let first = XMLFragments.attribute("firstSheet", in: tag).flatMap({ Int($0) }) {
                    let newFirst = moved(first, mustBeVisible: false)
                    if newFirst != first { tag = XMLFragments.settingAttribute("firstSheet", to: String(newFirst), in: tag) }
                }
                views.children[index].raw = tag
            }
            document.set("bookViews", raw: String(decoding: views.serialized(), as: UTF8.self), order: order)
        }
        return changed ? document.serialized() : nil
    }

    /// 新建的 workbook.xml（csv 另存成 xlsx）。
    static func fresh(entries: [Entry], workbook: Workbook) -> Data {
        var xml = OOXML.declaration + "<workbook xmlns=\"\(OOXML.main)\" xmlns:r=\"\(OOXML.relationships)\">"
        if workbook.dateSystem == .from1904 { xml += "<workbookPr date1904=\"1\"/>" }
        let active = workbook.sheets.firstIndex { $0.visibility == .visible } ?? 0
        xml += "<bookViews><workbookView activeTab=\"\(active)\"/></bookViews>"
        xml += "<sheets>" + entries.map { sheetElement($0, "", "r:") }.joined() + "</sheets>"
        xml += definedNames(workbook.definedNames, "") { workbook.sheets.indices.contains($0) ? $0 : nil } ?? ""
        return Data((xml + "<calcPr fullCalcOnLoad=\"1\"/></workbook>").utf8)
    }

    // MARK: - 元素

    private static func state(_ visibility: SheetVisibility) -> String? {
        switch visibility {
        case .visible: nil
        case .hidden: "hidden"
        case .veryHidden: "veryHidden"
        }
    }

    /// 新 sheet 的 `<sheet>`。根元素上没声明关系的命名空间（极少见）就在元素自己身上声明。
    private static func sheetElement(_ entry: Entry, _ p: String, _ relationshipPrefix: String?) -> String {
        var tag = "<\(p)sheet name=\"\(XMLText.attribute(entry.sheet.name))\" sheetId=\"\(entry.sheet.id)\""
        if let state = state(entry.sheet.visibility) { tag += " state=\"\(state)\"" }
        if let r = relationshipPrefix { return tag + " \(r)id=\"\(entry.relationshipID)\"/>" }
        return tag + " xmlns:r=\"\(OOXML.relationships)\" r:id=\"\(entry.relationshipID)\"/>"
    }

    /// `<definedNames>`；没有名称返回 nil（删掉这个元素）。`position` 把模型里的 sheet 下标换成 `<sheets>` 里的位置，
    /// 换不了的（不该发生）那个名称不写：写成全局的可能和别的名称撞名，Excel 会报错。
    private static func definedNames(_ names: [DefinedName], _ p: String, position: (Int) -> Int?) -> String? {
        let items = names.compactMap { name -> String? in
            var tag = "<\(p)definedName name=\"\(XMLText.attribute(name.name))\""
            if let index = name.sheetIndex {
                guard let local = position(index) else { return nil }
                tag += " localSheetId=\"\(local)\""
            }
            for key in name.extraAttributes.keys.sorted() {
                tag += " \(key)=\"\(XMLText.attribute(name.extraAttributes[key] ?? ""))\""
            }
            return tag + ">" + XMLText.formula(name.formula) + "</\(p)definedName>"
        }
        return items.isEmpty ? nil : "<\(p)definedNames>" + items.joined() + "</\(p)definedNames>"
    }
}
