# claudia-pet macOS 版

Windows 版的外壳（WPF + WebView2）换成了 Swift + AppKit + WKWebView。网页（`web/`）、立绘（`characters/`）、Claude Code 插件（`plugin/`）三个平台共用，数据目录也是同一个 `~/.claudia`。

## 安装

1. 装命令行工具（只要这个，不用装完整 Xcode）：`xcode-select --install`
2. 在仓库根目录：

```bash
sh mac/install.sh --connect
```

会编译到 `mac/build/claudia-pet`，建符号链接 `~/.local/bin/claudia-pet`（插件靠这个路径叫她出来），并接入 Claude Code 插件和 Claude 桌面端（MCP）。仓库装好后不要再挪位置。
不想改 Claude 的配置就不加 `--connect`，之后右键菜单里也能接入 / 撤销。改之前都会备份（`原文件名.bak-claudia-时间`）。

直接运行：`mac/build/claudia-pet`。日志：`~/.claudia/mac.log`，`CLAUDIA_DEBUG=1` 会写得更细。

## 卸载

```bash
sh mac/uninstall.sh              # 撤销两项接入、退出、删掉 ~/.local/bin/claudia-pet、编译结果和 ~/.claudia
sh mac/uninstall.sh --keep-data  # 同上，但保留设置和数据
```

仓库文件夹本身不删，不要了自己删掉。给过辅助功能权限的话，到「系统设置 → 隐私与安全性 → 辅助功能」里删掉 claudia-pet。

## 已做 / 没做

| 功能 | 状态 |
|---|---|
| 透明置顶窗口、人物动画、气泡、额度 | 做了（网页原样用） |
| 点击摸头、拖动、甩出去、碰边、走路 | 做了（物理在网页里算，外壳只挪窗口） |
| 点击穿透 | 做了：只在人物、气泡、名牌上收鼠标 |
| 读 Claude Code 状态 | 做了（`~/.claudia/state/*.json`，插件原样用） |
| 接入 Claude Code 插件 / 桌面端 MCP、`--ensure`、`--mcp` | 做了 |
| 右键菜单 | 做了：摸摸头、戳一下、动作、回默认位置、隐藏、待在、大小、通知、层级、额度样式、接入、退出（挥手道别再走） |
| 待在 Claude 窗口里（跟随窗口） | 做了（右键「待在」切换；默认在窗口右下角）|
| 设置页（右键「设置…」，和其他平台共用 settings.html）、系统通知 | 做了 |
| 右键「动作」菜单（按分组播放任意动作） | 已做 |
| 菜单栏图标（彩色应用图标，和右键菜单同一份，可在菜单里关掉） | 已做 |
| 聊天模式（非 Code）动画：回复时听 → 思考，回完开心 + 完成通知 | 做了，右键「聊天模式动画」打开，需要辅助功能权限；只验证过中文界面 |
| 隐藏快捷键 ⌃⌥P / ⌃⌥H（设置页「通用」里换或关掉） | 做了（Carbon 全局快捷键，不需要额外权限） |
| 多开 | 不做（暂时没必要） |
| 双击托盘图标叫出 | 不做：mac 菜单栏图标单击就弹菜单，菜单里有「显示」 |
| Chat 模式下刷新额度 | 做不到：额度只有 Code 插件写，桌面端的用量页从服务器现拉、本机不存（2026-11-19 查过 `plan-usage-history.json`，只在打开过 Claude 托盘用量时才轮询，也不更新） |
| 随 Claude 启动 / 退出 | 做了：接入后 Claude 一打开就叫她出来，Claude 关了她跟着退出（手动打开的不跟着退）|

## 代码

主体是 `ClaudiaPet.swift`（跟随窗口的挑选逻辑单独放在 `FollowPick.swift`，测试：`sh mac/test.sh`），和 Linux 版 `linux/claudia/*.py` 一一对应（`Pet` 类 ≈ `pet.py`，`SchemeHandler` ≈ `web.py`，`Connect` ≈ `claude.py`）。
坐标一律用「全局左上原点」，和网页、Windows / Linux 版一致；只在 `moveTo` 里换成 Cocoa 的左下原点。

## 已知限制

- **聊天模式动画要辅助功能权限**：外壳要读 Claude 窗口里「停止回复」按钮的出现和消失，只读按钮名，不读聊天内容。第一次在右键菜单里打开「聊天模式动画」时，系统会弹出授权请求，到「系统设置 → 隐私与安全性 → 辅助功能」里打开 claudia-pet 就行。目前只在中文界面上验证过。
- **签名和授权**：`build.sh` 优先用环境变量 `CLAUDIA_SIGN_ID` 指定的证书签名，没设就用钥匙串里第一个「Apple Development」证书，都没有才用 ad-hoc 签名。ad-hoc 签名每次编译都会变，辅助功能要重新授权：先在列表里删掉旧的 claudia-pet，必要时运行 `tccutil reset Accessibility io.github.claudia-pet`。
- **Chat 模式下额度不刷新**：额度只有 Claude Code 插件会写，只在 Code 会话里更新，和 Windows 版一样。
- **三指拖移（触控板）甩不出去**：这是 macOS 的特性，不是外壳的问题。
  三指拖移抬起手指后，系统要等一小会儿才发出「松手」事件，等它到的时候鼠标早已停了，而甩出去的速度只看松手前 150 毫秒的轨迹，所以会被当作轻放。
  用**单指按下触控板（物理按下去）再甩**、或者用鼠标，和 Windows 版一致，可以甩出去。三指拖移用来拖动、放置没有问题。
  试过放宽判定去迁就三指拖移，但抬手后要等一段时间才开始飞，手感不好，所以没有保留。
- 排查甩不出去时，看 `~/.claudia/mac.log` 里每次松手的那一行：「松手：速度约 … 像素/秒」。原版要求折算后不低于 500 才会甩出去，设置页「互动」里的「抛掷力度」可以放大它。
