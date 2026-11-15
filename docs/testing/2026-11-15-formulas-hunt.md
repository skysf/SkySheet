# 公式、数字和格式排查修复记录

任务日期 2026-11-15，基线 `f9405b4`，只修改 `fix-formulas-hunt` 的当前 worktree。这里记录实际运行的证据，
不把静态推断当作验证。自检在 `Sources/SkySheetChecks/FormulaHuntChecks.swift`，相邻边界在
`FormulaHuntBoundaryChecks.swift`；入口 `SkySheetChecks --formula-hunt`，单例可用
`SkySheetChecks --formula-hunt-case <名字>`。完整检查会自动调用它们。

## 逐项复现

先只加入自检、构建检查程序，再运行原业务代码：27 个隔离用例全部失败（含原清单的秒小数、形状变体及八个同类入口）。
提交 `0b8103d` 只包含这批失败复现，业务代码仍是基线，可单独检出核对；修复分组放在后续提交，最后再扩充边界自检。
崩溃用例退出信号为 5；累计利息在 5 秒截止后仅终止本次自检创建的子进程。没有终止作者的程序。

| 条目 | 自检名字 | 修改前实测 | 修法与回归结果 |
| --- | --- | --- | --- |
| 1 IRR | `irrErrors` | 中间现金流为 #N/A 或 #DIV/0! 都算出约 0.1 | 只跳过非数字普通值，错误立即传播；两种错误通过 |
| 2 NPV | `npvBooleans` | NPV(100%,TRUE,4) = 1.5；FALSE 时 = 1 | 共用取数内核为 NPV 跳过直接逻辑参数，其他聚合规则不变；均为 2 |
| 3 显式区域裁剪 | `criteriaExtent` | A1=1、公式在 B1，COUNTIF(A1:A3,"") = 0；D9 有无关内容后变成 2 | 条件统计保留完整形状，稀疏存值；正确为 2，整列、整行、多区域、整张空表的空白计数也通过 |
| 4 空白条件 | `blankCriterion` | 空白 B1 作为条件，COUNTIFS 得 0、SUMIF 得 0 | 空白引用条件转为数字 0，显式空文字保持空白语义；分别为 1、7 |
| 5 佛历 TODAY | `gregorianToday` | 同时刻同一时区，注入佛历得到 2569 年，公历为 2026 年 | TODAY 固定公历，只继承时区；固定时刻核对序列号和 YEAR(TODAY()) |
| 6 常量 SUM 数据行 | `constantSumData` | 两条数据只剩一条，SQL 合计 3（应 10），describe 统计也少一条 | 只有明确标签或本列完整竖向求和才剔除末行；两条数据、合计 10 通过 |
| 7 RANK | `rankOrder` | RANK、RANK.EQ 的 ±0.5 顺序均得 1 | 不再先截整数，非零 Decimal 都升序；四例均为 2 |
| 8 文字字符边界 | `utf16Text` | 心形加选择符、emoji 的 LEN 都为 1；组合音标 MID 取到 X | LEN、LEFT、RIGHT、MID 统一 UTF-16；组合音标、变体选择符、代理对及安全替换通过 |
| 9 秒小数格式 | `subsecond15` / `subsecond19` / `subsecond100` | 15、19、100 位全部崩溃 | 计算 10ⁿ 前限制为最多 14 位，超出显示 ########；直接渲染和 TEXT 均通过 |
| 10 形状越界 | `lookupShape` / `criteriaShape` | XLOOKUP(2,A1:A2,99)、COUNTIFS(A1:A2,">0",99,99) 都越界崩溃 | 按原引用检查形状，标量不能充当多格；均返回 #VALUE!，正常查找和 IFS 也通过 |
| 11 空格输入 | `whitespaceInput` | 单空格触发空数组越界崩溃 | trim 后为空直接保留原文字，日期拆分也检查 first；空格、tab、换行通过 |
| 12 日期大数导出 | `largeDateExport` | isoText(1e20) 强转 Int 崩溃，后续同例检查未执行 | 先检查日期上界再安全转换；isoText 返回 nil，SQL、另存 CSV、analysisData/export_sheet 底层均保留原数字 |
| 13 累计财务卡死 | `cumulativeBound` / `boundaryCumulative` | CUMIPMT 万亿期在 5 秒内未返回；同例中的 CUMPRINC 当时未执行 | 共用年金内核改为等比数列有界求和；该万亿期样例的 CUMIPMT/CUMPRINC 均返回 #NUM!；有限还款的万亿期和期初/期末逐期对照通过 |
| 14 DATE 溢出 | `dateOverflow` | DATE(1e18,1,1) 整数乘法崩溃 | 年份先检查，月日和加月使用报告溢出的加减；返回 #NUM!，正常月日进位仍通过 |
| 15 分数格式 | `fractionFormat` / `boundaryDates` | 1.5 的 # ?/? 得到错误的“ /2”，整数、负数和双位分母也错 | 新分数渲染器找最接近的有理数，分母上限 9/99，保留 ? 对齐空格；内置代码 12/13、整数、负数、进位、TEXT 和引号内斜杠通过 |
| 16 MCP 排查第 1 条 | `horizontalSumData` | Alice/Bob 各横向 SUM，Bob 被删，Jan 合计为 1（应 4） | 与第 6 条共用保守识表修复；SQL 两条记录、Jan 合计 4、describe 的 ColumnSummary 均通过 |

16 条均复现，没有按“可能是 bug”直接修改的清单项。佛历通过参数注入验证，没有修改本机历法设置。

## 同类写法排查

- 全仓库（排除 `.git`、`.build`、`SampleData`）检索 `Calendar.current`、`Locale.current`、`TimeZone.current` 及
  默认参数 `.current`，并检索 Sources 的历法、格式化和时区调用。计算里只发现 CivilDate.today 和 ZIP 的 DOSDateTime
  依赖系统历法。`dosCalendar` 在修改前证实同一时刻的 ZIP 日期字段 65391 / 23919 不同；现在两处都显式公历。
  DecimalMath 已用 POSIX locale；备份和导出文件名的 DateFormatter 用 POSIX，属于文件名显示；xlsx 文档属性用
  ISO8601DateFormatter，没有发现应随本次修改的日期计算。
- DateMath 的 DATE 年/月/日、EDATE、EOMONTH，DateSerial 的 civil/ISO 转换，以及 DateRenderer 的日数、一天刻度、
  elapsed h/m/s 乘法逐处检查。`dateMonthOverflow`、`dateDayOverflow`、`edateOverflow`、`eomonthOverflow`、
  `serialOverflow` 修改前全部崩溃，修后均通过；1900/1904 上界、最后一天、负数、超界舍入及常规日期通过。
  weekday 的整数运算调用来自已限界的日期渲染，serial(from:) 的文件输入调用先验证年月日，没有另改其语义。
- CellInput 的 trim、日期 split、分组数字 split 和时钟分量；CSVValue 的同类日期时钟代码。`inputTimeOverflow`、
  `csvTimeOverflow` 修改前用 23:59:Int.max 都崩溃，修后非法秒保留文字。仅 `¥`、`-`、`+` 可安全处理，没有修改分组数字
  路径；CSV 的原空白字段处理也未改。
- FunctionArguments 两种 grid、Grid 的面积乘法和所有调用点；XLOOKUP 的结果下标、IFS 的逐位置下标；SUMIF / AVERAGEIF
  的目标扩展与 IFS 的原引用等形分开处理。面积来自 Excel 行列上限，在 64 位 Int 中安全；条件统计移出实体 Grid，整列
  和整张表都不物化。`boundaryCriteria` 还覆盖二维、跨表、公式空文字、目标扩展、错形、匹配及不匹配错误传播。
- FinancialFunctions 的累计循环、payment/interest 非有限结果与 first/last 计数；共用有界内核供两个累计函数使用，期间
  个数先做安全的整数差再转 Double。常规 CUMIPMT/CUMPRINC 与逐期 IPMT/PPMT 对照，原财务标准例和 loan 金样通过。
- NumberRenderer 的 fixed/scientific、GeneralFormat、DecimalMath.powerOfTen 以及 FormatParser 的秒精度。其他 10ⁿ 使用
  Decimal，没有新的 Int 强转；100 位定点格式通过。分数搜索最多四位分母（9999），更高精度安全拒绝，防止修复引入
  另一种无界运算。分数遵循[微软占位符与分数格式说明](https://support.microsoft.com/en-us/excel/number-format-codes-in-excel-for-mac)。
- TextFunctions 全部现有位置/长度函数都检查过。UTF-16 初版回归中，大 MID 偏移触发 Swift UTF16View 内部溢出，
  `largeTextOffset` 先实测崩溃再加长度裁剪；完整回归已覆盖半代理对 U+FFFD。FIND / SEARCH / REPLACE 当前没有实现，
  没有在本次顺带新增。微软的[文字兼容版本说明](https://techcommunity.microsoft.com/blog/microsoft365insiderblog/improving-five-excel-text-functions-len-mid-search-find-and-replace--compatibili/4339080)
  与当前[LEN 文档](https://support.microsoft.com/en-us/excel/functions/len-function)已核对，设计第五节注明本次统一选择与版本差异。

## 性能与验证

前后都先运行 `nice -n 10 swift build -c release --arch arm64 --product SkySheet`，再执行
`nice -n 10 .build/arm64-apple-macosx/release/SkySheet --benchmark synthetic:formulas`。此模式的窗口只离屏排版和绘制。
同机、同合成工作簿（10000 行、50000 个公式），单位为毫秒，表内取主线程 CPU 时间中位数；打开重算只测一帧。

| 动作 | 修改前 f9405b4 | 修改后 | 变化 |
| --- | ---: | ---: | ---: |
| 打开时整本重算 | 291.98 | 263.12 | -9.9% |
| 改一格并提交 | 63.18 | 65.16 | +3.1% |

没有超过一成退步。打开步骤的墙钟重算另为 295 → 264 ms。合成表主要是还款公式链，不包含条件统计；条件统计另以
整列、整行、整张表的稀疏空白用例验证在每例 5 秒预算内完成，避免只测密集小区域而漏掉展开问题。

完整命令 `nice -n 10 scripts/check-all.sh`：9514 条自检通过。第一次仅构建 SkySheetChecks 的试跑缺少相邻 MCP helper，
失败项已由完整构建补齐后通过；没有把旧二进制当作新构建的验证。

## 范围与限制

- 没有实跑 Microsoft Excel，也没有更改本机历法；Excel 语义按上述微软文档和任务指定规则实现。
- SQL / describe / export 的共用内核已测，没有启动可见 App 做 MCP 客户端端到端操作；不弹窗口、不抢焦点，不用 UI 自动化。
- 未改界面画法，未另跑截图和像素 verify；不打包、不改版本、不发 tag/release、不碰 /Applications。
- 不读 SampleData 内容，完整脚本只按仓库原有方式检查它没有进入 git。零第三方依赖，未改 AI 客户端配置。
- 首次沙盒构建被 Swift 缓存写入拦住，按单条命令提权后成功；沙盒内测速因 AppKit 服务连接失败未返回，仅停止本次
  测速子进程，再按同一条命令提权成功。后续构建与完整检查都逐条提权，无拒绝和遗留阻塞。
- PR 和最新提交的 CI 状态在交付回复与 PR 中给出；本分支不合并，留给另一位审查者。
