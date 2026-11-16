# AI 接口（MCP）：让 Claude Code 和 Claude 桌面版读表、算数、写进新 sheet

> 已生效的长期约束（M4 落地，2026-10-09；同一天加了 Claude 桌面版的普通聊天；2026-10-14 加了 edit_rows_columns）。产品决定和理由见设计文档第九节、8.3 节、
> 第 12、13、14、17、23 条。
> 结构和大部分规矩从 SrtFlow 搬来（它的 `docs/architecture/ai-control-mcp.md`），这里只写 SkySheet 自己的样子。

## 一、结构：三段，活只在 App 里做

```
Claude Code ──MCP（stdio，一行一条 JSON）──▶ skysheet-mcp ──Unix socket──▶ SkySheet（AIToolRouter → AI*Tools）
```

| 部分 | 在哪 | 管什么 |
| --- | --- | --- |
| `SkySheetMCPKit`（库） | `Sources/SkySheetMCPKit/` | MCP 协议（`MCPServerCore`，两代客户端）、工具清单（`MCPToolName` + 说明）、总说明、通道格式与 socket 收发、AI 客户端配置文件的改法（`AIClientConfig` + `ClaudeCodeConfig` / `ClaudeDesktopConfig`）。只依赖 Foundation，小程序和 App 共用 |
| `skysheet-mcp`（小程序） | `Sources/SkySheetMCP/`，打包进 `SkySheet.app/Contents/Helpers/` | 握手和工具清单当场回，工具调用转给 App；App 没开就 `open -g` 拉起来（带 `--launched-by-ai`） |
| App 这一头 | `Sources/SkySheet/AI/` | `AIBridgeServer` 听 socket → `AIToolRouter` 排队、穷举分派 → `AIWorkbookTools` / `AIReadTools` / `AIWriteTools` / `AIRowColumnTools`；`AISession` 管这一轮 |

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
9. **版本和打包时间从 get_status 给**（`skysheet: {version, built}`）：模型看不到 MCP 握手里的 serverInfo，用户问「什么版本、
   什么时候的」只能从这里答，不然它会去网上搜（2026-10-14 桌面版的聊天）。版本读 Info.plist 的 CFBundleShortVersionString
   （和小程序报的 serverInfo 同一个读法，`MCPBridge.appVersion`），打包时间读 build-app.sh 写的 `SkySheetBuildDate`（UTC）；
   `swift run` 的开发版是 dev、没有打包时间。
10. **插删行列只在安全的表上**（`StructureLock`，设计 8.4 节）：表里或者文件别处有按位置指着格子、我们又读不懂的东西
   （图片、批注、条件格式、数据验证、图表……）就拒绝，话里说清楚是什么、让 AI 用 add_sheet copy_from 复制一份改副本
   （副本不带这些）。describe_sheet 对这样的 AI 的 sheet 给 `insert_delete`。改公式引用和界面上是同一份（`Workbook.shiftLines`），
   结果回改了几个公式、哪些变成了 #REF!。
11. **整列整行的区域**（C:E、3:5）：读、导出只到有内容的格子为止（`Sheet.contentRange`；腾讯文档给一大片空格子刷样式），
   改格式到刷过样式的地方为止（和界面一样）；get_status、show 的选区写成 C:E、3:5。
12. **工具说明改了以后，还开着的客户端用的是旧说明**（要重启客户端才换）：挪走的参数在 App 里照旧收（2026-10-14 把
   format_cells 的 column_width、freeze 挪到了 edit_rows_columns，format_cells 仍然认这两个，只是说明里不写了）。

## 四、连接 AI 客户端（设置 ⌘, 的「AI」一节）

两家各一行、一行一个按钮；读 `mcpServers.skysheet.command`、改文件的规矩（备份、软链接、原子写、没有要改的不写）
两家共用 `AIClientConfig`，按原文改 JSON 共用 `JSONText`。配置里写的都是**这一份 App 包里**的小程序路径。

### Claude Code（`ClaudeCodeSetup`）

- 走它自己的命令行 `claude mcp add --scope user skysheet -- <包里的小程序>`，**不直接改 `~/.claude.json`**（正在跑的
  Claude Code 会整份重写它）。同时往 `~/.claude/settings.json` 的 `permissions.allow` 加 `mcp__skysheet`（第一次改前备份成
  `.skysheet-backup`），只动这一条，文件格式不对就报错、一个字节不写。找不到命令行就「复制一段话」。
- **按原文改，不许整份解析再写回**（`JSONText`）：先让 JSONSerialization 验合法，再扫出每个值在原文里的位置，只在 allow
  列表末尾插进这一条（或删掉它和它的逗号）；新写的部分照文件自己的换行、缩进和冒号。没有要改的就不写。v0.3.0 用
  `JSONSerialization.data(.prettyPrinted, .sortedKeys)` 整份重写，作者的 settings.json 键全被重排（2026-10-09）。
  软链接写进它指向的文件（原子写会把链接换成普通文件）。都钉在 `Sources/SkySheetChecks/ClaudeCodeConfigChecks.swift`。

### Claude 桌面版的普通聊天（`ClaudeDesktopSetup`）

- 改 `~/Library/Application Support/Claude/claude_desktop_config.json` 的 `mcpServers.skysheet`
  （`{"command": <小程序>, "args": []}`，桌面版认的就是 command / args / env）。它的 Code 页跑的是 Claude Code，走上面那一行。
- 同样按原文只动这一项：没有就加在 mcpServers 末尾（没有 mcpServers 就补在根对象末尾），连着另一份只换 command 那个字符串
  （用户加的 env 留着），断开只删这一项（mcpServers 空了留着 `{}`）。格式不对一个字节不写。
- **备份连权限一起复制**（`copyItem`）：这个文件是 0600、里面有账号的东西，写一份新文件会变成 0644。
- **它开着时改的会被它盖掉**：桌面版启动时读一次整个文件，之后每次存偏好都把内存里那份整份写回、不重读（一天十几次，
  开 Code 会话就会写）；退出时不写；mcpServers 只在启动时读（2026-10-09，Claude 2.31226.0，读代码和
  `~/Library/Logs/Claude/main.log` 的「Config file written」确认）。所以：
  - 点的时候它没开：直接改，状态「Connected」。
  - 它开着：先改，记下要的结果（`pending`），状态「Restart Claude to finish」；听 `NSWorkspace.didTerminateApplication`，
    bundle id 是 `com.anthropic.claudefordesktop` 就照 `pending` 再写一遍（已经是这样就不写）。要 SkySheet 那时还开着，
    提示里说了；没赶上的话设置里显示没连上，再点一次。
  - 不替用户退出 Claude：会打断它正在跑的 Code 会话（我们自己就常在里面）。
- 「总是允许」存在桌面版自己那里，写不了：连上后的提示告诉用户在对话里点、或在它的 Connectors 设置里一次设好。
- 钉在 `Sources/SkySheetChecks/ClaudeDesktopConfigChecks.swift`（照桌面版自己写的样子逐字节比、备份权限）。

## 五、守卫和怎么测

- `MCPChecks`：真起小程序、旁边起假 App，两代协议各喂一遍（握手、清单、转发、客户端名、整数 id、版本错误、App 没开）；
  文字长度和只用英文。`ClaudeCodeConfigChecks`、`ClaudeDesktopConfigChecks`：两家配置文件的增删。`AICoreChecks`：表格块、
  SQL、算公式不写、sheet 操作、样式、署名。`XLSXWriteChecks` 的 aiProperties 组：custom.xml 读写。
- Claude 桌面版没法在自检里重启：发版前在真机上按清单连一遍（桌面版开着、没开各一次）。别在桌面版的 Code 页里让 AI
  替你退出 Claude：那个会话会一起被关掉。
- 开发时调 App 这一头、又不想动装着开着的那一份：App 和小程序都认 `SKYSHEET_MCP_SOCKET`，让编出来的 App 在别的 socket 上听
  （路径不能超过 103 个字节，放 /tmp），小程序加 `SKYSHEET_MCP_NO_LAUNCH=1` 连它。光秃秃的 debug 可执行文件没有 Info.plist、
  打不开 xlsx：拷进一个临时的 .app 外壳（`packaging/Info.plist`，bundle id 换一个，偏好设置不混）再跑。恢复副本、备份的
  目录不跟 bundle id 走（`SafetyFolders`），测完杀掉它以后，把它写进 `Recovery/` 的那几份（json 里的 originalPath 指着测试文件）
  删掉，不然装着的那一份下次启动会问要不要恢复（2026-10-14）。
- 端到端（发版前）：打包好的 App，用 JSON-RPC 直接跟包里的小程序说话（和 Claude Code 一样），再用
  `claude -p … --mcp-config <临时配置> --strict-mcp-config --allowedTools mcp__skysheet` 真问一遍（不动用户自己的
  Claude Code 配置），看它的 MCP 日志（`~/Library/Caches/claude-cli-nodejs/<目录>/mcp-logs-skysheet/`）里没有 truncated。
  清单在 `docs/testing/m4-mcp.md`。
