import Foundation
import SkySheetCore
import SkySheetFiles


@MainActor
func textRegressionChecks() {
    unicodeScalarTextChecks()
    boundedCheck("largeTextOffset")
    textBoundariesChecks()
}

@MainActor
func unicodeScalarTextChecks() {
    group("text: unicodeScalarText") {
        checkValue("LEFT(\"😀X\",1)", .text("😀"))
        checkValue("LEFT(\"𠮷野家\",1)", .text("𠮷"))
        checkValue("LEN(\"e\u{0301}\")", num("2"))
        checkValue("LEN(\"é\")", num("1"))
        checkValue("MID(\"éX\",2,1)", .text("X"))
        for text in ["😀X", "𠮷野家", "❤️", "e\u{0301}X"] {
            checkValue("LEFT(A1,1)&MID(A1,2,99)", ["A1": text], .text(text))
        }
        checkValue("LEN(\"❤️\")", num("2"))
        checkValue("LEN(\"😀\")", num("1"))
        checkValue("MID(\"e\u{0301}X\",2,1)", .text("\u{0301}"))
        checkValue("LEFT(\"e\u{0301}X\",1)", .text("e"))
        checkValue("RIGHT(\"Xe\u{0301}\",1)", .text("\u{0301}"))
    }
}

@MainActor
func largeTextOffsetChecks() {
    group("text: largeTextOffset") {
        checkValue("MID(\"abc\",9223372036854775807,9223372036854775807)", .text(""))
    }
}

@MainActor
func textBoundariesChecks() {
    group("text: textBoundaries") {
        for formula in ["LEFT(\"😀\",1)", "RIGHT(\"😀\",1)", "MID(\"😀X\",1,1)"] {
            checkValue(formula, .text("😀"))
        }
        checkValue("MID(\"😀X\",2,1)", .text("X"))
        checkValue("MID(\"😀X\",3,1)", .text(""))
        checkValue("LEFT(\"😀X\",2)", .text("😀X"))
        checkValue("LEFT(\"😀X\",9223372036854775807)", .text("😀X"))
        checkValue("RIGHT(\"😀X\",9223372036854775807)", .text("😀X"))
        checkValue("MID(\"abc\",9223372036854775807,9223372036854775807)", .text(""))
        checkValue("LEFT(\"abc\",-1)", .error(.value))
    }
}
