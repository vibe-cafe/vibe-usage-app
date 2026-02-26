# Vibe Usage

macOS 菜单栏应用，自动追踪 AI 编程工具的 Token 用量和费用。数据同步到 [vibecafe.ai/usage](https://vibecafe.ai/usage)。

## 下载

从 [Releases](https://github.com/vibe-cafe/vibe-usage-app/releases/latest) 下载最新版 `Vibe-Usage.zip`，解压后将 `Vibe Usage.app` 拖入 Applications 文件夹。

> **首次打开**：macOS 可能提示"无法验证开发者"。右键点击 app → 打开 → 再次点击"打开"即可。

## 配置

1. 前往 [vibecafe.ai/usage/setup](https://vibecafe.ai/usage/setup) 生成 API Key
2. 打开 Vibe Usage，在弹出窗口中粘贴 API Key
3. 点击「开始使用」— 验证通过后自动开始同步

## 功能

- 菜单栏常驻，后台每 5 分钟自动同步数据
- 弹出窗口查看费用、Token 用量、趋势图表
- 支持按终端 / 工具 / 模型 / 项目筛选
- 可在菜单栏显示今日费用和 Token 数
- 支持开机自启动

## 系统要求

- macOS 14 (Sonoma) 或更高版本
- [Node.js](https://nodejs.org) (v20+) 或 [Bun](https://bun.sh)

## 从源码构建

```bash
git clone https://github.com/vibe-cafe/vibe-usage-app.git
cd vibe-usage-app
./scripts/build-app.sh
open "dist/Vibe Usage.app"
```

## 相关项目

- [@vibe-cafe/vibe-usage](https://github.com/vibe-cafe/vibe-usage) — 命令行同步工具
- [vibecafe.ai/usage](https://vibecafe.ai/usage) — Web 仪表盘

## License

MIT
