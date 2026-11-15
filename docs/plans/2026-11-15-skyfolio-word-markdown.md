# SkyFolio（原 SkySheet）方案：Word 和 Markdown、改名、给别人用

> 2026-11-15 起草，**2026-11-16 作者全部拍板**。决定已经写进设计文档（`docs/plans/2026-10-08-skysheet-design.md`，下称「设计」）
> 和 CLAUDE.md（第十一节）；这份方案留着做法、理由和实测。还没做的都是计划，按第十节的里程碑一步步做。
> 实验都在仓库外的临时目录里做，用的是自己造的文件，没碰作者的任何文件，做完删了（第十三节）。网上查的东西都写了出处（文末）。
> 下文用 SkyFolio 指这个 App；还没改名的现状照旧叫 SkySheet。

## 决定一览

全部已定。拍板日期：11-15 = 2026-11-15，11-16 = 2026-11-16。

| # | 问题 | 决定 | 没选的 | 理由 | 拍板 |
| --- | --- | --- | --- | --- | --- |
| 1 | 范围 | 只做一个 App，每种文件有自己的界面。Word（.docx，顺手认 .dotx、.docm）只读、AI 能读；Markdown（.md）用户和 AI 都能改。PPT 只留位置；.doc、.rtf、.odt 不做 | 分成几个 App；加上 .doc 等老格式 | 作者要一个 App 开各种文件，不像 Office 分成好几个。.doc 是另一种二进制格式，要再写一个解析器 | 11-15、11-16 |
| 2 | Word 怎么显示 | 先用系统的 `QLPreviewView`（Quick Look）。要做「AI 读到哪段就高亮哪段」时，再把 docx-preview（Apache-2.0）搬进 WKWebView，用 SkyZip 替掉它依赖的 JSZip，WebView 锁死（3.3 节） | AppKit 的 NSAttributedString；一开始就自己解析、自己生成 HTML；自己排版（分页） | Quick Look 零代码，实测样式、编号、合并单元格、图片都对；NSAttributedString 实测不认样式、丢图片和合并单元格；自己写渲染要几千行，docx-preview 现成 | 11-16 |
| 3 | Word 给 AI 读 | 自己写 Swift 的 `DocxReader`，照 mammoth.js（BSD-2）的读法；输出带块编号的 Markdown，表格能按格子取；docx 永远只读 | 搬一个现成的库（没有能搬的 Swift 库） | AI 要按章节、按格子取，还要脚注、批注、修订；Quick Look 给不了，只能自己读 | 11-16 |
| 4 | Markdown 怎么解析、显示 | 搬 md4c（MIT，C）进 `ThirdParty/`，包一层 Swift 建文档模型；HTML 交给 WKWebView 显示，页面自己的脚本全关、原样 HTML 不放行；网上的图片默认不加载 | Foundation 的 `AttributedString(markdown:)`；自己写解析器；cmark-gfm / swift-markdown | md4c 一万行、零依赖、CommonMark 0.31.2 加 GFM 和脚注，在 OSS-Fuzz 里跑着，Qt 和 LibreOffice 都是拷进仓库用的。Foundation 的实测不认任务列表、脚注，不给原文位置；cmark-gfm 一系体积近 3 倍、安全公告更多 | 11-16 |
| 5 | Markdown 编辑器 | 系统的 NSTextView 编原文，照 CotEditor（Apache-2.0）的做法用临时属性着色（只拿代码，图片素材不能拿）；预览、原文、并排三种看法；系统的自动替换全关；保存走六道保险全套 | 所见即所得；WebView 加 CodeMirror（MarkEdit 那一套）；SwiftUI 的 TextEditor | 着色写在临时属性上，正文一个字都不改、不进撤销；所见即所得保不住原文写法；CodeMirror 的文档状态在 JS 里，还会把换行统一成 `\n` | 11-16 |
| 6 | AI 能不能改 md | 能。改动进 App 里打开着的文档，能撤销，改过的地方和表格里 AI 改过的格子一样标淡紫色；写回磁盘仍然只有用户按 ⌘S（设计第 15 条），走六道保险 | AI 只读 | 设计第 12 条管的是表格的原始 sheet（要永久保留的 raw data）；md 是用户自己在写的文档，作者明确允许 AI 改，落盘那一下仍在用户手里（4.5 节） | 11-16 |
| 7 | AI 怎么读、怎么改（MCP） | 还是一个服务（改名后叫 `skyfolio`）。新工具：`describe_document`、`read_document`、`find_in_document`（只读）、`edit_document`（只改 md）；`get_status`、`open_file`、`show`、`undo` 扩展到文档。总说明量过 1,817 个字符（上限 2,048） | 另起一个服务；每种格式各一组工具 | 用户只连一次、只放行一次；工具不分格式，以后 PPT 不用再加工具名 | 11-16 |
| 8 | 界面上怎么看出 AI 在读哪里 | md：这一轮 AI 读过的段落左边画一道淡紫色竖线，`show` 跳过去选中（M7 起）。Word：Quick Look 那一步做不到，等换成 docx-preview 以后 | 只在 `show` 时高亮 | 用户看得见 AI 在看什么，和表格里的淡紫色一个意思；Quick Look 是黑盒，没有按段滚动、高亮的接口 | 11-16 |
| 9 | Word 表格导进 sheet | 不加专门的工具：AI 用 `read_document` 按格子取，再 `add_sheet` + `write_cells` | `add_sheet` 加 `from_document_table` | 现有工具已经走得通，常用了再加 | 11-16 |
| 10 | 设计第 14 条（不许用别的程序改用户文件） | 管「用户的 .xlsx/.csv，以及在 SkyFolio 里开着的文件」；开着的文件在磁盘上被改了，没有没存的改动就先备份上一版再重新载入，有就按第六道保险先问 | 照搬到所有 .docx、.md；文档不管 | 总说明对整个会话生效，写「不许改 .md」会拦住 Claude Code 平时改 README；文档不管的话，用户没存的改动会被别的程序冲掉 | 11-16 |
| 11 | 名字 | 整体改名 SkyFolio：App 名、bundle id `ai.skylu.skyfolio`、MCP 服务名 `skyfolio`、仓库 `skysf/SkyFolio`；对外全名「SkyFolio by Skylu」。上 App Store 或正式推广之前，去 USPTO、EUIPO、中国商标网正式查一次。改名在 M6 做 | 保留 SkySheet；只改显示名；SkyLeaf、SkyBinder 等候选 | 它已经不只是表格。已知撞名（7.1 节）：作者知道后仍选它，全名带上品牌来区分 | 11-16 |
| 12 | 模块名 | 管整个 App 的四个跟着改（`SkySheet`、`SkySheetMCP`、`SkySheetMCPKit`、`SkySheetChecks` → `SkyFolio…`）；表格引擎三个（`SkySheetCore`、`SkySheetFiles`、`SkySheetDisplay`）不改，「SkySheet」从此是表格引擎的名字 | 全改；全不改 | 表格引擎一万多行、被 import 114 处，改名只搅历史，而且它就是表格引擎 | 11-16 |
| 13 | 签名 | 先不公证，继续用「Skylu Signing」自签名；README 和 DMG 里写清第一次打开怎么点（8.1 节） | 加入 Apple Developer Program 做公证 | 作者定。以后要公证需要什么，见 8.1 节末尾 | 11-15 |
| 14 | 更新 | 用户自己去 GitHub Releases 下载；不做自动更新，也不做应用内检查更新（8.2 节的发版清单） | 自动更新；应用内检查 | 作者定；SkyFolio 不联网 | 11-15 |
| 15 | 隐私 | 不加崩溃报告和统计。SkyFolio 自己完全不联网；README 和第一次打开时说清楚 AI 读到的内容去了哪里 | 自己做崩溃上报 | 表格里是财务数据，崩溃报告可能带出格子内容；要服务器、要管别人的数据 | 11-16 |
| 16 | 界面中文 | 现在不排，设计第 22 条不变 | 给别人用时加 | 作者定 | 11-16 |
| 17 | 搬进来的开源代码怎么管 | 设计第 7 条改成：不通过包管理器引用；许可证和 AGPL-3.0 兼容的代码可以复制进 `ThirdParty/<项目>/`，带原许可证和出处（`SOURCE.md`），一个项目一个 target，从此自己维护；搬之前审一遍，发版前核上游的安全修复（11.1 节） | 加包管理器依赖；一律自己写 | 代码都在仓库里，看得见、改得了，不会被上游的更新带着走，构建也不联网 | 11-16 |
| 18 | 顺序 | M5 收尾（含正在修的几批 bug）→ M6 改名 → M7 Markdown 只读和共用底层 → M8 Word → M9 Markdown 编辑（含 AI 改）→ M10 给别人用 | 先给别人用，再做 Word 和 md | 作者定。改名要动约 120 个文件，和修 bug 的分支同时做会到处冲突；名字要在别人装之前定；md 比 Word 简单，先用它把共用的部分做出来 | 11-16 |

还要作者告诉我们的事实（不是决定）：平时的 Word 文件是什么软件出的（Word、WPS、腾讯文档、Pages），M8 的测试样例要照着造；
以后给谁用（几个朋友，还是公开给任何人），M10 的 README 写多细跟着它。

## 一、为什么要做这些

- 作者要同一个 App 能开更多种文件、每种有自己的界面，不像 Office 分成好几个 App。这一轮做 Word 和 Markdown，PPT 以后。
  它已经不只是表格，所以整体改名为 SkyFolio（第七节）。
- 以后要给别人用：推翻设计第一节的「只给作者自己用」。先不公证、继续自签名，更新靠 GitHub Releases，所以第一次打开怎么点、
  README、隐私说明都要写清楚（第八节）。这一步排在最后（第十节）。
- 现在在哪：M4 完成（v0.3.1），M5 打磨中（性能那一块 PR #10 已合，另有几批 bug 正在修）。M5 的验收「作者日常用一周没卡壳」还没到。

## 二、Word 和 Markdown：做到什么程度

### 2.1 Word（.docx）

| 内容 | AI 读到什么（`DocxReader`，M8） | 界面上（Quick Look，M8） | 换成 docx-preview 以后 |
| --- | --- | --- | --- |
| 段落、字体、粗斜体、下划线、删除线 | 文字；要的时候带粗斜体（Markdown 写法） | 对（实测） | 对（据它的 README） |
| 标题 | 目录树，按章节取：样式继承里的大纲级别或「heading N」 | 对，字号、颜色照样式 | 对 |
| 列表：项目符号、编号、多级 | 按 numbering.xml 算出编号的文字（1.、a)、一、……） | 对：「1)」「(1.」「I.」「i.」「A)」和各种项目符号（调研实测） | 对 |
| 表格：合并单元格、表头行 | 按格子取，带合并信息（`gridSpan` / `vMerge`） | 合并单元格对；用表格样式定义的边框没画（实测一例） | 对 |
| 图片 | 图片编号和替代文字（AI 看不到图片内容） | 对 | 对 |
| 超链接 | 链接地址 | 显示成链接 | 外部链接交给系统浏览器，只在用户点的时候（3.3 节） |
| 脚注、尾注 | 要的时候带上 | 没有（实测） | 有 |
| 批注 | 要的时候带上：谁、什么时候、挂在哪段 | 没有（实测） | 实验功能 |
| 修订（插入、删除） | 默认给最终状态的文字、并说明有修订；要的时候带上标记和作者 | 不标：插入的当普通字，删除的不见了（实测） | 实验功能 |
| 页眉页脚 | 单独一类块 | 文字有，排在正文里，不在页边 | 有 |
| 分页符 | 标出来 | 画成一个「□」字，不分页（实测） | 分页 |
| 公式（OMML） | 告诉 AI 这里有一个公式、读不了 | 空白（调研实测） | 转成 MathML 显示 |
| 内容控件、`mc:AlternateContent`、符号字体 | 照 mammoth 的读法：取里面的内容、用备用的那一份、符号转 Unicode | — | — |
| SmartArt、图表、嵌入的对象 | 告诉 AI 这里有什么、读不了 | 看系统 | 看它 |
| 编辑；AI 写 | 不做，docx 永远只读 | — | — |
| .doc、.rtf、.odt、有密码的 docx | 打不开，明说 | 有密码的 docx 和 xlsx 一样是 OLE 文件，`OPCPackage.classifyNonZip` 现成能认 | — |

「读不懂的原样保留」（硬规矩第 3 条）在只读的文档上变成：**读不懂的不许悄悄丢**。AI 读到时被告知，`describe_document`
列出这份文件里有哪些读不了的东西。

### 2.2 Markdown（.md、.markdown）

- 解析交给 md4c：CommonMark 0.31.2，外加按开关打开的 GFM 表格、任务列表、删除线、宽松的自动链接、脚注（`MD_FLAG_TABLES`、
  `MD_FLAG_TASKLISTS`、`MD_FLAG_STRIKETHROUGH`、`MD_FLAG_PERMISSIVEURLAUTOLINKS`、`MD_FLAG_FOOTNOTES`）。
- md4c 不认开头的 front matter：包装层先把它切出来，显示成一个小信息框。
- 原样 HTML 不放行（`MD_FLAG_NOHTML`），当文字显示；数学公式、Mermaid 显示原文。
- 编码：UTF-8（带不带 BOM）、UTF-16、GB18030，直接用 csv 那套 `TextEncodingSniffer`（设计 7.3 节）；存的时候照原样写回（4.4 节）。
- 用户能改原文（4.3 节），AI 也能改（4.5 节）；保存走六道保险（4.4 节）。
- 不做：所见即所得、代码块着色、自动加载网上的图片。

### 2.3 和「Claude 自己直接读文件」比，在 SkyFolio 里开有什么用

Claude Code 自己能读 .md（就是文本）。读 .docx 要靠 Python（python-docx 一类的包，得先装），一般只拿到段落文字：
表格的合并、脚注、批注、修订多半丢了。Claude 桌面版的聊天根本读不了这台 Mac 上的文件。在 SkyFolio 里开：

1. **看的是同一份**。用户说「这段什么意思」，指的就是选中的那段（`get_status` 报选区），和表格里「我选中的这块」一样；
   md 里 AI 读过、引用、改过的地方都能点过去（Word 要等换成 docx-preview）。
2. **读得全**。表格按格子给（带合并），脚注、批注（谁写的）、修订（谁改的）、页眉页脚都给；读不了的（公式、图表）也说出来。
3. **读得省**。先看目录（`describe_document`），再按章节取，几十页的文件不用整份塞进对话。
4. **文档和表格放在一起用**。合同（docx）里的条款和贷款表（xlsx）对照，Word 里的表格变成 sheet 里能算的数。
5. **改得放心**。Word 只读；md 不管谁改，改动先留在窗口里、标出来、能撤销，按 ⌘S 才写回，有备份、崩溃恢复、外部改动先问。
6. **桌面版的聊天也能用**。

## 三、Word 怎么显示、怎么给 AI 读

### 3.1 比过的几条路（2026-11-15 实测，加调研）

拿一份自己拼的测试 docx（第十三节：样式定义的标题、多级项目符号和编号、横向和纵向合并单元格的表格、嵌入图片、超链接、
脚注、批注、修订的插入和删除、页眉页脚、分页符、中文）分别走一遍；调研那边又拿 docx-preview、mammoth 仓库里的样本跑了 Quick Look。

| 路线 | 保真度 | 工作量 | 能不能按段高亮 |
| --- | --- | --- | --- |
| **A. 系统的 Quick Look（`QLPreviewView`）——先用它** | 中上：样式、编号、合并单元格、图片、链接对；脚注、批注没有，修订不标，用表格样式定义的边框没画（一例），公式空白，不分页（分页符画成「□」，页眉页脚排在正文里） | 几十行 | 不能：黑盒 |
| B. AppKit 的 `NSAttributedString`（officeOpenXML） | 低：不认 styles.xml（标题全是 12 号 Times），编号列表变成圆点，合并单元格没了、后面的格子错一列，图片、链接、脚注、批注、删除的修订、页眉页脚全丢 | 几百行 | 能，但丢了的东西没法指 |
| C. 自己解析 + 自己排版（分页） | 理论上最高 | 上万行 | 能，不划算 |
| D. 自己解析 + 自己生成 HTML + WebKit | 高 | 渲染要几千行 | 能（实测离屏截图里看得到 JS 加的高亮） |
| **E. docx-preview 搬进 WKWebView——要高亮时换它** | 高（据 README 和源码：分页、页眉页脚、脚注尾注、编号、表格、图片、公式转 MathML；批注、修订是实验功能）。没在本机跑过（调研的规矩不许运行下载的代码） | 接入加 WebView 加固约一周（调研估计） | 能 |

B 是给 TextEdit 自己的 docx 往返用的：`textutil` 生成的 docx（全是直接格式）它读得很好，真实的 Word 文件不行。

### 3.2 定下来的做法

- **显示**：M8 用 Quick Look（`import Quartz`，窗口里放一个 `QLPreviewView`，`previewItem` 设成文件）。渲染在系统的独立进程里，只读。
  做不到按段高亮、跳到 AI 说的那一段，`show` 对 Word 只把窗口摆到前面，结果里明说「Word 里还不能指到某一段」。
- **给 AI 读**：自己写 `DocxReader`（Swift），照 mammoth.js 的读法：样式继承出标题；numbering 出列表层级和编号文字；`gridSpan`、`vMerge`
  出跨列跨行；脚注、尾注、批注、超链接、文本框；`w:sdt` 内容控件、`mc:AlternateContent`、`w:ins` / `w:del`；符号字体转 Unicode。
  边界情况（域代码、编号续号、修订）对照 pandoc 的 docx 读法（只看不搬）。用现有的 SkyZip 和 XMLScanner（挪进 `SkyOPC`，6.2 节）。
  照 mammoth 改写的文件保留它的版权声明（BSD-2）。只输出文字，不读外部文件，有大小和时间上限（mammoth 自己说不防恶意文档吃满 CPU）。
- **以后换 docx-preview**（没排期，要「AI 读到哪段就高亮哪段」时做）：3.3 节。换了以后，AI 读的块编号要和 docx-preview 画出来的元素对上，
  是那一步要解决的事。

### 3.3 docx-preview 搬进来时要做的（以后）

- 只搬打好的 `docx-preview.js`（约 167 KB）放进 `ThirdParty/docx-preview/`，带 Apache-2.0 原文；我们改过的文件要注明（Apache 第 4 条）。
  不要 npm，代价是以后要改只能改生成后的 JS。
- 不带 JSZip：它只在 `src/common/open-xml-package.ts` 里用了 `loadAsync`、`files[路径]`、`.async(类型)` 三个接口。写一个约 40 行的替身，
  由 Swift 用 SkyZip 解包，把各部件交给 JS。
- WebView 锁死：`renderAltChunks: false`（不然它会把 docx 里嵌的 HTML 放进 `<iframe srcdoc>` 渲染）；用 `WKContentRuleList` 拦掉所有网络请求；
  CSP 只放行自带的脚本；文档里的链接一律交给系统浏览器、只认 http(s)、只在用户点的时候；外链图片不加载；不暴露有权限的 message handler。
- 风险：基本一人维护，README 说只有 `renderAsync` 稳定，内部实现随时可能改。

## 四、Markdown 怎么显示、怎么编辑

### 4.1 解析：比过的几条路

| 路线 | 结论 |
| --- | --- |
| Foundation 的 `AttributedString(markdown:)` | 实测认 GFM 表格（带对齐）、代码块、嵌套列表；不认任务列表、脚注、front matter（变成一条分隔线加一个二级标题）、HTML（原样当字）；中文句号会被吞进自动链接（`https://example.org。` 的链接成了 `https://example.org.`）；不给原文位置；转成 NSAttributedString 以后段落之间连换行都没有。不用 |
| 自己写解析器 | 能做，但 CommonMark 加 GFM 要几千行、规范有 600 多个例子。不用 |
| **md4c（MIT，C）——用它** | `md4c.c` 7,464 行加实体表，共约 1.1 万行，零依赖；v0.6.0（2026-09-17）；OSS-Fuzz 里持续模糊测试；Qt 放在 `qtbase/src/3rdparty/md4c`，LibreOffice 26.2 放在 `external/md4c`。2018–2021 年出过约 8 个 CVE，都修了，以后要自己盯上游 |
| cmark-gfm、swift-markdown | 每个节点有源位置、能写回，但 C 代码约 2.9 万行（swift-markdown 还要加 9,000 行 Swift），登记过 10 个安全公告（含表格扩展的堆内存破坏 CVE-2022-24724）。不用 |

- 接法：`Package.swift` 加一个 C target（`path: "ThirdParty/md4c/…"`，3～5 个文件），再写约 300 行 Swift 包装，建我们自己的文档模型。
- md4c 的回调只给文字在原文里的指针，块本身没有源位置：块从第几行开始，包装层按这些指针推算（块编号、并排滚动、着色、AI 改都要用）。
- 预览的 HTML 照 md4c-html.c（658 行，MIT）的写法自己生成，多带一个 `data-block` 编号，用来高亮、滚动。
- AI 读 md 就读原文（它本来就是文字），解析只用来给目录（标题和行号）、表格按格子、块编号。

### 4.2 显示：几样东西怎么处理

- **WebView**：页面自己的脚本全关（`allowsContentJavaScript = false`），原样 HTML 不放行；高亮、滚动由 App 用 `evaluateJavaScript` 做
  （苹果说这个开关只管网页内容自带的脚本，M7 实测确认）。网络请求一律拦下。
- **GFM 表格**：HTML 表格，按分隔行的冒号对齐。AI 那边和 Word 的表格一样按格子取。
- **代码块**：等宽、保留空白、太宽就横向滚；记下语言，不着色。
- **本地相对路径的图片**：按 .md 所在的文件夹解析（`../images/x.png` 也行），走自己的 URL scheme：只放行真实存在的图片文件，有大小上限。
  图片在「文稿」「桌面」「下载」里时，第一次显示可能触发系统的访问询问。
- **网上的图片**：默认不加载，显示占位，点一下这一篇才加载。加载就等于告诉对方「有人在这台机器上看这份文件」。
- **链接**：http(s) 交给系统浏览器，只在用户点的时候；相对路径指向的 .md 在 SkyFolio 里打开；`#锚点` 在文档里跳；别的协议不理。

### 4.3 编辑器

- **NSTextView 编原文**（AppKit）。撤销重做、中文输入法、查找替换（自带的查找条）都现成；纯文本模式，粘贴进来的一律是纯文字。
- **着色照 CotEditor 的做法**：颜色写在 NSLayoutManager 的临时属性上，正文一个字都不改，也不进撤销。规则用正则（CotEditor 的 Markdown
  规则是 32 条、约 5 KB），配一个正则高亮器；只拿 Apache-2.0 的代码，**它的图片素材是 CC BY-NC-ND 4.0，不能拿**。这些代码和它的设置、
  主题模型缠在一起，要拆开。用 NSLayoutManager 就是 TextKit 1，Markdown 文件一般不大，够用。打字时只重新着色改到的那几行。
- **系统的自动替换全部关掉**：智能引号、智能破折号、文本替换、自动纠错、智能插入删除、自动识别链接和数据。它们会悄悄改掉用户没打的字
  （`"` 变成 “ ”、`--` 变成 –），在 Markdown 里就是改了语法。原则：**原文里每一个字节，只有用户的按键和 AI 的 `edit_document` 能改**，
  SkyFolio 不重排、不格式化、不替换。
- **三种看法**：工具栏一个分段按钮加菜单快捷键——「预览」（打开文件时默认）、「原文」、「并排」（左原文右预览，滚动按块的原文行号对齐）。
  从预览点「Edit」进原文，免得看着看着误改。停手 0.3 秒刷新预览，按顶上那一块的编号保住滚动位置。
- 没选的：所见即所得要把排好的版面翻回原文，`*` 还是 `_`、缩进、空行这些写法保不住；WebView 加 CodeMirror（MarkEdit）的文档状态在 JS 里，
  AI 写入、撤销、保存安全都要绕一道桥，而且 CodeMirror 不设 `lineSeparator` 会把换行统一成 `\n`；SwiftUI 的 TextEditor 在 macOS 15 上只能编纯文字。

### 4.4 保存：六道保险在 md 上

md 是用户自己的文件，设计第十节的六道保险一条不少地适用，做法照 csv（设计 7.3 节：按原编码写、解回来逐字节核对）：

| 设计第十节 | md 上 |
| --- | --- |
| 1. 只有 ⌘S 写回原文件 | 一样：不自动存回原处（`autosavesInPlace` 为 false），窗口标题显示「已编辑」。AI 的改动也一样只在窗口里（4.5 节） |
| 2. AI 没有覆盖原文件的工具 | 一样：`edit_document` 只改窗口里的文档，没有写盘的工具 |
| 3. 先写临时文件、核对、再替换 | 按打开时认出来的编码和 BOM 编码 → 写到同一个文件夹里的临时文件 → 读回来和要写的字节逐字节比、再按原编码解回来和内存里的文字比 → 全对才原子替换。是软链接就写进它指向的文件（和 `AIClientConfig` 一样），原文件的权限照旧 |
| 4. 第一次覆盖前备份 | 一样，用 `BackupStore`（每个文件留 10 份） |
| 5. 崩溃恢复 | 一样，用 `RecoveryStore`：每 30 秒给没存的 md 写一份恢复副本（文字加编码、BOM、换行方式、原路径），用户和 AI 的改动都在里面 |
| 6. 文件被别的程序改过先问 | 一样：存之前比修改时间，对不上就问「另存为新文件 / 仍然覆盖（先备份别人改的那一版）/ 重新载入 / 取消」。没有没存的改动时，文件在磁盘上变了就先备份上一版、自动重新载入 |

原文照原样写回（自检逐条钉住）：编码、BOM 照原样（GB18030 和 UTF-16 都能写所有 Unicode 字符）；换行记下是全 LF、全 CRLF、全 CR 还是混着的，
全 CRLF 的文件新敲的回车存成 CRLF，混着的不动，没改的行一个字节不变；文末有没有换行照原样；不做 Unicode 规范化。
几种编码 × BOM × 换行方式的文件读进来不改直接存，逐字节相同；改一个字，只有那几个字节不同；核对失败时原文件不动；恢复副本能恢复。

### 4.5 AI 改 md

- **改的是窗口里的文档**：`edit_document` 对开着的 md 做几种改动——替换某几块的原文、在某块后面插入、删掉某几块、在某一块里找一段字换掉、
  加在文末。改动在主线程上写进编辑器的文字，和用户打字一样：窗口标题变成「已编辑」，恢复副本也带上它。docx 和没在 SkyFolio 里开着的文件
  不能改（AI 只能开用户给的路径，规矩不变）。
- **标出来**：改过的地方和表格里 AI 改过的格子同一个淡紫色。原文里用临时属性涂底色（和着色一样，不碰正文），预览里那几块画淡紫色；
  横幅「Claude 改了 N 处 · 撤销这一轮」；下一轮开始时清掉。
- **能撤销**：一次调用是一步撤销（`AIUndoGrouping`，和表格一样，不然 AI 的几步会堆进同一组）；用户按 ⌘Z 撤的是 AI 那一整步；
  AI 的 `undo document=…` 只撤它自己连着的那几步，用户在它后面改过就拒绝；「撤销这一轮」换回这一轮开始时的文字（一步，⌘Z 能回来）。
- **不冲掉用户正在打的字**：每个改动带上 `expect`（AI 读到的那一块的原文，或者 `read_document` 给的指纹）。这一块在 AI 读过以后变了
  （用户在打字），整次调用都拒绝，告诉 AI「b12 你读过以后变了，再读一次」。
- **写回磁盘只有用户按 ⌘S**（设计第 15 条），走六道保险（4.4 节）。AI 没有存 md 的工具。
- **和设计第 12 条的关系**：第 12 条管的是表格的原始 sheet。那是 raw data，要永久保留原样，所以 AI 只能写新的 sheet，要改原表先复制。
  md 不是 raw data，是用户自己在写的文档；作者 2026-11-16 明确允许 AI 改它。保险在别处：改动只在内存里、看得见（淡紫）、撤得掉，
  落盘的那一下仍在用户手里。这一轮不加「这份 md 对 AI 只读」的开关，以后真有人要再加。
- 规模：工具、`AISession` 从工作簿扩到文字、编辑器和预览里的标记、自检，约 1,000–1,500 行。

## 五、AI 怎么读、怎么改（MCP）

### 5.1 工具

| 工具 | 新 / 改 | 只读 | 做什么 |
| --- | --- | --- | --- |
| `describe_document` | 新 | ✓ | 一份文档的概况：标题和文件信息；目录树（每个标题的块编号）；段落、表格、图片、脚注、批注、修订各有多少；每张表的编号、行列数、所在章节；读不了的东西；能不能改（md 能、docx 不能）、有没有没存的改动；用户正看着哪一块、选中了什么 |
| `read_document` | 新 | ✓ | 读一段：按章节（标题的编号或文字）、按块编号的范围，或者一张表（`table="t2"` 按格子回，带合并信息）。每块前面带编号；`include` 可以要批注、脚注、修订标记。一次最多约 2 万个字符，多的给 `next` 接着读。md 读的是窗口里的版本（含没存的改动），给每块一个指纹给 `edit_document` 用 |
| `find_in_document` | 新 | ✓ | 找字：回每一处的块编号和前后一小段；不给 `document` 就找所有开着的文档；最多回 100 处 |
| `edit_document` | 新 | | 只改 md：替换、插入、删除、块内替换、加在文末，每个改动带 `expect`；一次调用一步撤销；回改过的块的新编号和一小段前后对照 |
| `get_status` | 改 | ✓ | 多一个 `documents` 数组（5.4 节）；`workbooks` 不变 |
| `open_file` | 改 | | 也开 .docx、.dotx、.docm、.md、.markdown |
| `show` | 改 | ✓ | 多收 `document` 和 `block`：md 里滚到那一块、选中；Word 里只把窗口摆到前面（Quick Look 那一步）。`sheet` 从必填改成选填 |
| `undo` | 改 | | 多收 `document`：撤 AI 在这份 md 里的上一步，`round=true` 撤这一轮 |

- 新工具都收一个可选的 `document`（文件名或路径），规矩和现在的 `workbook` 一样：不给就用 AI 上次用过的那份，
  其次是最前面的窗口，只开着一份就是它。
- 不分格式：Word、Markdown、以后的 PPT 都用这几个。PPT 的一页就是一个「章节」，备注就是 `include` 的一种。
- 文件在磁盘上变了、重新载入以后，块编号可能变：下一次调用的结果前面加一句（和 `MCPBridge.relaunchNote` 一个做法），让 AI 重读目录。
- 改名以后服务名变成 `skyfolio`，工具的全名跟着变（`mcp__skyfolio__…`），老会话本来就要重连，这些改动不用照顾老会话的说明。

### 5.2 块编号和读出来的样子

- 编号按文档顺序：段落和标题 `b12`、表格 `t2`、图片 `i3`、脚注 `f1`、批注 `c4`。同一次载入里不变。md 改过以后按新的内容重新编号，
  没动的块尽量保持原编号（按原文行号对）。
- `read_document` 回的文字大概是这样：

```text
[b15] ## 1.2 表格
[t2] (table, 4 rows x 3 columns; read_document table="t2" for cells)
| 贷款类型 | 贷总额 | 年利率 |
| 商业贷款 | 1,000,000 | 3.10% |
[b16] 这一段有**加粗**、一个[超链接](https://example.com/)和一个脚注[^f1]。
```

- 按格子取的表格：`{"rows": [[...], ...], "merged": [{"row": 1, "column": 0, "rows": 2, "columns": 1}], "header_rows": 1}`，
  格子里都是显示的文字（数就是文字，要不要转成数由 AI 定）。

### 5.3 一个服务，总说明量过

- 一个服务：一个小程序、一个 socket、一次「Connect」、一条放行规则（`mcp__skyfolio`）。分开的话用户要连两次、放行两次，
  两边的连接、署名、这一轮都要各写一份。
- 总说明 ≤ 2,048 个字符（`MCPChecks` 钉着：长度、前 512 个字符点名 get_status / describe_sheet / add_sheet / write_cells、
  目录里有每个工具名、没有汉字）。现在 1,404 个字符；下面这份草稿量过是 **1,817** 个，几条检查全过，还剩 231 个：

```text
SkyFolio shows the user's spreadsheets (.xlsx, .csv) and documents (.docx, .md) on their Mac; its windows show what
you work on. For sheets: get_status (open files, the user's selection) or open_file; describe_sheet to learn the
layout; read_range, query (SQL) or evaluate to get numbers; put results in a new sheet with add_sheet and write_cells;
show to point the user at them. For documents: describe_document for the outline, then read_document by section or
table, or find_in_document; change .md files with edit_document. Tool descriptions have the details.

Rules:
- Original sheets are read-only. Results go in new sheets (add_sheet). To change original data, add_sheet
  copy_from=<sheet> and edit the copy.
- .docx files are read-only. Your .md edits stay in the open window, marked for the user. Cite block ids such as b12;
  show points the user at them.
- Prefer formulas that reference the original cells, e.g. =RATE(Loan!C5,-Loan!F5,Loan!B5)*12, over typed-in numbers,
  so the user can trace every result.
- Python is fine for heavy analysis if you can run it on this Mac: export_sheet gives a local CSV path; bring results
  back with add_sheet from_csv or write_cells. Never change the user's .xlsx/.csv files, or files open in SkyFolio,
  with other programs.
- Only open files the user named or these tools returned.
- Nothing reaches the user's file until they press Cmd+S. save_copy only writes a new file.
- A round of changes can be undone in one step (undo round=true).

Tools by need:
- Files: get_status, open_file, save_copy
- Read sheets: describe_sheet, read_range, query, evaluate, export_sheet
- Write (AI sheets only): add_sheet, write_cells, format_cells, edit_rows_columns, edit_sheet, undo
- Documents: describe_document, read_document, find_in_document, edit_document
- Point the user: show
```

  （这里为了排版折了行；量的是不折行的原文。）工具清单现在 18,015 个字符（自检上限 4 万），四个新工具约加 4,000。

### 5.4 get_status 怎么报不同种类的文件

`workbooks` 照旧，旁边加 `documents`；版本那一项的键从 `skysheet` 改成中性的 `app`：

```json
{
  "app": {"name": "SkyFolio", "version": "0.7.0", "built": "…"},
  "workbooks": [ "… 和现在一样 …" ],
  "documents": [{
    "document": "贷款合同.docx", "path": "/Users/…/贷款合同.docx", "kind": "docx", "current": true,
    "editable": false, "unsaved_changes": false,
    "title": "个人住房贷款合同", "blocks": 312, "tables": 4, "unreadable": 1,
    "user_is_on": "b45", "selection": {"blocks": ["b45"], "text": "第五条 利率……（最多 200 个字符）"},
    "reloaded_at": null
  }]
}
```

`kind` 现在是 xlsx / csv，文档加 docx、md（以后 pptx）。Word 在 Quick Look 那一步拿不到用户看到哪、选了什么，`user_is_on`、`selection` 是空的。
`current` 分开记：一个当前的工作簿、一个当前的文档。

### 5.5 Word 表格导进 sheet

不加专门的工具：`read_document table=…` 拿格子 → `add_sheet` → `write_cells`（一次最多 1 万格）。数要 AI 自己从文字转，合并要它自己用
`format_cells` 合。以后常用了，再考虑 `add_sheet from_document_table`（约 300 行，认数和日期照 csv 导入的规矩）。

### 5.6 设计第 14 条

- 第 14 条的理由是「写回统一经过 SkySheet，才有撤销和保存安全」。md 能在 SkyFolio 里改以后，这个理由对开着的 md 也成立：
  没存的改动和别的程序写进去的会打架。Word 开着的时候被别的程序改，用户看着旧的、AI 读着旧的。
- 但不能照搬到所有 .docx、.md：总说明对整个会话生效，写「不许改 .md」会拦住 Claude Code 平时改仓库里的 README。
- 所以是「用户的 .xlsx/.csv，以及在 SkyFolio 里开着的文件，不许用别的程序改」（5.3 节草稿里那一句），AI 从 `get_status` 知道哪些开着。
- SkyFolio 这边：开着的文件在磁盘上变了，没有没存的改动就先把打开时读进来的原字节存进备份（`BackupStore`），再重新载入、提示一句；
  有没存的改动就不动，存的时候按第六道保险问。

### 5.7 AI 读过的段落、show

- 「这一轮」照旧按时间划分（30 秒没调用算结束，设计 8.3 节）。md 里读文档的工具把读到的块记进这一轮，这些段落左边画一道淡紫色竖线，
  下一轮开始时清掉；只画竖线不涂底色，AI 一口气读完全文时整篇涂紫会很吵。改过的块才涂底色（4.5 节）。
- Word：Quick Look 那一步画不了，等换成 docx-preview。

## 六、架构

### 6.1 一个 App 管几种文件

- Info.plist 的 `CFBundleDocumentTypes` 加两类：docx（`org.openxmlformats.wordprocessingml.document`，加 template、macroenabled，角色 Viewer）
  和 md（`net.daringfireball.markdown`，角色 Editor），`LSHandlerRank` 照旧 Alternate（不抢 Word、Pages、Typora、VS Code 的默认打开）。
  这几个 UTI 本机（macOS 26）系统都声明了；macOS 15 上没核实，md 那个再写一份 `UTImportedTypeDeclarations` 兜底（重复声明无害）。
- 三个文档类，各自的窗口：
  - `WorkbookDocument`（xlsx、csv）：不动，表格窗口。
  - `MarkdownDocument`（md）：原文加 md4c 解析出的模型；窗口是预览（WKWebView）和原文编辑器（4.3 节）；保存走六道保险。
  - `WordDocument`（docx）：`DocxReader` 读出的只读模型给 AI；窗口先是 `QLPreviewView`，以后换成 WKWebView 加 docx-preview。
- 一张登记表（`DocumentKind`）：扩展名、UTI、用哪个文档类、哪个读法、能不能改、哪组 AI 工具。`open_file`、打开面板、`get_status`、
  自检（Info.plist 和登记表对得上）都看它，加一种文件只改这一处。
- 只读要在文档类里做死：Word 窗口里 ⌘S、另存为、复原这些菜单不亮，`data(ofType:)` 直接报错。

### 6.2 模块

| 模块 | 以后 | 为什么 |
| --- | --- | --- |
| `SkyZip` | 不动 | docx 和 xlsx 是同一种包装 |
| `SkyOPC`（新） | 从 `SkySheetFiles/Package` 挪出 `OPCPackage`、`XMLScanner`，改成 public，错误换成通用的 `PackageError` | `DocxReader`、以后的 PPT 读包、读关系、读 XML 都用这一份 |
| `SkySheetCore`、`SkySheetFiles`、`SkySheetDisplay` | 名字不改，是表格引擎；`SkySheetFiles` 依赖 `SkyOPC`；`TextEncodingSniffer` 挪到共用的地方（md 也要认编码） | 不复制第二份 |
| `SkyDocs`（新） | 文档模型（块、行内、表格、脚注、批注、修订）、块编号、目录、查找、读给 AI 的文字、表格按格子、md 的 HTML。只用 Foundation | Word、md、PPT 共用；和 AppKit 无关，自检能测 |
| `SkyWord`（新） | `DocxReader` | |
| `SkyMarkdown`（新） | md4c 的 Swift 包装：front matter、块的行号、建模型 | |
| `ThirdParty/md4c`（新，C target） | md4c 原样，带 LICENSE 和 SOURCE.md | 第 7 条的规矩（11.1 节） |
| `SkyFolioMCPKit`（原 `SkySheetMCPKit`） | 加 `MCPDocumentTools`；服务名 `skyfolio` | 清单还是只有一份（硬规矩第 6 条） |
| `SkyFolioMCP`（原 `SkySheetMCP`） | 小程序 `skyfolio-mcp` | |
| `SkyFolio`（原 `SkySheet`，App） | 加 `Reader/`（预览的 WebView 和传话）、`Markdown/`（文档类、编辑器、着色、保存）、`Word/`、`AI/AIDocumentTools`；`AISession` 的「这一轮」从工作簿扩到文档 | |
| `SkyFolioChecks`（原 `SkySheetChecks`） | 加 docx、md、md 存取往返、AI 改 md、配置和目录迁移、`ThirdParty/` 的守卫 | |

- 新模块统一「Sky + 哪一块」：`SkySheet*` 是表格、`SkyDocs` 是文档、`SkyZip`、`SkyOPC` 是底层。
- 估算：md4c 的包装和模型 800–1,000 行，`DocxReader` 1,500–2,500 行（调研估计），共用的模型、目录、读给 AI 的文字和 HTML 约 1,200 行，
  窗口（预览、Quick Look）约 800 行，md 编辑和保存约 1,500 行，AI 的文档工具（含 `edit_document`）约 1,200 行，自检约 2,000 行。
  合计约 9,000–10,000 行，md4c 本身的 1.1 万行 C 不算。

### 6.3 PPT 以后怎么接

- pptx 也是 OPC 包，`SkyOPC` 现成；显示先用 Quick Look（它也画 pptx）；给 AI 读的另写一个读法（幻灯片里的字是 DrawingML 的文本框，
  `DocxReader` 读图片、文本框的 DrawingML 部分写成能共用的）。
- 模型：一页是一个章节，备注单独一类块。AI 工具不用加（5.1 节）。

### 6.4 六道保险的边界

- md：全套（4.4 节），用户和 AI 的改动一样。
- Word 不写回，六道保险不照搬：⌘S、另存为、复原的菜单不亮；AI 没有任何写 Word 的工具；文件在磁盘上被改了，重新载入前备份上一版（5.6 节）；
  没有没存的改动，不需要恢复副本、不需要「先问」。哪一天 Word 也能改了，六道保险一条不少地搬过去。「只读」靠文档类里做死，不靠藏按钮。

## 七、改名为 SkyFolio

作者 2026-11-16 定：App 名 SkyFolio，对外全名「SkyFolio by Skylu」；bundle id `ai.skylu.skyfolio`；MCP 服务名 `skyfolio`；仓库 `skysf/SkyFolio`。
现在仓库里 122 个文件、583 行提到 SkySheet / skysheet（`Sources` 里 90 行是字符串，129 行是 `import SkySheet…`）。

### 7.1 撞名（另一个会话 2026-11-15～16 查的）

- 韩国 MUIN 公司（무인기업）2026 年 10 月发布了闭源的天文照片库「Skyfolio」：Mac 版是 Apple 芯片的 dmg，签了名、公证过，另有 Windows、Linux、
  Android 版；它也走 GitHub Releases（`muin-company/skyfolio-releases`，v0.5.1 发于 10-15，v0.6.2 发于 10-25），官网 skyfolio.space；
  iPhone、iPad 版写着「App Store 准备中」。和我们同名、同平台、同分发渠道，类别不同；它要是先上了 App Store，我们以后上 App Store 就不能
  直接叫「SkyFolio」（App Store Connect 要求名字唯一）。
- Snapwood Apps 的「SkyFolio - OneDrive Photos」：安卓、Google TV、Fire TV 上存在了十多年，没有苹果版。
- 商标只在网上搜过：没查到 SKYFOLIO 的注册商标；最接近的是 SKFOLIO（Skfolio Labs，美国 2026-05-12 注册，据第三方汇总站）。
  「Sky」前缀本来就有风险（英国 Sky 2013 年告赢微软 SkyDrive），SkySheet 也一样，不是换名新添的。
- 没人用的：App Store 美、中、日、韩、英、德六个区都没有叫 SkyFolio 的 app；`skysf/SkyFolio`、MCP 注册表、npm、PyPI、Homebrew 里都没有。
- 作者知道这些以后仍选 SkyFolio。对外全名用「SkyFolio by Skylu」来区分；上 App Store 或正式推广之前，去 USPTO、EUIPO、中国商标网正式查一次。

### 7.2 仓库里改什么

| 东西 | 现在 | 改成 | 说明 |
| --- | --- | --- | --- |
| App 名、可执行文件、图标 | `SkySheet`（Info.plist、`MainMenu`；界面文字和给模型看的说明里约 90 行字符串） | `SkyFolio` | |
| bundle id | `ai.skylu.skysheet`（Info.plist；小程序和 App 里的默认值） | `ai.skylu.skyfolio` | 系统从此当它是另一个 App（7.3 节） |
| 打包时间的 Info.plist 键 | `SkySheetBuildDate` | `SkyFolioBuildDate` | `MCPBridge.appBuildDate` 跟着改 |
| MCP 服务名、小程序 | `skysheet`、`skysheet-mcp`、放行规则 `mcp__skysheet` | `skyfolio`、`skyfolio-mcp`、`mcp__skyfolio` | `get_status` 的版本键改成 `app`（5.4 节） |
| socket、备份、恢复副本、导出 | `Application Support/ai.skylu.skysheet/…`、`Caches/ai.skylu.skysheet/exports` | `ai.skylu.skyfolio/…` | 备份、恢复副本要搬（7.3 节）；导出是缓存，不搬 |
| 开发用的环境变量 | `SKYSHEET_MCP_SOCKET`、`SKYSHEET_MCP_NO_LAUNCH`、`SKYSHEET_MCP_APP`、`SKYSHEET_CHECK_OUTPUT` | `SKYFOLIO_…` | 只影响开发 |
| 配置文件旁边的备份后缀 | `.skysheet-backup` | `.skyfolio-backup` | 老的备份留着不管 |
| 剪贴板类型、窗口位置的名字 | `ai.skylu.skysheet.cells`、`SkySheetWorkbook` | `ai.skylu.skyfolio.cells`、`Workbook` | 新旧版本之间复制粘贴会掉格式，无所谓 |
| 存进 xlsx 的 `<Application>` | `SkySheet` | `SkyFolio` | |
| **xlsx 里 AI 的 sheet 的标记** | `SkySheet.AI.<编号>`（已经写进了用户的文件） | **不改** | 它是文件格式，不是品牌：改了旧文件就认不出来 |
| 脚本 | `build-app.sh`（`APP_NAME`、DMG 名、「首次打开必读」）、`make-icon.swift`、`check-all.sh` | `SkyFolio`，DMG 叫 `SkyFolio-<版本>-arm64.dmg` | 签名脚本不带名字，不用改；证书不动（硬规矩第 5 条） |
| CI | `checks.yml` 里的 job 叫 `check-all` | **不改** | main 的保护规则按这个名字要求必须通过 |
| 文档 | CLAUDE.md、README、设计、`docs/architecture/mcp.md`、`docs/testing/*` | 名字、命令、`.build/arm64-apple-macosx/debug/SkyFolio` 这些路径 | 设计改标题和第 1 条，正文里的旧名字照实留着（历史） |
| 自检 | 两份 AI 配置的自检里写死的 `/Applications/SkySheet.app/…`、`skysheet` | 换成 SkyFolio 的路径和服务名，再加迁移的用例 | |

### 7.3 作者机器上的迁移（SkyFolio 第一次启动时做）

现在只有作者一台机器装过 SkySheet。迁移做进 App 里，做完给一句话的结果。

1. **备份和恢复副本**：`~/Library/Application Support/ai.skylu.skysheet/` 里的 `Backups/`、`Recovery/` 搬进 `ai.skylu.skyfolio/`（同名的子文件夹合并，
   重名的文件两份都留）。恢复副本的 json 里记的是原文件的路径，不受影响，搬完照常问要不要恢复。旧 SkySheet 还开着就先不搬（它可能正在写恢复副本），
   等它退出、下次启动再搬。`mcp.sock` 不动。搬完在旧目录里留一个说明文件。
2. **偏好设置**：旧的域里只有 AppKit 自己记的窗口位置和最近打开的文件（代码里没有用 `UserDefaults`），不搬，重来一次。
3. **Claude Code**：设置里那一行认得旧条目——`~/.claude.json` 里有 `mcpServers.skysheet` 就显示「连着旧的 SkySheet」，按钮变成「换成 SkyFolio」：
   先 `claude mcp add --scope user skyfolio -- <新的小程序>`，成功了再 `claude mcp remove --scope user skysheet`（先加后删，中途失败也不会两个都没有）；
   `~/.claude/settings.json` 的 `permissions.allow` 里加 `mcp__skyfolio`、删 `mcp__skysheet`，照旧按原文只动这两处、第一次改之前备份。
   找不到 `claude` 命令行就给「复制一段话」，两条命令都写上。
4. **Claude 桌面版**：`claude_desktop_config.json` 里 `mcpServers.skysheet` 原地换成 `skyfolio`，`command` 换成新的小程序，用户自己加的 `env`、`args` 留着；
   桌面版开着时照旧在它退出那一刻再写一遍（设计 9.5 节）。工具名变了，「总是允许」要重新点，提示里说。
5. **旧 App**：迁移完提示「应用程序里还有 SkySheet，可以扔进废纸篓」；不替用户删。
6. **系统那边重来一次的**：文件夹权限（「文稿」「下载」「桌面」）再问一次——bundle id 变了，签名的 designated requirement 跟着变，系统按它记账（TN3127）；
   「打开方式」里设过的默认 App 要重设；最近打开的文件清空。作者自己编的版本没有隔离属性，不用去「隐私与安全性」放行。
7. **用户自己写的东西**：提示词、CLAUDE.md 里写过的 `mcp__skysheet__…` 没法替他改，发版说明里提一句。
8. 认旧条目、搬旧目录的代码留到 v1.0 再删。

自检加的：两家配置里有旧条目 → 换成新的，别的字节一个不动、`env` 留着、备份只做一次；旧目录 → 搬过来、重名两份都留、旧 App 开着时不搬。

### 7.4 仓库改名、什么时候改

- GitHub 上把 `skysf/SkySheet` 改成 `skysf/SkyFolio`。GitHub 会把网页、git、API 的旧地址自动转到新仓库；**以后不能再建一个叫 SkySheet 的仓库**，
  建了转发就断（GitHub 文档的说法，这个会话没抓到原文，改之前再看一眼「Renaming a repository」）。本机顺手 `git remote set-url` 改成新地址。
  开着的 PR、分支保护、必过的检查 `check-all` 都跟着仓库走。本机的文件夹（`…/SkyStudio_APP_Master/SkySheet`）可以不改。
- 什么时候：M6，在 M5 和正在修的几批 bug 都合进 main 之后。一个 PR，分两个提交（机械的改名；迁移和它的自检）。改名要动约 120 个文件，
  和修 bug 的分支同时做会到处冲突。

## 平台与分发

第八、九节。

## 八、给别人用（M10）

推翻设计第一节的「只给作者自己用」；排在最后一个里程碑。另有 Codex 在单独排查「换一个人、换一台机器、换一份文件就出事」的 bug，
这里引到的风险点到为止，都放进 M10 的验收里实测。

### 8.1 签名：先不公证，第一次打开怎么点

继续用「Skylu Signing」自签名，签名只经 `sign-app.sh`（硬规矩第 5 条不变）。别人在 macOS 15 及以后第一次打开会这样（写进 README，配截图；
DMG 里的「首次打开必读」已经有这几步，照着更新）：

1. 从 GitHub Releases 用浏览器下载 `SkyFolio-<版本>-arm64.dmg`，打开，把 SkyFolio 拖进「应用程序」。**要用访达拖**：直接在 DMG 里或「下载」里双击，
   系统会把它放到一个随机的只读位置去跑（App Translocation），这时点「Connect」写进 Claude 配置的是个临时路径，退出就没了。
   只有用访达挪过一次才解除（苹果论坛上 Quinn 的说法）。
2. 在「应用程序」里双击：被拦下，系统说没法确认它不含恶意软件（原话以系统为准），点「完成」。macOS 15 起，按住 Control 点「打开」的老办法没有了
   （Apple 2024-08-06 的开发者新闻）。
3. 打开「系统设置 → 隐私与安全性」，往下翻到「安全性」，在关于 SkyFolio 的那一行点「仍要打开」，输入登录密码（或触控 ID）。
   这个按钮在第一次被拦之后大约一小时内有效（Mac 使用手册）。
4. 再双击，正常打开。以后每次都正常。

还要在 M10 的新用户上实测的几件事（点到为止）：

- **每下载一个新版本，大概都要再走一遍 2、3 步**（推测：新下载的文件又带隔离属性，签名的 cdhash 也变了）。发版说明里提醒。
- **小程序会不会被单独拦**：Claude Code 直接启动包里的 `skyfolio-mcp`，它也带着隔离属性。会不会再弹一次「无法打开」，没验证。
- **文件夹权限能不能跨版本留住**：作者机器上靠的是固定的签名身份（设计第十一节）。别人机器上没有这把证书，designated requirement 只比证书的哈希，
  按道理照样留得住（推测），要实测。
- **App 要能认出自己被 translocate 了**（路径里有 `/AppTranslocation/`，或者在 `/Volumes/` 下面）：这时设置里的「Connect」不许点，告诉用户先拖进「应用程序」。约 50 行。

以后要公证时需要的（不在计划里）：加入 Apple Developer Program（每年 99 美元，中国区 App Store 内购价 ¥688）；在开发者账号里建「Developer ID Application」
证书（自签名的证书公证不了）；`sign-app.sh` 加 `--options runtime`（强化运行时）和 `--timestamp`（现在是 `--timestamp=none`）；
`xcrun notarytool submit … --wait` 提交、`xcrun stapler staple` 把票据钉在 App 和 DMG 上（本机的命令行工具里两个命令都有）。代价：要花钱；
换签名身份后文件夹权限要重给一次（TN3127）；个人账号的证书上写的是作者的法定姓名。「Skylu Signing」照旧留给作者自用的版本和别的个人工具。
公证以后还能进 Homebrew 的官方 cask：它从 2026-09-01 起停用过不了 Gatekeeper 检查的 cask。

### 8.2 更新和发版

不做自动更新，也不做应用内检查更新：SkyFolio 不联网（8.4 节）。用户从 GitHub Releases 下载新版、先退出 SkyFolio、拖进「应用程序」替换旧的；
有 GitHub 账号的可以在仓库页面点 Watch → Custom → Releases 收到通知。想知道自己是哪一版：关于窗口，或者问 AI（`get_status` 报版本和打包时间）。

发版清单（M10 写进 `docs/` 一份，每次照着走）：

1. main 是绿的；这个里程碑的真机清单走过了（`docs/testing/`）。
2. 定版本号（小功能、修 bug 升最后一位，里程碑升中间一位）；`CFBundleVersion` 改成每次递增的整数（现在一直是 1，别的 App 和系统比较新旧时看它）。
3. 写发版说明（中文、英文各一份）：改了什么、已知问题、升级要注意的（改名、文件夹权限、每个新版本第一次打开都要放行）、第一次打开的步骤（链到 README）、
   DMG 的 SHA-256。
4. 在 main 的那个合并提交上打 tag：`git tag -a vX.Y.Z -m "…"`，推上去。
5. `VERSION=X.Y.Z scripts/build-app.sh` → `dist/SkyFolio.app` 和 `dist/SkyFolio-X.Y.Z-arm64.dmg`（签名只经 `sign-app.sh`，脚本里已经核对 designated requirement）。
6. `shasum -a 256 dist/SkyFolio-X.Y.Z-arm64.dmg`，填进发版说明。
7. `gh release create vX.Y.Z dist/SkyFolio-X.Y.Z-arm64.dmg --title "SkyFolio X.Y.Z" --notes-file <发版说明>`。
8. 第一次公开发版，以及打包、签名有改动的版本：在一个新建的 macOS 用户里，用浏览器从 Release 页面下载，照 README 走一遍第一次打开。
9. `ThirdParty/` 里的每个项目：看上游从记下的提交以来有没有安全修复（11.1 节）；包里和 DMG 里带上 `THIRD-PARTY-NOTICES`。

### 8.3 别人第一次用

- **运行要求**：Apple 芯片的 Mac，macOS 15 起。Claude Code、Claude 桌面版都要 macOS 13 起（官方文档），比我们低，不卡人。
- **引导**：第一次打开时一个欢迎窗口（约 200–300 行 SwiftUI）：SkyFolio 是干什么的；连接 Claude Code、Claude 桌面版的两个按钮（就是设置里那两行）；
  隐私一句话（8.4 节）；被 translocate 时提示先拖进「应用程序」。README 是完整版。
- **README**（中文、英文各一份；界面还是英文，设计第 22 条不变）：下载和第一次打开（8.1 节，带截图）；打开文件；连接两家 AI；AI 能做什么、不能做什么
  （原始 sheet、Word 对 AI 只读，md 的改动标出来、⌘S 才写回）；隐私；文件放在哪（`Application Support` 里的备份和恢复副本、`Caches` 里的导出、
  改过哪几个 AI 配置文件和它们的备份）；卸载（先在设置里 Disconnect 两家，再删 App 和那两个目录）；常见问题（每个新版本都要放行一次、
  为什么要拖进「应用程序」、`export_sheet` 要这台 Mac 能跑 Python）；第三方许可（`ThirdParty/` 的项目和许可证）。
- **别人机器上会不一样的**（点到为止）：
  - `claude` 命令行装在哪：现在找 `~/.local/bin`、`~/.claude/local`、`/opt/homebrew/bin`、`/usr/local/bin`、`~/.npm-global/bin`、`~/.bun/bin`；用 nvm、volta、asdf
    这类装的找不到，会退到「复制一段话」。
  - Claude 桌面版的 Code 页同时读 `claude_desktop_config.json`、`~/.claude.json`、`.mcp.json`（官方文档）：两家都连了，Code 页里会不会出现两个
    `skyfolio`，没验证。
  - AI 第一次打开「文稿」「下载」「桌面」里的文件，系统会问要不要给 SkyFolio 访问权限：引导和 README 里先说一声。

### 8.4 隐私和信任

要跟别人说清楚的（README 一节，欢迎窗口里一句话）：

- **SkyFolio 自己完全不联网**：代码里没有任何网络请求（搜过：没有 URLSession、Network 框架）；没有统计、没有崩溃上报、不检查更新。
  例外只有用户自己点的：链接交给浏览器，md 里网上的图片点了才加载。预览的 WebView 拦掉所有网络请求。
- **AI 读到的东西去了哪里**：AI 用工具读到的格子、查询结果、文档段落，会作为工具结果回到对话里，随对话发给 Anthropic（Claude 的工具调用文档）；
  按 Anthropic 的隐私政策成为用户的输入。拿来训练模型这件事，个人账号（Free、Pro、Max，包括用这些账号的 Claude Code）由用户自己在隐私设置里选，
  选了允许的保留五年，不允许的 30 天（Anthropic 2025-08-28 的公告）；它的说明里还写着「本机 MCP 服务器的原始内容」不算训练数据，除非复制进了对话。
  Claude Code 还会在本机的 `~/.claude/projects/` 里留 30 天的对话记录。README 只写这几句、附链接，以 Anthropic 的页面为准（政策会变）。
- **SkyFolio 自己写哪里**：备份、恢复副本（`Application Support`）、导出的 csv（`Caches`）、两家 AI 的配置文件（只动自己那一条，改之前先备份）。
  用户的文件只有按 ⌘S 才写。
- **信任**：Anthropic 不审查任何 MCP 服务器（Claude Code 的安全文档）；SkyFolio 是开源的（AGPL-3.0），代码可以自己看。
- **不加崩溃报告和统计**：表格里是财务数据，崩溃时内存里的格子内容可能被带出去；自己做要架服务器、管别人的数据；用的人少，
  GitHub issue 加 macOS 自己的崩溃日志（`~/Library/Logs/DiagnosticReports`，用户看过再贴）够用。

## 九、平台

只支持 Apple 芯片的 Mac：作者 2026-11-15 考虑过 Intel 芯片和 Windows，不做，设计第 3 条不变。

## 十、里程碑

| 里程碑 | 交付 | 验收 | 规模（依据） | 版本 |
| --- | --- | --- | --- | --- |
| M5 打磨（进行中） | 已有的打磨，加正在修的几批 bug；Codex 顺带把 IronCalc 的 calc_tests 和 numfmt 的数字格式用例搬进来当测试数据（第十二节） | 作者日常用一周没卡壳（不改） | — | v0.4.0 |
| M6 改名 SkyFolio | 第七节：仓库里的名字、bundle id、MCP 服务名；App 里的迁移（备份和恢复副本目录、两家 AI 配置里的旧条目）；仓库改名；文档 | 作者这台机器从 SkySheet 升上来：备份、恢复副本都在；Claude Code、桌面版各点一次就换成 `skyfolio`，配置里别的字节一个不动；`check-all` 绿 | 机械改名约 120 个文件、600 行上下；迁移 300–400 行加自检约 200 行。和「连接桌面版」那个 PR（#7，约 600 行）差不多 | v0.5.0 |
| M7 Markdown 只读和共用底层 | `SkyOPC` 挪出来；md4c 搬进 `ThirdParty/`；`SkyDocs`、`SkyMarkdown`；预览窗口（WKWebView，页面脚本关、网络拦）；`describe_document`、`read_document`、`find_in_document`，`get_status`、`open_file`、`show` 的扩展；读过的段落画竖线；截图模式能截文档 | 几份自己造的 md 和作者自己的 md（副本）显示对；喂畸形输入（随机字节、超长行、深嵌套）不崩；AI 按章节读、引用块编号，界面点得过去；总说明 ≤ 2,048；`ThirdParty/` 守卫过；`check-all` 绿 | 约 4,500–5,500 行（含自检，不含 md4c），和 M4（4,382 行）差不多 | v0.6.0 |
| M8 Word 只读 | `QLPreviewView` 显示；`DocxReader`；文档工具对 docx 生效（`show` 只摆窗口） | 一组造出来的 docx（Word、WPS、腾讯文档、Pages 各导出一份，内容是编的）：Quick Look 显示对；`DocxReader` 读出的文字、表格（含合并）、脚注、批注、修订和预期逐项相同；作者自己的 docx（副本）走一遍；docx 一个字节都不写 | 约 2,500–3,500 行（含自检），和 PR #9（3,225 行）差不多 | v0.7.0 |
| M9 Markdown 编辑（用户和 AI） | 原文编辑器和着色、三种看法、六道保险、恢复副本；`edit_document`、`undo` 对 md；改过的地方标淡紫 | 4.4 节的往返自检全过；AI 改的标出来、能撤销、和用户打字不打架（`expect`）、不按 ⌘S 不落盘；崩溃恢复、别的程序同时改了的四种选择都走一遍；总说明量过 ≤ 2,048 | 约 3,000–3,500 行（含自检），和 M3（3,819 行）差不多 | v0.8.0 |
| M10 给别人用 | 第一次打开的引导和 README（中英文、截图）、认出 translocation、隐私说明、发版清单、`CFBundleVersion` 递增、`THIRD-PARTY-NOTICES` 和关于窗口里的第三方许可 | 新建一个 macOS 用户（没有作者的证书、没有任何配置），用浏览器从 Release 下载，照 README：放行、打开 loan.xlsx 和一份 md、一份 docx、连两家 AI、问一个典型问题，不用作者帮；再发一个小版本照 README 升级一次。8.1 节那几件没验证的事在这里实测、记下来 | Swift 300–500 行，文档为主。和 PR #7、#8 加起来差不多 | v0.9.0（第一次给别人用） |
| 以后（没排期） | Word 换 docx-preview（AI 读到哪段就高亮哪段，3.3 节）；PPT；公证；Word 表格的专门导入工具；中文界面 | — | — | — |

- 规模的依据：各里程碑合进 main 时 `Sources/` 的增减行数（M1 5,935、M2 2,675、M3 3,819、M4 4,382、PR #7 604、PR #9 3,225、PR #10 2,985），
  和这份方案估的新代码量对着比。时间：过去每个里程碑的开发在一到两天（git 记录：M1–M3 都在 10-08，M4 在 10-09，PR #10 在 11-14、11-15），
  规模相近的新里程碑大概也是这样，作者走真机清单的时间另算（推测）。
- 顺序是作者 2026-11-16 定的（决定一览第 18 条）。

## 十一、写进设计文档和 CLAUDE.md 的改动

### 11.1 设计第 7 条：依赖

这一次已经写进设计（第 7 条和它下面的「搬进来的开源代码」）：

- **规矩**：不通过包管理器引用第三方库（`Package.swift` 里没有 `dependencies`，构建时不联网拉代码）。允许把许可证和 AGPL-3.0 兼容的开源代码复制进仓库，
  放在 `ThirdParty/<项目名>/`，带原许可证全文和出处记录，一个项目一个 target；复制进来就是我们的代码，由我们维护，和自己写的一样过自检和审查。
  zip 自己写（压缩用系统的 Compression），查询用系统的 SQLite3。
- **能搬的许可证**：MIT、BSD（2 条、3 条）、ISC、zlib、Apache-2.0、MPL-2.0（没带「与次级许可证不兼容」声明的）、GPL-3.0 及以后（含 GPL-2.0-or-later
  选 v3）、LGPL-3.0、AGPL-3.0、CC0 和 Unlicense 这类公有领域声明。**不搬**：GPL-2.0-only、没写许可证的（等于保留所有权利）、带「不许商用」
  「只许做好事」之类附加条件的、SSPL、BUSL 这类看得见源码但不自由的。按 FSF 的许可证兼容列表核，拿不准就不搬（这是一般理解，不是法律意见）。
- **怎么记出处**：`ThirdParty/<项目名>/` 下面：`LICENSE`（原文，一个字不改；有 NOTICE 的一起带）；`SOURCE.md`（上游地址、版本或 tag、提交哈希、
  复制的日期、复制了哪些文件、我们改了哪些地方和为什么、谁审的）；代码。我们改过的地方在代码里加注释「本仓库改：……为什么」（Apache 的文件改过
  要注明，MPL 的文件头要留着）。`ThirdParty/README.md` 一张总表：项目、许可证（SPDX 写法）、上游提交、上次核对上游的日期。只照着别人的读法
  改写、没搬原代码的（比如照 mammoth.js 写的 `DocxReader`），在文件头保留对方要求的版权声明，也记进总表。
- **搬之前审一遍**（照常走 PR，Codex 或另一个会话审、作者看）：许可证；把要搬的代码读一遍——从此是我们的：不联网、不往意料之外的地方写文件、
  没有统计；只用系统框架，自己不再依赖别的第三方库（依赖的要么也按这套规矩搬，要么替掉，像 docx-preview 的 JSZip）；只搬用得到的部分；
  自己写自检，把我们用到的行为钉住（比如 md4c 喂畸形输入不能崩）。
- **上游修了安全问题谁来跟**：作者是维护者，责任在我们。作者的 GitHub 账号对每个上游仓库点 Watch（Releases、Security alerts）；发版清单有一步
  （8.2 节第 9 步）：对总表里每个项目，看上游从记下的提交以来有没有安全公告或修复，有就单开一个 PR 搬过来，更新 `SOURCE.md` 和总表的日期。
  解析别人文件的代码（md4c、以后的 docx-preview）优先看。Dependabot 看不到复制进来的代码，只能靠这一步。
- **分发时带上版权声明**：MIT、BSD、Apache 这些要求分发二进制时带上版权声明：关于窗口里加「第三方许可」，包里和 DMG 里各放一份
  `THIRD-PARTY-NOTICES`，由 `build-app.sh` 从 `ThirdParty/*/LICENSE` 拼出来（M10）。
- **别人的测试数据**同样要许可证兼容、带许可证和出处，放在 `Fixtures/` 下按来源分的子目录（M5 搬 IronCalc、numfmt 时照这个做）。
- **守卫**（第一个项目搬进来时加进 `check-all.sh`）：`ThirdParty/` 下每个目录都有 `LICENSE` 和 `SOURCE.md`；`Package.swift` 里没有 `dependencies:`。
- CLAUDE.md 硬规矩第 4 条跟着改成：不通过包管理器引第三方库；别人的开源代码只能按设计第 7 条复制进 `ThirdParty/`。

### 11.2 这一次改了的

| 文件 | 改了什么 |
| --- | --- |
| 设计第一节 | 加「2026-11-15、11-16 定的方向」：通用的文件 App（Word、Markdown）、改名 SkyFolio、以后给别人用（先不公证、GitHub Releases），都标「计划」；「只给作者自己用」改成「现在只有作者自己在用」 |
| 设计第 1 条 | 加计划：M6 改名 SkyFolio（全名「SkyFolio by Skylu」、bundle id、MCP 服务名、仓库），迁移指向本方案第七节；撞名和正式查商标的打算；`SkySheet.AI.` 标记不改 |
| 设计第 5 条 | 加计划：docx 只读（M8），md 读写（M7 只读、M9 能改）；.doc 等不做 |
| 设计第 7 条 | 换成 11.1 节的规矩，表下加「搬进来的开源代码」细则 |
| 设计第 11 条 | 加：Word 的编辑和分页显示、.doc / .rtf / .odt、md 所见即所得、自动更新和应用内检查更新、公证（暂不）、崩溃报告和统计 |
| 设计第 12 条 | 加计划：Word 对 AI 只读；AI 能改 md 的边界（进窗口、能撤销、淡紫、⌘S 才写），和原始 sheet 的区别 |
| 设计第 14 条 | 加计划：范围扩到「在 App 里开着的文件」，不扩到所有 .docx、.md |
| 设计第十三节 | 加 M6–M10 和「以后」，M5 写上正在修的几批 bug |
| 设计变更记录 | 记 2026-11-15、11-16 的拍板 |
| CLAUDE.md | 开头加新方案的指引；硬规矩第 4 条换成新的依赖规矩。「现在在哪」不动（M5 还没完），App 名等 M6 再改 |

### 11.3 到了对应的里程碑再改的

这些写的是做法，做的时候再改，现在改就成了「已经有了」：

| 设计里 | 哪个里程碑改 | 改成什么 |
| --- | --- | --- |
| 第三节 整体结构 | M6、M7、M8 | 模块表按 6.2 节；目录指引加 `Reader/`、`Markdown/`、`Word/`、`ThirdParty/` |
| 第八节 App | M7、M9 | 新开两节：预览窗口、md 编辑器；8.3 节加「读过的段落画竖线」「md 里 AI 改过的地方」 |
| 第九节 MCP | M6、M7、M9 | 9.1 节 socket 路径换新的 bundle id；9.2 节工具表加 4 个、改 4 个；9.4 节总说明换成 5.3 节的草稿；9.5 节「连接」加「认得旧条目并换掉」 |
| 第十节 保存安全 | M7、M9 | md 全套适用（4.4 节）；Word 的边界（6.4 节）；开着的文件在磁盘上被改了先备份再载入 |
| 第十一节 构建、签名、CI | M6、M10 | 名字、DMG 名；发版清单（8.2 节）；`THIRD-PARTY-NOTICES` |
| 第十二节 自检 | M5–M9 | IronCalc、numfmt 的对照；md、docx 的读法；md 存取往返；AI 改 md；配置和目录迁移；`ThirdParty/` 守卫 |
| 第 15、16、19、20 条 | M9、M5、M6 | md 也只有 ⌘S 写回；md 的原文编辑；测试数据加 IronCalc、numfmt 和自己造的 docx、md；仓库改名、`check-all` 不改名 |
| 第十五节 已知不足 | 各自的里程碑 | Word 不分页、Quick Look 不显示脚注批注修订；md 的 HTML、公式只显示原文；网上的图片默认不加载；每个新版本第一次打开都要放行 |
| 设计以外 | 各自的里程碑 | README、`docs/architecture/mcp.md`、`docs/testing/` 加各里程碑的真机清单 |

## 十二、可以借用的开源代码

另一个会话 2026-11-15～16 调研过（只读代码、查资料，没运行下载的代码）。结论：整个 App 没有合适的底子，继续在现在的代码上加；搬这几样：

| 用途 | 搬什么 | 许可证 | 怎么用 | 什么时候 |
| --- | --- | --- | --- | --- |
| Markdown 解析 | md4c 0.6.0（`md4c.c`、`entity.c`、头文件，约 1.1 万行 C） | MIT | `ThirdParty/md4c/` 一个 C target，Swift 包装约 300 行；预览的 HTML 照 `md4c-html.c` 的写法自己出（带块编号） | M7 |
| Word 给 AI 读 | 不搬代码，照 mammoth.js（BSD-2）的读法用 Swift 改写；边界情况看 pandoc（GPL-2.0-or-later，只看）；docling、markitdown（MIT）参考合并单元格和标题层级 | BSD-2（改写的文件留版权声明） | `SkyWord` 里的 `DocxReader` | M8 |
| md 编辑器着色 | CotEditor 的「临时属性上色」做法、正则高亮器和 Markdown 规则；**不拿它的图片素材**（CC BY-NC-ND 4.0） | Apache-2.0（只限代码） | 拆出来放进 `ThirdParty/`，或者照着写；和它的设置、主题模型分开 | M9 |
| Word 显示（以后） | docx-preview 打好的 `docx-preview.js`，用 SkyZip 替掉 JSZip | Apache-2.0 | 3.3 节 | 以后 |
| 表格的测试数据 | IronCalc 的 `xlsx/tests/calc_tests`（225 个由 Excel 保存的 xlsx，覆盖 RATE、XIRR、PMT、EDATE、TEXT 等）；numfmt 的数字格式用例（按 Excel for Mac 校对过） | MIT 或 Apache-2.0；MIT | 进 `Fixtures/`，自检照 loan.xlsx 的流程比对；我们不支持的函数照规矩标「未重算」 | M5（Codex 排进修 bug 的队列） |

没搬的和为什么：

- Word：`NSAttributedString` 读 docx 太差（3.1 节）；SuperDoc（AGPL）是 Word 级编辑器，解开 14 MB、依赖 Vue 等一大堆，只拿来看太重；
  `ooxml-swift`、`word-to-md-swift` **没有许可证文件**，不能用；DuckX、shinjukunian/DocX 不更新或只能写。
- Markdown：cmark-gfm、swift-markdown 体积近 3 倍、安全公告多；swift-markdownkit 没有源位置；MarkEdit（WebView 加 CodeMirror）文档状态在 JS 里、
  换行会被统一；FSNotes 依赖多、属性直接写进正文；STTextView 用不着（NSTextView 够用）；MacDown 2021 年后没更新。
- 表格：IronCalc、LibreOffice、HyperFormula、formula.js 的代码都不搬（Rust 编不进来、只当语义参照、测试数据不如 IronCalc 直接、TEXT 这类语义太浅）。
- 整个 App：ONLYOFFICE（AGPL）、LibreOffice（MPL）源码两三百 MB，带 Chromium 等一大堆依赖，保存时重写整个文件，做不到「读不懂的原样保留」。

多出的长期负担（11.1 节的规矩就是为它们定的）：盯上游的安全修复（md4c 和 cmark-gfm 都出过 CVE）；许可证义务；C 代码的内存安全和 WebView 里的 JS
都算我们的事；自检要覆盖搬进来的代码。

## 十三、实验记录

都在仓库外的临时目录里做，2026-11-15，这台 M1（macOS 26.5.2，命令行工具 Swift 6.3.3），后台跑、不弹窗口；用的文件都是自己造的，做完全部删掉。

1. **造测试文件**：`textutil -convert docx` 从 HTML 转了一份——它写出来的 docx 是「压扁」的：没有 `<w:tbl>`（表格变成一段段文字）、列表符号是写死的字、
   没有样式和编号定义、图片没进去，不能当样例。所以又用 Python 标准库手拼了一份 docx：样式定义的标题、两级项目符号和编号、横向和纵向合并单元格的表格、
   嵌入 PNG、超链接、脚注、批注、修订（插入、删除）、页眉页脚（带 PAGE 域）、分页符、中文。
2. **NSAttributedString 读 docx**：小 Swift 程序逐段打印字体、列表、表格块、链接、附件。手拼的那份：所有段落都是 Times 12 号（不认样式），
   编号列表成了圆点，合并单元格没了、最后一行的「—」跑到了第二列，图片、链接、脚注、批注、删除的修订、分页、页眉页脚都没有。`textutil` 那份读得很好。
3. **Quick Look**：`QLThumbnailGenerator` 画成 PNG 看。样式、编号、图片、链接、页眉页脚都对；脚注、批注没有；修订不标；用表格样式定义的边框没画；
   分页符画成「□」，页脚跟在正文后面。调研那边用 `qlmanage -t` 跑了别的样本：合并单元格、各种编号格式对，公式空白。
4. **AttributedString(markdown:)**：拿一份带 front matter、强调、删除线、相对和外部链接、自动链接、嵌套列表、任务列表、引用、代码块、GFM 表格、
   相对路径图片、分隔线、行内和块 HTML、脚注、公式的 md 解析（4.1 节）。
5. **WKWebView 离屏**：App 设成 `.prohibited`，窗口不放上屏幕，载入手写的 HTML（合并单元格、边框、图片、多级编号、插入删除的颜色、批注底色、脚注），
   用 JS 给一块加高亮、滚过去，`takeSnapshot` 画成 PNG：1.3 秒画完，窗口自始至终不可见，高亮在图里。
6. **MCP 总说明**：从 debug 版的小程序握手里取出现在的总说明，量出 1,404 个字符；5.3 节的草稿量出 1,817 个，`MCPChecks` 的几条规矩逐条核过。
   工具清单 18,015 个字符。
7. **UTI**：本机 md、markdown 是 `net.daringfireball.markdown`，docx、dotx、docm、pptx 都是系统声明的。

## 十四、查不到、没验证、靠推测的

- **自签名的 App 在别人机器上**：每个新版本是不是都要再放行一次、包里的小程序被 Claude Code 启动时会不会被单独拦、文件夹权限能不能跨版本留住、
  App Translocation 什么时候触发（苹果说规则没公开、而且变过）——都没在别人的机器或新用户上试过，放进 M10 的验收实测。系统提示框的原话没核到。
- **docx-preview** 没在本机跑过（调研的规矩不许运行下载的代码），能力是按它的 README 和源码判断的。
- **Quick Look** 里能不能搜索、选中 docx 的文字，没验证。
- **md4c**：遇到中文标点时自动链接到哪里结束、块的行号从指针推算准不准，M7 实测；脚注、表格、任务列表靠它的开关（核过 README）。
- **WebView 关掉页面脚本以后 `evaluateJavaScript` 还能用**：按苹果文档的说法，M7 实测确认。
- **GitHub 仓库改名的转发**：凭 GitHub 文档的已知说法，这个会话没抓到原文。
- **macOS 15 上**：md 的 UTI 是不是系统声明的、Quick Look 和 `AttributedString(markdown:)` 的表现，只在 macOS 26 上试过。
- **WPS、腾讯文档、Pages 导出的 docx** 有什么怪癖，没有样例，不知道。
- **撞名**：Snapwood 那个的下载量来自搜索摘要；商标只在网上检索过，没查正式数据库（7.1 节）。
- **各部分的行数和天数**是按现有模块、调研的估计和过去的 PR 类比的，不是量出来的。
- **Anthropic 的数据政策**：README 引的是 2026-11-15 看到的页面，政策会变；它没有一句话直说「本机 MCP 工具的结果会发给 Anthropic」。
- **许可证兼容**（11.1 节）是一般理解，不是法律意见。

## 出处

除了标明的，都是 2026-11-15 查的，当天打开过原页面。

- Gatekeeper：Apple 开发者新闻 2024-08-06，macOS Sequoia 不能再按住 Control 点开（https://developer.apple.com/news/?id=saqachfa ）；
  「仍要打开」（https://support.apple.com/en-us/102445 ）；按钮大约一小时内有效、要输登录密码（https://support.apple.com/guide/mac-help/mh40616/mac ）。
- App Translocation：苹果论坛 Quinn（https://developer.apple.com/forums/thread/724969 、https://developer.apple.com/forums/thread/732370 ）；
  Eclectic Light 2024-05-14（https://eclecticlight.co/2024/05/14/lost-in-translocation/ ）。
- 签名和文件夹权限：TN3127（https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements ）；
  苹果论坛 Quinn「TCC 按 designated requirement 记」（https://developer.apple.com/forums/thread/721745 ）。
- 公证：年费 99 美元（https://developer.apple.com/support/purchase-activation/ ）；中国区 App Store 内购 ¥688（https://apps.apple.com/cn/app/apple-developer/id640199958 ）；
  证书种类（https://developer.apple.com/help/account/reference/certificate-types/ ）；自签名的公证不了（https://developer.apple.com/documentation/security/resolving-common-notarization-issues ）；
  强化运行时和时间戳（https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution ）；
  notarytool 和 stapler（https://developer.apple.com/documentation/security/customizing-the-notarization-workflow ）。
- Homebrew：cask 必须过 Gatekeeper 检查（https://docs.brew.sh/Acceptable-Casks ）；2026-09-01 停用过不了的 cask（https://brew.sh/2025/11/12/homebrew-5.0.0 、
  https://github.com/Homebrew/homebrew-cask/pull/226573 ）。
- Claude 的要求：桌面版 macOS 13 起（https://support.claude.com/en/articles/10065433-install-claude-desktop ）；Claude Code macOS 13.0 起（https://code.claude.com/docs/en/setup ）；
  `claude mcp add` 的写法和 `~/.claude.json`（https://code.claude.com/docs/en/mcp ）；桌面版的 Code 页同时读几份配置（https://code.claude.com/docs/en/desktop ）；
  桌面版配置文件的位置（https://modelcontextprotocol.io/docs/develop/connect-local-servers ）。
- 隐私：工具结果回到对话（https://platform.claude.com/docs/en/agents-and-tools/tool-use/overview ）；隐私政策「成为你的输入」（https://www.anthropic.com/legal/privacy ）；
  训练数据和本机 MCP（https://privacy.claude.com/en/articles/10023580-is-my-data-used-for-model-training ）；2025-08-28 个人账号的训练选择和保留期
  （https://www.anthropic.com/news/updates-to-our-consumer-terms ）；Claude Code 的本机记录（https://code.claude.com/docs/en/data-usage ）；
  Anthropic 不审查 MCP 服务器（https://code.claude.com/docs/en/security ）。
- md4c 的扩展开关（脚注、表格、任务列表、删除线、宽松自动链接）：README（https://raw.githubusercontent.com/mity/md4c/master/README.md ，2026-11-16 查）。
- 撞名和开源项目（另一个会话 2026-11-15～16 查的）：
  - MUIN 的 Skyfolio：https://github.com/muin-company/skyfolio-releases 、https://skyfolio.space ；App Store 名字唯一：
    https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app ；Snapwood 的 SkyFolio：
    https://www.snapwoodapps.com/skyfolio-for-onedrive/ 、https://play.google.com/store/apps/details?id=com.snapwood.skyfolio ；
    SKFOLIO：https://markinton.com/trademark/skfolio-79432495 ；Sky 和 SkyDrive：https://www.engadget.com/2013/06/30/bskyb-wins-trademark-case-against-microsoft-over-skydrive-name/ 。
  - 许可证兼容：https://www.gnu.org/licenses/license-list.html 。
  - md4c：https://github.com/mity/md4c ；docx-preview：https://github.com/VolodymyrBaydalka/docxjs ；mammoth.js：https://github.com/mwilliamson/mammoth.js ；
    pandoc：https://github.com/jgm/pandoc ；CotEditor：https://github.com/coteditor/CotEditor ；IronCalc：https://github.com/ironcalc/IronCalc ；
    numfmt：https://github.com/borgar/numfmt ；cmark-gfm：https://github.com/github/cmark-gfm ；swift-markdown：https://github.com/swiftlang/swift-markdown ；
    MarkEdit：https://github.com/MarkEdit-app/MarkEdit ；SuperDoc：https://github.com/superdoc/docx-editor 。
