import Foundation
import SkySheetCore

/// 贷款与理财函数。期望值是按同一套公式用 Python 独立算的精确值（2026-10-08），四舍五入后都和微软文档里的示例一致；
/// 括号里是文档给的数。Excel 自己的 RATE / IRR / XIRR 只迭代到大约 1e-8，所以和文档比要放宽，和精确值比按 1e-9。
@MainActor
func financialChecks() {
    func expect(_ formula: String, _ expected: Double, tolerance: Double = 1e-12,
                file: StaticString = #fileID, line: UInt = #line) {
        checkNumber(evaluate(formula), expected, tolerance: tolerance, "=\(formula)", file: file, line: line)
    }

    group("financial: annuity family") {
        expect("PMT(8%/12,10,10000)", -1037.03208935916)                      // (-1,037.03)
        expect("PMT(3.1%/12,360,1000000)", -4270.16398904692)                 // 贷 100 万、30 年、3.1%
        expect("PMT(0,10,1000)", -100)
        expect("IPMT(10%/12,1,36,8000)", -66.6666666666667)                   // (-66.67)
        expect("IPMT(10%,3,3,8000)", -292.447129909366)                       // (-292.45)
        expect("PPMT(10%/12,1,24,2000)", -75.6231860083666)                   // (-75.62)
        expect("PPMT(8%,10,10,200000)", -27598.0534624214)                    // (-27,598.05)
        expect("FV(6%/12,10,-200,-500,1)", 2581.40337406014)                  // (2,581.40)
        expect("FV(12%/12,12,-1000)", 12682.503013197)                        // (12,682.50)
        expect("PV(8%/12,240,500)", -59777.1458511878)                        // (-59,777.15)
        expect("NPER(1%,-100,-1000,10000,1)", 59.6738656742946)               // (59.6738657)
        expect("NPER(1%,-100,-1000,10000)", 60.0821228537617)                 // (60.0821229)
        expect("NPER(1%,-100,-1000)", -9.57859403981316)                      // (-9.57859404)
        expect("CUMIPMT(9%/12,360,125000,13,24,0)", -11135.2321307508)        // (-11,135.23213)
        expect("CUMIPMT(9%/12,360,125000,1,1,0)", -937.5)                     // (-937.50)
        expect("CUMPRINC(9%/12,360,125000,13,24,0)", -934.107123420876)       // (-934.1071234)
        expect("CUMPRINC(9%/12,360,125000,1,1,0)", -68.2782711809767)         // (-68.27827118)
        checkValue("CUMIPMT(0,360,125000,1,1,0)", .error(.num))
        checkValue("IPMT(10%,4,3,8000)", .error(.num))
        checkValue("PMT(5%,0,100)", .error(.num))
    }

    group("financial: rates and cash flows") {
        expect("RATE(48,-200,8000)", 0.00770147248820189, tolerance: 1e-9)    // (0.77%)
        expect("RATE(24,-2165.83,50000)*12", 0.037564446233059261, tolerance: 1e-9)   // 样例 J5 那一笔的精确解
        checkValue("RATE(0,-200,8000)", .error(.num))
        checkValue("RATE(12,100,1000)", .error(.num))                          // 只进不出，没有利率能让它平
        expect("NPV(10%,-10000,3000,4200,6800)", 1188.44341233522)            // (1,188.44)
        checkValue("IRR({-70000,12000,15000,18000,21000,26000})", .error(.name))   // 数组常量第一版不支持
        checkNumber(evaluate("IRR(A1:A6)", ["A1": "-70000", "A2": "12000", "A3": "15000", "A4": "18000",
                                            "A5": "21000", "A6": "26000"]),
                    0.0866309480365316, tolerance: 1e-9, "IRR (8.66%)")
        checkNumber(evaluate("IRR(A1:A5)", ["A1": "-70000", "A2": "12000", "A3": "15000", "A4": "18000", "A5": "21000"]),
                    -0.0212448482734109, tolerance: 1e-9, "IRR (-2.12%)")
        checkEqual(evaluate("IRR(A1:A2)", ["A1": "100", "A2": "200"]), .error(.num), "IRR needs both signs")

        let flows = ["A1": "-10000", "A2": "2750", "A3": "4250", "A4": "3250", "A5": "2750",
                     "B1": "=DATE(2008,1,1)", "B2": "=DATE(2008,3,1)", "B3": "=DATE(2008,10,30)",
                     "B4": "=DATE(2009,2,15)", "B5": "=DATE(2009,4,1)"]
        checkNumber(evaluate("XNPV(9%,A1:A5,B1:B5)", flows), 2086.64760203154, tolerance: 1e-12, "XNPV (2,086.65)")
        checkNumber(evaluate("XIRR(A1:A5,B1:B5)", flows), 0.373362533518831, tolerance: 1e-9, "XIRR (0.373362535)")
        checkEqual(evaluate("XIRR(A1:A5,B1:B4)", flows), .error(.num), "XIRR needs as many dates as values")

        expect("EFFECT(5.25%,4)", 0.0535426673707582)                         // (0.053542667)
        expect("NOMINAL(5.3543%,4)", 0.052500319868356)                       // (0.05250032)
        checkValue("EFFECT(-1%,4)", .error(.num))
    }
}
