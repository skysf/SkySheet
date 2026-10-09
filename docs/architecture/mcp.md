# AI 接口（MCP）：让 Claude Code 读表、算数、写进新 sheet

> 已生效的长期约束（M4 落地，2026-10-09）。产品决定和理由见设计文档第九节、8.3 节、第 12、13、14、17、23 条。
> 结构和大部分规矩从 SrtFlow 搬来（它的 `docs/architecture/ai-control-mcp.md`），这里只写 SkySheet 自己的样子。

## 一、结构：三段，活只在 App 里做

```
Claude Code ──MCP（stdio，一行一条 JSON）──▶ skysheet-mcp ──Unix socket──▶ SkySheet（AIToolRouter → AI*Tools）
```

| 部分 | 在哪 | 管什么 |
| --- | --- | --- |
| `SkySheetMCPKit`（库） | `Sources/SkySheetMCPKit/` | MCP 协议（`MCPServerCore`，两代客户端）、工具清单（`MCPToolName` + 说明）、总说明、通道格式与 socket 收发、Claude Code 配置文件的改法。只依赖 Foundation，小程序和 App 共用 |
| `skysheet-mcp`（小程序） | `Sources/SkySheetMCP/`，打包进 `SkySheet.app/Contents/Helpers/` | 握手和工具清单当场回，工具调用转给 App；App 没开就 `open -g` 拉起来（带 `--launched-by-ai`） |
| App 这一头 | `Sources/SkySheet/AI/` | `AIBridgeServer` 听 socket → `AIToolRouter` 排队、穷举分派 → `AIWorkbookTools` / `AIReadTools` / `AIWriteTools`；`AISession` 管这一轮 |

1. **工具清单只有一份**（`MCPToolName`）：小程序回清单、App 分派都 switch 它，加工具漏了哪边编译不过。清单由小程序给，
   不为了列清单把 App 拉起来。
2. **stdout 只写 MCP 消息**，调试输出写 stderr。
3. **给模型看的文字只用英文**：总说明 ≤ 2,048 个字符（Claude Code 只读这么多，超了静默截掉）、前 512 个字符自成一体、
   目录里有每个工具名；每个工具说明也 ≤ 2,048。选项词表（数字格式预设）在 `MCPVocabulary` 抄一份，自检和
   `FormatPreset.allCases` 对账。都钉在 `Sources/SkySheetChecks/MCPChecks.swift`。
4. **工具自己的失败是工具结果**（`isError: true` + 一句英文），不是协议错误。只有没有这个工具 / 方法、解析不了才回 JSON-RPC 错误。
5. **只读的和改东西的分开**（`readOnlyHint`）：get_status、describe_sheet、read_range、query、evaluate、export_sheet、show 只读。

## 二、通道

- 一次调用一条连接（连上 → 一行请求 → 一行回答 → 断开），带通道版本号，对不上回「请重启 Claude Code」。
- socket：`~/Library/Application Support/ai.skylu.skysheet/mcp.sock`（按 bundle id 分；太长退到 /tmp，用 FNV 哈希，
  **不能用 `hashValue`**）。目录 0700、socket 0600、`getpeereid` 核用户号；还有人在听就不抢。
- 阻塞收发只在自己开的 `Thread` 上，不进 Swift 并发的协作线程池。
- 小程序拉起 App 那一次，结果前面加一句（`MCPBridge.relaunchNote`）：之前开着的工作簿都不在了。
- **被 AI 拉起来时不许弹模态框**（没人看着，调用会一直挂着）：不弹「打开」面板；恢复副本的提示等用户自己切到 SkySheet 再问，
  而且只问启动时就在的那些（这次运行里写的属于开着的文档，2026-10-09 端到端时抓到）。

## 三、工具在 App 里怎么做（每一条都是约束）

1. **写入只认 AI 的 sheet**（`AIContext.requireAISheet`）：原始 sheet 一律拒绝，话里直接说「add_sheet copy_from 复制一份再改」。
   「AI 的 sheet」= `SheetRole.ai`：AI 用 add_sheet 建的，或者用户在页签右键里标的。
2. **一个工具 = 一步撤销**：改工作簿只走 `AIContext.change` → `AIUndoGrouping.step` → `SheetSession.apply`。撤销管理器按事件
   自动分组，AI 的调用不是事件，不显式分组的话 AI 的每一步堆进同一组、⌘Z 一按全退（SrtFlow 踩过）。包的那一段不许有 await。
3. **AI 的 undo 撤不到用户的活**：`AISession` 记着撤销栈顶上连着几步是 AI 的；用户在 AI 之后改过就拒绝。
4. **这一轮**：AI 第一次改一个工作簿时存一份快照，30 秒没有新调用算结束；「撤销这一轮」= 换回快照（一步，⌘Z 能回来）。
   改到的格子淡紫高亮（`SheetSession.aiTouched`），下一轮开始时清掉，不存进文件。
5. **署名**：AI 建的 sheet 记客户端名（握手里的，可靠）和模型名（add_sheet 的 `model`，自报），页签紫色、小标写品牌；
   直接改到 AI 的 sheet 记「最后是谁改的」（只算直接改，跟着重算变了值的不算）。存在 `docProps/custom.xml` 的
   `SkySheet.AI.<sheetId>`，紧凑 JSON ≤ 255 个字符，保存核对也比它。
6. **从不覆盖文件**：save_copy 目标已经有就拒绝；写临时文件、读回来核对、`moveItem` 挪过去（碰到同名会失败，不会盖掉）。
   AI 改的只在内存里，用户按 ⌘S 才进文件（第十节第 1 条）。
7. **结果给数字给全**：值按正确舍入的 Double 给（`DecimalMath.double` 按十进制文字解析；`NSDecimalNumber.doubleValue`
   会把 8673.94 变成 8673.939999999999）。表格块的合计行（有 SUM 公式的最后一行）不算数据，不进统计、不进 SQL 表。
8. **SQL 只读**：每次现建内存库、装表、`PRAGMA query_only`，只许一条语句、`sqlite3_stmt_readonly`，最多跑 3 秒、回 500 行。

## 四、连接 Claude Code（设置 ⌘,）

- 走它自己的命令行 `claude mcp add --scope user skysheet -- <包里的小程序>`，**不直接改 `~/.claude.json`**（正在跑的
  Claude Code 会整份重写它）。同时往 `~/.claude/settings.json` 的 `permissions.allow` 加 `mcp__skysheet`（第一次改前备份成
  `.skysheet-backup`），只动这一条，文件格式不对就报错、一个字节不写。找不到命令行就「复制一段话」。
- **按原文改，不许整份解析再写回**（`JSONText`）：先让 JSONSerialization 验合法，再扫出每个值在原文里的位置，只在 allow
  列表末尾插进这一条（或删掉它和它的逗号）；新写的部分照文件自己的换行、缩进和冒号。没有要改的就不写。v0.3.0 用
  `JSONSerialization.data(.prettyPrinted, .sortedKeys)` 整份重写，作者的 settings.json 键全被重排（2026-10-09）。
  软链接写进它指向的文件（原子写会把链接换成普通文件）。都钉在 `Sources/SkySheetChecks/ClaudeCodeConfigChecks.swift`。

## 五、守卫和怎么测

- `MCPChecks`：真起小程序、旁边起假 App，两代协议各喂一遍（握手、清单、转发、客户端名、整数 id、版本错误、App 没开）；
  文字长度和只用英文；Claude Code 配置的增删。`AICoreChecks`：表格块、SQL、算公式不写、sheet 操作、样式、署名。
  `XLSXWriteChecks` 的 aiProperties 组：custom.xml 读写。
- 端到端（发版前）：打包好的 App，用 JSON-RPC 直接跟包里的小程序说话（和 Claude Code 一样），再用
  `claude -p … --mcp-config <临时配置> --strict-mcp-config --allowedTools mcp__skysheet` 真问一遍（不动用户自己的
  Claude Code 配置），看它的 MCP 日志（`~/Library/Caches/claude-cli-nodejs/<目录>/mcp-logs-skysheet/`）里没有 truncated。
  清单在 `docs/testing/m4-mcp.md`。
