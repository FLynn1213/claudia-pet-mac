# macOS 版交接说明（给接手的 Claude / 自己看）

这个仓库是 kirito1207/claudia-pet 的 fork，`mac/` 是新写的 macOS 外壳。
`web/`、`characters/`、`plugin/` 是各平台共用的，**不要改**，除非 Windows/Linux 也一起改。

## 结构
- `mac/ClaudiaPet.swift`：主体，Swift + AppKit + WKWebView（约 1900 行）。`mac/FollowPick.swift`：跟随哪个 Claude 窗口的纯逻辑，单独拆出来好测试。`mac/build.sh` 编译并打包成 app（签名见下），`mac/install.sh` 编译后链接到 `~/.local/bin/claudia-pet`。
- 测试：`sh mac/test.sh`（`mac/tests/`，只测不碰系统接口的逻辑）。改了跟随逻辑先跑它。
- 外壳 ↔ 网页协议：注入 `window.chrome.webview.postMessage` 兼容层；网页上报 hitRects/motion/walk 等；外壳调用 JS：init、setCharacter、setSizes、setQuota、applyCharState、petMotion.*、show(...) 等。可对照 `linux/claudia/pet.py` 和 `app/src/`。
- `claudia://` 自定义协议：`app` 主机读 `web/`，`data` 主机读 `characters/`。
- 状态数据由 `plugin/hooks/register.ts` 写到 `~/.claudia/state/`，外壳轮询（按修改时间）。日志在 `~/.claudia/mac.log`，设置在 `~/.claudia/settings.json`。
- 坐标一律用全局左上角原点（和网页一致），只在 `moveTo` 里转成 Cocoa 的左下角。

## 已完成
动画与互动、拖动与甩出、跟随 Claude 窗口（CGWindowList，不要屏幕录制权限）、层级（只在 Claude 上面；Claude 在前台时用 .floating，避免点击闪烁）、额度条（只来自 Claude Code）、系统通知（需要 .app 包，退回 osascript）、设置页、随 Claude 启动/退出、右键「动作」菜单、菜单栏图标。

## 已知限制 / 决定
- 跟随哪个窗口（2026-11-20 修）：Claude 的授权 / 确认对话框是独立的大窗口，原来按「最前面的够大窗口」挑，会跳到对话框上、只能在对话框里活动。现在跟定一个窗口（`claudeWinID`）就一直跟，没了才挑最大的；对话框盖在主窗口上时（`claudeDialogOver`）不用 .floating，摆到主窗口和对话框之间，免得挡住对话框的按钮。逻辑在 `FollowPick.swift`，`mac/tests/FollowPickTests.swift` 用真机尺寸覆盖了这些情况（换回旧规则会挂 5 项）。实测过：Claude 窗口内的「信任此工作区」和系统的「想访问桌面」都不是 Claude 的独立窗口，她不动；独立的「Allow Claude to access this folder?」只在云端会话出现，没能当场复现。跟随窗口、对话框出现 / 关闭会写进 mac.log（「跟随：…」）。
- 三指拖移甩不出去：macOS 抬手后延迟发松手事件。试过放宽判定，延迟明显，已放弃，写进 README。
- 账户级用量同步：没有官方接口，已删除；额度只用 Code 标签的数据。
- 应用图标沿用原来的 `icon/AppIcon.png`（用户要求）；菜单栏图标也用它的彩色缩小版（2026-11-19 用户在三种方案里选的：单色线稿模板图 18 点下发灰发糊，已删掉；也比较过单色小花模板图）。菜单栏图标可在右键菜单里关。

## 待办（用户同意、按顺序）
1. ~~确认菜单栏图标效果~~：已换成彩色应用图标。
2. 聊天模式（非 Code）动画：已做，`ChatWatch`，默认关，右键「聊天模式动画」打开。
   - 信号（2026-11-19 用右键「诊断：记录 Claude 按钮 60 秒」确认）：用辅助功能读 Claude 窗口，回复时输入框旁「发送消息」按钮换成「停止回复」，回完换回。Code 标签里的停止按钮叫「停止」，不会混。英文界面的按钮名是猜的。
   - 查过不能用的：`main.log` 等日志没有逐条消息的记录；`IndexedDB/https_claude.ai_0` 只在打字、发送时写草稿，看不出回复状态。
   - 侧边栏里正在跑的对话标题后面会带「运行中」，能看到后台对话（含 Code），暂时没用。
   - 签名：ad-hoc 签名每次编译都变，辅助功能授权跟着失效。`build.sh` 现在优先用 `CLAUDIA_SIGN_ID`，其次用钥匙串里第一个「Apple Development」证书（按指纹，用户同意用自己的开发者证书），都没有才用 ad-hoc。
   - 授权：手动在列表里「+」容易加成别的副本（主目录和 worktree 各有一份 build）。现在开着聊天动画又没权限时，启动就调 `AXIsProcessTrustedWithOptions` 让系统弹请求，列表里加的就是正在运行的那一份。还不行就 `tccutil reset Accessibility io.github.claudia-pet`（要用户自己跑）。
   - 2026-11-19 在中文界面实测通过：日志里有「找到聊天输入框 → 开始回复 → 回复结束」，动画正常。
   - 待验证：长回复（> 1 分钟）、中途切走对话、点停止、英文界面。
3. 2026-11-19 补了：右键「摸摸头 / 戳一下」、退出时挥手道别（第一次多停几秒说明什么时候回来）、隐藏快捷键 ⌃⌥P / ⌃⌥H（Carbon `RegisterEventHotKey`）。
   未做：多开（原版最多 5 只，改动大）。不做：双击托盘叫出（mac 菜单栏单击即弹菜单）。
   Chat 模式额度：查过放弃。桌面端 `plan-usage-history.json` 只有百分比、没有重置时间，只在 24 小时内打开过 Claude 托盘用量时才轮询；用户名菜单里的「用量」页现拉服务器、本机不存。
4. 未验证：Code 会话进行中的工作动画、「需要你确认」通知。

## 环境注意
2026-11-19 已在本机（Swift 6.4，`-swift-version 5`）用 `sh mac/build.sh` 编译通过，没有错误和警告。
本仓库 fork 自原作者的 kirito1207/claudia-pet（`upstream`），工作在 `main` 分支。除 `mac/` 和根目录 README / NOTICE 里关于本仓库的说明外，不改原项目的文件，方便以后合并原项目的更新。
