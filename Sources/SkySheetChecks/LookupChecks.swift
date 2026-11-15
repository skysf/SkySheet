import Foundation
import SkySheetCore
import SkySheetFiles


@MainActor
func lookupRegressionChecks() {
    boundedCheck("lookupShape")
    boundaryLookupChecks()
}

@MainActor
func lookupShapeChecks() {
    group("lookup: lookupShape") {
        checkValue("XLOOKUP(2,A1:A2,99)", ["A1": "1", "A2": "2"], .error(.value))
    }
}

@MainActor
func boundaryLookupChecks() {
    group("lookup: boundaryLookup") {
        let cells = ["A1": "1", "A2": "2", "B1": "7", "B2": "8"]
        checkValue("XLOOKUP(2,A1:A2,B1:B2)", cells, num("8"))
        checkValue("XLOOKUP(2,A1:A2,B1)", cells, .error(.value))
        checkValue("XLOOKUP(2,A1:A2,B1:C2)", cells, .error(.value))
        checkValue("XLOOKUP(1,A1:B1,A2:A3)", cells, .error(.value))
        checkValue("XLOOKUP(99,A1:A2,B1:B2,\"missing\")", cells, .text("missing"))

    }
}
