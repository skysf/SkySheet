import Foundation
import SkySheetCore
import SkySheetFiles


@MainActor
func conditionalRegressionChecks() {
    criteriaExtentChecks()
    blankCriterionChecks()
    boundedCheck("criteriaShape")
    boundaryCriteriaChecks()
    conditionalClippingChecks()
    compiledCriteriaChecks()
}

@MainActor
func criteriaExtentChecks() {
    group("conditional: criteriaExtent") {
        checkEqual(evaluate("COUNTIF(A1:A3,\"\")", ["A1": "1"], at: "B1"), num("2"), "explicit trailing blanks")
        checkEqual(evaluate("COUNTIF(A1:A3,\"\")", ["A1": "1", "D9": "x"], at: "B1"), num("2"), "unrelated content")
        checkEqual(evaluate("COUNTIF(A:A,\"\")", ["A1": "1"], at: "B1"), num("1048575"), "whole column blanks stay sparse")
        checkEqual(evaluate("COUNTIFS(A:A,\"\",B:B,\"\")", ["A1": "1", "B2": "2"], at: "C1"), num("1048574"), "union of occupied positions")
        checkEqual(evaluate("COUNTIF(Data!A:XFD,\"\")", at: "A1", otherSheets: ["Data": ["A1": "1"]]),
                   num("17179869183"), "whole sheet blanks stay sparse")
        checkEqual(evaluate("AVERAGEIF(A1:A3,\"\",B1:B3)", ["A1": "1", "B2": "4", "B3": "8"], at: "C1"), num("6"), "average over blank criteria")
    }
}

@MainActor
func blankCriterionChecks() {
    group("conditional: blankCriterion") {
        checkEqual(evaluate("COUNTIFS(A1:A1,B1)", ["A1": "0"], at: "C1"), num("1"), "empty criterion reference is zero")
        checkValue("SUMIF(A1:A2,B1,C1:C2)", ["A1": "0", "A2": "2", "C1": "7", "C2": "8"], num("7"))
    }
}

@MainActor
func criteriaShapeChecks() {
    group("conditional: criteriaShape") {
        checkValue("COUNTIFS(A1:A2,\">0\",99,99)", ["A1": "1", "A2": "2"], .error(.value))
    }
}

@MainActor
func boundaryCriteriaChecks() {
    group("conditional: boundaryCriteria") {
        let cells = ["A1": "1", "A2": "=\"\"", "B1": "10", "B2": "20", "B3": "30"]
        checkValue("COUNTIF(A1:A4,\"\")", cells, num("3"))
        checkValue("COUNTIF(A1:A4,\"<>\")", cells, num("2"))
        checkValue("SUMIF(A1:A4,\"\",B1:B4)", cells, num("50"))
        checkValue("SUMIFS(B1:B4,A1:A4,\"\")", cells, num("50"))
        checkValue("AVERAGEIFS(B1:B4,A1:A4,\"\")", cells, num("25"))
        checkValue("SUMIF(A1:A3,\"\",B1)", cells, num("50"))
        checkValue("AVERAGEIF(A1:A3,\"\",B1)", cells, num("25"))
        checkValue("SUMIFS(B1:B4,A1:A3,\"\")", cells, .error(.value))
        checkValue("AVERAGEIFS(B1:B4,A1:A3,\"\")", cells, .error(.value))
        checkValue("COUNTIFS(A1:A3,\"\",B1:B2,\">0\")", cells, .error(.value))
        checkValue("COUNTIFS(99,99,A1:A2,\">0\")", cells, .error(.value))
        checkValue("SUMIF(A1:A3,\"\",99)", cells, .error(.value))
        checkValue("COUNTIF(3:3,\"\")", ["A3": "1"], num("16383"))
        checkValue("COUNTIFS(A1:B2,\"\",C1:D2,\"\")", ["A1": "x", "D2": "y"], num("2"))
        checkEqual(evaluate("COUNTIFS(A1:A2,\"\",Other!B1:B2,\"\")", ["A1": "x"], otherSheets: ["Other": [:]]), num("1"), "cross-sheet blanks")
        checkValue("SUMIF(A1:A3,\"\",B1:B3)", ["A1": "1", "B2": "=#N/A"], .error(.na))
        checkValue("SUMIF(A1:A3,\"\",B1:B3)", ["A1": "1", "B1": "=#N/A", "B2": "3"], num("3"))
    }
}

@MainActor
func conditionalClippingChecks() {
    group("conditional: shifted sum range clipped at worksheet edge") {
        checkValue("SUMIF(A:A,\"x\",B2:B10)", ["A1": "x", "A2": "x", "B2": "5", "B3": "7"], num("12"))
        checkValue("AVERAGEIF(A:A,\"x\",B2:B10)", ["A1": "x", "A2": "x", "B2": "5", "B3": "7"], num("6"))
        checkValue("SUMIF(1:1,\"x\",B2)", ["A1": "x", "B1": "x", "B2": "5", "C2": "7"], num("12"))
        checkValue("SUMIF(A1:B2,\"x\",XFD1048575)", ["A1": "x", "A2": "x", "B1": "x", "XFD1048575": "5", "XFD1048576": "7"], num("12"))
        checkValue("COUNTIFS(A1:A4,\"<>\",B1:B4,\">0\")", ["A1": "1", "A2": "=\"\"", "B1": "1", "B2": "2", "B3": "3"], num("2"))
    }
}

@MainActor
func compiledCriteriaChecks() {
    group("conditional: compiled criteria preserve wildcard semantics") {
        let cells = ["A1": "c7", "A2": "C7", "A3": "c*", "A4": "c?", "A5": "c~", "A6": "c77", "A7": "straße", "A8": "STRASSE", "A9": "e\u{0301}"]
        for (criterion, count) in [("c7", 2), ("c~7", 2), ("c~*", 1), ("c~?", 1), ("c~", 1), ("c?", 5), ("c*", 6), ("straße", 1), ("é", 1)] {
            checkValue("COUNTIF(A1:A9,\"\(criterion)\")", cells, .number(Decimal(count)))
        }
    }
}
