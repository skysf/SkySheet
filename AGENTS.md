# 给 AI 的说明

这个仓库的规矩、常用命令、现在做到哪，都写在 [CLAUDE.md](CLAUDE.md)。先读它，照它做。

还没做完的事记在 [docs/plans/remaining-work.md](docs/plans/remaining-work.md)：
- 开工前先读一遍。
- 第一次回复作者时，用两三句话提醒他还剩什么没做。

## Apple 开发者账号和签名（2026-11-25）

账号和 Developer ID 证书已经备好，可以开始做 Developer ID 签名和公证。这件事还没动手：
- 现在打的包仍用自签名的「Skylu Signing」（CLAUDE.md 硬规矩第 5 条）。
- 新方案第 13 条「先不公证」还没改。
- 公证要改哪些地方，见新方案 8.1 节末尾。

现状：
- **账号**：Apple Developer Program 已续费，个人账号。Team ID `26TVX3S9FR`，团队名 TIANYU LU。
- **签名身份**：`Developer ID Application: TIANYU LU (26TVX3S9FR)`，在 login 钥匙串里。
  - SHA-1 `1EC5EDA20BE8A7584E1744525669A3AFE69F8841`，2027-12-25 到期。
  - `security find-identity -v -p codesigning` 显示 1 valid（2026-11-25 核对过）。
- **本机**：没有 Xcode，只有命令行工具。证书链需要的 Developer ID G2 中间证书已经手动装好。
- **第一次用这把私钥签名会弹钥匙串授权窗口**，要作者点 Always Allow。
  - 第一次签之前先告诉作者。
  - 窗口没人点，codesign 就一直停在那里等。
