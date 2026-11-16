import Foundation
import SkySheetCore
import SkySheetFiles


@MainActor
func inputRegressionChecks() {
    boundedCheck("whitespaceInput")
    boundedCheck("bareCurrencyInput")
    boundedCheck("inputTimeOverflow")
}

@MainActor
func whitespaceInputChecks() {
    group("input: whitespaceInput") {
        for text in [" ", "   ", "\t", "\n"] {
            checkEqual(CellInput.parse(text), .value(.text(text)), "whitespace stays text")
        }
    }
}

@MainActor
func bareCurrencyInputChecks() {
    group("input: bareCurrencyInput") {
        checkEqual(CellInput.parse("¥"), .value(.text("¥")), "currency without digits stays text")
    }
}

@MainActor
func inputTimeOverflowChecks() {
    group("input: inputTimeOverflow") {
        let text = "2026-11-15 23:59:9223372036854775807"
        checkEqual(CellInput.parse(text), .value(.text(text)), "invalid seconds stay text")
    }
}
