# SkySheet 设计方案

> 2026-10-08 定稿。产品上的每一条都是作者在 2026-10-08 的讨论里逐条拍板的；
> 这里写决定、理由和做法。推翻哪一条之前先读它的理由；改了就在这里改，并在文末「变更记录」记一行。
> 其他文档引用时写成「设计第 N 条」（第二节的编号）或「设计 5.2 节」。

## 一、要做什么

SkySheet 是一个**给 AI 用的**轻量 macOS 表格工具：

- 用户用它打开 xlsx / csv，**主要是看**，偶尔改几个数。
- Claude Code 通过 MCP（服务名 `skysheet`）读表、算数，把结果**写进新的 sheet**；原始数据永远不动。
- 典型问题（作者原话整理）：算一下这几笔贷款的利率；哪种贷款方式更合理；和我现在每个月的还款比，
  我应该贷多少、多少利率的贷款。
- 数据规模：一张表最多几千行。
- 只给作者自己用：不做 Apple 公证，第一次打开走「系统设置 → 隐私与安全性 → 仍要打开」。

参考实现是作者的另一个 App SrtFlow（本机 `../srt_vtt/app_files`，公开仓库 `github.com/skysf/SrtFlow`）。
签名、MCP 三段结构、自检程序的写法都从那里搬，搬的时候按这里的取舍删减。

## 二、决定一览

| # | 方面 | 决定 | 理由 |
| --- | --- | --- | --- |
| 1 | 名字 | App 叫 SkySheet；bundle id `ai.skylu.skysheet`；MCP 服务名 `skysheet`；仓库 `skysf/SkySheet`（公开） | Excel 是微软的商标，Numbers 是苹果的，Sheet 是普通词。skylu 是作者的个人品牌（skylu.ai）；SkyStudio 是另一个品牌，不混用 |
| 2 | 许可证 | AGPL-3.0 | 和 SrtFlow 一样；MCP 协议代码从 SrtFlow 搬来，两边一致 |
| 3 | 平台 | macOS 15 起，只支持 Apple 芯片（arm64） | 和 SrtFlow 一样，不为 Intel 多测一套 |
| 4 | 签名 | 自签名证书「Skylu Signing」，作者所有个人工具共用；不公证 | 第十一节 |
| 5 | 文件 | 读写 xlsx、csv | 作者的数据就是这两种（腾讯文档、银行导出） |
| 6 | 原样保留 | 读不懂的、没改过的部分，保存时按原字节写回 | 样例里就有图片和合并单元格，丢了就是毁数据 |
| 7 | 依赖 | 零第三方依赖。zip 自己写（压缩用系统的 Compression），查询用系统的 SQLite3 | 作者定的：不引外部库 |
| 8 | 公式 | 常用函数子集，贷款理财的函数优先（第五节）；不追求全兼容 Excel | 够用、可测 |
| 9 | 数值 | 加减乘除和求和用 Decimal；RATE、IRR、XIRR 这类迭代或超越函数内部用 Double | 金额分毫不差；作者接受个别结果和 Excel 在最后一位上有出入 |
| 10 | 显示 | 人民币、万元、百分比、中文日期；兼容腾讯文档的非标准格式编号；不做中文大写金额 | 作者要求 |
| 11 | 不做 | 图表、透视表、宏、条件格式和数据验证的编辑、多人协作、在表格里显示图片；第一版也不做插入 / 删除行列 | 主要给 AI 用，用户只是看；汇总表让 AI 用公式或 SQL 生成。图片只原样保留（第 6 条）：SkySheet 里看不到，腾讯文档、Excel 里照常显示。插删行列要连带改整本里所有公式的引用，表里有我们不认识、又带范围的元素（条件格式、数据验证……）时也没法跟着改；需要的话放 M5，只在安全的表上允许 |
| 12 | AI 的权限 | 原始 sheet 对 AI 只读；结果写进新 tab；要改原表，先复制成新 tab 再改 | 原始数据当 raw data 永久保留 |
| 13 | AI 写什么 | 优先写引用原表的活公式（如 `=RATE(Loan!C5,-Loan!F5,Loan!B5)*12`）；纯文字结论和 Python 算出的结果写成值 | 原数据一改结果跟着变，用户能点开核对每个数怎么来的 |
| 14 | Python | 允许 Claude 用 Python / pandas 分析；数据进出只走 SkySheet 的工具，**不许用别的程序改用户的 xlsx / csv 文件** | 方便用自然语言操作；写回统一经过 SkySheet，才有撤销和保存安全 |
| 15 | 保存 | 只有用户按 ⌘S 才写回原文件；六道保险（第十节） | 作者定：哪种更能保证数据安全就选哪种 |
| 16 | 用户编辑 | 基础编辑：改值、改公式、撤销 / 重做、复制粘贴、sheet 的重命名 / 删除 / 复制 | 作者要求「基础的修改功能」 |
| 17 | AI 客户端 | 第一版只接 Claude Code | 协议层是通用的，以后加 Claude 桌面版、Codex 很便宜 |
| 18 | 敏感信息 | 不做脱敏 | 作者确认数据里没有身份证号、手机号这类信息 |
| 19 | 测试数据 | 只提交 `Fixtures/loan.xlsx`（从作者表格里抽出的 Loan 表，来历见 `Fixtures/README.md`）；`SampleData/` 永不入库 | 仓库是公开的；真实表格里还有房产、装修、理财等个人信息 |
| 20 | 仓库流程 | main 禁止直推，走 PR，CI 绿了才合；CI 只占 1 台 macOS 机器 | 和 SrtFlow 一样；免费档同时最多 5 台 macOS，是整个账号共用的 |
| 21 | 代码 | 按职责拆文件，一个文件大约 500 行就考虑拆，不设守卫脚本；多用泛型和共用内核，不复制第二份 | 作者定：方便维护、效率高就好，不必像 SrtFlow 那么严 |
| 22 | 语言 | 界面先只做英文；注释和文档用中文；给模型看的 MCP 文字用英文 | 作者 2026-10-08 定：先做英文版，中文以后再加。界面文字一律用 `String(localized:)`、开发语言英文，以后加中文只是补翻译。本机只有命令行工具，没有编 String Catalog（.xcstrings）的 xcstringstool（2026-10-08 实测），所以翻译照 SrtFlow 用 `.lproj/Localizable.strings`。本文引号里的界面文字只写意思，实际是英文 |
| 23 | AI 署名 | 每张 AI 的 sheet 记下是哪个 AI 建的、最后是谁改的；页签上显示 AI 的名字（如 Claude）；存进文件，下次打开还在；不写进 sheet 名 | 作者要求；以后会让用户接别的 AI，得分得清是谁写的。不进 sheet 名：名字会变长（Excel 限 31 个字符），换了 AI 再改时名字里的署名也会过时。做法见 9.3 节 |

## 三、整体结构

```
Claude Code ──MCP（stdio，一行一条 JSON）──▶ skysheet-mcp ──Unix socket──▶ SkySheet.app
                                            （小程序，只传话）              ├─ AI 层：AIToolRouter → 各组工具
                                                                            ├─ 文档层：WorkbookDocument（NSDocument）
                                                                            └─ 界面：自绘表格 + SwiftUI 外框
                    SkySheetFiles（xlsx / csv 读写）──▶ SkyZip（zip）
                    SkySheetCore（模型、公式、数字格式、SQL 查询）
```

| target | 类型 | 依赖 | 管什么 |
| --- | --- | --- | --- |
| `SkyZip` | 库 | Foundation、Compression | zip 读写：中央目录、stored / deflate、CRC32 |
| `SkySheetCore` | 库 | Foundation、SQLite3 | 值类型的工作簿模型、公式引擎和函数库、数字格式、把表格块装进 SQLite 查询 |
| `SkySheetFiles` | 库 | SkySheetCore、SkyZip | xlsx 读写（含原样保留）、csv 读写（含编码识别） |
| `SkySheetDisplay` | 库 | SkySheetCore | 画表格要做的决定：颜色换算、样式继承、行列几何、格子显示成什么、文字溢出、csv 自动列宽。和 AppKit 无关，自检能测（M2 加的） |
| `SkySheetMCPKit` | 库 | Foundation | MCP 协议、工具清单（唯一一份）、和 App 之间的通道；小程序和 App 共用 |
| `SkySheetMCP` | 可执行，产物 `skysheet-mcp` | SkySheetMCPKit | Claude Code 启动它；清单当场回，调用转给 App；App 没开就 `open -g` 拉起来 |
| `SkySheet` | 可执行（App） | 以上全部 | 文档、表格视图、编辑、保存安全、AI 层、「连接 Claude Code」 |
| `SkySheetChecks` | 可执行 | Core、Files、Display、MCPKit | 自检（第十二节） |

Core 和 Files 分开：公式、格式的自检不用造 xlsx；文件格式的改动不碰公式引擎。

目录（指引，不是穷举；每个文件只管一件事）：

```
Sources/
  SkyZip/              ZipReader、ZipWriter、ZipEntry、CRC32
  SkySheetCore/
    Model/             CellAddress、CellRange、CellValue、Cell、SparseGrid、Sheet、Workbook、StyleTable
    Formula/           Lexer、Parser、FormulaNode、Evaluator、EvalContext、ReferenceShift、Recalc
    Functions/         FunctionSpec、FunctionRegistry、Arguments（取参和类型转换，只写一份）
      Kernels/         Aggregate、Criteria、Annuity、RootSolver、CashFlow、DateMath（算法都在这里）
      Library/         Math、Logical、Lookup、Date、Text、Financial（只登记函数，调内核）
    Format/            FormatCode（解析）、FormatRenderer、BuiltinFormats、DateSerial、FormatPresets
    Query/             TableBlocks（从 sheet 里认出表格块）、SQLiteLoader、QueryRunner
  SkySheetFiles/
    Package/           OPCPackage（部件、关系、内容类型）、XMLScanner（共用的流式 XML 读取）
    XLSXRead/          WorkbookPart、StylesPart、SharedStringsPart、WorksheetPart、Quirks
    XLSXWrite/         PartPatcher（认识的元素重写、其余原样）、WorksheetWriter、WorkbookWriter、SaveVerifier
    CSV/               CSVReader、CSVWriter、TextEncodingSniffer
  SkySheetMCPKit/      MCPServerCore、JSONValue、MCPUnixSocket、MCPBridge（从 SrtFlow 搬）；MCPToolName、各组工具说明、MCPInstructions
  SkySheetMCP/         main.swift、AppConnection.swift（从 SrtFlow 搬）
  SkySheetDisplay/     Colors、ResolvedStyle、SheetGeometry、CellDisplay、AutoFit
  SkySheet/
    App/               main、AppDelegate（含菜单）、Snapshot（截图模式）
    Document/          WorkbookDocument（含 DocumentLoader）；M3 加 SaveSafety、Backups
    Window/            SheetSession（共享状态）、WorkbookWindowController、FormulaBar、BottomBar（SwiftUI）
    Grid/              SpreadsheetView（排布、滚动同步、键鼠）、PaneView（四块窗格、行号列标）、RegionRenderer、SheetCanvas
    AI/                AIBridgeServer、AIToolRouter、AISession（这一轮）、AISheetOwnership、各组工具（M4）
    Settings/          ConnectClaudeCode
  SkySheetChecks/      main.swift + 每块一个 *Checks.swift
```

## 四、核心模型

- 全是值类型（struct / enum）。快照、撤销、「撤销这一轮」都只是复制一份（写时复制，很便宜）。
- `CellValue`：`empty / number(Decimal) / text(String) / bool(Bool) / error(CellError)`。日期和 Excel 一样是数字
  （1900 日期系统的序列号）加日期格式；`date1904` 的文件读进来时换算。
- `Cell`：输入（字面值，或公式原文和解析结果）、计算值、样式编号。从文件读进来的公式同时留着文件里的缓存值。
- `SparseGrid<Value>`：稀疏的「行 → 列」存储，按行、按列有序遍历。单元格、AI 这一轮改过的高亮都用它。
- `Sheet`：`id`（xlsx 的 sheetId）、名字、角色（`.original` / `.ai`）、单元格、列宽行高、冻结窗格、合并单元格、
  tab 颜色，以及原样保留要用的原始部件（7.2 节）。
- `Workbook`：sheet 列表、样式表、日期系统，以及原始 xlsx 包（保存时照抄没动过的部分）。

## 五、公式引擎

### 5.1 流程和语法

文本 → `Lexer` → `Parser`（得到 `FormulaNode` 语法树）→ `Evaluator`（在 `EvalContext` 里求值）→ `Recalc`（整本重算）。

- 支持：数字、字符串、TRUE / FALSE、错误值；`A1`、`$A$1`、`A1:B9`、整列 `A:A`、整行 `1:1`；跨表 `Loan!A1`、
  `'中文 名字'!A1`；运算符 `+ - * / ^ & = <> < <= > >=`、一元负号、百分号；函数调用。
- 第一版不支持：数组公式和动态数组、结构化引用（`表名[列]`）、定义的名称（named range）、R1C1。
  文件里用到它们的公式照样保留原文、显示文件里的缓存值（5.3 节「未重算」）。
- xlsx 的共享公式（`<f t="shared">`，Excel 存文件时大量使用）读的时候展开成每个格子自己的公式。引用平移只有
  `ReferenceShift` 一份：展开共享公式、复制粘贴、复制 sheet、AI 的「往下填充」都用它。

### 5.2 函数：一张登记表，几个共用内核

- 每个函数是登记表里的一条 `FunctionSpec`：名字、参数个数、取参方式、求值闭包。取参和类型转换（范围里的文字
  忽略、直接给的文字转数字、错误值往上传）统一在 `Arguments` 里做一次，不在每个函数里各写一遍。
- 算法放在共用内核里，同一族函数只是参数不同：

| 内核 | 管什么 | 用它的函数 |
| --- | --- | --- |
| `Aggregate` | 对一串数字做累计 | SUM、AVERAGE、MIN、MAX、COUNT、COUNTA、PRODUCT、SUMPRODUCT |
| `Criteria` | `">=100"`、`"中信*"` 这类条件的解析和匹配 | SUMIF(S)、COUNTIF(S)、AVERAGEIF(S) |
| `Annuity` | 年金公式（等额本息） | PMT、IPMT、PPMT、PV、FV、NPER、CUMIPMT、CUMPRINC |
| `RootSolver` | 牛顿法加二分法兜底求根；不收敛回 `#NUM!`，和 Excel 一样 | RATE、IRR、XIRR |
| `CashFlow` | 现金流折现 | NPV、XNPV、IRR、XIRR |
| `DateMath` | 序列号和年月日互换、月份加减、月末 | TODAY、DATE、YEAR、MONTH、DAY、EDATE、EOMONTH、DATEDIF、DAYS |

### 5.3 第一版的函数（约 60 个）

- 样例表在用的，最先通过对照：RATE、SUM、IF、POWER、TODAY、XIRR
- 贷款与理财：PMT、IPMT、PPMT、PV、FV、NPER、NPV、XNPV、IRR、CUMIPMT、CUMPRINC、EFFECT、NOMINAL
- 数学与统计：AVERAGE、MIN、MAX、COUNT、COUNTA、PRODUCT、SUMPRODUCT、ROUND、ROUNDUP、ROUNDDOWN、INT、ABS、MOD、
  SQRT、SUMIF、SUMIFS、COUNTIF、COUNTIFS、AVERAGEIF、AVERAGEIFS
- 逻辑：AND、OR、NOT、IFERROR、IFS
- 查找：VLOOKUP、INDEX、MATCH、XLOOKUP
- 日期：DATE、YEAR、MONTH、DAY、EDATE、EOMONTH、DATEDIF、DAYS
- 文字：TEXT、CONCAT、LEFT、RIGHT、MID、LEN

清单之外的函数：公式原文和文件里的缓存值照样保留、照样显示，格子标「未重算」，AI 读到时也会被告知。缺哪个按需补。

### 5.4 数值

- 加减乘除、比较、求和一族用 Decimal（38 位有效数字），`0.1 + 0.2` 就是 `0.3`。
- 迭代和超越函数（RATE、IRR、XIRR、非整数次方、SQRT……）内部用 Double，结果转回 Decimal。
- 从文件读数字按原文解析成 Decimal，不经过 Double。
- 和 Excel / 腾讯文档对比按 15 位有效数字（Excel 自己只存 15 位）。

### 5.5 重算

- 第一版每次改动整本重算，带环检测（循环引用的格子显示「循环引用」，保存时不写缓存值）。先排好计算顺序再逐个算，
  不用递归：几百行的还款计划表每行引用上一行，递归深度就是行数。
- 2026-10-08 实测：一万行的还款计划表（5 万个公式，依赖链一万层深）在 debug 构建里 0.8 秒算完。整本重算够用，
  增量依赖图先不做（自检里留着这张表，变慢了会被发现）。
- TODAY() 在打开时、每天第一次重算时更新。

### 5.6 对照测试

- `Fixtures/loan.xlsx` 里 124 个公式都带着腾讯文档算出的缓存值：读进来、整本重算、逐个比对。这是 M1 的验收线。
- 容差分两档（2026-10-08 实测定的）：
  - 普通公式相对误差不超过 1e-13。缓存值只存 15 位有效数字，我们用 Decimal 算得更准，差在第 15 位以后；实测最大 4.5e-15（I10）。
  - 用到 RATE、IRR、XIRR 这类迭代求根的，放宽到 1e-9。腾讯文档的 RATE 只迭代到大约 1e-10 就停，和精确解最多差
    6.6e-11（J10），我们给的是精确解（用 Python 独立算过）。Excel 自己的 XIRR 也一样：微软文档示例给 0.373362535，
    精确解是 0.3733625335。
- 样例之外的函数，用公开文档里的标准例子（例如微软文档里 XIRR、PMT 的示例）对照。

## 六、数字格式

- 按 Excel 的格式代码规则实现：最多四段（正 ; 负 ; 零 ; 文字）、`[Red]` 等颜色、`[>=10000]` 条件、引号里的文字和
  `\`、`!` 转义、`_` 留空、`*` 填充（忽略）、`0 # ?`、千分位和末尾逗号缩放、`%`、科学计数、日期时间
  （`yyyy m d h mm ss` 等）、`@`。`[$-804]` 这类地区标记、`[DBNum1]` 这类中文数字标记不报错，按普通数字显示。
- 内置格式编号：0–49 是标准的；27–36、50–58 是中文环境的日期格式（如 31 = `yyyy"年"m"月"d"日"`，完整映射 M1 按
  ECMA-376 定）；59–62、67–81 是腾讯文档会写出来的编号，标准里属于泰文环境，去掉开头的 `t` 就对上了。样例实测：
  68 用在名义年化利率那一列，0.0214368 显示成 2.14%，对应 `0.00%`；60 用在每期本金上，对应 `0.00`。
- 预设：界面菜单里点选，AI 用名字指定，也可以直接给格式代码。

| 名字 | 格式代码 | 489000 显示成 |
| --- | --- | --- |
| `cny` 人民币 | `"¥"#,##0.00_);[Red]("¥"#,##0.00)` | ¥489,000.00 |
| `cny_int` 人民币取整 | `"¥"#,##0_);[Red]("¥"#,##0)` | ¥489,000 |
| `wan` 万元，1 位小数 | `0!.0,"万"` | 48.9万 |
| `wan_exact` 万元，精确到元 | `0!.0000"万"` | 48.9000万 |
| `percent` 百分比 | `0.00%` | — |
| `date_cn` 中文日期 | `yyyy"年"m"月"d"日"` | — |
| `date` 日期 | `yyyy/m/d` | — |

- 两种人民币格式就是样例表里在用的。万元只用 Excel 认得的写法，这样在 Excel、腾讯文档、WPS 里打开显示一样；
  代价是这种写法只能 1 位或 4 位小数，做不出「48.90万」这样的 2 位小数。

## 七、xlsx 和 csv 读写

### 7.1 读 xlsx

- SkyZip 读中央目录，支持 stored 和 deflate，校验 CRC。不支持 zip64；有密码的 xlsx 其实不是 zip，认出来就明确告诉
  用户「这个文件有密码，SkySheet 打不开」。
- 按 OPC 的规矩走：`[Content_Types].xml`、各级 `_rels`（相对路径、`..`），找到 workbook、styles、sharedStrings、各 sheet。
- 宽容处理。腾讯文档的这些怪癖样例里都有，读的时候全部要接住：`<f>` 里的公式原文带开头的 `=`（标准里不带；
  M1 的对照测试抓到的，不去掉一个公式都解析不了。写回时按标准不带 `=`）；非标准格式编号 60 / 68；
  `<dimension ref="AG212"/>` 只写一个格子；`<c t="s"/>` 没有 `<v>` 的空格子；关系编号从 `rId0` 起；
  `[Content_Types].xml` 排在 zip 最后；zip 里带目录条目；图片同时写了 `r:embed` 和 `r:link`。
- 富文本字符串显示时拼成纯文字，原文保留。
- 读不懂的一律不丢：部件、关系，以及 sheet 里认不出的元素（条件格式、数据验证、批注、页面设置……）都留着原文。

### 7.2 写 xlsx：认识的重写，其余原样

- **包**：没动过的部件逐字节照抄，包括图片、绘图、批注这些我们根本不解析的部件。
- **没改过的 sheet**：原字节写回。
- **改过的和新建的 sheet**：只重新生成我们管的元素（`sheetPr` 里的 tab 颜色、`dimension`、`sheetViews` 里的冻结窗格、
  `cols`、`sheetData`、`mergeCells`），其余元素原文照抄，并按 schema 规定的顺序排好（顺序错了 Excel 会报文件损坏）。
- **workbook.xml**：只改 `<sheets>`（增、删、改名、排序），其余照抄。只要重写过任何一张 sheet，就在 `calcPr` 加
  `fullCalcOnLoad="1"`：别的软件打开时自己重算一遍，不依赖我们写的缓存值。
- **styles.xml**、**sharedStrings.xml**：新内容只往后追加，已有的编号一个都不动。
- **`[Content_Types].xml`、workbook 的关系**：给新 sheet 加条目。
- **哪些是 AI 的 sheet、是谁写的**：记在 `docProps/custom.xml` 里，每张 AI 的 sheet 一个自定义属性，见 9.3 节。
- 写出来的 zip：`[Content_Types].xml` 放第一个，deflate 压缩。
- M3 落地时定下、实测出来的几条（代码注释里也写着）：
  - 「没改过」按打开（或上次保存）时的工作簿逐张比；没改过的 sheet、没动过的部件连压缩后的字节都照抄，不解压。
  - 重写的 sheet 用 `XMLFragments` 拆成根元素的直接子元素：我们管的换掉，别的原文照抄，新元素按 schema 顺序插。
    页签颜色、冻结窗格、默认行高列宽没变就连原来的元素都不碰。
  - 数字写 17 位有效数字（Double 的全部精度）、不用科学计数法；公式不带 `=`，CONCAT、IFS、XLOOKUP、DAYS 加 `_xlfn.`；
    循环引用的格子不写缓存值；`calcChain.xml` 作废删掉。
  - 共用字符串表：已有的文字用原来的编号；富文本那几条只给原来用它的格子用（文字没变就接着用，格式不丢）；新文字往后加，
    `uniqueCount` 改成条数，`count` 去掉（全书引用次数算不出来，它是可选的）。
  - 新 sheet 只写我们管的元素加默认页边距；复制出来的 sheet 不带原 sheet 的条件格式、数据验证、图片、批注（第十五节）。
  - 新的和重写的 sheet 总写 `sheetFormatPr`（默认行高）：Quick Look 遇到首格不在 A 列的行，没有它就画成一大片空白
    （2026-10-08 用 `qlmanage` 对照抓到的；Excel 自己存的文件都有这一项）。
  - sheet 编号只增不减（`Workbook.nextSheetID`）：删掉的 sheet 和我们跳过的图表 sheet 的编号都不再用，不然新 sheet 会被当成
    那张旧的去改。`<sheets>` 里的图表 sheet 原文留着，跟在它前面那张工作表后面；activeTab 跟着 sheet 的新位置走。
  - Strict Open XML 的文件读得了，改了存不回去（明确报错，原文件不动）。

### 7.3 csv

- 读：先认编码，带 BOM 或者整份是合法 UTF-8 就按 UTF-8，否则按 GB18030（国内 Excel 和银行导出的 csv 多是 GBK）；
  再认分隔符（逗号、制表符、分号）；引号按 RFC 4180。纯数字转成数字，`2025-12-01`、`2025/12/1` 转成日期，其余都是
  文字（带 ¥ 或千分位的先当文字，AI 需要时自己转）。
- csv 没有列宽：打开时按每列最长的显示文字自动定宽（最宽 60 个字符）。不然日期显示成 ###、文字被截断，
  Excel 打开 csv 就是这样（2026-10-08 截图核对时发现，AutoFit）。
- 写：用读进来时的编码、BOM、分隔符和换行写回；数字写原值（最多 15 位有效数字，和读的时候认数字的规矩一致），日期写
  `yyyy-mm-dd`（带时刻的加 ` hh:mm:ss`），百分比写 `5%`（读回来还是同一个数），公式写计算结果（csv 存不了公式），
  每行一样多的字段（和 Excel 一样）。原编码写不出来的字符（比如 GBK 的文件里新加了 emoji）明确报错，原文件不动。
  写完按同样的编码解回来，逐字段核对。
- csv 只能放一张表。打开的是 csv、AI 又加了 sheet 时，⌘S 弹框二选一：「另存为 xlsx（保留 AI 的 sheet，默认）」
  或「只存回 csv（AI 的 sheet 不会保存）」。

## 八、App

### 8.1 文档层用 AppKit 的 NSDocument

- SwiftUI 的 `DocumentGroup` 在 macOS 上会自动把改动存回原文件，违反第 15 条。所以文档层用 AppKit 的 `NSDocument`，
  `autosavesInPlace` 返回 false。
- NSDocument 顺带给了：⌘S 和另存为的标准流程、「文件被别的程序改过」的检测、每个文档自己的 `NSUndoManager`。
- 界面外框（工具栏、公式栏、sheet 页签、AI 横幅、设置页）用 SwiftUI，放进 `NSHostingView`。

### 8.2 表格视图自绘

- 表格是自己画的：主区放在 `NSScrollView` 里，只画看得见的格子；冻结的左上角、冻结行、冻结列、行号、列标各是一块，
  跟着主区滚动同步。四块窗格用同一个视图类、同一个渲染器（RegionRenderer），只是对应 sheet 的不同部分。几千行没有压力。
- M2 落地时踩到、写进代码注释的几条：
  - macOS 14 起视图默认不裁剪到自己的边界，传进 draw 的脏区域可能比边界大：自绘的视图都要打开 `clipsToBounds`，
    否则一块窗格刷的白底会盖住别的窗格和公式栏（第一次截图里主区整个是白的）。
  - 主区关掉「响应式滚动」：否则系统在别的线程上挪主区的图层，行号列标和冻结窗格跟着重画会差一帧。
  - 列宽的单位是「默认字体里数字的最大宽度」：按我们真正用的字体量（Mac 上用苹方替代「等线」，数字更宽），
    不能写死 Excel 的 7 像素，不然 Excel 里放得下的金额在我们这里变成 ###。
  - Excel 的主题色编号前四个两两对调（0 是 lt1、1 是 dk1）；腾讯文档的默认字体是 `theme="1"`，不对调字就全白了。
- 截图模式：`SkySheet --snapshot-input 文件 --snapshot-output 图.png [--select K60]` 在屏幕外把整个窗口画成 PNG。
  开发时核对显示用，不需要录屏权限。参数都带「-」：不带的会被 AppKit 当成要打开的文件，打不开就弹模态框卡死。
- SwiftUI 的 `Table` / `Grid` 做不了单元格选区、冻结窗格、格内编辑这些表格的基本功，把 NSTableView 改成表格也很
  别扭，所以自绘。
- 基础编辑（第 16 条）：双击或直接打字进入编辑；回车、Tab 移动；公式栏同步；⌘C / ⌘V 用制表符分隔的文字，和 Excel、
  腾讯文档互通；⌘Z / ⇧⌘Z。M3 落地时的细节：
  - 改工作簿只有一个入口（`SheetSession.apply`）：改一份副本、整本重算、换上去、登记撤销。撤销就是换回改之前的整本
    （值类型），连同当时看的 sheet 和选区。
  - 格内编辑框是盖在格子上的 NSTextField，和公式栏读写同一份文字。直接打字是「输入」模式（方向键提交并移动），
    双击、F2 是「编辑」模式（方向键移光标）；Option+回车在格子里换行；编辑中 ⌘Z 是取消这次编辑。
  - 中文输入法：开始打字的第一下按键要转给编辑框，拼音才从第一个字母就进输入法。第一下 Esc 取消拼音、第二下 Esc 取消编辑，
    和 Excel 一样（2026-10-08 打包后实测）。
  - 复制时放两份：显示的文字（给别的软件）和 SkySheet 自己的格式（原始写法，粘回来不丢精度、公式按位置平移引用）。
    剪切 = 复制再清掉，第一版不做「粘贴时才移走」。
  - sheet 的改名、复制、删除在页签右键菜单和菜单栏的 Sheet 菜单里，作用于正在看的那张。
- 页签：AI 的 sheet 页签是紫色，带一个写着 AI 名字的小标（如「Claude」），鼠标停在上面显示完整署名（9.3 节）；
  原始 sheet 照常显示。

### 8.3 AI 在界面上

- 「这一轮」：和 SrtFlow 一样按时间划分。AI 开始改就开一轮、存一份工作簿快照，30 秒没有新调用算这一轮结束。
- 横幅：「Claude 改了 N 处 · 撤销这一轮」，名字是这一轮的 AI（9.3 节）。撤销这一轮 = 换回快照（一步，可以再 ⌘Z 回来）。
- 这一轮 AI 改过的格子淡色高亮，下一轮开始时消失；高亮不存进文件。
- AI 打开文件、写入时不抢前台：窗口在后面也照样更新。
- 关掉最后一个窗口不退出 App（AI 下一次调用还要用）。

## 九、MCP

### 9.1 三段结构，照搬 SrtFlow

- 从 SrtFlow 搬：`MCPServerCore`（新旧两代协议都接）、`JSONValue`、`MCPUnixSocket`、`MCPBridge`，小程序的
  `main.swift` 和 `AppConnection.swift`，App 端 `AIBridgeServer` 的做法。改名字和 socket 路径，删掉用不上的
  （fal、录屏这些），其余不动。
- 规矩照搬（理由见 SrtFlow 的 `docs/architecture/ai-control-mcp.md`）：
  1. 工具清单只有一份（`MCPToolName` 穷举）。小程序回清单、App 分派都 switch 它，加工具漏了哪一边都编译不过。
  2. 清单由小程序直接回，不为了列清单把 App 拉起来。
  3. 小程序的 stdout 只写 MCP 消息，调试输出写 stderr。
  4. 工具自己的失败是工具结果（`isError: true` 加一句话），不是协议错误。
  5. 只读的工具和会改东西的工具分开（客户端按 `readOnlyHint` 放行）。
  6. 说明文字只用英文；总说明（`instructions`）不超过 2,048 个字符：Claude Code 只读这么多，超了静默截掉。
  7. socket 在 `~/Library/Application Support/ai.skylu.skysheet/mcp.sock`，目录 0700、socket 0600，连进来的用
     `getpeereid` 核对用户；一次调用一条连接。

### 9.2 工具清单（第一版 14 个）

| 工具 | 只读 | 做什么 |
| --- | --- | --- |
| `get_status` | ✓ | 打开着的工作簿；每张 sheet 是原始的还是 AI 的，AI 的是谁写的；有没有没保存的改动；用户当前选中的区域（「分析我选中的这块」） |
| `open_file` | | 打开一个 xlsx / csv。只开用户给的路径或工具返回的路径 |
| `describe_sheet` | ✓ | 一张表的结构：用到的范围；认出的表格块（标题行、每列的名字、类型、格式、非空个数、样例值、数字列的合计和最值）；公式个数；「未重算」的格子 |
| `read_range` | ✓ | 读一块区域：值（全精度），可选显示文字和公式原文。一次最多 2,000 格，更多的用 `query` 或 `export_sheet` |
| `query` | ✓ | 对表格块跑一条 SQL（SQLite，只许 SELECT）。表名、列名用 `describe_sheet` 给的，也可以临时指定区域；最多回 500 行。SQL 里的数字是 Double，看汇总够用，要分毫不差的金额用公式 |
| `evaluate` | ✓ | 用 SkySheet 的公式引擎算一个公式，不写进表（「贷 100 万、30 年、3.1%，月供多少」） |
| `export_sheet` | ✓ | 把一张表或一块区域导出成 csv（写到 App 自己的缓存目录），回文件路径，给 Python 用 |
| `show` | ✓ | 在窗口里切到某张表、选中某块区域，让用户看到。只动界面、不动数据，不抢前台 |
| `add_sheet` | | 新建 AI 的 sheet：空白的、复制一张原始 sheet（`copy_from`，即第 12 条的「复制成新 tab 再改」），或者从 csv 导入（`from_csv`，接 Python 的结果）。`model` 填 AI 自己的模型名，用于署名（9.3 节） |
| `write_cells` | | 往 AI 的 sheet 写值和公式，`=` 开头的是公式；可以把一行公式往下填充到某一行（引用跟着平移，和 Excel 的下拉一样）。回写入的范围、公式算出的值、出错的格子 |
| `format_cells` | | 数字格式（预设名或格式代码）、粗体、颜色、列宽、冻结窗格。只限 AI 的 sheet |
| `edit_sheet` | | AI 的 sheet 改名、删除、挪位置 |
| `undo` | | 撤销上一步；`round=true` 撤销这一轮 |
| `save_copy` | | 把整本另存成一个**新**文件，目标已存在就拒绝。AI 没有覆盖原文件的工具 |

### 9.3 AI 的 sheet：怎么认、谁写的、怎么保证改不到原始数据

1. 写入类工具（`write_cells`、`format_cells`、`edit_sheet`）只认 AI 的 sheet。对原始 sheet 一律拒绝，错误里直接说
   「用 add_sheet copy_from 复制一份再改」。
2. 「AI 的 sheet」就是 AI 用 `add_sheet` 建的。保存时记进文件的 `docProps/custom.xml`：每张一个自定义属性
   `SkySheet.AI.<sheetId>`，值是一小段 JSON（署名，见第 5 条），控制在 255 个字符以内（Excel 界面里自定义属性的值
   最长 255 个字符，保守起见照这个来）。页签同时设成紫色，在别的软件里也看得出来。
3. 认不出来就当原始数据，比如文件被别的软件另存过、标记丢了。这时 AI 只是要再复制一份，数据不会被改。
4. 用户自己可以在页签的右键菜单里把一张 sheet 标成「AI 可改」或「原始数据」。
5. **署名**（第 23 条）：每张 AI 的 sheet 记两件事：谁建的、什么时候；最后是谁改的、什么时候。
   - 「谁」由两部分组成。一是客户端名，来自 MCP 握手里的 clientInfo，是可靠的；SrtFlow 已经在用它（`MCPBridge.Request`
     的 `client` 字段，再由 `AISession.displayName` 换成 Claude Code、Codex 这样人认得的名字）。二是模型名，由 AI 在
     `add_sheet` 的 `model` 参数里自报（如 `claude-opus-5-5`）。MCP 不告诉服务器对面是哪个模型，所以只能自报，可能为空。
     同一个客户端后面的调用沿用它报过的模型名。
   - 页签小标显示品牌名：模型名认得出就用模型的品牌（`claude-*` → Claude，`deepseek-*` → DeepSeek……），认不出就用
     客户端名。以后用户接别的 AI（第 17 条），靠的就是模型名这一项。
   - 鼠标停在页签上显示完整署名，例如：「Created by Claude Code (claude-opus-5-5), Oct 8, 2026 14:03」和
     「Last changed by you, Oct 9, 2026 09:12」。
   - 用户自己改了 AI 的 sheet，「最后是谁改的」就记成用户。
6. 第 14 条（不许用别的程序改用户的文件）只能靠总说明约束，因为 Claude Code 有终端权限。所以还有第二道保险：
   保存前发现文件被别的程序改过，就先问用户（第十节第 6 条）。

### 9.4 总说明草稿（英文）

```text
SkySheet is a spreadsheet app on the user's Mac; its window shows the workbook while you work. Usual
order: get_status (open workbooks, sheets, the user's selection) or open_file; describe_sheet to learn
the layout; read_range, query (SQL) or evaluate to get numbers; put results in a new sheet with
add_sheet and write_cells; show to point the user at them. Tool descriptions have the details.

Rules:
- Original sheets are read-only. Results go in new sheets (add_sheet). To change original data,
  add_sheet copy_from=<sheet> and edit the copy.
- Prefer formulas that reference the original cells, e.g. =RATE(Loan!C5,-Loan!F5,Loan!B5)*12, over
  typed-in numbers, so the user can trace every result.
- Python is fine for heavy analysis: export_sheet gives a CSV path; bring results back with add_sheet
  from_csv or write_cells. Never open, change or save the user's .xlsx/.csv files with other programs.
- Only open files the user named or these tools returned.
- Nothing reaches the user's file until they press Cmd+S. save_copy only writes a new file.
- A round of edits can be undone in one step (undo round=true).

Tools by need:
- Workbooks: get_status, open_file, save_copy
- Read: describe_sheet, read_range, query, evaluate, export_sheet
- Write (AI sheets only): add_sheet, write_cells, format_cells, edit_sheet, undo
- Point the user: show
```

### 9.5 连接 Claude Code

- 设置页一个按钮「连接 Claude Code」：
  - 跑 `claude mcp add --scope user skysheet <App 包里 skysheet-mcp 的路径>`。不直接改 `~/.claude.json`：
    正在跑的 Claude Code 会整份重写它，直接改会被冲掉。
  - 往 `~/.claude/settings.json` 的 `permissions.allow` 里加 `mcp__skysheet`（第一次改之前先备份），免得每个工具都问一次。
  - 找不到 `claude` 命令行，就给「复制一段话」，让用户贴给 Claude Code 自己装。
- 状态有四种：没装 Claude Code / 没连接 / 已连接 / 连着另一份 SkySheet（App 挪过位置）。

### 9.6 一个完整的例子

用户：「算一下我这几笔分期的实际年化利率，哪笔最贵？」

1. `get_status` → 打开着 loan.xlsx，只有原始 sheet「Loan」。
2. `describe_sheet Loan` → 第 1–11 行是一个表格块（贷款类型、贷总额、分期月份……本+利），第 13–26 行是「参考选项」。
3. `add_sheet name="AI-实际利率"`，再 `write_cells`：第一行写标题；下面每行对应 Loan 里一笔每月还款额固定的贷款
   （第 2、5–10 行），写 `=Loan!A5`、`=Loan!B5`、`=RATE(Loan!C5,-Loan!F5,Loan!B5)*12` 这样的公式（第 5–10 行是连着的，
   写一行再往下填充）。
4. `format_cells` 把利率列设成 `percent`；`show` 选中结果。
5. 回答用户哪笔最贵。顺带提醒：商业贷款和公积金贷款（第 3、4 行）是等额本金，每月还款额不同，不能这样用 RATE，
   它们的实际利率就是名义利率。

用户在 SkySheet 里看到一张紫色页签的新表，点开每个格子都能看到公式指向 Loan 的哪一格；Loan 本身一个字没动。

## 十、保存安全（第 15 条的六道保险）

1. **只有 ⌘S 写回原文件**：AI 的改动和用户的改动一样，先放在内存里，窗口标题显示「未保存」。
2. **AI 没有覆盖原文件的工具**：只有 `save_copy` 另存成新文件，目标已存在就拒绝。
3. **先写临时文件，核对，再替换**：先写到同一个文件夹里的临时文件；用我们自己的读取器读回来，逐格比对内存里的
   工作簿，没动过的部件逐字节比对；全对才原子替换原文件。任何一步失败，原文件不动，告诉用户是哪一步。
4. **第一次覆盖前备份**：一个文件在 SkySheet 里第一次被覆盖之前，先把原文件复制到
   `~/Library/Application Support/ai.skylu.skysheet/Backups/`（文件名加时间），每个文件留最近 10 份。设置里有
   「打开备份文件夹」。
5. **崩溃恢复**：每 30 秒把有没保存改动的文档写一份恢复副本（xlsx，不碰原文件）到同一个目录下的 `Recovery/`，
   存了、关了就删。App 异常退出后，下次启动时提示：Restore（恢复成「（Recovered）」的未命名窗口，存的时候默认放回原文件
   旁边）/ Not Now（下次再问）/ Discard。M3 定了自己写，没用 NSDocument 自带的「另处自动保存」：它恢复时要靠系统的
   窗口恢复，什么时候恢复、恢复成什么样不好控制，也没法在自检里测。
6. **文件被别的程序改过就先问**：保存前比对打开时记下的修改时间，对不上就不覆盖，让用户选：另存为新文件 / 仍然覆盖
   （先把别人改过的那一版也备份）/ 重新载入 / 取消。NSDocument 自己也查，但它的提示只有「存 / 不存」，所以我们的检查
   放在它前面（`save(withDelegate:…)`），选了覆盖就把修改时间对上，它不再拦（2026-10-08 实测）。

## 十一、构建、签名、CI

- `Package.swift`：`swift-tools-version: 6.0`，Swift 6 语言模式，`.macOS(.v15)`。App target 如果被 AppKit 的并发
  标注卡住，可以单独降到 Swift 5 模式，在 `Package.swift` 里写明原因。
- **一律带 `--arch arm64`**：作者这台 M1 的终端跑在 Rosetta 下（`sysctl.proc_translated` 是 1），不带就编成 x86_64。
- 打包 `scripts/build-app.sh`：从 SrtFlow 搬，去掉 ffmpeg 那段。版本号取 git tag，正式发版用 `VERSION=x.y.z`
  显式指定。产物是 `dist/SkySheet.app` 和 `dist/SkySheet-<版本>-arm64.dmg`，DMG 里带「首次打开必读」。
- 签名 `scripts/signing/`（`common.sh`、`create-identity.sh`、`sign-app.sh`）：从 SrtFlow 搬，改成：
  - 证书叫「Skylu Signing」：自签名、只能签代码、20 年；
  - 私钥在仓库外的 `~/.config/skylu/signing/`（专用钥匙串和它的密码文件，目录 700、文件 600），要进 Time Machine 备份；
  - 仓库里只钉证书的 SHA-1：`packaging/signing-identity.sha1`；
  - 只经 `sign-app.sh` 签：先签 `Contents/Helpers/skysheet-mcp`，再签外层；
  - **永远不重建证书**。换机器就把整个目录拷过去；这台机器上没有，就停下来问作者。
  - 为什么要固定签名：AI 让 App 打开「下载」「文稿」「桌面」里的文件时，系统会弹框要权限。权限按签名记账，
    ad-hoc 签名的每个版本都算新 App，每次升级都要重新给。
  - 作者以后别的个人工具也用这一把证书（bundle id 不同，权限各算各的）。SrtFlow 那把不动。
- CI（`.github/workflows/checks.yml`）：每个 PR 和合进 main 之后跑 `scripts/check-all.sh`。用 `macos-26`
  （和本机工具链一致）。只开 1 个 job：免费档同时最多 5 台 macOS，整个账号共用，SrtFlow 一跑就占满。同一个 PR
  推了新提交就取消旧的那一轮。签名私钥不在 CI 上，CI 只编译和自检。
- 仓库规则：main 只能经 PR 合入；M1 有了 CI 之后，再把 `check-all` 设成必须通过。
- 发版：本机 `build-app.sh` 打包签名 → `gh release` 上传 DMG。

## 十二、自检

- 本机只有命令行工具：没有 XCTest，也没有 Swift Testing（2026-10-08 实测 `import Testing` 报 no such module）。
  所以照 SrtFlow 的做法：一个 `SkySheetChecks` 可执行程序，用极简的 `check` / `checkEqual` 断言，全过退出码 0；
  `scripts/check-all.sh` 一条命令跑完编译、自检程序和几条脚本守卫，本机和 CI 跑同一个。
- 要钉住的：
  1. **公式对照**：loan.xlsx 的 124 个公式（5.6 节）；加上一万行还款计划表的重算时间（5.5 节）。
  2. **格式对照**：样例里的格式逐个比显示文字，如 G2 `0.0000%` → `0.1786%`，I2 编号 68 → `2.14%`，K2 → `¥3,053.92`。
  3. **原样保留**：loan.xlsx 读进来不改直接存 → 每个部件逐字节相同；加一张 AI 的 sheet 再存 → Loan 的
     `sheet1.xml`、图片、绘图逐字节相同，新 sheet 读回来内容对。
  4. **zip**：我们写的包能通过系统 `unzip -t`；系统 `zip` 命令和 Python 打的包我们能读。
  5. **csv**：UTF-8（带和不带 BOM）、GB18030、逗号和制表符、引号里的换行。
  6. **MCP**：两代协议的握手、工具清单、总说明不超过 2,048 字符、说明文字里没有汉字（从 SrtFlow 搬对应的检查）。
  7. **样例泄漏守卫**：`git ls-files SampleData` 必须是空的。
- 显示效果靠截图模式核对（8.2 节），M2 起每次改表格画法都截一张看。
- 自动化够不着的（真窗口、别的软件打开我们存的文件、和 Claude Code 端到端对话），每个里程碑结束前在真机上按
  清单走一遍，清单放在 `docs/testing/`。

## 十三、里程碑

| 里程碑 | 内容 | 验收 | 版本 |
| --- | --- | --- | --- |
| M0 起步 | 仓库、许可证、样例、这份设计、`CLAUDE.md` | 作者过目 | — |
| M1 核心 | SkyZip；读 xlsx；模型；公式引擎和第一版函数；数字格式；自检程序和 CI | loan.xlsx 的 124 个公式对照全过；格式对照全过；CI 绿 | — |
| M2 查看器 | NSDocument、表格视图、页签、公式栏（只读）、打开 xlsx / csv；签名证书、打包脚本、DMG | 作者装上能打开 loan.xlsx 和自己的表，显示和腾讯文档一致（图片除外） | v0.1.0 |
| M3 编辑与保存 | 基础编辑、撤销、复制粘贴、sheet 操作；写 xlsx（原样保留）；六道保险；写 csv | 原样保留的自检全过；存过的文件在腾讯文档、Numbers 里打开正常 | v0.2.0 |
| M4 MCP | MCPKit、小程序、App 的 AI 层、14 个工具、这一轮和撤销、AI sheet 的标记和署名、连接 Claude Code | 用作者的三类典型问题和 Claude Code 端到端走通 | v0.3.0，第一个真正可用的版本 |
| M5 打磨 | 按实际使用补函数和格式、性能、把长期约束整理进 `docs/architecture/` | 作者日常用一周没卡壳 | v0.4.0 |

## 十四、待确认

暂无。新的待确认项写在这里，定了就挪进第二节，并在变更记录里记一行。

## 十五、已知不足（第一版）

- 公式只是子集：数组公式、结构化引用、定义的名称都不支持；清单外的函数显示文件里的缓存值，标「未重算」。
- Decimal 和 Excel 的 Double 在第 15 位有效数字以后可能不同。
- 万元格式只有 1 位小数和精确到元两种。
- 打不开有密码的 xlsx，也不支持 xls（老格式）和 ods。
- 条件格式、数据验证、批注、图片都显示不出来（第 11 条）；没改过的部分保存时原样保留。
- 署名里的模型名是 AI 自报的，SkySheet 核实不了；客户端名是可靠的。
- 改过的 sheet 写回时，行的分组（大纲）、自动行高标记，格子上的 `vm` / `cm`（Excel 新版的格内图片、动态数组的元数据）
  不保留；没改过的 sheet 原样不受影响。
- 复制 sheet 不带条件格式、数据验证、图片、批注；只在图表 sheet 里有效的定义名称读的时候就不要了（第一版用不到）。
- 剪切不是「粘贴时才移走」，而是复制后马上清掉。

## 变更记录

- 2026-10-08 起草。
- 2026-10-08 作者确认：界面先只做英文（第 22 条）；第一版不做插删行列（第 11 条）；AI 的 sheet 记在文件里、页签紫色
  （9.3 节）。新增 AI 署名（第 23 条），起因是作者说以后会让用户接别的 AI。
- 2026-10-08 作者确认：图片不显示、只原样保留（第 11 条）；AI 的名字不写进 sheet 名（第 23 条）。定稿。
- 2026-10-08 M1 完成：zip、读 xlsx、公式引擎（62 个函数）、数字格式、自检程序和 CI。实测结果写进 5.5、5.6、7.1 节。
- 2026-10-08 M2 完成：查看器 v0.1.0（表格、冻结窗格、公式栏、页签、选区合计、打开 xlsx 和 csv、签名证书、打包）。加了 SkySheetDisplay 模块；实测写进 7.3、8.2 节和第 22 条。
- 2026-10-08 M3 完成：编辑与保存 v0.2.0（格内编辑和公式栏、撤销、复制粘贴、sheet 改名复制删除、写 xlsx 和 csv、六道保险）。
  第十节第 5 条定为自己写恢复副本；第 6 条的检查要放在 NSDocument 自己的前面。实测写进 7.2、7.3、8.2、第十、十五节。
