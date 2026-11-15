# SkyFolio（原 SkySheet）方案：Word 和 Markdown、改名、给别人用

> 2026-11-15 起草，2026-11-16 按作者的拍板改定。**方案，待作者拍板**：「决定一览」里标了「已定」的是作者已经拍板的，其余待定。
> 这一轮只规划，不写产品代码；拍板以后再改设计文档（`docs/plans/2026-10-08-skysheet-design.md`，下称「设计」），
> 改哪几条见第十二节。先读「决定一览」（十分钟），后面各节是理由、做法和实测。
> 实验都在仓库外的临时目录里做，用的是自己造的文件，没碰作者的任何文件，做完删了（第十四节）。网上查的东西都写了出处，
> 查的日期是 2026-11-15（文末「出处」）。
>
> 作者已经定了的（2026-11-15、11-16）：只做一个 App，Word、md 都在里面开，每种文件有自己的界面；Word 能看、AI 能读；
> md 能看、能改、AI 能读；整体改名为 **SkyFolio**；以后给别人用，先不公证、继续自签名；更新靠用户自己去 GitHub Releases 下载；
> 继续只支持 Apple 芯片（设计第 3 条不变）；Windows 不做；第三方代码不通过包管理器引用，允许把许可证兼容的开源代码复制进仓库、
> 自己维护（设计第 7 条要改，12.1 节）。下文用 SkyFolio 指这个 App；还没改名的现状照旧叫 SkySheet。

## 决定一览

| # | 问题 | 状态 | 决定或建议 | 备选 | 理由 |
| --- | --- | --- | --- | --- | --- |
| 1 | 这一轮的范围 | 已定 | Word（.docx）只读、AI 能读；Markdown（.md）能看、能改、AI 能读；同一个 App、各有各的界面；PPT 只留位置。建议顺手把 .dotx、.docm 当 docx 开；.doc、.rtf、.odt 不做 | — | 作者定的。.doc 是另一种二进制格式，要再写一个解析器 |
| 2 | Word 怎么显示 | 待拍板 | 自己解析 docx → 自己的文档模型 → 生成 HTML → WebKit 显示，不分页；解析失败时退回 Quick Look 只看 | Quick Look；AppKit 的 NSAttributedString；自己排版（像 Word 一样分页） | 实测：NSAttributedString 不认样式，丢图片、脚注、批注、合并单元格；Quick Look 好看但是黑盒，没法按段高亮，也丢脚注、批注、修订。AI 本来就要一份自己的模型，显示用同一份，读到哪段就能高亮哪段。分页排版要上万行，对「看内容」帮助不大 |
| 3 | Markdown 怎么显示 | 待拍板 | 自己写解析器（CommonMark 常用部分 + GFM 的表格、删除线、任务列表、自动链接 + 脚注 + front matter），和 Word 共用模型和 HTML 显示；网上的图片默认不加载 | Foundation 的 `AttributedString(markdown:)`；从开源项目搬一个进来（等第十三节的调研） | 实测 Foundation 的认表格、代码块，但不认任务列表、脚注、front matter，中文句号会被吞进自动链接，不给原文位置，排版也还得自己做 |
| 4 | Markdown 的编辑器 | 待拍板 | NSTextView 编辑原文，自己写着色（用同一个解析器）；打开时是预览，点 Edit 进原文，也能左右并排；保存走六道保险全套；SkyFolio 不替用户改原文的任何写法 | 所见即所得；SwiftUI 的 TextEditor | 所见即所得要把排好的版面翻回原文，`*` 还是 `_`、缩进、空行这些写法保不住；TextEditor 在 macOS 15 上只能编纯文字，没法着色 |
| 5 | AI 能不能改 md | 待拍板（默认只读） | 这一轮 AI 只读，和设计第 12 条（原始数据对 AI 只读）一致 | AI 能改：用户先把这份文档标成「AI 可改」，改动只进内存、⌘S 才写、能整轮撤销；约 +1,000–1,500 行 | md 是用户自己的原文；先把用户自己改的那条路做稳 |
| 6 | AI 怎么读（MCP） | 待拍板 | 还是一个服务（改名后叫 `skyfolio`），加 3 个只读工具：`describe_document`、`read_document`、`find_in_document`；`get_status`、`open_file`、`show` 扩展到文档。总说明从 1,404 个字符变成 1,765 个（上限 2,048） | 另起一个服务；每种格式各一组工具 | 用户只连一次、只放行一次；工具不分格式，以后 PPT 不用再加工具名、不再占总说明 |
| 7 | 界面上怎么看出 AI 在读哪里 | 待拍板 | 这一轮 AI 读过的段落，左边画一道淡紫色竖线；`show` 跳过去并选中 | 只在 `show` 时高亮 | 和表格里「这一轮 AI 改过的格子淡紫色」是一个意思：用户看得见 AI 在看什么 |
| 8 | Word 表格导进 sheet | 待拍板 | 这一轮不加专门的工具：AI 用 `read_document` 按格子取，再 `add_sheet` + `write_cells` | `add_sheet` 加 `from_document_table`（约 300 行，要开着一个工作簿） | 现有工具已经走得通，常用了再加 |
| 9 | 设计第 14 条（不许用别的程序改用户文件） | 待拍板 | 只管「在 SkyFolio 里开着的文件」：总说明写「不许用别的程序改用户的 .xlsx/.csv、也不许改在 SkyFolio 里开着的文件」；开着的文件在磁盘上被改了，没有没保存的改动就先备份上一版再重新载入，有就按第六道保险先问 | 照搬到所有 .docx、.md；文档不管 | 总说明对整个会话生效，写「不许改 .md」会拦住 Claude Code 平时改 README；文档不管的话，用户在 SkyFolio 里没存的改动可能被别的程序冲掉 |
| 10 | 名字 | 已定（**待查重确认**） | 整体改名为 SkyFolio：App 名、bundle id `ai.skylu.skyfolio`、MCP 服务名 `skyfolio`、仓库 `skysf/SkyFolio`。放在 M5 和正在修的五批 bug 都合进去之后、给别人用之前（M6） | — | 作者定：它已经不只是表格。迁移步骤见第七节 |
| 11 | 模块名跟不跟着改 | 待拍板 | 管整个 App 的四个跟着改（`SkySheet`、`SkySheetMCP`、`SkySheetMCPKit`、`SkySheetChecks` → `SkyFolio…`）；表格引擎三个（`SkySheetCore`、`SkySheetFiles`、`SkySheetDisplay`）不改，「SkySheet」从此是 SkyFolio 里表格那一块的名字，和 `SkyDocs`、`SkyZip` 并列 | 全改成 `SkyFolio*`；全不改 | 表格引擎三个模块一万多行、被 import 114 处，改名只搅历史，而且它就是表格引擎；管整个 App 的不改，看代码的人会以为 App 还叫 SkySheet |
| 12 | 签名 | 已定 | 先不公证，继续用「Skylu Signing」自签名；README 和 DMG 里写清第一次打开怎么点（8.1 节） | — | 作者定。以后要公证需要什么，见 8.1 节末尾 |
| 13 | 更新 | 已定 | 用户自己去 GitHub Releases 下载；不做自动更新，也不做应用内检查更新。发版清单见 8.2 节 | — | 作者定 |
| 14 | 隐私 | 待拍板 | 不加崩溃报告和统计。SkyFolio 自己完全不联网；README 和第一次打开时说清楚 AI 读到的内容去了哪里 | 自己做崩溃上报（要自己架服务器） | 表格里是财务数据，崩溃报告可能带出格子内容；要服务器、要管别人的数据；用的人少，GitHub issue 加系统自己的崩溃日志够用 |
| 15 | 界面中文 | 待拍板 | 第一次给别人用的版本（M7）加简体中文，约 300 条文字 | 先英文，等有人要 | 作者和身边的人多半用中文；文字都已经是 `String(localized:)`，只是补翻译 |
| 16 | 搬进来的开源代码怎么管 | 待拍板（原则已定） | 放 `Vendor/<项目>/`，带原许可证和出处记录，一个项目一个 target；只收和 AGPL-3.0 兼容的许可证；搬之前审一遍，搬进来以后和自己的代码一样过自检和审查；上游的安全修复每次发版前逐个核（12.1 节） | — | 作者 11-16 定了「可以复制进来自己维护」；措辞和规矩是这里拟的 |
| 17 | 先做哪件 | 待拍板 | M5 收尾（含正在修的五批 bug）→ M6 改名 SkyFolio → M7 给别人用 → M8 Markdown 只读 + 共用底座 → M9 Word → M10 Markdown 编辑。M5 的验收不改；M7 的验收：新建的 macOS 用户从下载到问出一个问题，不用人帮 | 先做 Word、md，再给别人用；md 编辑提到 Word 前面 | 改名要动约 120 个文件，和修 bug 的分支同时做会到处冲突；名字和第一次打开的说明要在别人装之前定好；md 比 Word 简单，先用它把共用的部分做出来；先让两种文件都能看、AI 能读，再做要动保存的编辑 |

还要作者告诉我们的事实（不是方案）：

- 以后给谁用：几个朋友，还是公开给任何人（影响第 14、15 条和 README 写多细）。
- 平时的 Word 文件是什么软件出的（Word、WPS、腾讯文档、Pages）：测试样例要照着造，就像 xlsx 照着腾讯文档的怪癖做。

## 一、为什么现在要定这些

- 作者要同一个 App 能开更多种文件、每种有自己的界面，不像 Office 分成好几个 App。这一轮先做 Word 和 Markdown；
  PPT 以后做，现在留位置（6.3 节）。它已经不只是表格，所以整体改名为 SkyFolio（第七节）。
- 以后要给别人用：推翻设计第一节的「只给作者自己用」。先不公证、继续自签名，更新靠 GitHub Releases，所以第一次打开怎么点、
  README、隐私说明都要写清楚（第八节）；排序也跟着变（第十一节）。
- 现在在哪：M4 完成（v0.3.1），M5 打磨中（性能那一块 PR #10 已合，另有五批 bug 正在修）。M5 的验收「作者日常用一周没卡壳」还没到。

## 二、Word 和 Markdown：做到什么程度

### 2.1 Word（.docx）

| 内容 | 这一轮 | 界面上 | AI 读到什么 |
| --- | --- | --- | --- |
| 段落文字；字体、字号、粗斜体、下划线、删除线、颜色、突出显示 | 做 | 按 styles.xml 的继承算：文档默认 → 段落样式 → 字符样式 → 直接格式 | 文字；要的时候带粗斜体（Markdown 写法） |
| 标题 | 做 | 按样式的大纲级别（`outlineLvl`）或「heading N」认 | 目录树，按章节取 |
| 列表：项目符号、编号、多级 | 做 | 按 numbering.xml 算出编号的文字（1.、a)、一、……） | 编号照显示的写 |
| 表格：边框、合并单元格、表头行、表格套表格 | 做 | HTML 表格，`gridSpan` / `vMerge` 换成 colspan / rowspan | 按格子取，带合并信息 |
| 图片：嵌入的 png、jpeg、gif；浮动的 | 做 | 原图；浮动的放在它锚定的那一段，位置不追求和 Word 一样 | 图片编号和替代文字（AI 看不到图片内容） |
| 超链接、书签 | 做 | 外部链接用户点了才交给浏览器；书签在文档里跳 | 链接地址 |
| 脚注、尾注 | 做 | 正文里上标编号，文末列出，能来回跳 | 要的时候带上 |
| 批注 | 做 | 批注的范围淡黄底，鼠标停上去或在侧栏看作者、时间、内容 | 要的时候带上：谁、什么时候、挂在哪段 |
| 修订（插入、删除） | 做；默认「显示标记」，能切成「最终状态」 | 插入加下划线、删除加删除线，按作者分颜色 | 默认给最终状态的文字、并说明有修订；要的时候带上标记和作者 |
| 页眉页脚 | 做，每一节一份 | 每节开头、结尾各画一次，不按页重复 | 单独一类块 |
| 分页符、分节符 | 显示成一条分隔线 | — | 标出来 |
| 域（目录、页码、交叉引用） | 显示文件里缓存的结果 | — | 缓存的文字 |
| 文本框、形状里的字 | 字做，位置近似 | 放在锚定处的一个框里 | 文字 |
| 公式（OMML）、SmartArt、图表、嵌入的对象 | 不认识 | 显示文件里自带的替代图片（`mc:AlternateContent` 的 Fallback），没有就是占位 | 告诉 AI 这里有什么、读不了 |
| 分页、第几页、总页数 | 不做 | Word 的分页只有排版引擎算得准 | — |
| 编辑；AI 写 | 不做 | — | — |
| .dotx、.docm | 当 docx 打开（只读，宏不执行） | — | — |
| .doc（97–2003 的二进制）、.rtf、.odt、有密码的 docx | 不做，认出来明说打不开 | 有密码的 docx 和 xlsx 一样是 OLE 文件，`OPCPackage.classifyNonZip` 现成能认 | — |

「读不懂的原样保留」（硬规矩第 3 条）在只读的文档上变成：**读不懂的不许悄悄丢**。界面上画占位，AI 读到时被告知，
`describe_document` 列出这份文件里有哪些读不了的东西。

### 2.2 Markdown（.md、.markdown）

- 认：CommonMark 的常用部分（标题、段落、强调、行内代码、代码块、引用、列表、分隔线、链接、图片、自动链接），GFM 的表格、
  删除线、任务列表（预览里只显示勾选状态，要勾就改原文）、自动链接，外加脚注和开头的 front matter（显示成一个小信息框）。
- 不认、显示原文：HTML（不执行，当代码显示，第四节）、数学公式、Mermaid 图。
- 编码：UTF-8（带不带 BOM）、UTF-16、GB18030，直接用 csv 那套 `TextEncodingSniffer`（设计 7.3 节）；存的时候照原样写回（4.4 节）。
- 能改：改的是原文（4.3 节），保存走六道保险（4.4 节）。AI 默认只读（决定一览第 5 条）。
- 不做：所见即所得、代码语法高亮（以后要的话自己写几种语言的简单着色）、自动加载网上的图片。

### 2.3 和「Claude 自己直接读文件」比，在 SkyFolio 里开有什么用

Claude Code 自己能读 .md（就是文本）。读 .docx 要靠 Python（python-docx 一类的包，得先装），一般只拿到段落文字：
表格的合并、脚注、批注、修订多半丢了。Claude 桌面版的聊天根本读不了这台 Mac 上的文件。在 SkyFolio 里开：

1. **看的是同一份**。AI 读过哪段、引用哪段（块编号）界面上都能点过去；用户说「这段什么意思」，指的就是选中的那段
   （`get_status` 报选区），和表格里「我选中的这块」一样。
2. **读得全**。表格按格子给（带合并），脚注、批注（谁写的）、修订（谁改的）、页眉页脚都给；读不了的（公式、图表）也说出来。
3. **读得省**。先看目录（`describe_document`），再按章节取，几十页的文件不用整份塞进对话。
4. **文档和表格放在一起用**。合同（docx）里的条款和贷款表（xlsx）对照，Word 里的表格变成 sheet 里能算的数。
5. **改得放心**。Word 只读；md 在 SkyFolio 里改，有备份、崩溃恢复、外部改动先问。
6. **桌面版的聊天也能用**。

说实话，md 对 Claude Code 的增益不大（它自己读得很好），主要是 1、5、6。所以 md 的显示和 Word 共用一份，力气花在共用的部分上。

## 三、Word 怎么显示

### 3.1 四条路（2026-11-15 实测）

拿一份自己拼的测试 docx（第十四节：样式定义的标题、多级项目符号和编号、横向和纵向合并单元格的表格、嵌入图片、超链接、
脚注、批注、修订的插入和删除、页眉页脚、分页符、中文）分别走一遍：

| 路线 | 保真度（实测） | 工作量 | AI 读到哪段、界面高亮哪段 | 其他 |
| --- | --- | --- | --- | --- |
| A. 系统的 Quick Look（`QLPreviewView`；实测用 `QLThumbnailGenerator` 画成 PNG） | 中上：标题样式（字号、颜色）、编号（1. 2. a)）、图片、链接、页眉页脚都对。脚注、批注没有；修订不标（插入的当普通字，删除的不见了）；表格样式里的边框没画；不分页：分页符画成一个「□」字，页脚跟在正文后面 | 最小，几十行 | **做不到**：黑盒，没有按段滚动、高亮的接口；AI 那边还得另外解析一遍，两边对不上号 | 系统框架。真正画 docx 的是系统私有的 OfficeImport，换系统版本可能变样 |
| B. AppKit 的 `NSAttributedString` 读 docx（officeOpenXML） | 低：**不认 styles.xml**，标题全成了 12 号 Times；编号列表变成圆点；合并单元格没了，后面的格子还错了一列；图片、链接、脚注、批注、删除的修订、分页、页眉页脚全丢 | 小，几百行（NSTextView） | 能（NSTextView 按字符范围加临时属性、滚过去），但丢了的东西没法指 | 它是给 TextEdit 自己的 docx 往返用的：`textutil` 生成的 docx（全是直接格式）它读得很好，真实的 Word 文件不行 |
| C. 自己解析 + 自己排版（像 Word 一样分页） | 理论上最高：分页、每页的页眉页脚、页底的脚注 | 最大：断行、分页、表格跨页、浮动图片绕排，上万行，风险高 | 能 | 分页对「看内容、给 AI 读」帮助不大，不建议 |
| **D. 自己解析 + 生成 HTML + WebKit 显示（建议）** | 高：A 画得出的都画，再加上脚注、批注、修订标记、合并单元格和边框（实测 WebKit 画对了合并单元格、边框、图片、多级编号、插入删除的颜色）；不分页 | 中：docx 解析 2,000–3,000 行；共用的文档模型和 HTML 约 1,500 行（Markdown、PPT 也用） | **能**：每一块带 `data-block` 编号，JS 加高亮、滚过去（实测离屏截图里看得到高亮） | WebKit 是系统框架。AI 读的和用户看的是同一份模型。实测窗口不放上屏幕也能画成 PNG（1.3 秒，App 设成 `.prohibited`、不进 Dock），截图模式能照旧在后台跑 |

### 3.2 建议：路线 D，Quick Look 兜底

- AI 一定要有一份自己解析的模型（按章节取、按格子取、带块编号），A、B 都给不了。既然有了模型，显示用同一份，
  「AI 读到哪段、界面高亮哪段」就是顺手的事。
- 排版交给 WebKit：中文断行、表格、图片、选中复制、查找（`WKWebView` 自带查找）、缩放、打印都现成。
  不分页：要看「第几页」，用户去 Word、Pages。
- docx 解析出错（遇到我们不认识的结构）时，窗口退回 Quick Look 只看（几十行），AI 那边明说「这份读不了」。
- 生成的 HTML 不带任何外部资源，内容安全策略（CSP）只许本地图片；不执行文档里的任何东西。网页内的导航一律拦下：
  外部链接交给系统浏览器，而且只在用户点的时候。

## 四、Markdown 怎么显示、怎么编辑

### 4.1 显示：三条路

| 路线 | 实测（2026-11-15） | 工作量 | 原文位置、高亮 |
| --- | --- | --- | --- |
| Foundation 的 `AttributedString(markdown:)`（`.full`） | 认：标题、强调、行内代码、删除线、链接（相对路径按文件位置解析成 file://）、图片地址（不加载）、嵌套列表、引用、代码块（带语言）、**GFM 表格（带对齐）**、分隔线。不认：任务列表（`[ ] 待办` 当普通字）、脚注（`[^1]` 变成指向一个怪文件的链接）、front matter（变成一条分隔线加一个二级标题）、HTML（原样当字）。中文句号会被吞进自动链接：`https://example.org。` 的链接成了 `https://example.org.` | 解析省了，但转成 NSAttributedString 以后**块结构全没了**（段落之间连换行都没有），表格、列表、代码块全要自己排；还要绕上面那些坑：约 1,500 行 | 不给原文的行号；「这一块是原文第几行」要自己再对一遍，编辑时预览和原文对不上 |
| 自己写解析器 | CommonMark 常用部分 + GFM 表格、删除线、任务列表、自动链接（遇到中文标点就结束）+ 脚注 + front matter，全按我们要的来 | 1,500–2,000 行，加对照自检（照 CommonMark 规范的例子挑着写自己的用例） | 每一块带原文行号，现成：预览和原文并排时按它对齐，着色也用它 |
| WebKit 显示自己转出的 HTML | 这是「显示」那一半，和上面哪个解析搭都行 | HTML、样式表和 Word 共用 | 能（同 Word） |

建议：自己写解析器 → 共用的文档模型 → 共用的 HTML → WebKit。CommonMark 难的是强调的嵌套、懒续行、HTML 块这些边角；
看文件够用的子集不难，边角不对也只是显示差一点，不碰数据（存的永远是原文，4.4 节）。第十三节的调研如果找到许可证合适、
写得好的解析器，再和自己写比一次。

### 4.2 几样东西怎么显示

- **GFM 表格**：HTML 表格，按分隔行的冒号对齐；格子里的行内格式照常。AI 那边和 Word 的表格一样按格子取。
- **代码块**：等宽、保留空白、太宽就横向滚，不自动折行；记下语言但不着色。AI 拿到原文。
- **本地相对路径的图片**：按 .md 所在的文件夹解析（`../images/x.png` 也行），交给 WebKit 时走自己的 URL scheme：只放行真实存在的
  图片文件，有大小上限。图片在「文稿」「桌面」「下载」里时，第一次显示可能触发系统的访问询问（和设计第十一节说的
  文件夹权限是同一回事）。
- **网上的图片**：默认不加载，显示占位，点一下这一篇才加载。加载就等于告诉对方「有人在这台机器上看这份文件」。
- **链接**：http(s) 交给系统浏览器，只在用户点的时候；相对路径指向的 .md 在 SkyFolio 里打开；`#锚点` 在文档里跳
  （标题的锚点按 GitHub 的规则生成，中文照留）；别的协议不理。
- **HTML、数学公式、Mermaid**：当代码显示原文，不执行。

### 4.3 编辑器（决定一览第 4 条）

- **NSTextView 编原文**（AppKit，系统框架）。撤销重做、中文输入法、查找替换（自带的查找条）、大文件都现成。纯文本模式，粘贴进来的
  一律是纯文字。
- **系统的自动替换全部关掉**：智能引号、智能破折号、文本替换、自动纠错、智能插入删除、自动识别链接和数据。它们会悄悄改掉用户没打的字
  （`"` 变成 “ ”、`--` 变成 –），在 Markdown 里就是改了语法。原则：**原文里每一个字节，只有用户自己的按键能改**，SkyFolio 不重排、
  不格式化、不替换。
- **着色自己写**：用显示用的同一个解析器，按块（标题、代码块、引用、表格、列表）和行内（强调、代码、链接）给原文上颜色和字重。
  颜色只是显示用的属性，存的时候只写文字。打字时只重新算改到的那几块（解析器给行号），大文件也不卡。默认等宽字体，中文按系统回退。
- **预览和原文怎么切**：三种看法，工具栏一个分段按钮加菜单快捷键——「预览」（打开文件时默认，和 Word 一样的阅读窗口）、「原文」、
  「并排」（左原文右预览，滚动按块的原文行号对齐）。点「Edit」从预览进原文，免得看着看着误改。停手 0.3 秒刷新预览，按顶上那一块的
  编号保住滚动位置。
- 不用所见即所得：要把排好的版面翻回原文，写法保不住，违反「不认识的原样保留」。不用 SwiftUI 的 TextEditor：macOS 15 上只能编纯文字，
  没法着色。不用 WebKit 编辑：输入法、撤销都要自己接。

### 4.4 保存：六道保险在 md 上

md 是用户自己的文件，设计第十节的六道保险一条不少地适用，做法照 csv（设计 7.3 节：按原编码写、解回来逐字节核对）：

| 设计第十节 | md 上 |
| --- | --- |
| 1. 只有 ⌘S 写回原文件 | 一样：不自动存回原处（`autosavesInPlace` 为 false），窗口标题显示「已编辑」。AI 默认只读，没有写的工具 |
| 2. AI 没有覆盖原文件的工具 | 一样。AI 能改 md（决定一览第 5 条）的话，改动也只进内存，⌘S 才写 |
| 3. 先写临时文件、核对、再替换 | 按打开时认出来的编码和 BOM 编码 → 写到同一个文件夹里的临时文件 → 读回来和要写的字节逐字节比、再按原编码解回来和内存里的文字比 → 全对才原子替换。是软链接就写进它指向的文件（和 `AIClientConfig` 一样），原文件的权限照旧 |
| 4. 第一次覆盖前备份 | 一样，用 `BackupStore`（每个文件留 10 份） |
| 5. 崩溃恢复 | 一样，用 `RecoveryStore`：每 30 秒给没存的 md 写一份恢复副本（文字加编码、BOM、换行方式、原路径），下次启动问恢复不恢复 |
| 6. 文件被别的程序改过先问 | 一样：存之前比修改时间，对不上就问「另存为新文件 / 仍然覆盖（先备份别人改的那一版）/ 重新载入 / 取消」。没有没存的改动时，文件在磁盘上变了就先备份上一版、自动重新载入 |

原文照原样写回的几条（自检逐条钉住）：

- 编码、BOM 照原样。GB18030 和 UTF-16 都能写所有 Unicode 字符，不会有「原编码写不出来」的情况（csv 那边会有，是因为要兼容别的软件）。
- 换行：打开时记下是全 LF、全 CRLF、全 CR 还是混着的。全 CRLF 的文件，用户新敲的回车存成 CRLF；混着的不动。没改的行一个字节不变。
- 文末有没有换行照原样；不做 Unicode 规范化（é 和 e + U+0301 各是各的，和设计 8.2 节「缓存的键按标量比」同一个道理）。
- 自检：几种编码 × BOM × 换行方式的文件读进来不改直接存，逐字节相同；改一个字，只有那几个字节不同；核对失败时原文件不动；
  恢复副本能恢复。

规模：编辑器和着色 700–1,000 行，保存 400–600 行（大半复用 csv、备份、恢复副本现成的），自检约 500 行，合计约 2,000 行。

### 4.5 AI 改 md（可选，决定一览第 5 条）

- 默认只读，和设计第 12 条一致：md 是用户的原文。
- 真要让 AI 改：照表格的「AI 可改」做——用户在窗口里把这份文档标成「AI 可改」，AI 才能用一个新工具（比如 `edit_document`：替换某几块的原文、
  在某块后面插入）；改动只进内存，⌘S 才写；这一轮改过的块淡紫色、能整轮撤销；横幅照常。总说明要多一行（约 100 个字符，还剩 283）。
- 约 +1,000–1,500 行。

## 五、AI 怎么读（MCP）

### 5.1 工具

| 工具 | 新 / 改 | 只读 | 做什么 |
| --- | --- | --- | --- |
| `describe_document` | 新 | ✓ | 一份文档的概况：标题和文件信息（作者、时间）；目录树（每个标题的块编号）；段落、表格、图片、脚注、批注、修订各有多少；每张表的编号、行列数、所在章节；读不了的东西列表；用户正看着哪一块、选中了什么；md 有没有没存的改动 |
| `read_document` | 新 | ✓ | 读一段：按章节（标题的编号或文字）、按块编号的范围，或者一张表（`table="t2"` 按格子回，带合并信息）。文字用 Markdown 写法，每块前面带编号；`include` 可以要批注、脚注、修订标记。一次最多约 2 万个字符，多的给 `next` 接着读。md 读的是窗口里的版本（含没存的改动），结果里说明 |
| `find_in_document` | 新 | ✓ | 找字：回每一处的块编号和前后一小段；不给 `document` 就找所有开着的文档；最多回 100 处 |
| `get_status` | 改 | ✓ | 多一个 `documents` 数组（5.4 节）；`workbooks` 不变 |
| `open_file` | 改 | | 也开 .docx、.dotx、.docm、.md、.markdown |
| `show` | 改 | ✓ | 多收 `document` 和 `block`：滚到那一块、选中、窗口摆到前面但不抢键盘。`sheet` 从必填改成选填 |

- 三个新工具都收一个可选的 `document`（文件名或路径），规矩和现在的 `workbook` 一样：不给就用 AI 上次用过的那份，
  其次是最前面的窗口，只开着一份就是它。
- 不分格式：Word、Markdown、以后的 PPT 都用这三个。PPT 的一页就是一个「章节」，备注就是 `include` 的一种。
- 文件在磁盘上变了、重新载入以后，块编号可能变：下一次调用的结果前面加一句（和 `MCPBridge.relaunchNote` 一个做法），让 AI 重读目录。
- 改名以后服务名变成 `skyfolio`，工具的全名跟着变（`mcp__skyfolio__…`），老会话本来就要重连，所以这些改动不用照顾老会话的说明。

### 5.2 块编号和读出来的样子

- 编号按文档顺序：段落和标题 `b12`、表格 `t2`、图片 `i3`、脚注 `f1`、批注 `c4`。同一次载入里不变；界面、AI 都用它。
  md 编辑以后按新的内容重新编号，没动的块尽量保持原编号（按原文行号对）。
- `read_document` 回的文字大概是这样（AI 引用 `b16`，用户在界面上点得过去）：

```text
[b15] ## 1.2 表格
[t2] (table, 4 rows x 3 columns; read_document table="t2" for cells)
| 贷款类型 | 贷总额 | 年利率 |
| 商业贷款 | 1,000,000 | 3.10% |
[b16] 这一段有**加粗**、一个[超链接](https://example.com/)和一个脚注[^f1]。
```

- 按格子取的表格：`{"rows": [[...], ...], "merged": [{"row": 1, "column": 0, "rows": 2, "columns": 1}], "header_rows": 1}`，
  格子里都是显示的文字（数就是文字，要不要转成数由 AI 定，不替它猜）。

### 5.3 和表格工具放在一个服务里

- 一个服务：一个小程序、一个 socket、一次「Connect」、一条放行规则（`mcp__skyfolio`）。分开的话用户要连两次、放行两次，
  两边的连接、署名、这一轮都要各写一份。
- 守住总说明 ≤ 2,048 个字符（`MCPChecks` 钉着：长度、前 512 个字符点名 get_status / describe_sheet / add_sheet / write_cells、
  目录里有每个工具名、没有汉字）。现在 1,404 个字符。下面这份草稿量过是 **1,765** 个（名字按 8 个字母算，SkyFolio 正好 8 个），
  上面几条检查全过，还剩 283 个：

```text
SkyFolio shows the user's spreadsheets (.xlsx, .csv) and documents (.docx, .md) on their Mac; its windows show what
you work on. For sheets: get_status (open files, the user's selection) or open_file; describe_sheet to learn the
layout; read_range, query (SQL) or evaluate to get numbers; put results in a new sheet with add_sheet and write_cells;
show to point the user at them. For documents: describe_document for the outline, then read_document by section or
table, or find_in_document. Tool descriptions have the details.

Rules:
- Original sheets are read-only. Results go in new sheets (add_sheet). To change original data, add_sheet
  copy_from=<sheet> and edit the copy.
- Documents are read-only to you (the user may edit .md files here). Cite block ids such as b12 so the user can jump
  there; show selects them.
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
- Read documents: describe_document, read_document, find_in_document
- Point the user: show
```

  （这里为了排版折了行；量的是不折行的原文。）工具清单现在 18,015 个字符（自检上限 4 万），三个新工具约加 3,000。

### 5.4 get_status 怎么报不同种类的文件

`workbooks` 照旧，旁边加 `documents`；版本那一项的键从 `skysheet` 改成中性的 `app`：

```json
{
  "app": {"name": "SkyFolio", "version": "0.7.0", "built": "…"},
  "workbooks": [ "… 和现在一样 …" ],
  "documents": [{
    "document": "贷款合同.docx", "path": "/Users/…/贷款合同.docx", "kind": "docx", "current": true,
    "title": "个人住房贷款合同", "blocks": 312, "tables": 4, "unreadable": 1, "unsaved_changes": false,
    "user_is_on": "b45", "selection": {"blocks": ["b45"], "text": "第五条 利率……（最多 200 个字符）"},
    "reloaded_at": null
  }]
}
```

`kind` 现在是 xlsx / csv，文档加 docx、md（以后 pptx）。`current` 分开记：一个当前的工作簿、一个当前的文档。

### 5.5 Word 表格导进 sheet（可选，决定一览第 8 条）

- 不做专门的工具也走得通：`read_document table=…` 拿格子 → `add_sheet` → `write_cells`（一次最多 1 万格）。数要 AI 自己从文字转，
  合并要它自己用 `format_cells` 合。
- 做成 `add_sheet from_document_table={document, table}`：认数和日期照 csv 导入的规矩（设计 7.3 节，带 ¥ 和千分位的先当文字），
  合并照搬，署名照常。约 300 行加自检。前提是开着一个工作簿：现在没有「新建工作簿」的工具，要不要加是另一件事。
- 建议这一轮不做，看 AI 实际用得多不多。

### 5.6 第 14 条（决定一览第 9 条）

- 第 14 条的理由是「写回统一经过 SkySheet，才有撤销和保存安全」。md 能在 SkyFolio 里改以后，这个理由对开着的 md 也成立：
  用户没存的改动和别的程序写进去的会打架。Word 在 SkyFolio 里只读，开着的时候被别的程序改，会让用户看着旧的、AI 读着旧的。
- 但不能照搬到所有 .docx、.md：总说明对整个会话生效，写「不许改 .md」会拦住 Claude Code 平时改仓库里的 README。
- 所以改成「用户的 .xlsx/.csv，以及在 SkyFolio 里开着的文件，不许用别的程序改」（5.3 节草稿里那一句），AI 从 `get_status` 知道哪些开着。
- SkyFolio 这边：开着的文件在磁盘上变了（NSDocument 本来就能知道），没有没存的改动就先把打开时读进来的原字节存进备份（`BackupStore`），
  再重新载入、提示一句；有没存的改动就不动，存的时候按第六道保险问。

### 5.7 AI 读过的段落、show（决定一览第 7 条）

- 「这一轮」照旧按时间划分（30 秒没调用算结束，设计 8.3 节）。读文档的工具把读到的块记进这一轮，窗口里这些段落左边画一道
  淡紫色竖线；下一轮开始时清掉。横幅写「Claude 在读 · 读了 N 段」，没有「撤销这一轮」（没改东西）。
- `show document=… block=b12`：滚过去、选中、加深高亮，窗口摆到前面但不抢键盘（和表格的 `show` 一样）。
- 只画竖线不涂底色：AI 一口气读完全文时，整篇涂紫会很吵。

## 六、架构

### 6.1 一个 App 管几种文件

- Info.plist 的 `CFBundleDocumentTypes` 加两类：docx（`org.openxmlformats.wordprocessingml.document`，加 template、macroenabled，角色 Viewer）
  和 md（`net.daringfireball.markdown`，角色 Editor），`LSHandlerRank` 照旧 Alternate（不抢 Word、Pages、Typora、VS Code 的默认打开）。
  这几个 UTI 本机（macOS 26）系统都声明了；macOS 15 上没核实，md 那个再写一份 `UTImportedTypeDeclarations` 兜底（重复声明无害）。
- 三个文档类，各自的窗口：
  - `WorkbookDocument`（xlsx、csv）：不动，表格窗口。
  - `MarkdownDocument`（md）：原文 + 解析出的模型；窗口是阅读视图和原文编辑器（4.3 节）；保存走六道保险（4.4 节）。
  - `WordDocument`（docx，以后 pptx 用同一套只读的做法）：只读的模型；阅读视图；解析失败退回 Quick Look。
  - 阅读视图（WKWebView 加左边的目录、查找条、AI 横幅）md 和 Word 共用一份。
- 一张登记表（`DocumentKind`）：扩展名、UTI、用哪个文档类、哪个解析器、能不能改、哪组 AI 工具。`open_file`、打开面板、`get_status`、
  自检（Info.plist 和登记表对得上）都看它，加一种文件只改这一处。
- 只读要在文档类里做死：Word 窗口里 ⌘S、另存为、复原这些菜单不亮，`data(ofType:)` 直接报错；以后要导出（PDF）只写新文件（`NewFile`）。

### 6.2 模块：抽出来的、新加的、改名的

| 模块 | 现在 | 以后 | 为什么 |
| --- | --- | --- | --- |
| `SkyZip` | zip 读写 | 不动 | docx 和 xlsx 是同一种包装 |
| `SkyOPC`（新） | `SkySheetFiles/Package` 里的 `OPCPackage`、`XMLScanner`（现在是 internal，报错用 `XLSXError`） | 挪出来、改成 public，错误换成通用的 `PackageError`，`XLSXError` 包它 | Word、PPT 读包、读关系、读 XML 都用这一份 |
| `SkySheetCore`、`SkySheetFiles`、`SkySheetDisplay` | 表格引擎 | 名字不改（决定一览第 11 条）；`SkySheetFiles` 改成依赖 `SkyOPC`；`TextEncodingSniffer` 挪到共用的地方（md 也要认编码），md 的写回也借 csv 的编码写法 | 不复制第二份 |
| `SkyDocs`（新） | — | 文档模型（块、行内、表格、图片、脚注、批注、修订）、块编号、目录、查找、读给 AI 的文字、表格按格子、HTML 和样式表。只用 Foundation | Word、md、PPT 共用；和 AppKit 无关，自检能测 |
| `SkyWord`（新） | — | docx → 模型：样式继承、编号、表格合并、图片、脚注批注修订、页眉页脚、域 | |
| `SkyMarkdown`（新） | — | md → 模型（带原文行号）；着色用的行内扫描 | 显示、着色、AI 读都用这一份 |
| `SkySheetMCPKit` → `SkyFolioMCPKit` | 工具清单 | 加 `MCPDocumentTools`（三个工具的说明）；服务名 `skyfolio` | 清单还是只有一份（硬规矩第 6 条） |
| `SkySheetMCP` → `SkyFolioMCP` | 小程序 `skysheet-mcp` | `skyfolio-mcp` | |
| `SkySheet` → `SkyFolio`（App） | 表格窗口、AI 层 | 加 `Reader/`（阅读视图、和网页之间传话）、`Markdown/`（文档类、编辑器、着色、保存）、`Word/`、`AI/AIDocumentTools`；`AISession` 的「这一轮」从只认工作簿改成也认文档 | |
| `SkySheetChecks` → `SkyFolioChecks` | 自检 | 加 docx、md、HTML、md 存取往返、配置和目录迁移的自检 | |

- 表里改名的四行按决定一览第 11 条的建议写，那一条还待拍板。
- 新模块不带「Sheet」字样，统一「Sky + 哪一块」：`SkySheet*` 是表格、`SkyDocs` 是文档、`SkyZip`、`SkyOPC` 是底层。
- 估算：共用的模型和 HTML 约 1,500 行，md 解析 1,500–2,000 行，docx 解析 2,000–3,000 行，阅读视图和 AI 工具约 1,500 行，
  md 编辑和保存约 1,500 行，自检约 2,000 行。合计 10,000–11,500 行，比 M1（5,935 行）加 M2（2,675 行）多一点（第十一节）。

### 6.3 PPT 以后怎么接

- pptx 也是 OPC 包：`SkyOPC` 现成。幻灯片里的字是 DrawingML 的文本框，docx 的图片、文本框也是 DrawingML：这部分在 `SkyWord` 里
  就写成能共用的。
- 模型：一页是一个章节（标题 + 各个文本框的段落 + 表格 + 图片），备注单独一类块。AI 工具不用加（5.1 节）。
- 显示：另一种 HTML（每页按幻灯片的尺寸绝对定位、缩放），还是 WebKit、还是阅读视图。

### 6.4 Word 只读、md 能改：六道保险的边界

- md：六道保险全套（4.4 节）。
- Word 不写回，六道保险不用照搬，边界是：

| 设计第十节 | Word 上 |
| --- | --- |
| 1. 只有 ⌘S 写回原文件 | 没有写回。⌘S、另存为、复原的菜单不亮 |
| 2. AI 没有覆盖原文件的工具 | AI 对 Word 一个写的工具都没有 |
| 3. 先写临时文件、核对、再替换 | 不写。以后的导出只写新文件（`NewFile`），已经有就拒绝 |
| 4. 第一次覆盖前备份 | 不覆盖。改成：文件在磁盘上被改了，重新载入前备份上一版（5.6 节） |
| 5. 崩溃恢复 | 没有没存的改动，不用 |
| 6. 文件被别的程序改过先问 | 没东西要存，不用问：直接重新载入、提示一句；AI 下一次调用被告知 |

**边界**：哪一天 Word 也能改了，六道保险一条不少地搬过去。「只读」靠文档类里做死，不靠界面上藏按钮。

## 七、改名为 SkyFolio（决定一览第 10、11 条）

作者 2026-11-16 定：App 名 SkyFolio、bundle id `ai.skylu.skyfolio`、MCP 服务名 `skyfolio`、仓库 `skysf/SkyFolio`（名字查重还在另一个会话里做）。
现在仓库里 122 个文件、583 行提到 SkySheet / skysheet（`Sources` 里 90 行是字符串，129 行是 `import SkySheet…`）。

### 7.1 仓库里改什么

| 东西 | 现在 | 改成 | 说明 |
| --- | --- | --- | --- |
| App 名、可执行文件、图标 | `SkySheet`（Info.plist、`MainMenu`；界面文字和给模型看的说明里约 90 行字符串） | `SkyFolio` | 界面文字和给模型看的说明一起改 |
| bundle id | `ai.skylu.skysheet`（Info.plist；小程序和 App 里的默认值） | `ai.skylu.skyfolio` | 系统从此当它是另一个 App（7.2 节） |
| 打包时间的 Info.plist 键 | `SkySheetBuildDate` | `SkyFolioBuildDate` | `MCPBridge.appBuildDate` 跟着改 |
| MCP 服务名、小程序 | `skysheet`、`skysheet-mcp`、放行规则 `mcp__skysheet` | `skyfolio`、`skyfolio-mcp`、`mcp__skyfolio` | `MCPServerCore.serverName`；`get_status` 的版本键改成 `app`（5.4 节） |
| socket、备份、恢复副本、导出 | `Application Support/ai.skylu.skysheet/…`、`Caches/ai.skylu.skysheet/exports` | `ai.skylu.skyfolio/…` | 备份、恢复副本要搬（7.2 节）；导出是缓存，不搬 |
| 开发用的环境变量 | `SKYSHEET_MCP_SOCKET`、`SKYSHEET_MCP_NO_LAUNCH`、`SKYSHEET_MCP_APP`、`SKYSHEET_CHECK_OUTPUT` | `SKYFOLIO_…` | 只影响开发，文档跟着改 |
| 配置文件旁边的备份后缀 | `.skysheet-backup` | `.skyfolio-backup` | 老的备份留着不管 |
| 剪贴板类型、窗口位置的名字 | `ai.skylu.skysheet.cells`、`SkySheetWorkbook` | `ai.skylu.skyfolio.cells`、`Workbook` | 新旧版本之间复制粘贴会掉格式，无所谓 |
| 存进 xlsx 的 `<Application>` | `SkySheet` | `SkyFolio` | 只是记一笔谁写的 |
| **xlsx 里 AI 的 sheet 的标记** | `SkySheet.AI.<编号>`（`docProps/custom.xml`，已经写进了用户的文件） | **不改** | 它是文件格式，不是品牌：改了旧文件就认不出来，还得两种都读。「SkySheet」从此就是表格引擎的名字（决定一览第 11 条），说得通 |
| 脚本 | `build-app.sh`（`APP_NAME`、DMG 名、「首次打开必读」）、`make-icon.swift`、`check-all.sh` | `SkyFolio`、DMG 叫 `SkyFolio-<版本>-arm64.dmg` | 签名脚本不用改（不带名字）；证书不动（硬规矩第 5 条） |
| CI | `checks.yml` 里的 job 叫 `check-all` | **不改** | main 的保护规则按这个名字要求必须通过 |
| 文档 | CLAUDE.md、README、设计、`docs/architecture/mcp.md`、`docs/testing/*` | 名字、命令、`.build/arm64-apple-macosx/debug/SkyFolio` 这些路径 | 设计文档改标题和第 1 条，正文里的旧名字照实留着（历史） |
| 自检 | `ClaudeCodeConfigChecks`、`ClaudeDesktopConfigChecks` 里写死的 `/Applications/SkySheet.app/…`、`skysheet` | 换成 SkyFolio 的路径和服务名，再加迁移的用例（7.2 节） | |

### 7.2 作者机器上的迁移（SkyFolio 第一次启动时做）

现在只有作者一台机器装过 SkySheet。迁移做进 App 里（不让作者手动搬），做完给一句话的结果。

1. **备份和恢复副本**：`~/Library/Application Support/ai.skylu.skysheet/` 里的 `Backups/`、`Recovery/` 搬进 `ai.skylu.skyfolio/`（同名的子文件夹合并，
   重名的文件两份都留）。恢复副本的 json 里记的是原文件的路径，不受影响，搬完照常问要不要恢复。旧 SkySheet 还开着就先不搬
   （它可能正在写恢复副本），等它退出、下次启动再搬。`mcp.sock` 不动（旧 App 自己会清）。搬完在旧目录里留一个说明文件。
2. **偏好设置**：旧的域（`ai.skylu.skysheet`）里只有 AppKit 自己记的窗口位置和最近打开的文件（代码里没有用 `UserDefaults`），不搬，重来一次。
3. **Claude Code**：设置里那一行认得旧条目——`~/.claude.json` 里有 `mcpServers.skysheet` 就显示「连着旧的 SkySheet」，按钮变成「换成 SkyFolio」：
   先 `claude mcp add --scope user skyfolio -- <新的小程序>`，成功了再 `claude mcp remove --scope user skysheet`（先加后删，中途失败也不会两个都没有）；
   `~/.claude/settings.json` 的 `permissions.allow` 里加 `mcp__skyfolio`、删 `mcp__skysheet`，照旧按原文只动这两处、第一次改之前备份。
   找不到 `claude` 命令行就给「复制一段话」，两条命令都写上。
4. **Claude 桌面版**：`claude_desktop_config.json` 里 `mcpServers.skysheet` 原地换成 `skyfolio`，`command` 换成新的小程序，用户自己加的 `env`、`args` 留着；
   桌面版开着时照旧在它退出那一刻再写一遍（设计 9.5 节）。工具名变了，桌面版的「总是允许」要重新点，提示里说。
5. **旧 App**：迁移完提示「应用程序里还有 SkySheet，可以扔进废纸篓」；不替用户删。
6. **系统那边重来一次的**：文件夹权限（「文稿」「下载」「桌面」）再问一次——bundle id 变了，签名的 designated requirement 跟着变，
   系统按它记账（TN3127）；「打开方式」里设过的默认 App 要重设；最近打开的文件清空。作者自己编的版本没有隔离属性，不用去「隐私与安全性」放行。
7. **用户自己写的东西**：提示词、CLAUDE.md 里写过的 `mcp__skysheet__…` 没法替他改，发版说明里提一句。
8. 认旧条目、搬旧目录的代码留到 v1.0 再删：只有作者一台机器要迁移，但不知道他什么时候升级。

自检加的：两家配置里有旧条目 → 换成新的，别的字节一个不动、`env` 留着、备份只做一次；旧目录 → 搬过来、重名两份都留、旧 App 开着时不搬。

### 7.3 仓库改名

- GitHub 上把 `skysf/SkySheet` 改成 `skysf/SkyFolio`。GitHub 会把网页、git、API 的旧地址自动转到新仓库；**以后不能再建一个叫 SkySheet 的仓库**，
  建了转发就断（GitHub 文档的说法，这个会话没抓到原文，改之前再看一眼「Renaming a repository」）。本机的 `origin` 照样能用，顺手
  `git remote set-url` 改成新地址。
- 改名前开着的 PR、分支保护、必过的检查 `check-all` 都跟着仓库走；Release 的下载地址也会转。
- 本机的文件夹（`…/SkyStudio_APP_Master/SkySheet`）可以不改：作者和各个会话的工具里写着这个路径，改了要一起改。

### 7.4 什么时候改

M5 收尾、正在修的五批 bug 都合进 main 之后，给别人用（M7）之前，单独一个里程碑 M6：一个 PR，分两个提交（机械的改名；迁移和它的自检）。
理由：改名要动约 120 个文件，和修 bug 的分支同时做会到处冲突；名字要在别人装之前定死，装了以后每个人都要迁移一遍。

## 平台与分发

第八到十节。作者定了：给别人用，先不公证、继续自签名，更新靠 GitHub Releases；继续只支持 Apple 芯片；Windows 不做。

## 八、给别人用

推翻设计第一节的「只给作者自己用」。另有 Codex 在单独排查「换一个人、换一台机器、换一份文件就出事」的 bug，结果不经过这份方案；
这里引到的风险点到为止，都放进 M7 的验收里实测。

### 8.1 签名：先不公证，第一次打开怎么点（决定一览第 12 条）

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

还要在 M7 的新用户上实测的几件事（点到为止）：

- **每下载一个新版本，大概都要再走一遍 2、3 步**（推测：新下载的文件又带隔离属性，签名的 cdhash 也变了）。发版说明里提醒。
- **小程序会不会被单独拦**：Claude Code 直接启动包里的 `skyfolio-mcp`，它也带着隔离属性。会不会再弹一次「无法打开」，没验证。
- **文件夹权限能不能跨版本留住**：作者机器上靠的是固定的签名身份（设计第十一节）。别人机器上没有这把证书，designated requirement 只比证书的哈希，
  按道理照样留得住（推测），要实测。
- **App 要能认出自己被 translocate 了**（路径里有 `/AppTranslocation/`，或者在 `/Volumes/` 下面）：这时设置里的「Connect」不许点，告诉用户先拖进「应用程序」。约 50 行。

以后要公证时需要的（不在这一轮）：加入 Apple Developer Program（每年 99 美元，中国区 App Store 内购价 ¥688）；在开发者账号里建「Developer ID Application」
证书（自签名的证书公证不了）；`sign-app.sh` 加 `--options runtime`（强化运行时）和 `--timestamp`（现在是 `--timestamp=none`）；
`xcrun notarytool submit … --wait` 提交、`xcrun stapler staple` 把票据钉在 App 和 DMG 上（本机的命令行工具里两个命令都有）。代价：要花钱；
换签名身份后文件夹权限要重给一次（TN3127）；个人账号的证书上写的是作者的法定姓名。「Skylu Signing」照旧留给作者自用的版本和别的个人工具，
两把各钉各的。公证以后还能进 Homebrew 的官方 cask：它从 2026-09-01 起停用过不了 Gatekeeper 检查的 cask。

### 8.2 更新和发版（决定一览第 13 条）

不做自动更新，也不做应用内检查更新：SkyFolio 不联网（8.4 节）。用户从 GitHub Releases 下载新版、拖进「应用程序」替换旧的
（先退出 SkyFolio）；有 GitHub 账号的可以在仓库页面点 Watch → Custom → Releases 收到通知。用户想知道自己是哪一版：关于窗口，
或者问 AI（`get_status` 报版本和打包时间）。

发版清单（写进 `docs/` 一份，每次照着走）：

1. main 是绿的；这个里程碑的真机清单走过了（`docs/testing/`）。
2. 定版本号（小功能、修 bug 升最后一位，里程碑升中间一位）；`CFBundleVersion` 跟着递增（现在一直是 1；建议改成递增的整数，
   别的 App 和系统比较新旧时看它）。
3. 写发版说明（中文、英文各一份）：改了什么、已知问题、升级要注意的（改名、文件夹权限、每个新版本第一次打开都要放行）、第一次打开的步骤（链到 README）、
   DMG 的 SHA-256。
4. 在 main 的那个合并提交上打 tag：`git tag -a vX.Y.Z -m "…"`，推上去。
5. `VERSION=X.Y.Z scripts/build-app.sh` → `dist/SkyFolio.app` 和 `dist/SkyFolio-X.Y.Z-arm64.dmg`（签名只经 `sign-app.sh`，脚本里已经核对 designated requirement）。
6. `shasum -a 256 dist/SkyFolio-X.Y.Z-arm64.dmg`，填进发版说明。
7. `gh release create vX.Y.Z dist/SkyFolio-X.Y.Z-arm64.dmg --title "SkyFolio X.Y.Z" --notes-file <发版说明>`。
8. 第一次公开发版，以及打包、签名有改动的版本：在一个新建的 macOS 用户里，用浏览器从 Release 页面下载，照 README 走一遍第一次打开。
9. 搬进来的开源代码：发版前逐个看上游有没有安全修复（12.1 节）；包里和 DMG 里带上 `THIRD-PARTY-NOTICES`。

### 8.3 别人第一次用

- **运行要求**：Apple 芯片的 Mac，macOS 15 起。Claude Code、Claude 桌面版都要 macOS 13 起（官方文档），比我们低，不卡人。
- **引导**：第一次打开时一个欢迎窗口（约 200–300 行 SwiftUI）：SkyFolio 是干什么的；连接 Claude Code、Claude 桌面版的两个按钮（就是设置里那两行）；
  隐私一句话（8.4 节）；被 translocate 时提示先拖进「应用程序」。README 是完整版。
- **README**（中文、英文各一份）：下载和第一次打开（8.1 节，带截图）；打开文件；连接两家 AI；AI 能做什么、不能做什么（原始 sheet、Word 对 AI 只读，⌘S 才写回）；
  隐私；文件放在哪（`Application Support` 里的备份和恢复副本、`Caches` 里的导出、改过哪几个 AI 配置文件和它们的备份）；卸载（先在设置里 Disconnect 两家，
  再删 App 和那两个目录）；常见问题（每个新版本都要放行一次、为什么要拖进「应用程序」、`export_sheet` 要这台 Mac 能跑 Python）。
- **别人机器上会不一样的**（点到为止）：
  - `claude` 命令行装在哪：现在找 `~/.local/bin`、`~/.claude/local`、`/opt/homebrew/bin`、`/usr/local/bin`、`~/.npm-global/bin`、`~/.bun/bin`；用 nvm、volta、asdf
    这类装的找不到，会退到「复制一段话」。
  - Claude 桌面版的 Code 页同时读 `claude_desktop_config.json`、`~/.claude.json`、`.mcp.json`（官方文档）：两家都连了，Code 页里会不会出现两个
    `skyfolio`，没验证。
  - AI 第一次打开「文稿」「下载」「桌面」里的文件，系统会问要不要给 SkyFolio 访问权限：引导和 README 里先说一声。
- **界面语言**：现在只有英文；建议 M7 加简体中文（决定一览第 15 条）：266 处 `String(localized:)` 加 32 处 SwiftUI 里直接写的文字，约 300 条，
  照设计第 22 条用 `.lproj/Localizable.strings`。

### 8.4 隐私和信任（决定一览第 14 条）

要跟别人说清楚的（README 一节，欢迎窗口里一句话）：

- **SkyFolio 自己完全不联网**：代码里没有任何网络请求（搜过：没有 URLSession、Network 框架）；没有统计、没有崩溃上报、不检查更新。
  例外只有用户自己点的：链接交给浏览器，md 里网上的图片点了才加载。
- **AI 读到的东西去了哪里**：AI 用工具读到的格子、查询结果、文档段落，会作为工具结果回到对话里，随对话发给 Anthropic（Claude 的工具调用文档）；
  按 Anthropic 的隐私政策成为用户的输入。拿来训练模型这件事，个人账号（Free、Pro、Max，包括用这些账号的 Claude Code）由用户自己在隐私设置里选，
  选了允许的保留五年，不允许的 30 天（Anthropic 2025-08-28 的公告）；它的说明里还写着「本机 MCP 服务器的原始内容」不算训练数据，除非复制进了对话。
  Claude Code 还会在本机的 `~/.claude/projects/` 里留 30 天的对话记录。README 只写这几句、附链接，以 Anthropic 的页面为准（政策会变）。
- **SkyFolio 自己写哪里**：备份、恢复副本（`Application Support`）、导出的 csv（`Caches`）、两家 AI 的配置文件（只动自己那一条，改之前先备份）。
  用户的文件只有按 ⌘S 才写。
- **信任**：Anthropic 不审查任何 MCP 服务器（Claude Code 的安全文档）；SkyFolio 是开源的（AGPL-3.0），代码可以自己看。
- **不加崩溃报告和统计**：表格里是财务数据，崩溃时内存里的格子内容可能被带出去；自己做要架服务器、管别人的数据；用的人少，
  GitHub issue 加 macOS 自己的崩溃日志（`~/Library/Logs/DiagnosticReports`，用户看过再贴）够用。以后要的话可以加「复制诊断信息」：
  版本、系统、最近一次崩溃日志的路径，由用户自己看过、自己贴，SkyFolio 不发。

## 九、Intel 芯片：不做

作者 2026-11-15 考虑过，定了不做，设计第 3 条不变。当天顺手做过的实验留作记录：现在的代码不改一行就能编成 x86_64
（debug，0 个错误、0 个警告），在 Rosetta 下 9,461 项自检全过；唯一的差别是 loan.xlsx 里 RATE 的最大相对误差在两种芯片上
末几位不同（6.74e-11 和 6.48e-11），都在容差 1e-9 以内。

## 十、Windows：不做

2026-11-15 评估过，作者定了不做。

## 十一、里程碑

| 里程碑 | 交付 | 验收 | 规模（依据） | 版本 |
| --- | --- | --- | --- | --- |
| M5 打磨（进行中） | 已有的打磨，加正在修的五批 bug | 作者日常用一周没卡壳（不改） | — | v0.4.0 |
| M6 改名 SkyFolio | 第七节：仓库里的名字、bundle id、MCP 服务名；App 里的迁移（备份和恢复副本目录、两家 AI 配置里的旧条目）；仓库改名；文档 | 作者这台机器从 SkySheet 升上来：备份、恢复副本都在；Claude Code、桌面版各点一次就换成 `skyfolio`，配置里别的字节一个不动；`check-all` 绿；查重确认过 | 机械改名约 120 个文件、600 行上下；迁移 300–400 行加自检约 200 行。和「连接桌面版」那个 PR（#7，约 600 行）差不多 | v0.5.0 |
| M7 给别人用 | 第一次打开的引导和 README（中英文、截图）、认出 translocation、隐私说明、简体中文、发版清单、`CFBundleVersion` 递增 | 新建一个 macOS 用户（没有作者的证书、没有任何配置），用浏览器从 Release 下载，照 README：放行、打开 loan.xlsx、连两家 AI、问一个典型问题，不用作者帮；再发一个小版本照 README 升级一次。8.1 节那几件没验证的事在这里实测、记下来 | Swift 300–500 行，翻译约 300 条，文档为主。和 PR #7、#8 加起来差不多 | v0.6.0（第一次给别人用） |
| M8 Markdown 只读 + 共用底座 | `SkyOPC` 挪出来；`SkyDocs`、`SkyMarkdown`；阅读视图（WebKit）；3 个文档工具和 `get_status`、`open_file`、`show` 的扩展；截图模式能截文档 | 几份自己造的 md 和作者自己的 md（副本）显示对；AI 按章节读、引用块编号，界面点得过去；总说明 ≤ 2,048；`check-all` 绿 | 约 5,500–6,000 行（含自检），和 M1（5,935 行）差不多 | v0.7.0 |
| M9 Word 只读 | `SkyWord`（样式、编号、表格合并、图片、脚注批注修订、页眉页脚、域），Quick Look 兜底 | 一组造出来的 docx（Word、WPS、腾讯文档、Pages 各导出一份，内容是编的）和 Quick Look 的样子对照：表格、编号、批注、修订都对；AI 按格子读表格；作者自己的 docx（副本）走一遍 | 约 3,000–3,800 行（含自检），和 M3（3,819 行）差不多 | v0.8.0 |
| M10 Markdown 编辑 | 原文编辑器和着色、三种看法、六道保险、恢复副本 | 4.4 节的往返自检全过；真机：改、存、崩溃恢复、别的程序同时改了的四种选择都走一遍；存出来的文件在别的编辑器里打开一个字节不差（除了改的地方） | 约 2,000–2,500 行（含自检），和 M2（2,675 行）差不多 | v0.9.0 |

- 规模的依据：各里程碑合进 main 时 `Sources/` 的增减行数（M1 5,935、M2 2,675、M3 3,819、M4 4,382、PR #7 604、PR #9 3,225、PR #10 2,985），
  和这份方案估的新代码量对着比。时间：过去每个里程碑的开发在一到两天（git 记录：M1–M3 都在 10-08，M4 在 10-09，PR #10 在 11-14、11-15），
  规模相近的新里程碑大概也是这样，作者走真机清单的时间另算（推测）。
- M6 必须在五批 bug 之后；M7 必须在 M6 之后（名字要在别人装之前定）。M8 和 M9 的顺序可以对调（作者更急着要 Word 的话），代价是 Word 那一步
  要一起把共用的模型、阅读视图、AI 工具做出来，那一步会变大。M10 可以提到 M9 前面，看作者更急着要哪个。

## 十二、对现有设计的改动（拍板以后再改，这次不动设计文档）

### 12.1 设计第 7 条：依赖（作者 11-16 定了原则，措辞和规矩这里拟）

拟改成：

| # | 方面 | 决定 | 理由 |
| --- | --- | --- | --- |
| 7 | 依赖 | 不通过包管理器引用第三方库：`Package.swift` 里没有 `dependencies`，构建时不联网拉代码。允许把许可证和 AGPL-3.0 兼容的开源代码复制进仓库：放在 `Vendor/<项目名>/`，带原许可证全文和出处记录，一个项目一个 target；复制进来就是我们的代码，由我们维护，和自己写的一样过自检和审查。zip 自己写（压缩用系统的 Compression），查询用系统的 SQLite3 | 作者 2026-10-08 定「不引外部库」；2026-11-16 放宽：可以把别人的开源代码搬进来自己维护。代码都在仓库里，看得见、改得了，不会被上游的更新带着走，构建也不依赖网络 |

搬进来以后的规矩（写进设计第 7 条底下，CLAUDE.md 硬规矩第 4 条跟着改成「不通过包管理器引第三方库；复制进来的开源代码只放 `Vendor/`，规矩见设计第 7 条」）：

1. **能搬的许可证**：MIT、BSD（2 条、3 条）、ISC、zlib、Apache-2.0、MPL-2.0（没带「与次级许可证不兼容」声明的）、GPL-3.0 及以后、LGPL-3.0、AGPL-3.0、
   CC0 和 Unlicense 这类公有领域声明。**不搬**：GPL-2.0-only、没写许可证的（等于保留所有权利）、带「不许商用」「只许做好事」之类附加条件的、
   SSPL、BUSL 这类看得见源码但不自由的。拿不准的按 FSF 的许可证兼容列表核，还拿不准就不搬。（这是一般理解，不是法律意见。）
2. **放哪、怎么记出处**：`Vendor/<项目名>/` 下面三样：`LICENSE`（原文，一个字不改；有 NOTICE 的一起带）；`SOURCE.md`（上游地址、版本或 tag、
   提交哈希、复制的日期、复制了哪些文件、我们改了哪些地方和为什么、谁审的）；`Sources/`（代码）。我们改过的地方在代码里加注释
   「SkyFolio 改：……为什么」。`Vendor/README.md` 一张总表：项目、许可证（SPDX 写法）、上游提交、上次核对上游的日期。`Package.swift` 里
   每个项目一个 target（`path: "Vendor/<项目名>/Sources"`），我们的代码只通过它用。
3. **搬之前审一遍**（照常走 PR，Codex 或另一个会话审、作者看）：许可证对不对；把要搬的代码读一遍——从此是我们的：不联网、不往意料之外的地方写文件、
   没有统计；只用系统框架，自己不再依赖别的第三方库（依赖的要么也按这套规矩搬，要么不搬）；能在 Swift 6 语言模式下编（不行就单给这个 target
   降到 Swift 5 模式，在 `Package.swift` 里写原因，和设计第十一节的做法一样）；只搬用得到的部分；自己写自检，把我们用到的行为钉住。
4. **上游修了安全问题谁来跟**：作者是维护者，责任在我们。做法：作者的 GitHub 账号对每个上游仓库点 Watch（Releases、Security alerts）；
   发版清单里有一步（8.2 节第 9 步）：对总表里每个项目，看上游从记下的那个提交以来有没有安全公告或修复，有就单开一个 PR 搬过来，更新 `SOURCE.md`
   和总表的日期。解析别人文件的代码（docx、md）优先看：它们会读到别人发来的文件。Dependabot 看不到复制进来的代码，只能靠这一步。
5. **分发时带上版权声明**：MIT、BSD、Apache 这些要求分发二进制时带上版权声明。App 的关于窗口加「Acknowledgements」，包里和 DMG 里各放一份
   `THIRD-PARTY-NOTICES`，由 `build-app.sh` 从 `Vendor/*/LICENSE` 拼出来。
6. **守卫**：`check-all.sh` 加一条：`Vendor/` 下每个目录都有 `LICENSE` 和 `SOURCE.md`；`Package.swift` 里没有 `dependencies:`；`Vendor/` 以外不许出现
   搬来的代码（靠审查，脚本只查前两条）。

### 12.2 其余要改的条目

| 设计里 | 改成什么 |
| --- | --- |
| 第一节「要做什么」 | SkyFolio：给 AI 用的轻量 macOS 文件工具，开 xlsx、csv、docx、md；以后给别人用（不公证、自签名，GitHub Releases 下载）。典型问题加上「对照合同和表格」 |
| 第 1 条 名字 | App 名 SkyFolio、bundle id `ai.skylu.skyfolio`、MCP 服务名 `skyfolio`、仓库 `skysf/SkyFolio`；理由：已经不只是表格（2026-11-16）。xlsx 里的 `SkySheet.AI.` 标记照旧，SkySheet 是表格引擎的名字 |
| 第 3 条 平台 | 不变（作者 2026-11-15 确认继续只支持 Apple 芯片） |
| 第 4 条 签名 | 做法不变（自签名、不公证）；理由改成「给别人用也先不公证（2026-11-15）；第一次打开的步骤写进 README」；以后公证要什么见本方案 8.1 节 |
| 第 5 条 文件 | xlsx、csv 读写；docx 只读；md 读写 |
| 第 7 条 依赖 | 见 12.1 节 |
| 第 11 条 不做 | 加上：Word 编辑和分页显示、.doc / .rtf / .odt、md 所见即所得、自动更新和应用内检查更新、公证（暂不）、崩溃报告和统计（决定一览第 14 条拍板后） |
| 第 12 条 AI 的权限 | 加上：Word 和 md 对 AI 只读（AI 改 md 等决定一览第 5 条） |
| 第 14 条 Python | 范围改成「用户的 .xlsx/.csv，以及在 SkyFolio 里开着的文件」（决定一览第 9 条拍板后） |
| 第 15 条 保存 | 加上：md 也只有 ⌘S 写回，六道保险全套 |
| 第 16 条 用户编辑 | 加上：md 的原文编辑（4.3 节） |
| 第 19 条 测试数据 | 加上：docx、md 的样例只用自己造的（脚本生成或手写，或者用各软件导出一份内容是编的文件），作者的文件不进仓库 |
| 第 20 条 仓库流程 | 仓库改名 `skysf/SkyFolio`；CI 的 `check-all` 不改名 |
| 第 22 条 语言 | 中文的时间改成 M7（决定一览第 15 条拍板后） |
| 新增几条 | Word 和 md 的显示路线（决定一览第 2、3 条）；md 编辑器（决定一览第 4 条）；隐私：SkyFolio 不联网、不加统计（决定一览第 14 条） |
| 第三节 整体结构 | 模块表按 6.2 节；目录指引加 `Reader/`、`Markdown/`、`Word/` 和 `Vendor/` |
| 第八节 App | 新开两节：阅读视图、md 编辑器（设计里的 8.5、8.6 节，内容取本方案 3.2、4.3 节）；8.3 节「AI 在界面上」加「读过的段落画竖线」 |
| 第九节 MCP | 9.1 节第 7 条 socket 路径换新的 bundle id；9.2 节工具表加 3 个、改 3 个；9.4 节总说明换成 5.3 节的草稿；9.5 节「连接」加「认得旧条目并换掉」 |
| 第十节 保存安全 | 加：md 全套适用（4.4 节）；Word 的边界（6.4 节）；开着的文件在磁盘上被改了，先备份上一版再重新载入 |
| 第十一节 构建、签名、CI | 名字、DMG 名；发版清单（8.2 节）；`THIRD-PARTY-NOTICES`；公证留给以后（8.1 节末尾） |
| 第十二节 自检 | 加：docx、md 解析和 HTML 的对照；md 存取往返（4.4 节）；两家配置和旧目录的迁移；`Vendor/` 守卫 |
| 第十三节 里程碑 | M6–M10（第十一节） |
| 第十五节 已知不足 | 加：Word 不分页、读不了的元素只画占位；md 的 HTML、公式、Mermaid 只显示原文；网上的图片默认不加载；自签名，每个新版本第一次打开都要放行 |
| 变更记录 | 记 2026-11-15、11-16 这几次拍板 |
| 设计以外 | CLAUDE.md（名字、命令和路径、硬规矩第 4 条）、README、`docs/architecture/mcp.md`（名字、文档工具）、`docs/testing/` 加 M6–M10 的清单 |

## 十三、可以借用的开源代码（待调研）

另一个会话在调研，结果回来再补。补的时候每个候选写：许可证（能不能搬，12.1 节第 1 条）、要搬哪一部分、要改什么、和自己写比省多少、
维护负担（上游活不活跃、有没有安全问题的记录）。这份方案里可能受影响的几处：Markdown 解析（第四节，自己写约 1,500–2,000 行）、
docx 解析（第三节，约 2,000–3,000 行）、md 编辑器的着色（4.3 节）。搬还是写，等结果回来逐项比。

## 十四、实验记录

都在仓库外的临时目录里做，2026-11-15，这台 M1（macOS 26.5.2，命令行工具 Swift 6.3.3），后台跑、不弹窗口；用的文件都是自己造的，
做完全部删掉。

1. **造测试文件**：`textutil -convert docx` 从 HTML 转了一份（标题、列表、表格、图片、中文）——结果它写出来的 docx 是「压扁」的：没有 `<w:tbl>`（表格变成一段段文字）、
   列表符号是写死的字、没有样式和编号定义、图片没进去。所以又用 Python 标准库手拼了一份 docx：样式定义的标题、两级项目符号和编号、
   横向和纵向合并单元格的表格、嵌入 PNG、超链接、脚注、批注、修订（插入、删除）、页眉页脚（带 PAGE 域）、分页符、中文。
2. **NSAttributedString 读 docx**：小 Swift 程序逐段打印字体、列表、表格块、链接、附件。手拼的那份：所有段落都是 Times 12 号（不认样式），
   编号列表成了圆点，合并单元格没了、最后一行的「—」跑到了第二列，图片、链接、脚注、批注、删除的修订、分页、页眉页脚都没有，用到的属性只有字体和段落样式。
   `textutil` 那份（直接格式）读得很好。
3. **Quick Look**：`QLThumbnailGenerator` 画成 PNG 看。样式、编号、图片、链接、页眉页脚都对；脚注、批注没有；修订不标；表格边框没画；
   分页符画成「□」，页脚跟在正文后面（3.1 节）。
4. **AttributedString(markdown:)**：拿一份带 front matter、强调、删除线、相对和外部链接、自动链接、嵌套列表、任务列表、引用、代码块、GFM 表格、
   相对路径图片、分隔线、行内和块 HTML、脚注、公式的 md 解析（4.1 节）。另外：转成 NSAttributedString 以后整篇连成一行，块结构只剩属性。
5. **WKWebView 离屏**：App 设成 `.prohibited`，窗口不放上屏幕，载入手写的 HTML（合并单元格、边框、图片、多级编号、插入删除的颜色、批注底色、脚注），
   用 JS 给一块加高亮、滚过去，`takeSnapshot` 画成 PNG：1.3 秒画完，窗口自始至终不可见，高亮在图里。
6. **MCP 总说明**：从 debug 版的小程序握手里取出现在的总说明，量出 1,404 个字符；5.3 节的草稿量出 1,765 个，`MCPChecks` 的几条规矩逐条核过。工具清单 18,015 个字符。
7. **UTI**：本机 md、markdown 是 `net.daringfireball.markdown`，docx、dotx、docm、pptx 都是系统声明的。
8. **x86_64 编译和自检**：见第九节（作者已定不做 Intel，只留记录）。

## 十五、查不到、没验证、靠推测的

- **自签名的 App 在别人机器上**：每个新版本是不是都要再放行一次、包里的小程序被 Claude Code 启动时会不会被单独拦、文件夹权限能不能跨版本留住、
  App Translocation 什么时候触发（苹果说规则没公开、而且变过）——都没在别人的机器或新用户上试过，放进 M7 的验收实测。
- **系统提示框的原话**：「无法打开」那个框的确切文字没在网上核到原文，README 的截图以实测为准。
- **GitHub 仓库改名的转发**：凭 GitHub 文档的已知说法，这个会话没抓到原文。
- **macOS 15 上**：md 的 UTI 是不是系统声明的、Quick Look 和 `AttributedString(markdown:)` 的表现，只在 macOS 26 上试过。
- **WebKit 显示很大的 docx**（几百页）的速度没量。
- **WPS、腾讯文档、Pages 导出的 docx** 有什么怪癖，没有样例，不知道。
- **各部分的行数和天数**是按现有模块和过去的 PR 类比估的，不是量出来的。
- **Anthropic 的数据政策**：README 引的是 2026-11-15 看到的页面，政策会变；它没有一句话直说「本机 MCP 工具的结果会发给 Anthropic」，最接近的是工具调用文档和隐私政策里「成为你的输入」那句。
- **许可证兼容**（12.1 节第 1 条）是一般理解，不是法律意见。
- **名字查重**在另一个会话里做，结果没回来。

## 出处

都是 2026-11-15 查的；「抓过」是当天打开过原页面。

- Gatekeeper：Apple 开发者新闻 2024-08-06，macOS Sequoia 不能再按住 Control 点开（https://developer.apple.com/news/?id=saqachfa ，抓过）；
  「仍要打开」（https://support.apple.com/en-us/102445 ，抓过）；按钮大约一小时内有效、要输登录密码（https://support.apple.com/guide/mac-help/mh40616/mac ，抓过）。
- App Translocation：苹果论坛 Quinn（https://developer.apple.com/forums/thread/724969 、https://developer.apple.com/forums/thread/732370 ，抓过）；
  Eclectic Light 2024-05-14（https://eclecticlight.co/2024/05/14/lost-in-translocation/ ，抓过）。
- 签名和文件夹权限：TN3127（https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements ，抓过）；
  苹果论坛 Quinn「TCC 按 designated requirement 记」（https://developer.apple.com/forums/thread/721745 ，抓过）。
- 公证：年费 99 美元（https://developer.apple.com/support/purchase-activation/ ，抓过）；中国区 App Store 内购 ¥688（https://apps.apple.com/cn/app/apple-developer/id640199958 ，抓过）；
  证书种类（https://developer.apple.com/help/account/reference/certificate-types/ ，抓过）；自签名的公证不了（https://developer.apple.com/documentation/security/resolving-common-notarization-issues ，抓过）；
  强化运行时和时间戳（https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution ，抓过）；
  notarytool 和 stapler（https://developer.apple.com/documentation/security/customizing-the-notarization-workflow ，抓过）。
- Homebrew：cask 必须过 Gatekeeper 检查（https://docs.brew.sh/Acceptable-Casks ，抓过）；2026-09-01 停用过不了的 cask（https://brew.sh/2025/11/12/homebrew-5.0.0 、
  https://github.com/Homebrew/homebrew-cask/pull/226573 ，抓过）。
- Claude 的要求：桌面版 macOS 13 起（https://support.claude.com/en/articles/10065433-install-claude-desktop ，抓过）；Claude Code macOS 13.0 起（https://code.claude.com/docs/en/setup ，抓过）；
  `claude mcp add` 的写法和 `~/.claude.json`（https://code.claude.com/docs/en/mcp ，抓过）；桌面版的 Code 页同时读几份配置（https://code.claude.com/docs/en/desktop ，抓过）；
  桌面版配置文件的位置（https://modelcontextprotocol.io/docs/develop/connect-local-servers ，抓过）。
- 隐私：工具结果回到对话（https://platform.claude.com/docs/en/agents-and-tools/tool-use/overview ，抓过）；隐私政策「成为你的输入」（https://www.anthropic.com/legal/privacy ，抓过）；
  训练数据和本机 MCP（https://privacy.claude.com/en/articles/10023580-is-my-data-used-for-model-training ，抓过）；2025-08-28 个人账号的训练选择和保留期
  （https://www.anthropic.com/news/updates-to-our-consumer-terms ，抓过）；Claude Code 的本机记录（https://code.claude.com/docs/en/data-usage ，抓过）；
  Anthropic 不审查 MCP 服务器（https://code.claude.com/docs/en/security ，抓过）。
