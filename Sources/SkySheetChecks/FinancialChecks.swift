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

@MainActor
func financialRegressionChecks() {
    irrErrorsChecks()
    npvBooleansChecks()
    cumulativePrecisionChecks()
    cumulativeSinglePeriodChecks()
    cumulativeTinyRateChecks()
    cumulativeLatePeriodChecks()
    boundedCheck("cumulativeBound")
    boundedCheck("boundaryCumulative")
}

@MainActor
func irrErrorsChecks() {
    group("financial: irrErrors") {
        for (source, error) in [("=#N/A", CellError.na), ("=1/0", .div0)] {
            checkValue("IRR(A1:A3)", ["A1": "-100", "A2": source, "A3": "110"], .error(error))
        }
    }
}

@MainActor
func npvBooleansChecks() {
    group("financial: npvBooleans") {
        checkValue("NPV(100%,TRUE,4)", num("2"))
        checkValue("NPV(100%,FALSE,4)", num("2"))
    }
}

@MainActor
func cumulativeBoundChecks() {
    group("financial: cumulativeBound") {
        for function in ["CUMIPMT", "CUMPRINC"] {
            checkNumber(evaluate("\(function)(0.01,1000000000000,1000,1,1000000000000,0)"),
                        function == "CUMPRINC" ? -1000 : -9999999999000, "discounted huge annuity stays bounded")
        }
    }
}

@MainActor
func boundaryCumulativeChecks() {
    group("financial: boundaryCumulative") {
        for type in 0...1 {
            for (first, last) in [(1, 1), (1, 12), (5, 12)] {
                var interest = 0.0
                var principal = 0.0
                for period in first...last {
                    let values = "5%/12,\(period),12,1000,0,\(type)"
                    interest += DecimalMath.double(evaluate("IPMT(\(values))").number!)
                    principal += DecimalMath.double(evaluate("PPMT(\(values))").number!)
                }
                let arguments = "5%/12,12,1000,\(first),\(last),\(type)"
                checkNumber(evaluate("CUMIPMT(\(arguments))"), interest, tolerance: 1e-11, "cumulative interest matches periods")
                checkNumber(evaluate("CUMPRINC(\(arguments))"), principal, tolerance: 1e-11, "cumulative principal matches periods")
            }
        }
        checkNumber(evaluate("CUMPRINC(0.01,1000000000000,1000,1,1000000000000,0)"), -1000, "principal telescopes to present value")
        let bounded = evaluate("CUMIPMT(0.0000000000001,1000000000000,1000,1,1000000000000,0)")
        check(bounded.number.map { $0 < 0 && $0 > -1000 } == true, "finite payment with huge period count is bounded")
    }
}

/// 区间只有一期时，CUMIPMT 按定义就是这一期的 IPMT。第 1 期（期末付）两边都是 −现值 × 利率，必须逐位相等；
/// 极小利率下利息比付款和本金小几十个数量级，用「付款总额 − 本金」会算成 0。其余各期 IPMT 走增长因子，
/// 只在增长因子不大的常规贷款上按 1e-12 比较。
@MainActor
func cumulativeSinglePeriodChecks() {
    group("financial: single-period CUMIPMT equals IPMT") {
        for rate in ["0.0000000000000000000000001", "0.00000000000000001", "0.000000001", "0.0075", "0.1", "3"] {
            for (periods, present) in [(500, "1000000000000000000000000000000"), (500, "1000"), (360, "125000"), (1, "1000")] {
                let interest = "\(rate),1,\(periods),\(present),0,0"
                checkEqual(evaluate("CUMIPMT(\(rate),\(periods),\(present),1,1,0)"), evaluate("IPMT(\(interest))"),
                           "first period of CUMIPMT(\(rate),\(periods),\(present))")
                checkEqual(evaluate("CUMIPMT(\(rate),\(periods),\(present),1,1,1)"), .number(0),
                           "a payment at the start of period 1 carries no interest")
            }
        }
        checkNumber(evaluate("CUMIPMT(0.0000000000000000000000001,500,1000000000000000000000000000000,1,1,0)"), -100000,
                    tolerance: 0, "reviewer example: tiny rate keeps the interest")
        for rate in ["0.0075", "5%/12", "0.01"] {
            for periods in [12, 60, 360] {
                for type in [0, 1] {
                    for period in Set([1, 2, periods / 2, periods - 1, periods]) {
                        let single = "CUMIPMT(\(rate),\(periods),125000,\(period),\(period),\(type))"
                        let ipmt = evaluate("IPMT(\(rate),\(period),\(periods),125000,0,\(type))")
                        guard case .number(let expected) = ipmt else { fail("IPMT failed for \(single): \(ipmt)"); continue }
                        checkNumber(evaluate(single), DecimalMath.double(expected), tolerance: 1e-12, "\(single) equals IPMT")
                    }
                }
            }
        }
    }
}

/// 极小利率跨多期：利息里的差项 D = m − X（m 期数、X ≈ m）在 mL ≤ 1 时要用级数，直接相减有效位全丢。
/// 单期时 D 恰好是 0，上面的单期自检抓不到：第四次审查把级数分支去掉后自检全绿，CUMIPMT(1e-25,500,1e30,1,500,0)
/// 却从 −25050000 变成 −100000。期望是按逐期余额算的 360 位独立值；mL 在 1 两侧（m = 10、360）各取一组，
/// 两个分支的接缝上不能跳。
@MainActor
func cumulativeTinyRateChecks() {
    group("financial: multi-period tiny-rate interest") {
        for (formula, expected) in [
            ("CUMIPMT(1e-25,500,1e30,1,500,0)", -25050000.0),
            ("CUMIPMT(1e-25,500,1e30,1,500,1)", -24950000.0),
            ("CUMIPMT(1e-25,500,1e30,498,500,0)", -1200.0),
            ("CUMIPMT(1e-25,500,1e30,498,500,1)", -1200.0),
            ("CUMIPMT(1e-17,500,1e30,1,500,0)", -2505000000000002.0833249999999999895833),
            ("CUMIPMT(1e-17,500,1e30,1,500,1)", -2495000000000002.0583749999999999689996),
            // mL = 1 − 1e-14 和 1 + 1e-14
            ("CUMIPMT(0.1051709180756465196407897508431744,111,125000,2,11,0)", -131462.04701296110040820114954675355724),
            ("CUMIPMT(0.1051709180756465196407897508431744,111,125000,2,11,1)", -118951.77918892977267745918732130069777),
            ("CUMIPMT(0.1051709180756487299826259021384241,111,125000,2,11,0)", -131462.04701296386361190950078225089393),
            ("CUMIPMT(0.1051709180756487299826259021384241,111,125000,2,11,1)", -118951.77918893203502400978138008342631),
            ("CUMIPMT(0.002781639377196297110649252600623720,461,125000,2,361,0)", -90459.857505869544919377802600775955732),
            ("CUMIPMT(0.002781639377196297110649252600623720,461,125000,2,361,1)", -90208.928797352133220199860476041272279),
            ("CUMIPMT(0.002781639377196352820740329111530662,461,125000,2,361,0)", -90459.857505871620798883024604025785066),
            ("CUMIPMT(0.002781639377196352820740329111530662,461,125000,2,361,1)", -90208.928797354198329767352104672836186),
        ] {
            checkNumber(evaluate(formula), expected, tolerance: 1e-12, "=\(formula)")
        }
    }
}

/// 期次超过 2^53 时 Double(last) 会并到相邻的整数（1e16 − 1 变成 1e16），尾期就算成了别的期；期次要按整数精确
/// 相减。期望是 360 位独立值（第四次审查）；超出期数的期次照样 #NUM!，不能被舍入成刚好等于期数。
@MainActor
func cumulativeLatePeriodChecks() {
    group("financial: late periods beyond 2^53") {
        for (formula, expected) in [
            ("CUMIPMT(0.01,10000000000000000,1000,9999999999999999,9999999999999999,0)", -0.19703950593079109891187138515831781198),
            ("CUMPRINC(0.01,10000000000000000,1000,9999999999999999,9999999999999999,0)", -9.8029604940692089010881286148416821880),
            ("CUMIPMT(0.01,10000000000000000,1000,9999999999999999,9999999999999999,1)", -0.19508861973345653357611028233496813067),
            ("CUMPRINC(0.01,10000000000000000,1000,9999999999999999,9999999999999999,1)", -9.7059014792764444565228996186551308792),
            ("CUMIPMT(0.01,10000000000000000,1000,9999999999999998,10000000000000000,0)", -0.59014792764444565228996186551308792285),
            ("CUMIPMT(0.1,1000000000000000000,1000,999999999999999999,999999999999999999,0)", -17.355371900826446280991735537190082645),
            ("CUMPRINC(0.1,1000000000000000000,1000,999999999999999999,999999999999999999,0)", -82.644628099173553719008264462809917355),
            ("CUMIPMT(0.1,1000000000000000000,1000,999999999999999999,999999999999999999,1)", -15.777610818933132982719759579263711495),
            ("CUMPRINC(0.1,1000000000000000000,1000,999999999999999999,999999999999999999,1)", -75.131480090157776108189331329827197596),
            ("CUMIPMT(1e-20,1000000000000000000,1000,999999999999999999,999999999999999999,0)", -2.0100166666388889550061393496247166200e-35),
            ("CUMIPMT(1e-20,1000000000000000000,1000,999999999999999999,999999999999999999,1)", -2.0100166666388889549860391829583277304e-35),
        ] {
            checkNumber(evaluate(formula), expected, tolerance: 1e-11, "=\(formula)")
        }
        for function in ["CUMIPMT", "CUMPRINC"] {
            checkValue("\(function)(0.01,10000000000000000,1000,10000000000000001,10000000000000001,0)", .error(.num))
        }
    }
}

/// 全期本金必须还清现值；这些期望可直接由现金流守恒推出，不能只检查结果有限。
@MainActor
func cumulativePrecisionChecks() {
    group("financial: discounted cumulative precision") {
        for rate in ["0.05", "0.1", "0.000001"] {
            for periods in [360, 500, 1000, 5000] {
                for type in [0, 1] {
                    checkNumber(evaluate("CUMPRINC(\(rate),\(periods),1000,1,\(periods),\(type))"), -1000,
                                tolerance: 1e-12, "whole term principal")
                }
            }
        }
        checkNumber(evaluate("CUMIPMT(0.1,500,1000,1,500,0)"), -49000, "high growth interest")
        // 90 位 Decimal 独立期望：常规区间逐期摊还，万亿期用现金流守恒；覆盖极小本金、尾段、期初付和非整期。
        checkNumber(evaluate("CUMPRINC(0.1,500,1000,1,10,0)"), -3.2068272403476635e-18,
                    tolerance: 1e-11, "high precision amortization oracle")
        checkNumber(evaluate("CUMIPMT(0.1,500,1000,1,10,0)"), -1000,
                    tolerance: 1e-11, "high precision amortization oracle")
        checkNumber(evaluate("CUMPRINC(0.1,500,1000,450,500,0)"), -992.2558624731812,
                    tolerance: 1e-11, "high precision amortization oracle")
        checkNumber(evaluate("CUMIPMT(0.1,500,1000,450,500,0)"), -4107.744137526819,
                    tolerance: 1e-11, "high precision amortization oracle")
        checkNumber(evaluate("CUMPRINC(0.1,500,1000,1,500,1)"), -1000,
                    tolerance: 1e-11, "high precision amortization oracle")
        checkNumber(evaluate("CUMIPMT(0.1,500,1000,1,500,1)"), -44454.545454545456,
                    tolerance: 1e-11, "high precision amortization oracle")
        checkNumber(evaluate("CUMPRINC(0.1,500,1000,450,500,1)"), -902.05078406652842,
                    tolerance: 1e-11, "high precision amortization oracle")
        checkNumber(evaluate("CUMIPMT(0.1,500,1000,450,500,1)"), -3734.3128522971078,
                    tolerance: 1e-11, "high precision amortization oracle")
        checkNumber(evaluate("CUMPRINC(0.05,360.5,1000,1,360,0)"), -975.90007239483464,
                    tolerance: 1e-11, "high precision amortization oracle")
        checkNumber(evaluate("CUMIPMT(0.05,360.5,1000,1,360,0)"), -17024.100341157238,
                    tolerance: 1e-11, "high precision amortization oracle")
        checkNumber(evaluate("CUMPRINC(0.0000000000001,1000000000000,1000,1,1000000000000,0)"), -1000,
                    tolerance: 1e-11, "high precision amortization oracle")
        checkNumber(evaluate("CUMIPMT(0.0000000000001,1000000000000,1000,1,1000000000000,0)"), -50.833194477554919,
                    tolerance: 1e-11, "high precision amortization oracle")
    }
}
