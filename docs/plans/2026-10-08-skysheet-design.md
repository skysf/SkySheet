# SkySheet 设计方案

> 2026-10-08 定稿。产品上的每一条都是作者在 2026-10-08 的讨论里逐条拍板的；
> 这里写决定、理由和做法。推翻哪一条之前先读它的理由；改了就在这里改，并在文末「变更记录」记一行。
> 其他文档引用时写成「设计第 N 条」（第二节的编号）或「设计 5.2 节」。

## 一、要做什么

SkySheet 是一个**给 AI 用的**轻量 macOS 表格工具：

- 用户用它打开 xlsx / csv，**主要是看**，偶尔改几个数。
- Claude Code（和 Claude 桌面版的聊天，第 17 条）通过 MCP（服务名 `skysheet`）读表、算数，把结果**写进新的 sheet**；
  原始数据永远不动。
- 典型问题（作者原话整理）：算一下这几笔贷款的利率；哪种贷款方式更合理；和我现在每个月的还款比，
  我应该贷多少、多少利率的贷款。
- 数据规模：一张表最多几千行。
- 现在只有作者自己在用：不做 Apple 公证，第一次打开走「系统设置 → 隐私与安全性 → 仍要打开」。

**2026-11-15、11-16 作者定的方向（计划，还没做）**。做法、理由、实测和调研在 `docs/plans/2026-11-15-skyfolio-word-markdown.md`
（下称「新方案」），排期见第十三节：

- **从表格工具变成通用的文件 App**：同一个 App 里还开 Word（.docx，只读，AI 能读）和 Markdown（.md，用户和 AI 都能改），每种文件有自己的界面；
  PPT 以后再说。理由：作者要一个 App 开各种文件，不像 Office 分成好几个 App（第 5 条）。
- **改名 SkyFolio**（第 1 条）：它已经不只是表格。
- **以后给别人用**，不再只给作者自己：先不公证，别人第一次打开同样走「仍要打开」，步骤写进 README；更新靠用户自己去 GitHub Releases 下载，
  不做自动更新，也不做应用内检查更新；App 自己不联网，不加崩溃报告和统计（第 11 条）。排在最后一个里程碑（新方案第八节）。

参考实现是作者的另一个 App SrtFlow（本机 `../srt_vtt/app_files`，公开仓库 `github.com/skysf/SrtFlow`）。
签名、MCP 三段结构、自检程序的写法都从那里搬，搬的时候按这里的取舍删减。

## 二、决定一览

| # | 方面 | 决定 | 理由 |
| --- | --- | --- | --- |
| 1 | 名字 | App 叫 SkySheet；bundle id `ai.skylu.skysheet`；MCP 服务名 `skysheet`；仓库 `skysf/SkySheet`（公开）。**计划（2026-11-16 定，M6 做）：改名 SkyFolio**，对外全名「SkyFolio by Skylu」；bundle id `ai.skylu.skyfolio`，MCP 服务名 `skyfolio`，仓库 `skysf/SkyFolio`；App 第一次启动时把备份、恢复副本和两家 AI 客户端配置里的 `skysheet` 条目迁过来（新方案第七节）。xlsx 里 AI 的 sheet 的标记 `SkySheet.AI.` 不改；表格引擎的模块继续叫 `SkySheet*` | Excel 是微软的商标，Numbers 是苹果的，Sheet 是普通词。skylu 是作者的个人品牌（skylu.ai）；SkyStudio 是另一个品牌，不混用。改名是因为它要开 Word、Markdown，不只是表格了。已知撞名：韩国 MUIN 公司 2026-10 发布的天文照片 Mac app「Skyfolio」（也走 GitHub Releases），安卓上 Snapwood 的「SkyFolio - OneDrive Photos」；作者知道后仍选它，全名带上品牌来区分；上 App Store 或正式推广之前，去 USPTO、EUIPO、中国商标网正式查一次。`SkySheet.AI.` 已经写进了用户的文件，改了旧文件就认不出来 |
| 2 | 许可证 | AGPL-3.0 | 和 SrtFlow 一样；MCP 协议代码从 SrtFlow 搬来，两边一致 |
| 3 | 平台 | macOS 15 起，只支持 Apple 芯片（arm64） | 和 SrtFlow 一样，不为 Intel 多测一套 |
| 4 | 签名 | 自签名证书「Skylu Signing」，作者所有个人工具共用；不公证 | 第十一节 |
| 5 | 文件 | 读写 xlsx、csv。计划（2026-11-15、11-16 定）：Word（.docx，顺带 .dotx、.docm）只读，M8 做；Markdown（.md）读写，M7 先只读、M9 能改；.doc、.rtf、.odt 不做 | 作者的数据就是这两种（腾讯文档、银行导出）。2026-11-15 作者要同一个 App 开更多种文件：先 Word 和 Markdown，PPT 以后（新方案第二节） |
| 6 | 原样保留 | 读不懂的、没改过的部分，保存时按原字节写回 | 样例里就有图片和合并单元格，丢了就是毁数据 |
| 7 | 依赖 | 不通过包管理器引用第三方库：`Package.swift` 里没有 `dependencies`，构建时不联网拉代码。允许把许可证和 AGPL-3.0 兼容的开源代码复制进仓库，放在 `ThirdParty/<项目名>/`，带原许可证和出处，一个项目一个 target；复制进来就是我们的代码，由我们维护，和自己写的一样过自检和审查（细则见本表下面）。zip 自己写（压缩用系统的 Compression），查询用系统的 SQLite3 | 作者 2026-10-08 定：不引外部库。2026-11-16 放宽：可以把别人的开源代码搬进来自己维护——代码都在仓库里，看得见、改得了，不会被上游的更新带着走，构建也不联网（新方案 11.1 节；要搬的项目见新方案第十二节） |
| 8 | 公式 | 常用函数子集，贷款理财的函数优先（第五节）；不追求全兼容 Excel | 够用、可测 |
| 9 | 数值 | 加减乘除和求和用 Decimal；RATE、IRR、XIRR 这类迭代或超越函数内部用 Double | 金额分毫不差；作者接受个别结果和 Excel 在最后一位上有出入 |
| 10 | 显示 | 人民币、万元、百分比、中文日期；兼容腾讯文档的非标准格式编号；不做中文大写金额 | 作者要求 |
| 11 | 不做 | 图表、透视表、宏、条件格式和数据验证的编辑、多人协作、在表格里显示图片。插入 / 删除行列第一版没做，2026-10-14 起只在安全的表上做（8.4 节）。2026-11-15、11-16 加：Word 的编辑和分页显示；.doc、.rtf、.odt；Markdown 的所见即所得；自动更新和应用内检查更新；Apple 公证（暂不）；崩溃报告和统计 | 主要给 AI 用，用户只是看；汇总表让 AI 用公式或 SQL 生成。图片只原样保留（第 6 条）：SkySheet 里看不到，腾讯文档、Excel 里照常显示。插删行列要连带改整本里所有公式的引用，表里有我们不认识、又按位置指着格子的东西（图片、条件格式、数据验证……）时没法跟着改，所以只在没有这些东西的表上允许；2026-10-14 作者要了，就照这个条件做。11-15、11-16 加的几样：Word 只读就够看、够给 AI 读，分页要排版引擎；Markdown 只编原文，所见即所得保不住原文的写法；App 不联网（不查更新、不发崩溃报告），表格里是财务数据；公证要花钱，先不做（新方案第三、四、八节） |
| 12 | AI 的权限 | 原始 sheet 对 AI 只读；结果写进新 tab；要改原表，先复制成新 tab 再改。计划（2026-11-16 定）：Word 对 AI 只读；Markdown AI 能改——改动进窗口里打开着的文档，能撤销，改过的地方和表格里 AI 改过的格子一样标淡紫色，写回磁盘仍然只有用户按 ⌘S（第 15 条），走六道保险（第十节） | 原始数据当 raw data 永久保留。这一条管的是表格的原始 sheet；Markdown 不是 raw data，是用户自己在写的文档，作者 2026-11-16 明确允许 AI 改：改动只在内存里、看得见、撤得掉，落盘的那一下仍在用户手里（新方案 4.5 节） |
| 13 | AI 写什么 | 优先写引用原表的活公式（如 `=RATE(Loan!C5,-Loan!F5,Loan!B5)*12`）；纯文字结论和 Python 算出的结果写成值 | 原数据一改结果跟着变，用户能点开核对每个数怎么来的 |
| 14 | Python | 允许 Claude 用 Python / pandas 分析；数据进出只走 SkySheet 的工具，**不许用别的程序改用户的 xlsx / csv 文件**。计划（2026-11-16 定，能开文档以后生效）：范围扩到「在 App 里开着的文件」，不扩到所有 .docx、.md；开着的文件在磁盘上被改了，没有没存的改动就先备份上一版再重新载入，有就按第十节第 6 条先问 | 方便用自然语言操作；写回统一经过 SkySheet，才有撤销和保存安全。不扩到所有 .md：总说明对整个会话生效，会拦住 Claude Code 平时改 README（新方案 5.6 节） |
| 15 | 保存 | 只有用户按 ⌘S 才写回原文件；六道保险（第十节） | 作者定：哪种更能保证数据安全就选哪种 |
| 16 | 用户编辑 | 基础编辑：改值、改公式、撤销 / 重做、复制粘贴、sheet 的重命名 / 删除 / 复制。2026-10-14 加：列宽行高（拖边线、双击自动适应、输入数值）、整行整列的选中和隐藏、冻结窗格、插删行列、单元格格式（粗体斜体、数字格式、字色底色、对齐、换行、合并）；这些 AI 也都能做（9.2 节） | 作者要求「基础的修改功能」；2026-10-14 作者要「更多的编辑功能，比如拉伸整列整行的间距」，新功能同样要支持 MCP，给出的几组全选了 |
| 17 | AI 客户端 | Claude Code 和 Claude 桌面版的普通聊天（9.5 节） | 协议层是通用的。第一版只接 Claude Code；2026-10-09 作者要桌面版的普通聊天（不是它的 Code 页，那里跑的就是 Claude Code）也能用。Codex 等以后要了再加 |
| 18 | 敏感信息 | 不做脱敏 | 作者确认数据里没有身份证号、手机号这类信息 |
| 19 | 测试数据 | 只提交 `Fixtures/loan.xlsx`（从作者表格里抽出的 Loan 表，来历见 `Fixtures/README.md`）；`SampleData/` 永不入库 | 仓库是公开的；真实表格里还有房产、装修、理财等个人信息 |
| 20 | 仓库流程 | main 禁止直推，走 PR，CI 绿了才合；CI 只占 1 台 macOS 机器 | 和 SrtFlow 一样；免费档同时最多 5 台 macOS，是整个账号共用的 |
| 21 | 代码 | 按职责拆文件，一个文件大约 500 行就考虑拆，不设守卫脚本；多用泛型和共用内核，不复制第二份 | 作者定：方便维护、效率高就好，不必像 SrtFlow 那么严 |
| 22 | 语言 | 界面先只做英文；注释和文档用中文；给模型看的 MCP 文字用英文 | 作者 2026-10-08 定：先做英文版，中文以后再加。界面文字一律用 `String(localized:)`、开发语言英文，以后加中文只是补翻译。本机只有命令行工具，没有编 String Catalog（.xcstrings）的 xcstringstool（2026-10-08 实测），所以翻译照 SrtFlow 用 `.lproj/Localizable.strings`。本文引号里的界面文字只写意思，实际是英文 |
| 23 | AI 署名 | 每张 AI 的 sheet 记下是哪个 AI 建的、最后是谁改的；页签上显示 AI 的名字（如 Claude）；存进文件，下次打开还在；不写进 sheet 名 | 作者要求；以后会让用户接别的 AI，得分得清是谁写的。不进 sheet 名：名字会变长（Excel 限 31 个字符），换了 AI 再改时名字里的署名也会过时。做法见 9.3 节 |

**第 7 条细则：搬进来的开源代码**（2026-11-16 定；理由、调研和这几样怎么搬见新方案 11.1 节、第十二节）：

- 能搬的许可证：MIT、BSD（2 条、3 条）、ISC、zlib、Apache-2.0、MPL-2.0（没带「与次级许可证不兼容」声明的）、GPL-3.0 及以后（含 GPL-2.0-or-later 选 v3）、
  LGPL-3.0、AGPL-3.0、CC0 和 Unlicense 这类公有领域声明。不搬：GPL-2.0-only、没写许可证的（等于保留所有权利）、带「不许商用」之类附加条件的、SSPL、BUSL。
  按 FSF 的许可证兼容列表核，拿不准就不搬。
- 放在 `ThirdParty/<项目名>/`：`LICENSE` 原文（有 NOTICE 的一起带）、`SOURCE.md`（上游地址、版本、提交哈希、复制日期、复制了哪些文件、改了什么和为什么、
  谁审的）、代码；一个项目一个 target。改过的地方加注释「本仓库改：……为什么」（Apache 的文件改过要注明，MPL 的文件头要留着）。
  `ThirdParty/README.md` 一张总表：项目、许可证（SPDX 写法）、上游提交、上次核对上游的日期。只照着别人的读法改写、没搬原代码的，文件头保留对方要求的
  版权声明，也记进总表。
- 搬之前审一遍（照常走 PR）：许可证；把要搬的代码读一遍——从此是我们的：不联网、不往意料之外的地方写文件、没有统计；只用系统框架，不再带别的第三方依赖
  （带了的要么也按这套规矩搬，要么替掉）；只搬用得到的部分；自己写自检钉住用到的行为（比如解析器喂畸形输入不能崩）。
- 上游的安全修复由我们跟：作者对每个上游仓库点 Watch（Releases、Security alerts）；每次发版前对总表逐个核一遍上游从记下的提交以来的安全修复，
  有就单开一个 PR 搬过来、更新记录。解析别人文件的代码优先看。
- 分发时带上版权声明：关于窗口里的「第三方许可」，包里和 DMG 里的 `THIRD-PARTY-NOTICES`（由打包脚本从 `ThirdParty/*/LICENSE` 拼出来）。
- 别人的测试数据同样要许可证兼容、带许可证和出处，放在 `Fixtures/` 下按来源分的子目录。
- 第一个项目搬进来时 `check-all.sh` 加守卫：`ThirdParty/` 下每个目录都有 `LICENSE` 和 `SOURCE.md`；`Package.swift` 里没有 `dependencies:`。

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
| `SkySheetMCP` | 可执行，产物 `skysheet-mcp` | SkySheetMCPKit | Claude Code、Claude 桌面版启动它；清单当场回，调用转给 App；App 没开就 `open -g` 拉起来 |
| `SkySheet` | 可执行（App） | 以上全部 | 文档、表格视图、编辑、保存安全、AI 层、「连接 Claude Code / Claude 桌面版」 |
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

- LEN、LEFT、RIGHT、MID 按 Excel 版本 2 的语义，按 Unicode 标量计数和截取：代理对只占一个位置，组合音标、
  变体选择符各占一个位置，不会切开代理对产生 U+FFFD。依据微软的
  [兼容版本说明](https://support.microsoft.com/en-gb/excel/compatibility-versions)和
  [LEN 文档](https://support.microsoft.com/en-us/excel/functions/len-function)。不切换到旧版按码元计数的行为。
  FIND、SEARCH、REPLACE 当前尚未登记，仍保留文件缓存值。
- 条件统计（COUNTIF(S)、SUMIF(S)、AVERAGEIF(S)）保留显式区域完整大小，不能因为 usedRange 较小丢掉末尾空白；整列、
  整行也保留逻辑大小，只存有值的位置。数空白按「区域格数 − 各条件区域有值位置的并集格数」加匹配到的有值位置计算，
  不逐格展开。区域用有序数组和游标归并，不为每次调用建字典、集合或排序；文字条件模板只解析一次，避免每格重复分词。空白条件引用按 0，显式 `""` / `"="`
  匹配空白及公式返回的空文字；`"<>"` 只排除真正的空格子，公式空文字仍计入非空（微软
  [COUNTIF 答复](https://learn.microsoft.com/en-us/answers/questions/4972990/having-issue-with-excel-countif-formula)
  说明这个区别；官方函数参考没有单独列出此边界，尚待真机交叉核对）。IFS 参数形状不一致返回 #VALUE!。
  SUMIF / AVERAGEIF 的目标从左上角按条件区域的逻辑大小扩展，越出工作表的部分截到边界；位置仍按逻辑列宽对齐。
  微软 [SUMIF 文档](https://support.microsoft.com/en-us/excel/functions/sumif-function)明确了左上角和形状规则，未明说越界；
  截断沿用 main 的结果，并按工作表边界推断，真机清单保留核对项。
- 财务取参有函数自己的规则：IRR 跳过文字和逻辑值，但必须传播现金流中的错误；NPV 忽略直接给的逻辑值，后面的数不能
  因为它多折现一期。CUMIPMT / CUMPRINC 用贴现后的等比数列有界计算：指数非正，不先算巨大的增长因子，也不把
  付款与利息的消减误差再放大。非有限结果返回 #NUM!，不能按输入期数无限循环。
- TODAY 只取本机时区，历法显式用公历；DATE、EDATE、EOMONTH 和序列号换算在整数运算前检查范围，超出 Excel 的
  9999 年上界返回 #NUM!。XLOOKUP 必须先检查原引用等形，不能靠裁剪后的形状蒙混或越界读结果。
  多列返回区域给 #VALUE!：Excel 365 会溢出成多格，但当前内核只返回单值，不支持动态数组。

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
- 2026-11-14（M5 性能，8.2 节「性能」）：还是整本重算，但计划（解析每个公式、找依赖、排顺序）只由「哪些格子有公式、
  原文是什么、sheet 名的顺序」定（`FormulaLayout`），两次之间没变就接着用上一次的（`RecalcCache`，一个窗口一份，读文件时
  那一次排的也交给窗口）；解析结果按原文跨重算留着（`FormulaParseCache`）；找公式时上一次见过的表只看改过的行
  （`SparseGrid.rowsDiffering`）。找依赖改成按列号从左到右走，计算顺序每次一样。实测（release，见 8.2 节的表）：这张表
  改利率一次 280 → 89 毫秒（主线程 CPU 时间的中位数），剩下的大头是 Decimal 求值本身。
- 2026-11-15 循环引用漏标（main 上就有的 bug，Codex 审 PR #10 时指出）：原来深度优先碰到「还在栈上的格子」才把栈上
  那一段标上，同一个环里从别的路走到、已经走完的公式会漏标——A1 = SUM(B1:C1)、B1 = A1、C1 = IFERROR(B1,7)，先走 B1
  就漏了 C1，C1 显示 7。漏不漏随字典顺序变；11-14 按列号固定了顺序，这个例子就固定地漏了（当时写的「只改标记顺序、
  值不变」不对）。现在按强连通分量（Tarjan，显式的栈）：**环上的每个公式都标**（分量里有两个以上公式，或者只有一个
  但引用了自己），标哪些和走的先后无关；只是依赖环、自己不在环上的公式不标，值是从环传下来的错误（原来就是这样）。
  某些表上的值会变：原来漏标的公式从算出来的数变成 #CIRC!，依赖它的跟着变。自检 `circularChecks`（随机图对照穷举）。增量依赖图（只算受影响的公式）还是没做：改利率这种全表都依赖的格子它也帮不上，要更快得给 Decimal
  的加减乘除加快速路径（第十五节）。

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
- 2026-11-15 内置 12 / 13（`# ?/?` / `# ??/??`）按分母最多 9 / 99 找最近的分数；整数省掉分数但保留 `?` 的对齐空格，
  负号、颜色和负值分段仍走共用渲染。未转义斜杠才表示分数。分母占位符支持最多四位，更多安全显示 `########`。
  连分数算法选最近的既约分数，固定分母（`# ?/2`、`?/4`、`# ?/8`、`# ??/16`、`# ?/10`、`# ??/100`）保留指定分母，
  缩放后及分数转换前检查有限性，溢出显示 `########`；混合 `#0` 从右侧填数，只补未占用的强制零位。
  依据微软 [分数格式说明](https://support.microsoft.com/en-us/excel/display-numbers-as-fractions)。`00/00` 的分母补前导零。
  混合分数的零分子在没有强制 `0` 时隐藏分数、保留对齐空格；例如 0 与 0.01 在 `# ?/?` 下均只有四个空格，
  0.01 在 `# ??/??` 下为 `  1/99`。这是按微软
  [占位符规则](https://support.microsoft.com/en-us/excel/review-guidelines-for-customizing-a-number-format)
  和最近分数规则推导，文档没有逐一列出零值的精确空格输出，仍列入真机比对。
  秒小数支持最多 14 位（一天的刻度仍能放进 Int），更多精度安全显示 `########`；不能先算 10ⁿ 再检查。
  超范围日期导出为 ISO 时返回 nil，CSV / SQL 保留原数字，不能让文件里的大数触发强转崩溃。

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
  - 共用字符串表：已有的文字用原来的编号；富文本那几条只给原来用它的格子用（文字没变就接着用，格式不丢；哪一格用的哪一条
    记在 `Sheet.richTextSources` 上，2026-10-14 起插删行列、复制 sheet 时跟着格子走）；新文字往后加，
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
  或「只存回 csv（AI 的 sheet 不会保存）」。2026-10-14 起界面上能改格式了：这张表新改了 csv 存不下的样子（字体、底色、边框、
  对齐、换行、csv 写不出来的数字格式、合并、隐藏、行高、冻结；日期、百分比、列宽不算）也弹同一个框，「只存数据」以后
  不再问（和上次存的时候比）。

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
- 截图模式：`SkySheet --snapshot-input 文件 --snapshot-output 图.png [--select K60] [--zoom 1.5]` 把整个窗口画成 PNG。
  开发时核对显示用，不需要录屏权限。参数都带「-」：不带的会被 AppKit 当成要打开的文件，打不开就弹模态框卡死。
  2026-11-14 起窗口根本不放上屏幕（`OffscreenWindow`：defer 建窗口、不 orderFront，启动时设成 `.prohibited`），
  作者开着别的东西干活时也能跑，不弹窗、不抢焦点、不进 Dock。
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
- **性能（2026-11-14，M5）**。作者说「打开的表格数据比较多就会卡」，没说哪个动作卡，所以先做了能重复的测量，再按量出来
  的占比改：
  - 测速模式（`App/Benchmark.swift`、`BenchmarkSupport.swift`）：`SkySheet --benchmark synthetic:data|synthetic:formulas|
    synthetic:styles|文件.xlsx [--sheet-index N] [--benchmark-only scroll|select|edit|resize|switch|verify] [--frames N]
    [--benchmark-json 结果.json]`。
    六类动作（打开、滚动、移动选区、改格子、拖列宽行高、换 sheet 和缩放）各做若干帧，报每帧**主线程 CPU 时间**的
    中位数、p95、最大值，以及每帧重建了几次画布、画了几块、画了多大。窗口不放上屏幕（`OffscreenWindow`），照屏幕上
    会发生的事画进位图：视图标脏的区域（`DrawStats` 记）加主区滚动新露出来的条。合成的表（`SyntheticWorkbook`：
    10 万行 × 20 列纯数据、一万期还款表 5 万个公式、5,000 行 6,500 个合并单元格加各种样式，固定种子）先写成 xlsx
    再打开，「打开」走的和双击文件同一条路。要用 release 构建量（`swift build -c release --arch arm64 --product SkySheet`）。
    热点用系统的 `sample` 对着测速进程采。
  - `--benchmark-only verify`（`App/BenchmarkVerify.swift`）：每个视图留一张「屏幕」，只按标脏的区域往上画（滚动时照系统
    的做法把原来的内容挪过去），每一步之后和整块重画逐字节比，对不上的打印 MISMATCH、以 1 退出。**改了画法就跑一遍**：
    点格子、方向键、Shift 拉、整行整列、全选、改格子、滚动、换 sheet、合并单元格，100% 和 137% 缩放。
  - 量出来的原因，按占比（都改了，改前改后的数字见下表）：
    1. 选区一变，四块窗格和行号列标整块重画：按一下方向键就把一屏的字全画一遍。→ 只重画旧选区、新选区经过的那几行，
       行号列标只重画选中过的那几条（`SpreadsheetView.invalidateSelection`）。
    2. 画格子：`SparseGrid.row` 每次连值排序，填充、文字、边框三遍各排一次；每个格子都把整张表的合并单元格过一遍；
       主线程上的闭包交给别的模块的函数（`first(where:)`、`overflowColumns`），**Swift 6 每调一次都做运行时的线程检查**
       （`swift_task_isCurrentExecutor`），几千格下来比画字还贵。→ 一行只取一次（`entries(inRow:columns:)`）、
       `MergeIndex`（按 32 行分桶）、热循环里不传闭包（要传的放进 nonisolated 静态函数）。
    3. 画字：每格现建 Swift 字典和段落样式，AppKit 每查一个键都要桥接；每一帧重新按数字格式排字、量字。→
       `TextAttributes`（真正的 NSDictionary，字串和属性拼成 CFAttributedString 来量和画）；显示文字按位置记着
       （`DisplayContentCache`，取的时候拿格子本身比，改过的不会用旧的）；量出来的宽度、数字放不下时显示成什么也记着。
    4. 重建画布（拖边线、缩放每一帧都建）：每次数一遍所有格子求用到的范围、重排行列、重建合并表、量十个数字。→
       和上一份画布比，没变的接着用；改过几格只看改过的行（`SparseGrid.rowsDiffering`）；最近看过的几张表的画布留着，
       换 sheet 回来接着用。`SparseGrid` 里比两版表格、合计时走格子的几个函数标了 `@inlinable`：App 跨模块调泛型版本，
       每一行都要查一遍类型信息，慢十倍。
    5. 改格子：整本重算每次从头排计划（5.5 节）；`@Observable` 赋值前把新旧两本整个比一遍；SwiftUI 页签收的是整张 Sheet、
       每次更新也比一遍。→ 计划接着用；`SheetSession.workbook` 改成记版本号；页签只收名字、署名、颜色。
    6. 状态栏合计：先攒成数组，再用 Decimal 一个一个加（一次一微秒上下）。→ 挨个走、不排序，`DecimalSum`（整数个
       10⁻¹⁸ 用 Int128 加；每个数最多 18 位小数、绝对值加起来不到 10²⁰ 时，按什么顺序加 Decimal 都是精确的，结果和 SUM
       一样；否则按 SUM 的顺序退回 Decimal 加）。2026-11-15 修：原来出不出界看的是不排序那一路的部分和，9×10¹⁹ 和 10⁻¹⁸
       混在一起时合计会随走的先后变（每次启动都可能不同），也和 SUM 不一样（Codex 审 PR #10 时指出，自检
       `selectionSumChecks` 对照 SUM）。
    7. 读 xlsx：每个格子的地址、数字都先建 Unicode 标量数组再拼字符串，每个数字还新建一个 Locale。→ 按字节检查，
       数照旧交给 `Decimal(string:locale:)`，Locale 只建一次。
  - 线索里排除的：`HeaderView` 一开始不是大头（不到一成，格子那边变快以后才显出来，第 1 条一起改了）；`SheetGeometry`
    查位置本来就是前缀和加二分，不是每次从头累加（贵的是每次重建画布都重排一遍，第 4 条）；`observeChanges` 没有多余的
    回调（一次变化每个订阅回调一次）。
  - **局部重画的规矩**（以后改画法要守）：局部重画和整块重画画出来必须一模一样。`RegionRenderer` 要画的格子比重画的范围
    往外多看 `spill`（填充、边框会画出格子边外，最多 1.5 + 1.5 × 缩放 点）；合并单元格的边框（画到它左上角那一格时才画）、
    AI 改过的淡紫色、往旁边溢出的长文字，都按「整块重画时看得见的行列」来定，不按这次重画的行列。整块重画时两边一样，
    截图和原来逐像素相同；滚动时系统只画新露出来的那一条，这一条现在也多半和整块重画一样了（原来起点在条外的合并单元格
    边框、边上格子画出界的那一点会缺）。行号列标同理：标签居中画在那一条上，极窄的列、极矮的行，标签比那一条宽（高），
    往两边伸出去，选区变了标脏要连伸出去的部分一起（`HeaderView.labelReach`），画的时候伸进重画范围的标签也要画上
    （2026-11-15，Codex 审 PR #10 时指出；verify 加了 0.1 个字符宽的列、1 磅高的行和连着六行的场景）。
  - **拿空框裁剪等于没裁**（2026-11-15）：`NSRectClip` 拿 null 的框（不相交的两个框求交、宽高扣成负的框）裁剪什么都不裁。
    原来自动换行的字有两处踩到：藏起来的行（高 0）扣掉边距成了 null 的框，字挤到裁剪框的一角成一团黑块（main 上就有，
    整块重画也有）；局部重画时在条外面的格子，下面几行字画进了条里。11-14 记的「自动换行的格子被可见区切开时滚出来的条
    有个别像素不同」就是这个。现在要画的字和这次重画的范围求交，空的就不画（`RegionRenderer`）。
  - **缓存的键按标量比**（2026-11-15，Codex 审 PR #10 时指出）：Swift 的 String 相等按「规范等价」算，é（U+00E9）和
    e + U+0301 是同一个键；可公式切词按标量（`Cafe\u{301}!A1` 读不出来，`Café!A1` 是引用），字体量字也按标量（Verdana、
    Georgia 这类字体里两种写法宽度不同，本机实测 616 种字体 / 字号 / 写法组合里 130 种差 0.01 点以上）。所以：公式解析
    缓存（所有窗口共用，原来会跨工作簿串）、量字和缩数字的缓存按 `ExactText`（UTF-8 字节）做键；显示文字的缓存取的时候
    按标量再比一次；重算计划判断「公式没变」改成看行的存储是不是同一份（`SparseGrid.rowsNotShared`）、原文按标量比——
    格子的 == 看不出只换了写法的公式（重新载入文件时就会这样）。表头标签只有字母和数字，不受影响；字体缓存（main 上就有）
    按字体名找字体，两种写法找到的是同一个，没改。自检 `exactTextChecks`，截图核对了量字那一处。
    2026-11-15 收尾时把整个 `Sources/` 的字符串键和含字符串的复合键再查一遍，补上先前漏掉的格式解析缓存
    （`FormatCodeCache`）：`"é"0` 的两种写法不能共用 literal，否则后一个的 0065 0301 0031 会变成 00E9 0031。
    同样先写失败自检再修了：共享字符串写回表（`SharedStringTable`，含原富文本编号复用）、OPC 部件名兜底索引、
    xlsx 替换和删除部件的集合、关系 ID 和内容类型的删除集合、插删行列保护里的「跳过的部件 / 已知 sheet」集合、
    SQL 列名去重（SQLite 区分两种写法，不能误加后缀后查不到原列）。这些共用 `ExactText`；原来要忽略大小写的地方
    仍先转小写再按字节比。ZIP 读索引和写入重名集合直接用标准库 UTF-8 字节数组做键，避免底层模块反过来依赖表格模型，
    没另写相等或哈希内核。文件自检只用内存里的合成包；`exactTextChecks`、`zipChecks` 覆盖保存读回、复制、删除和引用保护。
  - 怎么保证没改样子：改之前先用截图模式截了 58 张（`Fixtures/loan.xlsx` 的多个选区和缩放、合成的三张表、作者的样本
    5 张表），每改一步都重截、逐像素比，全部相同；verify 每一步整块重画的样子也和改之前的版本逐张比（最后一次 5,977 张，
    含改格子、滚动、换 sheet、缩放）全部相同。2026-11-15 的审查修正：截图 34 张（loan.xlsx 12 张、合成的三张表 21 张、
    循环引用的小例子 1 张；这次不碰作者的样本）改前改后逐像素比，33 张相同，不同的是循环引用那张（C1 从 7 变成 #CIRC!，
    预期的）；verify 全量（含新加的极窄列、极矮行）：loan.xlsx 962 次、公式表 560 次、10 万行的表 988 次都 0 处，样式表
    1879 次剩 1 处（第十五节「滚动以后可见区的原点不在整像素上」那一条）。
  - 实测（2026-11-14，M1，release，窗口 1280 × 800、2 倍像素；主线程 CPU 毫秒的中位数，「改前 → 改后」；loan.xlsx 只有
    一张表，没量换 sheet）。作者这台机器同时在跑别的，测速用 `nice -n 10`，改前改后的程序**紧挨着**量（同一张表先量改前、
    马上量改后）：负载一变数字就差一截，同一个改前的程序隔三个小时量，公式表改一格是 537 和 280 毫秒（多半是忙的时候被
    排到了效率核上，CPU 时间也跟着变长），分开量的两组数不能比。

    | 动作 | 10 万行纯数据 | 5 万个公式 | 合并 + 样式 | loan.xlsx |
    | --- | ---: | ---: | ---: | ---: |
    | 打开：读 xlsx | 15,606 → 10,367 | 390 → 287 | 893 → 725 | 37.6 → 28.3 |
    | 打开：整本重算 | 383 → 209 | 246 → 274 | 14.0 → 8.3 | 2.7 → 1.8 |
    | 打开：建窗口、画第一屏 | 170 → 88.0 | 64.7 → 60.8 | 339 → 169 | 85.0 → 65.8 |
    | 向下滚（每帧 3 行） | 8.5 → 2.4 | 2.6 → 1.8 | 50.1 → 3.4 | 9.2 → 1.4 |
    | 向上滚 | 8.4 → 1.7 | 3.8 → 2.5 | 49.7 → 2.5 | 9.2 → 2.0 |
    | 左右滚（每帧 1 列） | 20.6 → 2.2 | 7.2 → 1.8 | 239 → 3.3 | 8.6 → 2.2 |
    | 方向键 ↓ | 33.3 → 2.7 | 12.7 → 3.1 | 282 → 4.4 | 29.3 → 2.5 |
    | 方向键 → | 33.0 → 3.5 | 10.9 → 2.3 | 283 → 2.8 | 25.7 → 4.1 |
    | Shift + ↓ 拉选区 | 34.1 → 6.0 | 14.0 → 6.4 | 294 → 22.6 | 30.5 → 8.2 |
    | 拖选 | 35.1 → 7.1 | 15.1 → 6.8 | 288 → 16.6 | 32.0 → 11.6 |
    | 全选（含底栏合计） | 1,593 → 132 | 85.2 → 78.5 | 372 → 31.0 | 29.3 → 17.1 |
    | 全选后点一格 | 34.3 → 9.2 | 12.9 → 5.1 | 278 → 13.3 | 30.0 → 8.9 |
    | 改一格并提交（含重算） | 292 → 58.3 | 280 → 89.4 | 297 → 18.1 | 29.8 → 8.6 |
    | 拖列宽（每帧） | 51.8 → 10.0 | 12.7 → 4.3 | 279 → 15.6 | 26.9 → 7.4 |
    | 拖列宽松手（改工作簿、重算） | 268 → 10.6 | 282 → 78.1 | 290 → 15.3 | 30.1 → 9.0 |
    | 拖行高（每帧） | 51.1 → 9.8 | 12.6 → 4.4 | 287 → 15.2 | 27.0 → 7.7 |
    | 拖行高松手 | 265 → 10.1 | 280 → 78.3 | 301 → 15.5 | 30.8 → 8.8 |
    | 换到另一张表 | 6.1 → 4.5 | 5.9 → 4.3 | 6.5 → 4.8 | — |
    | 换回这张表 | 52.8 → 12.1 | 14.6 → 6.2 | 280 → 17.5 | — |
    | 缩放（每帧） | 51.9 → 11.9 | 14.0 → 6.8 | 266 → 20.1 | 25.1 → 8.7 |

    作者自己的样本（真实文件，只在本机量，不进仓库）：改前按一下方向键 16–29 毫秒，改后滚动、移动选区、改格子、拖边线、
    换 sheet、缩放的中位数都在 17 毫秒以内（全选最慢），打开约 0.1 秒；只有很稀疏的那张左右滚每帧慢了零点几毫秒
    （0.9 → 1.4），都在 2 毫秒以内。10 万行那张的内存峰值 1.16 GB → 0.66 GB。
  - 逐步（每个提交单独编译、一个接一个量；数据表用 2 万行的版本、帧数少一些，所以和上表对不齐；单个格子的起伏多半是
    负载抖动，比如 ③ 的「样式 ↓」，同一步的 p95 也跳了）：

    | 步骤 | loan ↓ | loan 缩放 | 样式 ↓ | 样式 左右滚 | 样式 换回 | 2 万行 拖列宽 | 2 万行 全选 | 2 万行 改一格 | 2 万行 换回 | 2 万行 读 xlsx | 公式表 改一格 |
    | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
    | 改之前（7c03b72） | 29.0 | 24.4 | 299 | 253 | 308 | 37.5 | 312 | 84.0 | 37.3 | 3,279 | 305 |
    | ① 画一帧：一行只取一次、合并单元格查表、不传闭包（原因 2） | 17.9 | 15.2 | 36.2 | 22.0 | 38.0 | 34.5 | 298 | 88.9 | 37.0 | 3,427 | 286 |
    | ② 画字：属性只建一次（原因 3） | 11.9 | 11.0 | 21.7 | 13.2 | 23.9 | 18.8 | 324 | 76.0 | 20.2 | 3,109 | 300 |
    | ③ 重建画布接着用上一份（原因 4） | 12.0 | 10.9 | 31.6 | 12.0 | 26.9 | 15.5 | 276 | 64.2 | 20.4 | 3,222 | 298 |
    | ④ 选区只重画经过的几行（原因 1） | 3.8 | 10.8 | 6.5 | 11.4 | 23.7 | 15.3 | 274 | 66.2 | 20.6 | 3,018 | 266 |
    | ⑤ 状态栏合计 DecimalSum（原因 6） | 3.6 | 11.0 | 5.9 | 11.7 | 24.1 | 15.4 | 91.6 | 62.7 | 20.4 | 3,031 | 296 |
    | ⑥ 重算计划接着用（原因 5） | 3.7 | 11.2 | 6.4 | 14.0 | 23.7 | 15.6 | 88.6 | 37.3 | 20.5 | 3,075 | 88.2 |
    | ⑦ @Observable 记版本号、页签只收几样（原因 5） | 4.1 | 11.0 | 6.4 | 11.7 | 23.7 | 15.5 | 88.8 | 40.1 | 20.5 | 3,099 | 93.2 |
    | ⑧ 读 xlsx 按字节（原因 7） | 4.7 | 10.7 | 6.3 | 11.7 | 23.7 | 15.6 | 90.0 | 38.3 | 20.4 | 2,036 | 84.9 |
    | ⑨ 显示文字、量字结果记下来（原因 3） | 4.6 | 10.1 | 4.9 | 3.8 | 24.2 | 10.8 | 84.1 | 31.5 | 20.3 | 2,019 | 87.2 |
    | ⑩ 改格子后只看改过的行（原因 4、5） | 3.3 | 9.2 | 4.7 | 3.7 | 24.1 | 10.9 | 82.9 | 20.4 | 20.3 | 2,083 | 117 |
    | ⑪ 行号列标局部重画（原因 1） | 2.2 | 8.6 | 3.7 | 3.5 | 23.6 | 9.7 | 83.2 | 21.1 | 19.1 | 2,094 | 125 |
    | ⑫ 合计不排序、跨模块展开（原因 6） | 3.3 | 9.5 | 3.8 | 3.7 | 23.6 | 10.1 | 41.5 | 20.0 | 19.6 | 2,057 | 130 |
    | ⑬ 修公式表上的退步（原因 5） | 2.7 | 9.1 | 5.6 | 3.5 | 23.0 | 10.1 | 40.5 | 18.8 | 18.5 | 2,006 | 88.0 |
    | ⑭ 换 sheet 留着画布（原因 4） | 2.9 | 8.6 | 3.6 | 3.5 | 18.1 | 10.1 | 40.8 | 17.7 | 11.9 | 1,985 | 87.9 |

    ⑦ 在这组数里看不出来（当时 sample 采到它占公式表改一格的两成上下，这里被抖动盖住了）；⑩ 让公式表改一格从 87 退到
    117 毫秒，⑬ 找到原因修回 88（提交说明里写了）。
  - 2026-11-15 审查修正（见变更记录）前后紧挨着量（3be6b5e → 改后，中位数）：公式表打开时整本
    重算 261 / 269 → 258 / 264、改一格 98 / 102 → 98 / 94（各量两次）；全选 10 万行 136 → 138；滚动不变；方向键每帧多了
    零点几毫秒（表头重画的条宽了，最多 loan.xlsx ↓ 2.9 → 3.3、公式表 → 1.8 → 2.4），都在 5 毫秒以内。
  - 还没到目标的（改后 p95 超过一帧 16 毫秒、或改格子超过 100 毫秒；括号里是 p95）：
    - 全选：10 万行 132（294）、5 万个公式 79（82）、合并 + 样式 31（44）、loan.xlsx 17（18）：底栏合计要把选中的格子
      走一遍，200 万格就要这么久；38 位有效数字的数（公式算出来的）在定点整数的范围外，退回 Decimal 逐个加，更慢。
    - 合并 + 样式那张：Shift + ↓ 23（23）、拖选 17（23）、缩放 20（32）、换回这张表 18（18）、拖列宽行高 15–16（16–17）：
      一屏都是合并单元格和边框，选区一拉长就是大半屏重画，每格四笔边框；缩放时字号变了，量字、排字的缓存都得重新建。
    - 10 万行那张：方向键 → 的 p95 20（走到右边、表格跟着横着滚的那几帧）。
    - 5 万个公式的表：改一格 89（96），松手改列宽、行高 78：改工作簿都走整本重算（第 16 条），剩下的是 Decimal 求值本身。
      打开时的第一次整本重算反而慢了一点（246 → 274）：多了解析缓存、按列排顺序、记下给下一次编辑用的状态。
    - 打开 10 万行：读 xlsx 约 10 秒。
  - 没做的大改（建议，由作者定）：读 xlsx 换掉 Foundation 的 XMLParser、自己按字节切 `sheetData`（10 万行的表现在读文件
    约 10 秒，大头在 XMLParser 本身和它把属性桥接成 Swift 字典）；给 Decimal 的加减乘除加 Int128 快速路径（5 万个公式的表
    改一格约 0.1 秒，剩下的是 Decimal 求值）；全选几百万格时状态栏合计放到后台算（会让底栏的数晚一拍出来，是行为变化）；
    只改宽高、格式的编辑不重算（TODAY() 现在是每天第一次重算时更新，跳过以后更新的时机会变，是行为变化）；边框按颜色、
    粗细攒成一条路径一次画（少很多次 NSBezierPath，但抗锯齿的像素会变，要作者看过再定）。

### 8.3 AI 在界面上

- 「这一轮」：和 SrtFlow 一样按时间划分。AI 开始改就开一轮、存一份工作簿快照，30 秒没有新调用算这一轮结束。
- 横幅：「Claude 改了 N 处 · 撤销这一轮」，名字是这一轮的 AI（9.3 节）。撤销这一轮 = 换回快照（一步，可以再 ⌘Z 回来）。
- 这一轮 AI 改过的格子淡色高亮，下一轮开始时消失；高亮不存进文件。
- AI 打开文件、写入时不抢前台：窗口在后面也照样更新。
- 关掉最后一个窗口不退出 App（AI 下一次调用还要用）。

### 8.4 行、列和格式的编辑（2026-10-14 加，第 16 条）

- 整行整列：点列标（行号）选整列（整行），Shift 点、拖着选好几列；选区记着是哪一种（`Selection.kind`），活动格放在看得见的
  那一行，表格不跳。复制、改格式只到用到的地方为止（整列有一百多万格）。
- 宽高：拖列标行号之间的边线，旁边一个小牌子写着宽度（「Width: 12.50 (92 px)」，和 Excel 一样）；拖的时候只改画出来的样子
  （`SheetSession.resizePreview`），松手才改工作簿，一步撤销。选着好几整列、拖的是其中一列时一起改；拖到 0 就藏起来。
  双击边线按内容自动定宽（定高）；Format 菜单里也能输数值、自动适应。拖到的像素换成 Excel 的单位时往上取到 1/256 个字符
  （行高按 0.75 磅），再换回像素正好是拖到的那么宽。
- 自动适应的规矩（`AutoFit`）：列宽按这一列最宽的显示文字（一格里有换行的按最长的那一行），最宽 255 个字符；行高按
  「几行字 × 这个字号一行的高度」，自动换行的格子按列宽折行，默认字号的一行字正好是默认行高；合并单元格不算（Excel 也不算）；
  整列没有内容回到默认大小。量字用真正画的字体（App 层的 `ContentFit`）。
- 隐藏：Format 菜单和右键菜单里藏、取消藏（和 Excel 一样，取消隐藏要选上两边的列）；藏起来的地方在列标行号上画一道深色的线；
  方向键跳过藏着的行列。
- 冻结：View 菜单里冻结首行、首列、冻结到选区（选整行冻结它上面的行，选一格冻结它上面的行和左边的列）、取消冻结。
- 格式：Format 菜单（⌘B、⌘I、数字格式预设、字色底色的色板、对齐、自动换行、合并 / 拆开）。开关类的看活动格现在是什么样。
  合并时左上角以外有内容先问（和 Excel 一样只留左上角），整块换成左上角那一格的样式；编辑格子时格式菜单不能用（第一版没有
  一格里几种字体）。
- 插删行列：Insert 菜单、Edit 菜单、右键菜单；选了几行插几行，标题按选区写（「Insert 3 Rows Above」「Delete Rows 3–5」）。
  新行照抄上面那一行的样式和行高（Excel 的「格式同上」），新列照抄左边那一列。格子、行高列宽、合并单元格、冻结窗格
  （在冻结的行里插，冻结的行数跟着变多）、数组公式的范围、富文本的记录，以及整本里指向这张表的公式和定义的名称都跟着挪；
  指向删掉的格子的变成 #REF!（带 sheet 名的写成 `Loan!#REF!`），和 Excel 一样。挪法只有一份（`LineShift`）。
  不能插删的情况：读不懂的公式（切不了词）提到了这张表、只插删数组公式的一部分、会把有内容的格子挤出表外——整个不做，
  工作簿不动，说清楚为什么。
- **安全的表（`StructureLock`）**：sheet 里只有我们管的元素和与位置无关的元素（页边距、页面设置、页眉页脚、背景图……），
  关系只有打印机设置这类，而且文件别处（图表、数据透视表、别的表的条件格式和数据验证……）没有按名字指着它。图片、批注、
  条件格式、数据验证、超链接、筛选、Excel 表格、分页符、别的读不懂的元素都算不安全：插删以后它们还指着原来的位置，
  在 Excel、腾讯文档里就对不上了。这次新建、复制、导入的表整份由我们写（复制出来的表不带这些东西），总是安全的。
  不安全的表上插删时弹框说为什么，建议复制一份改副本；AI 那边同样拒绝、给同样的建议。判断要解压扫一遍包，按文档缓存，
  存过以后重新判断。Fixtures 的 Loan 带一张图片，就不能插删（复制出来的那张能）。

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

### 9.2 工具清单（第一版 14 个，2026-10-14 起 15 个）

| 工具 | 只读 | 做什么 |
| --- | --- | --- |
| `get_status` | ✓ | 打开着的工作簿；每张 sheet 是原始的还是 AI 的，AI 的是谁写的；有没有没保存的改动；用户当前选中的区域（「分析我选中的这块」）。还有这个 SkySheet 的版本和打包时间（2026-10-14 加：模型看不到握手里的 serverInfo，用户问「什么版本、什么时候的」当场答，不上网找） |
| `open_file` | | 打开一个 xlsx / csv。只开用户给的路径或工具返回的路径 |
| `describe_sheet` | ✓ | 一张表的结构：用到的范围；认出的表格块（标题行、每列的名字、类型、格式、非空个数、样例值、数字列的合计和最值）；公式个数；「未重算」的格子 |
| `read_range` | ✓ | 读一块区域：值（全精度），可选显示文字和公式原文。一次最多 2,000 格，更多的用 `query` 或 `export_sheet` |
| `query` | ✓ | 对表格块跑一条 SQL（SQLite，只许 SELECT）。表名、列名用 `describe_sheet` 给的，也可以临时指定区域；最多回 500 行。SQL 里的数字是 Double，看汇总够用，要分毫不差的金额用公式 |
| `evaluate` | ✓ | 用 SkySheet 的公式引擎算一个公式，不写进表（「贷 100 万、30 年、3.1%，月供多少」） |
| `export_sheet` | ✓ | 把一张表或一块区域导出成 csv（写到 App 自己的缓存目录），回文件路径，给 Python 用 |
| `show` | ✓ | 在窗口里切到某张表、选中某块区域，让用户看到。只动界面、不动数据，不抢前台 |
| `add_sheet` | | 新建 AI 的 sheet：空白的、复制一张原始 sheet（`copy_from`，即第 12 条的「复制成新 tab 再改」），或者从 csv 导入（`from_csv`，接 Python 的结果）。`model` 填 AI 自己的模型名，用于署名（9.3 节） |
| `write_cells` | | 往 AI 的 sheet 写值和公式，`=` 开头的是公式；可以把一行公式往下填充到某一行（引用跟着平移，和 Excel 的下拉一样）。回写入的范围、公式算出的值、出错的格子 |
| `format_cells` | | 数字格式（预设名或格式代码）、粗体、斜体、字色底色、对齐、换行、合并 / 拆开。只限 AI 的 sheet |
| `edit_rows_columns` | | 整行整列（2026-10-14 加）：插删（只在安全的表上，8.4 节）、列宽行高、按内容自动适应、隐藏、冻结。只限 AI 的 sheet |
| `edit_sheet` | | AI 的 sheet 改名、删除、挪位置 |
| `undo` | | 撤销上一步；`round=true` 撤销这一轮 |
| `save_copy` | | 把整本另存成一个**新**文件，目标已存在就拒绝。AI 没有覆盖原文件的工具 |

### 9.3 AI 的 sheet：怎么认、谁写的、怎么保证改不到原始数据

1. 写入类工具（`write_cells`、`format_cells`、`edit_rows_columns`、`edit_sheet`）只认 AI 的 sheet。对原始 sheet 一律拒绝，错误里直接说
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

9.3 节 M4 落地时的细节（2026-10-09）：
- AI 的 sheet 页签颜色是 `FFAF52DE`（系统紫）；custom.xml 里的署名是紧凑 JSON（c / m / t 建的人、模型、时间，
  l / lm / lt 最后改的，cu / lu 为 1 表示用户自己），名字太长截短，保证不超过 255 个字符。
- 用户标成「AI 可改」的 sheet 署名是用户自己（页签小标写 You）；不改它的页签颜色。
- 「最后是谁改的」只算直接改到这张 sheet：用户改了原始数据、AI 的 sheet 跟着重算变了值，不算用户改的。

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
- Python is fine for heavy analysis if you can run it on this Mac: export_sheet gives a local CSV path;
  bring results back with add_sheet from_csv or write_cells. Never open, change or save the user's
  .xlsx/.csv files with other programs.
- Only open files the user named or these tools returned.
- Nothing reaches the user's file until they press Cmd+S. save_copy only writes a new file.
- A round of edits can be undone in one step (undo round=true).

Tools by need:
- Workbooks: get_status, open_file, save_copy
- Read: describe_sheet, read_range, query, evaluate, export_sheet
- Write (AI sheets only): add_sheet, write_cells, format_cells, edit_rows_columns, edit_sheet, undo
- Point the user: show
```

### 9.5 连接 Claude Code 和 Claude 桌面版

设置页「AI」一节，两家各一行，一行一个按钮（第 17 条）。

- 「连接 Claude Code」：
  - 跑 `claude mcp add --scope user skysheet <App 包里 skysheet-mcp 的路径>`。不直接改 `~/.claude.json`：
    正在跑的 Claude Code 会整份重写它，直接改会被冲掉。
  - 往 `~/.claude/settings.json` 的 `permissions.allow` 里加 `mcp__skysheet`（第一次改之前先备份），免得每个工具都问一次。
    **按原文只插进这一条**（断开时只删这一条），别的字节一个不动：这是用户自己的文件，可能手排过、可能进了 git。
    v0.3.0 整份解析再写回，键被排序、冒号两边的空格和末尾换行全变了（内容没变），v0.3.1 改掉。
    文件是软链接（dotfiles）就写进它指向的文件，链接留着。
  - 找不到 `claude` 命令行，就给「复制一段话」，让用户贴给 Claude Code 自己装。
  - 状态有五种：没装 / 没连接 / 已连接 / 连着但每个工具都问（没放行）/ 连着另一份 SkySheet（App 挪过位置）。
- 「连接 Claude 桌面版」（2026-10-09 加，第 17 条）：管的是桌面版的**普通聊天**；它的 Code 页跑的是 Claude Code，
  用上面那一行的连接。
  - 往 `~/Library/Application Support/Claude/claude_desktop_config.json` 的 `mcpServers` 里加
    `"skysheet": {"command": <App 包里 skysheet-mcp 的路径>, "args": []}`。官方就是让用户改这个文件，没有命令行。
    和 settings.json 一样**按原文只动这一项**（断开只删这一项，mcpServers 空了留着 `{}`）、文件格式不对就报错不写、
    第一次改之前备份（复制一份，权限跟着原文件：它是 0600，里面有账号的东西）。连着另一份 SkySheet 时只换 command。
  - **桌面版开着的时候，改了会被它盖掉**（2026-10-09 读 Claude 2.31226.0 的代码和日志确认）：它启动时把整个文件读进
    内存，之后每次存自己的偏好（开 Code 会话、切窗格……作者的机器上一天十几次）都把内存里那份整份写回，不先重读；
    退出时不写（日志里 63 次退出，一次都没写）；mcpServers 也只在启动时读。所以点「连接」时它没开就直接改，打开就有；它开着就先改、记下要的结果，
    提示用户退出再打开 Claude，**在它退出那一刻再写一遍**（那时没人盖了；断开也一样）。这一步要 SkySheet 开着：
    SkySheet 先退出、它又刚好盖过，设置里会显示没连上，再点一次就好。没选「替用户退出 Claude」：会打断它正在跑的
    Code 会话，让用户自己挑时候。
  - 放行：桌面版的「总是允许」存在它自己那里，SkySheet 写不了；连上后的提示里告诉用户在对话里点、或者在它的
    Connectors 设置里一次设好。
  - 状态：没装 / 没连接 / 已连接 / 连着另一份 SkySheet / 重启 Claude 才算完（这次运行里改了、它还没退出过）。
- 两家共用的：读 `mcpServers.skysheet.command`、改文件的规矩（`AIClientConfig`）；按原文改 JSON（`JSONText`）。

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

### 9.7 M4 落地时定下、实测出来的（2026-10-09）

- 工作簿怎么指：每个工具收一个可选的 `workbook`（文件名或路径）。不给就用「当前的」：AI 上次打开或用过的那个，
  其次是最前面的窗口，只开着一个就是它。sheet 用名字（不分大小写）；区域可以带 sheet 名（`Loan!A1:K11`）。
- 表格块：一段连续有内容的行算一块；顶上单独一格文字是标题。分组版式（少列或横向合并）只能提供候选；
  第二行必须全为无公式的文字才能认作第二行表头，出现数字、公式或其他类型就保留为数据，防止首条记录被吞掉。
  末行只有强证据才排除：同列同表 SUM / SUBTOTAL(9 或 109) 的范围从表头或首条数据开始，连续且不重叠、正好到上一行；
  分词失败的 SUBTOTAL 也必须核对范围，不能只凭编号。结构化引用缺少区域元数据，不能据此确认。
  另一种证据是末行标签去掉全部空白和冒号后，恰好等于「合计 / 总计 / 小计 / 汇总 / 共计 / Total / Subtotal /
  Grand Total / Sum」，并且数字列的值按该格显示精度等于上面至少两条数据行的和。结构化公式缓存也可用这条核对。
  只有名字像合计，或公式不完整、跨表、范围不明时保留数据；describe_sheet 用英文不确定提示标出行号与保留状态。
  常量与横向逐行 SUM 留作数据。只有一格的零碎内容另外列出。
- SQL：每张表多一列 `_row`（记录在 sheet 里是第几行）；日期是 'YYYY-MM-DD' 的文字；数字是浮点数；最多跑 3 秒、回 500 行。
- 给 AI 的数字按正确舍入的 Double 给：`NSDecimalNumber.doubleValue` 不正确舍入，8673.94 会变成 8673.939999999999
  （端到端时看到的），`DecimalMath.double` 改成按十进制文字解析，函数里的计算也跟着更准一点。
- write_cells 的值：数字按最短的十进制写法收（0.1 就是 0.1），文字按打字的规矩，null 清掉；一次最多 1 万格，
  fill_down_to 和 Excel 的下拉填充一样平移引用。结果里回公式算出来的值和出错的格子（算不了的写明原因）。
- AI 的 undo：只撤 AI 自己连着的那几步；用户在 AI 之后改过就拒绝。undo round=true 撤的是「这一轮」（30 秒没调用算结束，
  下一个改动开新的一轮）。
- export_sheet 写到 `~/Library/Caches/ai.skylu.skysheet/exports/`，数字写原值（百分比写小数），日期写 ISO。
- 和真的 Claude Code 端到端（`claude -p`，只挂 SkySheet）：它会先用 ToolSearch 加载要用的工具，再按总说明的顺序走；
  碰到 ROW、RANK 不支持就换写法（v0.3.0 补上了 ROW、COLUMN、ROWS、COLUMNS、RANK、RANK.EQ）。用 COUNTIF(">"&H2)
  排名会差一位：数变成文字只留 15 位有效数字，自己比自己的近似值大（Excel 也这样），RANK 按精确值比就没这个问题。
- 被 AI 在后台拉起来时：不弹「打开」面板；恢复副本的提示等用户切过来再问，只问启动时就在的；没记住窗口位置时摆在主屏幕正中。
- 2026-10-14 加 `edit_rows_columns`：rows（"3"、"3:5"）或 columns（"C"、"B:D"）加上要做的事。insert=true 是「这几行变成新的空行，
  原来的往下挪」，和 Excel 选几行再插入一样，几行就插几行；delete=true 删掉。插删不能和别的选项一起给；freeze 必须从第 1 行
  （A 列）开始。结果里回改了几个公式、哪些变成了 #REF!。列宽、冻结从 format_cells 挪了过来：说明里不再写，但还开着的老会话
  照旧的说明在 format_cells 里给 column_width、freeze，照做。
- 整列整行的区域（C:E、3:5）：read_range、export_sheet 只读到有内容的地方为止（腾讯文档给一大片空格子刷样式，loan.xlsx
  刷到 AG212，按刷过样式的算就是一堆 null）；format_cells 改到刷过样式的地方为止，和界面一样。get_status、show 的选区也这么写。
- SwiftUI 的 NSHostingView 默认把内容的最大宽度变成约束：空横幅的最大宽度是 0，整个窗口被拉成 130 点宽、还被记成了
  窗口位置。横幅只让内容决定高度（`sizingOptions = [.intrinsicContentSize]`），记住的大小比最小尺寸还小就不用。

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
  显式指定；打包时间（UTC）写进 Info.plist 的 `SkySheetBuildDate`，get_status 报给 AI。产物是 `dist/SkySheet.app` 和
  `dist/SkySheet-<版本>-arm64.dmg`，DMG 里带「首次打开必读」。
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
  8. **大表格不卡**（`LargeSheetChecks`，2026-11-14）：快的写法和原来的写法逐条对照（地址、数字解析、`DecimalSum`、状态栏
     合计、一行取一段、合并单元格查找表、接着用的几何、只看改过的行求用到的范围）；数得出来的量（画一屏只看这一屏附近的
     合并单元格、只改值的编辑不重排重算计划、编辑以后只看改过的行找公式、拖列宽时行的排布接着用）。用时间判断的只有两处，
     上限放得很宽，只防退化成整张表反复走。
  9. **审查修正**（2026-11-15，PR #10 的 Codex 审查，每条先写成失败的自检再修）：循环引用标哪些格子（`circularChecks`，
     400 个随机小图对照「从自己能走回自己」的穷举）；缓存的键按 Unicode 标量（`exactTextChecks`）；状态栏合计和 SUM 每一位
     都一样（`selectionSumChecks`，Codex 的例子放在 64 个位置上，加 300 个随机的表）；开发工具不覆盖已有的文件
     （`developerToolChecks`）。
- 显示效果靠截图模式核对（8.2 节），M2 起每次改表格画法都截一张看。表格视图的局部重画自检够不着（在 App 里），改画法时
  本机跑测速模式的 verify（8.2 节「性能」）；它要建 AppKit 窗口、跑几分钟，没放进 CI。
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
| M5 打磨 | 按实际使用补函数和格式、性能、把长期约束整理进 `docs/architecture/`；更多编辑（行列、格式，2026-10-14，8.4 节）；2026-11-16 起加上正在修的几批 bug，顺带把 IronCalc 的 calc_tests 和 numfmt 的数字格式用例搬进来当测试数据（第 7 条） | 作者日常用一周没卡壳 | v0.4.0 |
| M6 改名（计划） | 改名 SkyFolio：仓库里的名字、bundle id、MCP 服务名；App 第一次启动时迁移备份、恢复副本和两家 AI 客户端配置里的旧条目；仓库改名（新方案第七节） | 作者这台机器从 SkySheet 升上来：备份、恢复副本都在，两家 AI 各点一次就连上 `skyfolio`，配置里别的字节一个不动 | v0.5.0 |
| M7 Markdown 只读（计划） | md4c 搬进 `ThirdParty/`；共用的文档模型和预览窗口；读文档的 AI 工具；AI 读过的段落画淡紫竖线（新方案第四、五节） | md 显示对，喂畸形输入不崩；AI 按章节读、引用块编号，界面点得过去；总说明 ≤ 2,048 个字符 | v0.6.0 |
| M8 Word 只读（计划） | Quick Look 显示；自己写的 `DocxReader` 给 AI 读（新方案第三节） | 各软件导出的 docx 样例（内容是编的）显示对，读出的文字、表格、脚注、批注、修订和预期相同；docx 一个字节都不写 | v0.7.0 |
| M9 Markdown 编辑（计划） | 原文编辑器和着色；用户和 AI 都能改（AI 的改动标淡紫、能撤销）；保存走六道保险（新方案 4.3–4.5 节） | 各种编码、换行方式的文件不改直接存，逐字节相同；AI 改的看得见、撤得掉、不按 ⌘S 不落盘 | v0.8.0 |
| M10 给别人用（计划） | 第一次打开的引导和 README、隐私说明、发版清单、第三方许可（新方案第八节） | 新建一个 macOS 用户，用浏览器从 GitHub Releases 下载，照 README 走到问出一个问题，不用作者帮 | v0.9.0 |

M6–M10 的顺序是作者 2026-11-16 定的：改名要动约 120 个文件，等修 bug 的分支都合进 main 再做；名字要在别人装之前定；Markdown 比 Word 简单，
先用它把共用的部分（文档模型、预览窗口、AI 工具）做出来；给别人用放在最后。以后（没排期）：Word 换成 docx-preview 显示（AI 读到哪段就高亮哪段，
新方案 3.3 节）、PPT、公证、中文界面（第 22 条）。各里程碑的规模估算和依据见新方案第十节。

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
- 公式里还不能对区域做数组运算（`SUMPRODUCT(--(A1:A5>B1))`、`(A1:A5>B1)*1`）：AI 碰到会换成 COUNTIF / RANK 这类写法。
- AI 的模型名是自报的；同一个客户端后面的调用沿用它报过的那个，换了模型没报就还是旧的。
- 插删行列只在安全的表上（8.4 节）：有图片、批注、条件格式、数据验证、超链接、筛选、Excel 表格、分页符，或者被图表、
  数据透视表、别的表的条件格式指着的表不行，复制一份改副本。三维引用（`Sheet1:Sheet3!A1`）插删时不跟着改。
- 整列整行的格式只改用到的格子，不记成列（行）的样式：以后在下面新输入的格子不带这个格式（Excel 会带）。
- 改格式时新样式只带我们认识的几项（数字格式、字体、填充、边框、水平垂直对齐、换行），原样式里的缩进、旋转这类对齐属性
  不带（2026-10-14 查过，腾讯文档的文件里没有这些）。
- 自动适应按我们的字体量，和在 Excel 里双击边线的结果可能差一点。
- csv 存不下格式：新改了格式的 csv 存的时候先问要不要另存成 xlsx（7.3 节的弹框，2026-10-14 加了这种情况）。
- 大表格（2026-11-14 实测，8.2 节「性能」）：读 xlsx 慢，10 万行 × 20 列约 10 秒（Foundation 的 XMLParser 本身和它把属性
  桥接成 Swift 字典，要再快得自己切 sheetData）；5 万个公式的表改一格约 0.1 秒（Decimal 求值）；全选几百万格时状态栏合计
  要一百多毫秒（200 万格约 0.13 秒），选区里有公式算出来的 38 位有效数字的数时走 Decimal 一个一个加，更慢；
  10 万行的表在内存里约 0.7 GB。
- 滚动以后可见区的原点不在整像素上（缩放成 137% 这种）、正好挪了整数个像素时，系统挪过去的旧内容和整块重画在字的
  抗锯齿上可能差几个像素：浮点误差刚好落在字的位置取舍的边上（2026-11-15 verify 在合并单元格的表上碰到一处，让 verify
  在这种原点上整块重画就没有了）。屏幕上也是挪旧内容，看不出来；要根治得把滚动位置对齐到像素。
  2026-11-15 作者装 0.3.4 真机试过，没发现问题，所以不改滚动的行为。这项定了不做，仍保留为 verify 的已知限制。
- Claude 桌面版：「总是允许」只能用户自己在它的界面里设；它开着时点的连接 / 断开，要等它退出、而且 SkySheet 那时还开着
  才算数（9.5 节）；它的聊天一般没法在这台 Mac 上跑 Python，用不上 export_sheet 写在本机的 csv（总说明里写了「能在这台
  Mac 上跑才用」）。

## 变更记录

- 2026-10-08 起草。
- 2026-10-08 作者确认：界面先只做英文（第 22 条）；第一版不做插删行列（第 11 条）；AI 的 sheet 记在文件里、页签紫色
  （9.3 节）。新增 AI 署名（第 23 条），起因是作者说以后会让用户接别的 AI。
- 2026-10-08 作者确认：图片不显示、只原样保留（第 11 条）；AI 的名字不写进 sheet 名（第 23 条）。定稿。
- 2026-10-08 M1 完成：zip、读 xlsx、公式引擎（62 个函数）、数字格式、自检程序和 CI。实测结果写进 5.5、5.6、7.1 节。
- 2026-10-08 M2 完成：查看器 v0.1.0（表格、冻结窗格、公式栏、页签、选区合计、打开 xlsx 和 csv、签名证书、打包）。加了 SkySheetDisplay 模块；实测写进 7.3、8.2 节和第 22 条。
- 2026-10-08 M3 完成：编辑与保存 v0.2.0（格内编辑和公式栏、撤销、复制粘贴、sheet 改名复制删除、写 xlsx 和 csv、六道保险）。
  第十节第 5 条定为自己写恢复副本；第 6 条的检查要放在 NSDocument 自己的前面。实测写进 7.2、7.3、8.2、第十、十五节。
- 2026-10-09 M4 完成：MCP v0.3.0（skysheet-mcp 小程序、14 个工具、这一轮和撤销、AI 的 sheet 的标记和署名、连接 Claude Code）。
  用 JSON-RPC 走完 14 个工具，又用 `claude -p` 和真的 Claude Code 问了一遍典型问题。实测写进 9.3、9.7、十五节；
  长期约束写进 `docs/architecture/mcp.md`。
- 2026-10-09 v0.3.1：作者装到本机点「Connect」时发现 settings.json 被整份重排（键按字母排、冒号两边加空格、末尾换行没了）。
  改成按原文插进或删掉那一条（9.5 节），软链接也留着。
- 2026-10-09 作者要求 Claude 桌面版的普通聊天（不是它的 Code 页）也能用 SkySheet：第 17 条改成两家；设置里多一行
  「Claude Desktop」，按原文改它的 claude_desktop_config.json。它开着时会拿内存里的那份把文件盖掉，所以在它退出那一刻
  再写一遍（9.5 节）。顺带：总说明和 export_sheet 的说明点明 Python 要能在这台 Mac 上跑（桌面版的聊天不行）；
  「请重启 Claude Code」的两句改成按客户端说；备份配置文件改成连权限一起复制。
- 2026-10-14 作者在桌面版的聊天里问「SkySheet 是什么版本」「是什么时候的」，AI 答不上来、跑去网上搜：模型看不到 MCP
  握手里的 serverInfo。get_status 改成带上 `skysheet: {version, built}`（版本和打包时间，build-app.sh 写进 Info.plist），
  说明里写明这类问题从这里答（9.2 节、第十一节）。
- 2026-10-14 作者要「更多的编辑功能，比如拉伸整列整行的间距」，新功能都要支持 MCP；给出的几组（列宽行高、隐藏行列 + 冻结窗格、
  单元格格式、插删行列）全选了。第 11 条改成插删行列只在安全的表上做，第 16 条加上这些编辑；新加 8.4 节；MCP 加
  `edit_rows_columns`（15 个工具），format_cells 加斜体、对齐、换行、合并，列宽和冻结挪到 edit_rows_columns（9.7 节）。
  富文本的格子改记在 sheet 上（7.2 节）；csv 新改了格式时存之前先问（7.3 节）。实测写进第十五节。
- 2026-11-15 PR #10 的审查修正（Codex 只读代码找出五处，逐条先复现再修，各一个提交）：测速、截图、verify 只写新文件；
  循环引用按强连通分量标，环上每个公式都标（5.5 节，某些表上的值会从算出来的数变成 #CIRC!）；缓存的键按 Unicode 标量比；
  状态栏合计和 SUM 每一位都一样、和走的先后无关；行号列标的标签比那一条宽时局部重画连伸出去的部分；拿空框裁剪等于没裁，
  自动换行的字和重画范围求交是空的就不画（11-14 记的「滚出来的条个别像素不同」就是它）。
- 2026-11-14 M5 性能：作者说打开的表格数据多了会卡。先做了测速模式（六类动作逐帧量主线程 CPU 时间）和局部重画的逐像素
  核对（verify），再按 sample 采出来的占比一处一处改：选区变了只重画经过的几行和那几条行号列标、画格子时一行只取一次和
  合并单元格查表、热循环不传主线程闭包、画字的属性和显示文字缓存、重建画布和换 sheet 接着用上一份、重算计划接着用、
  `@Observable` 不再整本比较、状态栏合计用定点整数精确地加、读 xlsx 按字节解析地址和数字（8.2 节「性能」、5.5 节）。
  截图模式、测速模式的窗口从此不放上屏幕。画出来的样子不变：截图 58 张、verify 整块重画 5,977 张逐像素和改之前相同。
  自检加了「大表格不卡」（第十二节第 8 条），真机清单 `docs/testing/m5-performance.md`。没做的大改写进 8.2 节「性能」
  和第十五节。
- 2026-11-15 收尾：先复现再把 `FormatCodeCache` 改成共用 `ExactText`；全 `Sources/` 排查还修了共享字符串写回、
  ZIP 名称索引和重名集合、OPC 兜底索引、xlsx 部件替换和删除、关系 ID 和内容类型删除、插删行列引用保护、SQL 列名去重
  的规范等价串键（8.2 节「缓存的键按标量比」）。新增自检分批在改前失败，改后统一检查 9480 条全过。
  `.gitignore` 只补忽略 Claude Code 子会话的临时 worktree 目录。作者装 0.3.4 真机试过，没发现问题：滚动对齐像素定了不做，
  仍记为 verify 的已知限制（第十五节）；真机清单只补这句反馈，不逐项勾选，M5 仍未整个完成。
- 2026-11-15 作者考虑过支持 Intel 芯片和 Windows，不做，第 3 条不变。
- 2026-11-15 作者定：同一个 App 还开 Word（只读）和 Markdown；以后给别人用，先不公证，更新靠用户自己去 GitHub Releases 下载。
- 2026-11-15 公式、数字与格式排查：16 个问题先复现再修，覆盖现金流错误传播和取参、条件统计区域与空白条件、RANK
  顺序、文字边界、合计行、分数格式、秒小数精度、查找形状、空白输入、日期大数和累计财务。相邻的 DATE / EDATE /
  EOMONTH 溢出、输入与 CSV 秒数也纳入自检；后续复审纠正文字语义、补全合计识别与格式性能，见末尾 11-16 条目。
- 2026-11-16 作者定：改名 SkyFolio（已知有同名的 Mac app 和安卓 app，仍选它，全名「SkyFolio by Skylu」）；第 7 条放宽为「可以把许可证兼容的
  开源代码复制进 `ThirdParty/` 自己维护」，加了细则；Markdown 用户和 AI 都能改；里程碑 M6–M10 的顺序；中文界面先不排（第 22 条不变）。
  改了第一节、第 1、5、7、11、12、14 条和第十三节，没做的都写成计划；做法、理由、实测和调研在新方案
  `docs/plans/2026-11-15-skyfolio-word-markdown.md`。
- 2026-11-16 公式、数字与格式排查及 PR #12 复审修正：保留上一轮 16 个边界修复；补齐 Excel / WPS 合计标签、
  多行表头和结构化 SUBTOTAL，疑似末行通过英文说明披露；文字统一 Unicode 标量；分数改成连分数并补固定分母；
  条件统计改有序稀疏数组、修正非空条件和 SUMIF 越界；CSV 空白字段不崩溃，日期输入与 CSV 共用解析。
  自检按职责拆分，仅崩溃 / 超时输入隔离，删除未被 App 调用的 DOSDateTime(Date) 自检；CSV 原空白字段的崩溃处理已改。
  过程探针、测速、变异和检查日志只留临时目录，要点随 PR 记录；真机项目留在 M5 清单。
- 2026-11-16 PR #12 第二轮返工：合计改为完整范围或精确标签与显示精度下的数字和双重核对，保留普通名称；
  第二行表头遇数字或公式一律保留为数据。分数缩放溢出安全拒绝，混合占位符按右端填数字；累计财务采用贴现等比式，
  避免高增长区间的消减失真。`scripts/check-table-layouts.py` 用相同生成输入分别链接 main 和当前内核，逐例检查 SQL、
  describe 的列名、数据范围、统计和提示；有差异必须有意图说明，且通过已知数据的独立断言。产物只在临时目录。
