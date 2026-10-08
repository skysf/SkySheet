import Foundation
import SkySheetCore

/// 第一版的函数（设计 5.3 节）：数学、统计、条件、逻辑、查找、日期、文字。财务函数在 FinancialChecks.swift。
@MainActor
func functionChecks() {
    group("functions: every listed function is registered") {
        let expected = ["ABS", "AND", "AVERAGE", "AVERAGEIF", "AVERAGEIFS", "CONCAT", "CONCATENATE", "COUNT", "COUNTA",
                        "COUNTIF", "COUNTIFS", "CUMIPMT", "CUMPRINC", "DATE", "DATEDIF", "DAY", "DAYS", "EDATE", "EFFECT",
                        "EOMONTH", "FV", "IF", "IFERROR", "IFS", "INDEX", "INT", "IPMT", "IRR", "LEFT", "LEN", "MATCH",
                        "MAX", "MID", "MIN", "MOD", "MONTH", "NOMINAL", "NOT", "NPER", "NPV", "OR", "PMT", "POWER",
                        "PPMT", "PRODUCT", "PV", "RATE", "RIGHT", "ROUND", "ROUNDDOWN", "ROUNDUP", "SQRT", "SUM",
                        "SUMIF", "SUMIFS", "SUMPRODUCT", "TEXT", "TODAY", "VLOOKUP", "XIRR", "XLOOKUP", "XNPV", "YEAR"]
        checkEqual(FunctionLibrary.names, expected, "function list")
    }

    group("functions: math") {
        checkValue("ROUND(2.5,0)", num("3"))
        checkValue("ROUND(-2.5,0)", num("-3"))
        checkValue("ROUND(1234.5678,-2)", num("1200"))
        checkValue("ROUND(1.005,2)", num("1.01"))            // Double 会得到 1.0（1.005 存不准），Decimal 不会
        checkValue("ROUNDUP(-2.1,0)", num("-3"))
        checkValue("ROUNDUP(2.01,1)", num("2.1"))
        checkValue("ROUNDDOWN(-2.9,0)", num("-2"))
        checkValue("INT(-2.5)", num("-3"))
        checkValue("INT(2.5)", num("2"))
        checkValue("ABS(-3)", num("3"))
        checkValue("MOD(-3,2)", num("1"))
        checkValue("MOD(3,-2)", num("-1"))
        checkValue("MOD(0.3,0.1)", num("0"))
        checkValue("MOD(1,0)", .error(.div0))
        checkValue("SQRT(16)", num("4"))
        checkValue("SQRT(-1)", .error(.num))
        checkValue("POWER(2,10)", num("1024"))
    }

    group("functions: aggregates") {
        let cells = ["A1": "1", "A2": "2", "A3": "'3", "A4": "TRUE", "A5": "", "B1": "10", "B2": "=1/0"]
        checkValue("SUM(A1:A5)", cells, num("3"))            // 区域里的文字 "3" 和 TRUE 不算
        checkValue("SUM(1,\"3\",TRUE)", num("5"))           // 直接写的都算
        checkValue("SUM(1,\"x\")", .error(.value))
        checkValue("SUM(A1:B2)", cells, .error(.div0))       // 错误往上传
        checkValue("AVERAGE(A1:A5)", cells, num("1.5"))
        checkValue("AVERAGE(A5)", cells, .error(.div0))
        checkValue("MIN(A1:A5,7)", cells, num("1"))
        checkValue("MAX(A5)", cells, num("0"))
        checkValue("COUNT(A1:A5,\"4\",\"x\")", cells, num("3"))
        checkValue("COUNTA(A1:A5)", cells, num("4"))
        checkValue("PRODUCT(A1:A2,5)", cells, num("10"))
        checkValue("SUMPRODUCT(A1:A2,B1:B1)", cells, .error(.value))
        checkValue("SUMPRODUCT({1},2)", .error(.name))       // 数组常量第一版不支持（缓存值缺省时显示 #NAME?）
        let table = ["A1": "2", "A2": "3", "B1": "10", "B2": "20"]
        checkValue("SUMPRODUCT(A1:A2,B1:B2)", table, num("80"))
    }

    group("functions: conditions") {
        let cells = ["A1": "中信分期", "A2": "招行e招贷", "A3": "中信现金", "A4": "工行装修贷",
                     "B1": "36144.81", "B2": "26000", "B3": "27000", "B4": "50000",
                     "C1": "36", "C2": "24", "C3": "24", "C4": "60"]
        checkValue("SUMIF(A1:A4,\"中信*\",B1:B4)", cells, num("63144.81"))
        checkValue("SUMIF(B1:B4,\">30000\")", cells, num("86144.81"))
        checkValue("COUNTIF(C1:C4,24)", cells, num("2"))
        checkValue("COUNTIF(A1:A4,\"<>中信*\")", cells, num("2"))
        checkValue("COUNTIF(A1:A4,\"?行*\")", cells, num("2"))
        checkValue("SUMIFS(B1:B4,A1:A4,\"中信*\",C1:C4,24)", cells, num("27000"))
        checkValue("COUNTIFS(A1:A4,\"中信*\",B1:B4,\">30000\")", cells, num("1"))
        checkValue("AVERAGEIF(C1:C4,24,B1:B4)", cells, num("26500"))
        checkValue("AVERAGEIFS(B1:B4,C1:C4,\">100\")", cells, .error(.div0))
        checkValue("SUMIF(A1:A4,\"~*\",B1:B4)", cells, num("0"))
        checkValue("SUMIFS(B1:B4,A1:A3,\"中信*\")", cells, .error(.value))   // 区域大小不一样
        checkValue("COUNTIF(D1:D4,\"\")", cells, num("4"))                    // 空格子算「等于空」
    }

    group("functions: logic") {
        checkValue("IF(1>0,\"yes\",\"no\")", .text("yes"))
        checkValue("IF(FALSE,1)", .bool(false))
        checkValue("IF(TRUE,,1)", num("0"))
        checkValue("IF(\"x\",1,2)", .error(.value))
        checkValue("IF(TRUE,1,1/0)", num("1"))             // 没选中的分支里的错误不影响
        checkValue("AND(TRUE,1,\"TRUE\")", .bool(true))
        checkValue("OR(FALSE,0)", .bool(false))
        checkValue("AND(A1:A2)", ["A1": "x"], .error(.value))   // 一个逻辑值都没有
        checkValue("NOT(0)", .bool(true))
        checkValue("IFERROR(1/0,\"div\")", .text("div"))
        checkValue("IFERROR(5,0)", num("5"))
        checkValue("IFS(1>2,\"a\",2>1,\"b\")", .text("b"))
        checkValue("IFS(FALSE,1)", .error(.na))
    }

    group("functions: lookup") {
        let cells = ["A1": "10", "A2": "20", "A3": "30", "B1": "ten", "B2": "twenty", "B3": "thirty",
                     "D1": "Apple", "D2": "Banana", "D3": "Cherry"]
        checkValue("VLOOKUP(20,A1:B3,2,FALSE)", cells, .text("twenty"))
        checkValue("VLOOKUP(25,A1:B3,2)", cells, .text("twenty"))
        checkValue("VLOOKUP(5,A1:B3,2)", cells, .error(.na))
        checkValue("VLOOKUP(20,A1:B3,3,FALSE)", cells, .error(.ref))
        checkValue("VLOOKUP(\"ban*\",D1:D3,1,FALSE)", cells, .text("Banana"))
        checkValue("MATCH(30,A1:A3,0)", cells, num("3"))
        checkValue("MATCH(25,A1:A3)", cells, num("2"))
        checkValue("MATCH(\"cherry\",D1:D3,0)", cells, num("3"))
        checkValue("MATCH(99,A1:A3,0)", cells, .error(.na))
        checkValue("INDEX(A1:B3,3,2)", cells, .text("thirty"))
        checkValue("INDEX(A1:A3,2)", cells, num("20"))
        checkValue("INDEX(A1:B1,2)", cells, .text("ten"))
        checkValue("INDEX(A1:B3,4,1)", cells, .error(.ref))
        checkValue("INDEX(A:A,50)", cells, num("0"))          // 用到的范围以外也是格子：空的显示 0
        checkValue("XLOOKUP(20,A1:A3,B1:B3)", cells, .text("twenty"))
        checkValue("XLOOKUP(25,A1:A3,B1:B3,\"none\")", cells, .text("none"))
        checkValue("XLOOKUP(25,A1:A3,B1:B3,,-1)", cells, .text("twenty"))
        checkValue("XLOOKUP(25,A1:A3,B1:B3,,1)", cells, .text("thirty"))
        checkValue("XLOOKUP(\"c*\",D1:D3,A1:A3,,2)", cells, num("30"))
        checkValue("XLOOKUP(99,A1:A3,B1:B3)", cells, .error(.na))
    }

    group("functions: dates") {
        checkValue("TODAY()", num("46303"))
        checkValue("DATE(2026,10,8)", num("46303"))
        checkValue("DATE(2025,13,1)", num("46023"))           // 第 13 个月是下一年 1 月
        checkValue("DATE(2025,3,0)", num("45716"))            // 第 0 天是上个月最后一天（2025-02-28）
        checkValue("DATE(125,1,1)", num("45658"))             // 0–1899 年加 1900
        checkValue("DATE(1900,2,29)", num("60"))              // 和 Excel 一样认那个不存在的日子
        checkValue("YEAR(46303)", num("2026"))
        checkValue("MONTH(46303.75)", num("10"))
        checkValue("DAY(46303)", num("8"))
        checkValue("EDATE(DATE(2025,1,31),1)", num("45716"))  // 1 月 31 日加一个月是 2 月 28 日
        checkValue("EOMONTH(DATE(2024,1,15),1)", num("45351"))   // 2024-02-29
        checkValue("EOMONTH(DATE(2024,3,15),-1)", num("45351"))
        checkValue("DATEDIF(DATE(2024,1,31),DATE(2024,3,1),\"M\")", num("1"))
        checkValue("DATEDIF(DATE(2020,5,10),DATE(2026,10,8),\"Y\")", num("6"))
        checkValue("DATEDIF(DATE(2020,5,10),DATE(2026,10,8),\"YM\")", num("4"))
        checkValue("DATEDIF(DATE(2020,5,10),DATE(2026,10,8),\"MD\")", num("28"))
        checkValue("DATEDIF(DATE(2026,1,1),DATE(2025,1,1),\"D\")", .error(.num))
        checkValue("DAYS(DATE(2026,10,8),DATE(2026,1,1))", num("280"))
        checkValue("YEAR(-1)", .error(.num))
    }

    group("functions: text") {
        checkValue("TEXT(0.0214368,\"0.00%\")", .text("2.14%"))
        checkValue("TEXT(489000,\"0!.0,\"\"万\"\"\")", .text("48.9万"))
        checkValue("TEXT(\"45758\",\"yyyy年m月d日\")", .text("2025年4月11日"))
        checkValue("CONCAT(A1:B1,\"!\")", ["A1": "等额", "B1": "本息"], .text("等额本息!"))
        checkValue("CONCATENATE(\"a\",1,TRUE)", .text("a1TRUE"))
        checkValue("LEFT(\"招行e招贷\",2)", .text("招行"))
        checkValue("RIGHT(\"招行e招贷\",3)", .text("e招贷"))
        checkValue("MID(\"工行装修贷\",3,2)", .text("装修"))
        checkValue("LEN(\"等额本金\")", num("4"))
        checkValue("LEFT(\"abc\",-1)", .error(.value))
    }
}
