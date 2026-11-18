// claudia-pet macOS 版外壳（对应 Windows 版 app/ 的 WPF + WebView2、Linux 版 linux/claudia/ 的 GTK + WebKitGTK）。
// 网页（web/）、立绘（characters/）、Claude Code 插件（plugin/）和三个平台共用，数据目录同为 ~/.claudia。
// 目前只做「待在桌面上」：透明置顶窗口 + WKWebView，拖动 / 飞行 / 走路由网页算、这里按回来的位置挪窗口。
import Cocoa
import WebKit
import Darwin
import UserNotifications
import Carbon.HIToolbox

// MARK: - 路径、日志、JSON

let fm = FileManager.default
let homeDir = NSHomeDirectory()
let appName = "claudia-pet"
let schemeName = "claudia"

func envVar(_ k: String) -> String? {
    guard let v = ProcessInfo.processInfo.environment[k]?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
    return v
}

let dataDir = envVar("CLAUDIA_DATA_DIR") ?? homeDir + "/.claudia"
let stateDir = envVar("CLAUDIA_STATE_DIR") ?? dataDir + "/state"
let runDir = dataDir + "/run"

/// 可执行文件的真实路径（跟着符号链接走）
let exePath: String = {
    let p = Bundle.main.executablePath ?? CommandLine.arguments[0]
    return URL(fileURLWithPath: p).resolvingSymlinksInPath().path
}()

/// 安装目录 = 仓库根目录：从可执行文件往上找，直到有 web/index.html
let installRoot: String = {
    if let e = envVar("CLAUDIA_INSTALL") { return e }
    var url = URL(fileURLWithPath: exePath).deletingLastPathComponent()
    for _ in 0..<8 {
        if fm.fileExists(atPath: url.appendingPathComponent("web/index.html").path) { return url.path }
        url.deleteLastPathComponent()
    }
    return fm.currentDirectoryPath
}()

func readText(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }

func readJSON(_ path: String) -> [String: Any]? {
    guard let d = fm.contents(atPath: path) else { return nil }
    return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
}

func writeJSON(_ path: String, _ obj: Any, pretty: Bool = false) throws {
    let url = URL(fileURLWithPath: path)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var opts: JSONSerialization.WritingOptions = [.withoutEscapingSlashes]
    if pretty { opts.insert(.prettyPrinted) }
    let d = try JSONSerialization.data(withJSONObject: obj, options: opts)
    try d.write(to: url, options: .atomic)
}

/// 任何 JSON 值（含字符串、数字这种「片段」）转成能直接拼进脚本的文本
func js(_ v: Any) -> String {
    if let s = v as? String {
        if let d = try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes]),
           let t = String(data: d, encoding: .utf8) { return String(t.dropFirst().dropLast()) }
        return "\"\""
    }
    if let b = v as? Bool { return b ? "true" : "false" }
    if let n = v as? Double { return n.isFinite ? String(n) : "0" }
    if let n = v as? Int { return String(n) }
    if let d = try? JSONSerialization.data(withJSONObject: v, options: [.withoutEscapingSlashes]),
       let t = String(data: d, encoding: .utf8) { return t }
    return "null"
}

let debugOn = envVar("CLAUDIA_DEBUG") != nil
func log(_ text: String) {
    let f = dataDir + "/mac.log"
    try? fm.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
    if let a = try? fm.attributesOfItem(atPath: f), (a[.size] as? Int ?? 0) > 1_000_000 { try? fm.removeItem(atPath: f) }
    let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm:ss "
    let line = df.string(from: Date()) + text + "\n"
    if let h = FileHandle(forWritingAtPath: f) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
    else { try? line.write(toFile: f, atomically: true, encoding: .utf8) }
    if debugOn { FileHandle.standardError.write(line.data(using: .utf8)!) }
}

func appVersion() -> String { (readText(installRoot + "/VERSION") ?? "0").trimmingCharacters(in: .whitespacesAndNewlines) }

// MARK: - 设置（~/.claudia/settings.json，和 Windows / Linux 版同一份格式）

var settings: [String: Any] = readJSON(dataDir + "/settings.json") ?? [:]
func saveSettings() { try? writeJSON(dataDir + "/settings.json", settings) }
func settingOn(_ k: String) -> Bool { (settings[k] as? Bool) ?? true }   // 没存过算开
func settingFlag(_ k: String) -> Bool { (settings[k] as? Bool) == true }
func settingNum(_ k: String, _ lo: Double, _ hi: Double, _ def: Double) -> Double {
    if let v = settings[k] as? Double, v.isFinite { return min(max(v, lo), hi) }
    return def
}

// MARK: - 角色清单（对应 Store.Manifest）

let charactersDir = installRoot + "/characters"

func urlFor(_ parts: [String]) -> String {
    var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
    return "\(schemeName)://data/characters/" + parts.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }.joined(separator: "/")
}

func buildManifest() -> [String: Any] {
    var chars: [String: Any] = [:]
    let dirs = ((try? fm.contentsOfDirectory(atPath: charactersDir)) ?? []).sorted()
    for cid in dirs {
        let d = charactersDir + "/" + cid
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: d, isDirectory: &isDir), isDir.boolValue, var info = readJSON(d + "/character.json") else { continue }
        var poses: [String: [String]] = [:]
        var blink: Any = NSNull(), blinkBase: Any = NSNull()
        let files = ((try? fm.contentsOfDirectory(atPath: d)) ?? []).sorted()
        for f in files {
            let ext = (f as NSString).pathExtension.lowercased()
            guard ext == "webp" || ext == "png" else { continue }
            let stem = (f as NSString).deletingPathExtension
            if ["portrait", "portrait-card", "avatar"].contains(stem) { continue }
            let u = urlFor([cid, f])
            if stem == "idle-blink" { blink = u; continue }
            if stem == "idle" { blinkBase = u }
            poses[String(stem.split(separator: "-", omittingEmptySubsequences: false).first ?? ""), default: []].append(u)
        }
        if poses["idle"] == nil && poses["default"] == nil { continue }
        var sheets: [String: String] = [:]
        let anim = d + "/anim"
        for f in ((try? fm.contentsOfDirectory(atPath: anim)) ?? []).sorted() where (f as NSString).pathExtension.lowercased() == "webp" {
            sheets[(f as NSString).deletingPathExtension] = urlFor([cid, "anim", f])
        }
        if let custom = (settings["names"] as? [String: Any])?[cid] as? String, !custom.trimmingCharacters(in: .whitespaces).isEmpty {
            info["name"] = custom.trimmingCharacters(in: .whitespaces)
        }
        info["poses"] = poses; info["blink"] = blink; info["blinkBase"] = blinkBase; info["sheets"] = sheets
        chars[cid] = info
    }
    return ["characters": chars]
}

// MARK: - 动作菜单数据（从 linux/claudia/actions.py 搬来，两边改要一起改）

let actionGroups: [(String, [String])] = [
    ("日常", ["idle", "hum", "stretch", "yawn", "sleeping", "clawd"]),
    ("工作", ["listening", "thinking", "reading", "searching", "writing", "running", "delegating", "compact", "busy_left", "busy_right", "swamped_left", "swamped_right", "asking", "sorry"]),
    ("心情", ["happy", "proud", "surprised", "oops", "annoyed", "puffed", "redhot", "sulk", "coaxed", "forgiven"]),
    ("互动", ["pat", "pout", "bye", "bonk", "stagger", "fallen", "faceplant", "dizzy"]),
    ("问候", ["greet_morning", "greet_noon", "greet_afternoon", "greet_evening", "greet_night"]),
    ("小动作", ["look", "tap", "cube", "bubbles", "pen_spin", "finger_count", "nails", "scratch", "eye_rub", "tummy", "toes", "leg_bounce", "hand_flick", "wrist_roll"]),
    ("Claude 梗", ["token", "mutter", "mutter_lazy", "abacus", "gamer"]),
    ("才艺", ["cards", "dove", "flower", "bookspirit", "animals", "butterflies", "juggle", "flute", "violin", "leaf_flute", "glass_harp", "air_guitar", "music_box", "woodfish", "dance_skirt", "dance_otaku", "dance_swing", "curtsy", "dressup"]),
    ("玩耍", ["toycar", "update", "watergun", "gomoku", "top", "cat", "shuttlecock", "rockinghorse", "pagebeat", "jenga", "dandelion", "forehead_flick", "bubble_wrap", "skip_stone", "diabolo", "hat_toss", "apple_toss", "dice", "cats_cradle", "shadow_step", "umbrella_spin", "plate_spin"]),
    ("手工", ["beads", "paper_boat", "clay", "ink", "grasshopper"]),
    ("吃喝", ["rice", "onigiri", "soup", "fishbone", "hotpot", "crab", "snack", "chocolate", "pudding", "cracker", "honey", "sweet_potato", "chestnut", "corn", "watermelon", "shaved_ice", "soda"]),
    ("节日", ["fest_newyear", "laba", "fest_spring", "fest_lantern", "qingtuan", "fest_dragonboat", "qixi", "zhongyuan", "fest_midautumn", "chongyang", "chongyanggao", "fest_halloween", "fest_christmas"]),
    ("四季", ["kite", "raindrop", "clear_umbrella", "windy", "sunshade", "fan", "cicada", "leaves", "hand_warmer", "warm_breath", "snowflake", "snow_step"]),
    ("走路", ["walk_crab", "walk_float", "run_left"]),
    ("余额", ["quota_full", "quota_jingle", "quota_count", "quota_empty", "quota_broke", "tired"])
]

let actionNames: [String: String] = [
    "idle": "待机",
    "hum": "哼歌",
    "stretch": "伸懒腰",
    "yawn": "打哈欠",
    "tired": "累了",
    "sleeping": "睡觉",
    "clawd": "抱 Clawd",
    "listening": "听你说",
    "thinking": "思考",
    "reading": "看书",
    "writing": "写东西",
    "running": "敲命令",
    "searching": "查资料",
    "delegating": "派活",
    "compact": "整理记忆",
    "busy_left": "忙碌（左）",
    "busy_right": "忙碌（右）",
    "swamped_left": "忙不过来（左）",
    "swamped_right": "忙不过来（右）",
    "update": "拆礼物",
    "happy": "开心",
    "proud": "得意",
    "surprised": "吃惊",
    "oops": "哎呀",
    "sorry": "道歉",
    "asking": "有事问你",
    "annoyed": "不耐烦",
    "puffed": "鼓脸",
    "redhot": "红温",
    "sulk": "赌气",
    "coaxed": "被哄",
    "forgiven": "原谅你了",
    "dizzy": "晕乎乎",
    "pat": "被摸头",
    "pout": "傲娇",
    "bye": "再见",
    "bonk": "撞头",
    "stagger": "站不稳",
    "fallen": "摔倒",
    "faceplant": "趴地",
    "greet_morning": "早上好",
    "greet_noon": "中午好",
    "greet_afternoon": "下午好",
    "greet_evening": "晚上好",
    "greet_night": "晚安",
    "fest_newyear": "元旦迎新",
    "fest_spring": "春节舞狮",
    "fest_lantern": "元宵吃汤圆",
    "fest_dragonboat": "端午吃粽子",
    "look": "东张西望",
    "tap": "敲桌面",
    "cube": "玩魔方",
    "bubbles": "吹泡泡",
    "bookspirit": "书灵现世",
    "flower": "凭空生花",
    "dove": "变鸽子",
    "snack": "偷吃零食",
    "token": "吃 Token",
    "mutter": "对屏碎碎念",
    "gamer": "玩游戏气急败坏",
    "animals": "动物环绕",
    "butterflies": "蝴蝶蜜蜂",
    "juggle": "三球抛接",
    "cards": "扑克魔术",
    "flute": "吹笛子",
    "violin": "小提琴",
    "dance_skirt": "裙摆舞",
    "dance_otaku": "宅舞",
    "dance_swing": "摇摆舞",
    "dressup": "换装试色",
    "toycar": "玩具汽车",
    "watergun": "玩水枪",
    "gomoku": "下五子棋",
    "top": "抽陀螺",
    "cat": "撸猫",
    "shuttlecock": "踢毽子",
    "rockinghorse": "骑木马",
    "pagebeat": "拍书打节奏",
    "rice": "吃白饭",
    "hotpot": "涮火锅",
    "crab": "吃大闸蟹",
    "watermelon": "吃西瓜",
    "qingtuan": "清明吃青团",
    "laba": "腊八喝粥",
    "chongyanggao": "重阳吃糕",
    "kite": "放风筝",
    "fan": "摇扇纳凉",
    "leaves": "被落叶淹没",
    "qixi": "七夕穿针",
    "zhongyuan": "中元放河灯",
    "chongyang": "重阳赏菊",
    "walk_crab": "螃蟹步",
    "walk_float": "飘着走",
    "run_left": "往左跑",
    "quota_full": "钱袋满溢",
    "quota_jingle": "金袋叮当",
    "quota_count": "数金皱眉",
    "quota_empty": "袋空如洗",
    "quota_broke": "分文不剩",
    "fest_midautumn": "中秋赏月",
    "fest_halloween": "万圣节讨糖",
    "fest_christmas": "圣诞装点彩树",
    "toes": "伸脚趾",
    "nails": "咬指甲",
    "scratch": "抓痒",
    "leg_bounce": "抖腿",
    "finger_count": "掰手指",
    "eye_rub": "揉眼睛",
    "tummy": "摸肚子",
    "hand_flick": "甩手甩水",
    "wrist_roll": "转手腕",
    "pen_spin": "转笔",
    "leaf_flute": "吹叶笛",
    "glass_harp": "弹玻璃杯沿",
    "air_guitar": "空气吉他",
    "music_box": "手摇八音盒",
    "woodfish": "敲木鱼",
    "curtsy": "淑女屈膝礼",
    "jenga": "叠叠乐",
    "dandelion": "吹蒲公英",
    "forehead_flick": "弹脑门",
    "bubble_wrap": "戳泡泡纸",
    "skip_stone": "打水漂",
    "diabolo": "抖空竹",
    "hat_toss": "抛帽接帽",
    "apple_toss": "抛接小苹果",
    "dice": "摇骰盅",
    "cats_cradle": "翻花绳",
    "shadow_step": "踩影子",
    "umbrella_spin": "转伞",
    "plate_spin": "转盘子",
    "chocolate": "分巧克力",
    "shaved_ice": "刨冰屑",
    "chestnut": "剥栗子",
    "pudding": "吸布丁",
    "cracker": "咬脆饼",
    "corn": "啃玉米",
    "soup": "喝汤吹凉",
    "fishbone": "挑鱼刺",
    "onigiri": "捏饭团",
    "soda": "摇汽水瓶",
    "sweet_potato": "烤红薯",
    "honey": "舀蜂蜜",
    "sunshade": "举手遮阳偷看",
    "snow_step": "原地踏雪",
    "cicada": "听蝉",
    "hand_warmer": "抱暖手炉",
    "snowflake": "掌心接雪花",
    "raindrop": "接雨滴",
    "warm_breath": "搓手哈气取暖",
    "clear_umbrella": "撑透明小伞",
    "windy": "被风吹乱发型",
    "beads": "串珠链",
    "paper_boat": "折小纸船",
    "clay": "捏陶土",
    "ink": "磨墨",
    "grasshopper": "编草蚱蜢",
    "abacus": "拨算盘珠",
    "mutter_lazy": "犯懒碎碎念"
]

// MARK: - claudia:// 协议（app 主机给 web/，data 主机给立绘）

final class SchemeHandler: NSObject, WKURLSchemeHandler {
    private func fail(_ task: WKURLSchemeTask, _ msg: String) {
        task.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist, userInfo: [NSLocalizedDescriptionKey: msg]))
    }

    private func mime(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json"
        case "webp": return "image/webp"
        case "png": return "image/png"
        case "svg": return "image/svg+xml"
        default: return "application/octet-stream"
        }
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let host = url.host else { return fail(task, "bad url") }
        let path = url.path   // 已经解码
        var file: String? = nil
        if host == "app" {
            let root = URL(fileURLWithPath: installRoot + "/web").standardized.path
            let full = URL(fileURLWithPath: root + (path.isEmpty ? "/index.html" : path)).standardized.path
            if full.hasPrefix(root + "/") { file = full }
        } else if host == "data" {
            // /characters/<角色>/<图> 或 /characters/<角色>/anim/<图>，只给 .webp / .png
            let parts = path.components(separatedBy: "/")
            let anim = parts.count == 5 && parts[3] == "anim"
            if (parts.count == 4 || anim), parts[0] == "", parts[1] == "characters" {
                let name = parts[parts.count - 1], cid = parts[2]
                let ext = (name as NSString).pathExtension.lowercased()
                let bad = [cid, name].contains { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("\\") }
                if !bad, ext == "webp" || ext == "png" {
                    file = charactersDir + "/" + cid + (anim ? "/anim/" : "/") + name
                }
            }
        }
        guard let f = file, let data = try? Data(contentsOf: URL(fileURLWithPath: f), options: .mappedIfSafe) else {
            return fail(task, "not found: " + path)
        }
        let headers = ["Content-Type": mime((f as NSString).pathExtension), "Content-Length": String(data.count),
                       "Access-Control-Allow-Origin": "*", "Cache-Control": "no-cache"]
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(resp)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

// MARK: - 窗口：自己收鼠标事件，网页只管画

final class PetWindow: NSWindow {
    weak var pet: Pet?
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func sendEvent(_ e: NSEvent) {
        if let p = pet, p.handle(e) { return }
        super.sendEvent(e)
    }
}

let shimScript = """
(function () {
  if (window.chrome && window.chrome.webview) return;
  window.chrome = window.chrome || {};
  window.chrome.webview = {
    postMessage: function (m) {
      try { window.webkit.messageHandlers.claudia.postMessage(JSON.stringify(m)); } catch (e) {}
    }
  };
})();
"""

let drawnJS = "(() => { const s = document.getElementById('stage'); if (!s || s.classList.contains('swap')) return false;"
    + " const i = document.querySelector('#body img.on'); const c = document.querySelector('html.sheet-on canvas.sheet');"
    + " return !!(c || i && i.complete && i.naturalWidth > 0); })()"

let physicsRanges: [String: (Double, Double, Double)] = [
    "throwPower": (0.2, 2.5, 1.0), "gravity": (0, 3000, 1400), "restitution": (0, 0.95, 0.78),
    "groundFriction": (0.5, 12, 2.5), "elasticity": (0, 0.25, 0.12),
]

// MARK: - 桌宠

final class Pet: NSObject, WKScriptMessageHandler, WKNavigationDelegate, NSMenuDelegate {
    let baseW: CGFloat = 260, baseH: CGFloat = 362
    var window: PetWindow!
    var web: WKWebView!
    var ready = false, revealed = false, concealed = false, userHidden = false
    // 窗口左上角，全局「左上原点」坐标（和网页、Windows / Linux 版一致）
    var x: CGFloat = 0, y: CGFloat = 0, w: CGFloat = 260, h: CGFloat = 362
    var pageW: CGFloat = 260, pageH: CGFloat = 362, pageFoot: CGFloat = 62
    var shownScale: CGFloat = 1, shownFoot: CGFloat = 0
    var hitRects: [[CGFloat]]? = nil
    var stamps: [String: String] = [:]
    // 鼠标
    var pressed = false, dragging = false, flying = false
    var down: (CGFloat, CGFloat) = (0, 0)
    var motionId = 0, dragT0 = 0.0
    var lastPtr: (CGFloat, CGFloat) = (-1, -1)
    var lastBounds = ""
    var motionMargins: (CGFloat, CGFloat, CGFloat)? = nil
    var dragTimer: Timer?
    var dragOrigin: (CGFloat, CGFloat) = (0, 0)   // 开始拖动时窗口的位置
    var sawPhysical = false   // 这次拖动里见到过物理按键按下；没见到就是三指拖移这类系统合成的拖动，松手事件也会晚到
    var lastMoveAt = 0.0
    var releaseTrail: [(t: Double, x: CGFloat, y: CGFloat)] = []   // 只用来在日志里写松手速度，方便排查甩不出去
    // 走路
    var walking = false
    var walkDir: CGFloat = 1, walkSpeed: CGFloat = 0, walkX: CGFloat = 0, walkLast = 0.0, walkUntil = 0.0
    var walkTimer: Timer?
    var topAt = 0.0
    // 跟随 Claude 窗口（Quartz 坐标，左上原点，和我们的坐标一致）
    var claudeRect: CGRect? = nil
    var followHidden = false          // Claude 开着但没有可见窗口（最小化、在别的桌面）时先藏起来
    var claudePidCache: pid_t = 0, claudePidAt = 0.0
    var lastFollowAt = 0.0, lastFullAt = 0.0, fastUntil = 0.0
    var claudeWinID: CGWindowID = 0
    var layerFails = 0, layerBroken = false
    var settingsController: SettingsController?
    var current = "claude"
    let notices = TaskNoticePolicy(started: Date().timeIntervalSince1970)
    var followClaude = false          // 由 Claude 叫出来的：Claude 关了她也退出
    var claudeSeenAt = 0.0, claudeEverSeen = false
    var ignoring = true
    let chatWatch = ChatWatch()
    var chatSince = 0.0, chatBeat: Timer?
    let hotkey = Hotkey()
    var hotkeyFailed = false
    var quitting = false

    var primaryH: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
    var zoom: CGFloat { max(w / pageW, 0.01) }
    func nowMs() -> Double { ProcessInfo.processInfo.systemUptime * 1000 }

    // ---- 启动 ----
    func start() {
        let conf = WKWebViewConfiguration()
        conf.setURLSchemeHandler(SchemeHandler(), forURLScheme: schemeName)
        let ucc = WKUserContentController()
        ucc.addUserScript(WKUserScript(source: shimScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.add(self, name: "claudia")
        conf.userContentController = ucc
        if debugOn { conf.preferences.setValue(true, forKey: "developerExtrasEnabled") }
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: baseW, height: baseH), configuration: conf)
        web.setValue(false, forKey: "drawsBackground")   // 透明底
        web.navigationDelegate = self
        web.autoresizingMask = [.width, .height]

        window = PetWindow(contentRect: NSRect(x: 0, y: 0, width: baseW, height: baseH), styleMask: [.borderless],
                           backing: .buffered, defer: false)
        window.pet = self
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.alphaValue = 0   // 人物画好再显示
        window.ignoresMouseEvents = true
        placeOnDesktop(initial: true)
        window.orderFrontRegardless()

        web.load(URLRequest(url: URL(string: "\(schemeName)://app/index.html")!))

        registerHotkey()
        chatWatch.pidProvider = { [weak self] in self?.claudePid() }
        chatWatch.onChange = { [weak self] s in self?.chatStreaming(s) }
        if settingFlag("chatWatch") {
            chatWatch.start()
            // 没权限就让系统弹授权请求：这样「辅助功能」列表里加的一定是正在跑的这一份 app（手动加容易加成别的副本）
            if !AXProbe.trusted(prompt: true) { log("聊天监视：已请求辅助功能权限，请在系统设置里打开 \(Bundle.main.bundlePath)") }
        }
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.poll() }
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.updateIgnore() }
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.followPoll() }
        // Claude 被点到最前时马上多看几次，把她摆回它上面
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            if let me = self {
                me.fastUntil = me.nowMs() + 600; me.lastFullAt = 0
                if me.claudeWinID != 0 { me.ensureLayer(above: false, num: Int(me.claudeWinID)) }   // 立刻切层级，不等下一次轮询
            }
        }
    }

    func eval(_ code: String) {
        web.evaluateJavaScript(code) { _, err in
            if let e = err, debugOn { log("JS 出错: \(e.localizedDescription)  ← \(code.prefix(120))") }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let u = action.request.url, u.scheme == schemeName, u.host == "app" { decisionHandler(.allow) }
        else { decisionHandler(.cancel) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log("网页进程退出，重新加载")
        ready = false
        web.reload()
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        stopMotion(save: false); ready = false; hitRects = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let manifest = buildManifest()
        let chars = (manifest["characters"] as? [String: Any]) ?? [:]
        current = chars["claude"] != nil ? "claude" : (chars.keys.sorted().first ?? "claude")
        let aura = ["on", "off"].contains(settings["auraMode"] as? String ?? "") ? settings["auraMode"] as! String : "auto"
        let quota = quotaStyle()
        let freq = ["quiet", "normal", "lively"].contains(settings["idleFrequency"] as? String ?? "") ? settings["idleFrequency"] as! String : "normal"
        let behavior: [String: Any] = ["idleEnabled": settingOn("idleEnabled"), "idleFrequency": freq,
                                       "clickBounce": settingOn("clickBounce"), "tumbleActions": settingOn("tumbleActions")]
        eval("init(\(js(manifest))); setCharacter(\(js(current)), true); setAuraMode(\(js(aura))); "
             + "setShowName(\(js((settings["showName"] as? Bool) ?? true))); setPowerSave(\(js(settingFlag("powerSave")))); "
             + "setQuotaStyle(\(js(quota))); setBehavior(\(js(behavior)))")
        settings["lastVersion"] = appVersion(); saveSettings()
        ready = true
        applySizes(anchor: "corner")
        stamps.removeAll()
        poll()
        // 保险：最多等 3 秒就显示
        var tries = 0
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            tries += 1
            if self.revealed { t.invalidate(); return }
            if tries >= 30 { t.invalidate(); self.reveal(); return }
            self.web.evaluateJavaScript(drawnJS) { v, _ in
                if (v as? Bool) == true { t.invalidate(); self.reveal() }
            }
        }
    }

    func reveal() {
        if revealed { return }
        revealed = true
        if !concealed { window.alphaValue = 1 }
        updatePageHidden()
    }

    // ---- 网页来的消息 ----
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let s = message.body as? String, let d = s.data(using: .utf8),
              let m = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return }
        if let rects = m["hitRects"] as? [Any] {
            hitRects = rects.compactMap { r in
                guard let a = r as? [Any], a.count == 4 else { return nil }
                let n = a.compactMap { ($0 as? NSNumber)?.doubleValue }
                return n.count == 4 ? n.map { CGFloat($0) } : nil
            }
            updateIgnore()
        } else if let mo = m["motion"] as? [String: Any] {
            acceptMotion(mo)
        } else if m["walk"] != nil {
            handleWalk(m["walk"] as? [String: Any])
        } else if let e = m["jsError"] {
            log("网页脚本出错: \(e)")
        } else if let e = m["imageError"] {
            log("立绘加载失败: \(e)")
        }
    }

    // ---- 读 Claude Code 插件写的状态 ----
    func poll() {
        guard ready else { return }
        for kind in ["state", "quota", "sessions"] {
            let f = "\(stateDir)/claude-\(kind).json"
            guard let a = try? fm.attributesOfItem(atPath: f), let size = a[.size] as? Int, size <= 1_000_000,
                  let mt = a[.modificationDate] as? Date else { continue }
            let stamp = "\(mt.timeIntervalSince1970):\(size)"
            let key = "claude-\(kind)"
            if stamps[key] == stamp { continue }
            if kind == "state" && Date().timeIntervalSince(mt) > 600 { stamps[key] = stamp; continue }   // 只认 10 分钟内的
            guard let v = readJSON(f) else { continue }   // 可能正被写一半，下次再读
            stamps[key] = stamp
            let data = js(v)
            switch kind {
            case "sessions": eval("setSessions(\"claude\", \(data))")
            case "state": noticeFromState(v); eval("applyCharState(\"claude\", \(data))")
            default: eval("setQuota(\"claude\", \(data), \(Int(mt.timeIntervalSince1970)))")
            }
        }
        pollTaskNotices()
    }

    // ---- 聊天模式：用和 Code 插件一样的状态包，网页那边不用改 ----
    func chatState(_ pose: String, _ event: String) {
        guard ready else { return }
        let st: [String: Any] = ["pose": pose, "event": event, "tool": "", "ts": Date().timeIntervalSince1970, "sid": "chat"]
        eval("applyCharState(\"claude\", \(js(st)))")
    }
    func chatStreaming(_ on: Bool) {
        chatBeat?.invalidate(); chatBeat = nil
        if on {
            chatSince = Date().timeIntervalSince1970
            log("聊天：Claude 开始回复")
            chatState("listening", "UserPromptSubmit")   // 网页先演「听」，过一会儿自己转「思考」
            // 长回复：每分钟续一次「思考」，免得网页 3 分钟没动静当成卡住
            chatBeat = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.chatState("thinking", "ChatStreaming") }
        } else {
            let secs = Int(Date().timeIntervalSince1970 - chatSince)
            log("聊天：回复结束（约 \(secs) 秒）")
            chatState("happy", "Stop")
            let ts = Date().timeIntervalSince1970
            taskNotice("chat:\(ts)", "complete", ts)
        }
    }

    // ---- 任务通知 ----
    func taskNotice(_ nid: String, _ kind: String, _ ts: Double) {
        let enabled = settingOn(kind == "waiting" ? "notifyWaiting" : "notifyResults")
        guard notices.accept(nid, kind, ts, Date().timeIntervalSince1970, enabled: enabled,
                             foreground: claudeIsFront(), backgroundOnly: settingOn("notifyBackgroundOnly")) else { return }
        let titles = ["waiting": "Claude 需要你确认", "error": "Claude 任务出错"]
        let texts = ["waiting": "有授权申请或问题等待你处理，回到 Claude 看一下吧。", "error": "这一轮未能正常完成，请回到 Claude 查看。"]
        Notifier.post(titles[kind] ?? "Claude 任务已完成", texts[kind] ?? "这一轮工作已结束，可以回到 Claude 查看结果。")
    }

    /// 旧插件没有通知队列：从状态里推断
    func noticeFromState(_ st: [String: Any]) {
        if st["noticeV"] != nil { return }
        guard let ts = (st["ts"] as? NSNumber)?.doubleValue else { return }
        let pose = st["pose"] as? String, ev = st["event"] as? String
        let kind = pose == "asking" ? "waiting"
            : (ev == "Stop" && (pose == "happy" || pose == "proud")) ? "complete"
            : (ev == "Stop" && pose == "oops") ? "error" : nil
        if let k = kind { taskNotice("state:\(ts):\(k)", k, ts) }
    }

    func pollTaskNotices() {
        let names = ((try? fm.contentsOfDirectory(atPath: stateDir)) ?? []).filter { $0.hasPrefix("claude-notify-") && $0.hasSuffix(".json") }
        for n in names {
            let f = stateDir + "/" + n
            guard let a = try? fm.attributesOfItem(atPath: f), let size = a[.size] as? Int, let mt = a[.modificationDate] as? Date,
                  size <= 100_000, Date().timeIntervalSince(mt) <= 120 else { continue }
            let key = "notice:" + f, stamp = "\(mt.timeIntervalSince1970):\(size)"
            if stamps[key] == stamp { continue }
            guard let d = readJSON(f), let events = d["events"] as? [[String: Any]] else { continue }
            stamps[key] = stamp
            for e in events {
                guard let id = e["id"], let kind = e["kind"] as? String, let ts = (e["ts"] as? NSNumber)?.doubleValue else { continue }
                taskNotice("\(id)", kind, ts)
            }
        }
    }

    func tick() {
        if followClaude && (settings["runMode"] as? String) != "standalone" {
            if claudeApp() != nil { claudeSeenAt = nowMs(); claudeEverSeen = true }
            else if claudeEverSeen && nowMs() - claudeSeenAt > 2000 {
                log("Claude 关了，\(appName) 跟着退出")
                NSApp.terminate(nil)
                return
            }
        }
        if dragging || flying { updateMotionGeometry(); return }
        if !walking && ready {
            let (x0, y0, x1, y1) = bounds()
            let nx = min(max(x, x0), x1), ny = min(max(y, y0), y1)
            if nx != x || ny != y { moveTo(nx, ny) }
        }
        keepOnTop()
    }

    func keepOnTop() {
        if concealed || window.level != .floating { return }
        let n = nowMs()
        if n - topAt < 5000 { return }
        topAt = n
        window.orderFrontRegardless()
    }

    // ---- 位置 ----
    func moveTo(_ nx: CGFloat, _ ny: CGFloat) {
        let rx = nx.rounded(), ry = ny.rounded()
        if rx != x || ry != y { x = rx; y = ry }
        window.setFrameOrigin(NSPoint(x: x, y: primaryH - y - h))
    }

    func workArea(atPointer: Bool) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        var screen: NSScreen? = nil
        if atPointer { let p = NSEvent.mouseLocation; screen = NSScreen.screens.first { NSPointInRect(p, $0.frame) } }
        if screen == nil {
            let c = NSPoint(x: window.frame.midX, y: window.frame.midY)
            screen = NSScreen.screens.first { NSPointInRect(c, $0.frame) } ?? NSScreen.main ?? NSScreen.screens.first
        }
        guard let vf = screen?.visibleFrame else { return (0, 0, 1440, 900) }
        return (vf.minX, primaryH - vf.maxY, vf.maxX, primaryH - vf.minY)
    }

    /// 人物本体离窗口左、上、右边各多远（窗口点）：碰边按本体算。拖动、飞行时用开始那一刻的
    func bodyMargins() -> (CGFloat, CGFloat, CGFloat) {
        if (dragging || flying), let m = motionMargins { return m }
        guard let rs = hitRects, let best = rs.max(by: { $0[2] * $0[3] < $1[2] * $1[3] }) else { return (0, 0, 0) }
        let z = zoom
        return (max(0, (best[0] * z).rounded()), max(0, (best[1] * z).rounded()), max(0, (w - (best[0] + best[2]) * z).rounded()))
    }

    func wantFollow() -> Bool { (settings["mode"] as? String) != "desktop" }

    /// 她能活动的范围：跟着 Claude 时是 Claude 窗口，否则是所在屏幕的工作区
    func areaRect() -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        if wantFollow(), let r = claudeRect { return (r.minX, r.minY, r.maxX, r.maxY) }
        return workArea(atPointer: dragging)
    }

    func bounds() -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        let (l, t, r, b) = areaRect()
        let (ml, mt, mr) = bodyMargins()
        let minX = l - ml, maxX = max(minX, r - w + mr)
        let minY = t - mt, maxY = max(minY, b - h)
        return (minX, minY, maxX, maxY)
    }

    func placeOnDesktop(initial: Bool = false) {
        let screen = NSScreen.screens.first ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var px = vf.maxX - w - 40, py = primaryH - vf.minY - h
        if let d = settings["desk"] as? [String: Any], let dx = (d["x"] as? NSNumber)?.doubleValue, let dy = (d["y"] as? NSNumber)?.doubleValue {
            px = CGFloat(dx); py = CGFloat(dy)
        }
        x = px; y = py
        window.setFrame(NSRect(x: x, y: primaryH - y - h, width: w, height: h), display: true)
        if !initial { let (x0, y0, x1, y1) = bounds(); moveTo(min(max(x, x0), x1), min(max(y, y0), y1)) }
    }

    func savePosition() {
        let (x0, y0, x1, y1) = bounds()
        let nx = min(max(x, x0), x1), ny = min(max(y, y0), y1)
        moveTo(nx, ny)
        if wantFollow(), let r = claudeRect {
            // 记离 Claude 窗口右下角的距离：窗口挪动、改大小，她都留在同一个角
            settings["follow"] = ["right": Double(r.maxX - (nx + w)), "bottom": Double(r.maxY - (ny + h))]
        } else {
            settings["desk"] = ["x": Double(nx), "y": Double(ny)]
        }
        saveSettings()
    }

    func recenter() {
        stopMotion(save: false)
        settings.removeValue(forKey: "desk"); settings.removeValue(forKey: "follow"); saveSettings()
        if wantFollow(), let r = claudeRect { placeInClaude(r) } else { placeOnDesktop() }
        if userHidden { setUserHidden(false) }
    }

    // ---- 跟随 Claude 窗口 ----
    func claudePid() -> pid_t? {
        let n = nowMs()
        if claudePidCache == 0 || n - claudePidAt > 1000 {
            claudePidAt = n
            claudePidCache = claudeApp()?.processIdentifier ?? 0
        }
        return claudePidCache == 0 ? nil : claudePidCache
    }

    /// Claude 主窗口（最前面的、够大的普通窗口）：位置、窗口号、她现在是不是压在它上面。
    /// 读窗口位置不需要屏幕录制权限，只有读窗口标题才要
    func findClaude() -> (CGRect, Int, Bool)? {
        guard let pid = claudePid(),
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let mine = window.windowNumber
        var petIndex: Int? = nil
        for (i, wi) in list.enumerated() {
            let num = (wi[kCGWindowNumber as String] as? NSNumber)?.intValue ?? -1
            if num == mine { petIndex = i; continue }
            guard (wi[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (wi[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bd = wi[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bd as CFDictionary), r.width >= 300, r.height >= 300 else { continue }
            return (r, num, petIndex != nil)   // 列表是从前往后排的：她在前面就是压在上面
        }
        return nil
    }

    /// 只问这一个窗口的位置，比翻整张窗口列表便宜得多，拖动 Claude 窗口时每帧用它
    func quickRect() -> CGRect? {
        guard claudeWinID != 0 else { return nil }
        var ids: [UnsafeRawPointer?] = [UnsafeRawPointer(bitPattern: Int(claudeWinID))]
        guard let arr = CFArrayCreate(kCFAllocatorDefault, &ids, 1, nil),
              let d = CGWindowListCreateDescriptionFromArray(arr) as? [[String: Any]], let wi = d.first,
              (wi[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
              let bd = wi[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: bd as CFDictionary) else { return nil }
        return r
    }

    /// 层级：默认只压在 Claude 窗口上面（别的应用盖到 Claude 上时她也被盖住，和 Windows 版一样）；选「总在最前」就浮在所有窗口上
    func layerMode() -> String { (settings["layer"] as? String) == "top" ? "top" : "claude" }

    func claudeIsFront() -> Bool {
        guard let pid = claudePid() else { return false }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    /// Claude 在最前台时她用浮动层级：你在 Claude 里每点一下，系统都会把 Claude 窗口提到最前，
    /// 普通层级的她会被压到下面、等下一次检查才摆回来，看着就是闪一下。切到别的应用，她才降成「只压在 Claude 上面」
    func ensureLayer(above: Bool, num: Int) {
        if layerMode() == "top" || layerBroken || !wantFollow() || claudeIsFront() {
            if window.level != .floating { window.level = .floating }
            layerFails = 0
            return
        }
        if window.level != .normal { window.level = .normal }
        if above || concealed || !revealed { layerFails = 0; return }
        window.order(.above, relativeTo: num)
        layerFails += 1
        if layerFails >= 20 {   // 多次摆不上去：这个系统上用不了，改回总在最前，免得她被压在 Claude 底下看不见
            layerBroken = true
            log("没能把她摆到 Claude 窗口上面，改为总在最前")
            window.level = .floating
        }
    }

    func placeInClaude(_ r: CGRect) {
        claudeRect = r
        let f = settings["follow"] as? [String: Any]
        let rr = CGFloat((f?["right"] as? NSNumber)?.doubleValue ?? 16), rb = CGFloat((f?["bottom"] as? NSNumber)?.doubleValue ?? 0)
        moveTo(r.maxX - w - rr, r.maxY - h - rb)
        let (x0, y0, x1, y1) = bounds()
        moveTo(min(max(x, x0), x1), min(max(y, y0), y1))
    }

    func applyConceal() { setConcealed(userHidden || followHidden) }

    /// 平时每 0.25 秒看一次；按着鼠标（可能在拖 Claude 窗口）或窗口刚动过，就每帧看，跟得上手
    func followPoll() {
        guard ready, wantFollow() else { return }
        let n = nowMs()
        let busy = NSEvent.pressedMouseButtons != 0 || n < fastUntil || dragging || flying
        if !busy && n - lastFollowAt < 250 { return }
        lastFollowAt = n
        var found: CGRect? = nil
        if busy && n - lastFullAt < 120 { found = quickRect() }   // 忙的时候多数帧只问这一个窗口，每 120 毫秒翻一次整张列表（校正层级）
        if found == nil, let f = findClaude() {
            found = f.0; claudeWinID = CGWindowID(f.1); lastFullAt = n
            ensureLayer(above: f.2, num: f.1)
        }
        guard let r = found else {
            claudeRect = nil; claudeWinID = 0
            if window.level != .floating { window.level = .floating }
            let running = claudePid() != nil
            if followHidden != running { followHidden = running; applyConceal() }   // 开着但没窗口：藏；根本没开：当普通桌宠
            return
        }
        if followHidden { followHidden = false; applyConceal() }
        guard let old = claudeRect else { placeInClaude(r); return }
        if old == r { return }
        fastUntil = n + 400
        let rr = old.maxX - (x + w), rb = old.maxY - (y + h)
        claudeRect = r
        if dragging || flying { updateMotionGeometry(); return }
        if walking { walkX += r.maxX - old.maxX }
        moveTo(r.maxX - w - rr, r.maxY - h - rb)
        let (x0, y0, x1, y1) = bounds()
        moveTo(min(max(x, x0), x1), min(max(y, y0), y1))
    }

    func setFollowMode(_ on: Bool) {
        stopMotion(save: false); stopWalk(nil)
        settings["mode"] = on ? "claude" : "desktop"; saveSettings()
        claudeRect = nil
        if followHidden { followHidden = false; applyConceal() }
        if !on { window.level = .floating; placeOnDesktop() }   // 跟着的话，下一次轮询会把她摆回 Claude 窗口里
        lastFollowAt = 0
    }

    // ---- 大小 ----
    func scale() -> CGFloat { CGFloat(settingNum("size", 0.6, 1.6, 1.0)) }

    func applySizes(anchor: String = "feet") {
        stopMotion(save: false)
        guard ready else { applyScale(scale(), anchor: anchor); return }
        let tsz = settingNum("textSize", 0.6, 1.6, 1.0), linked = (settings["textLinked"] as? Bool) ?? true
        web.evaluateJavaScript("setSizes(\(scale()), \(tsz), \(linked))") { [weak self] v, _ in
            guard let self = self else { return }
            if let o = v as? [String: Any], let pw = (o["w"] as? NSNumber)?.doubleValue, let ph = (o["h"] as? NSNumber)?.doubleValue,
               let pf = (o["foot"] as? NSNumber)?.doubleValue, pw > 0, ph > 0 {
                self.pageW = CGFloat(pw); self.pageH = CGFloat(ph); self.pageFoot = CGFloat(pf)
            }
            self.applyScale(self.scale(), anchor: anchor)
        }
    }

    func applyScale(_ s: CGFloat, anchor: String) {
        let ox = x, oy = y, ow = w, oh = h
        let nw = max(1, (pageW * s).rounded()), nh = max(1, (pageH * s).rounded())
        w = nw; h = nh
        web.pageZoom = s
        window.setContentSize(NSSize(width: nw, height: nh))
        let foot = pageFoot * nw / pageW
        var nx = ox, ny = oy
        if anchor != "corner" {
            nx = ox + ow / 2 - nw / 2
            ny = anchor == "feet" ? oy + oh + (foot - (shownFoot == 0 ? foot : shownFoot)).rounded() - nh : oy + oh - nh
        }
        shownFoot = foot; shownScale = s
        moveTo(nx, ny)
        savePosition()
    }

    // ---- 能点到的区域：只在人物、气泡、名牌、额度上收鼠标，别的地方穿透 ----
    func updateIgnore() {
        var want = true
        if revealed && !concealed {
            if pressed || dragging || menuOpen { want = false }
            else if let rs = hitRects {
                let p = NSEvent.mouseLocation, f = window.frame
                let z = zoom
                let lx = (p.x - f.minX) / z, ly = (f.maxY - p.y) / z
                want = !rs.contains { lx >= $0[0] - 1 && lx <= $0[0] + $0[2] + 1 && ly >= $0[1] - 1 && ly <= $0[1] + $0[3] + 1 }
            }
        }
        if want != ignoring { ignoring = want; window.ignoresMouseEvents = want }
    }

    // ---- 鼠标：单击摸头、拖动、右键菜单 ----
    func pointer() -> (CGFloat, CGFloat) { let p = NSEvent.mouseLocation; return (p.x, primaryH - p.y) }

    func handle(_ e: NSEvent) -> Bool {
        switch e.type {
        case .leftMouseDown:
            if e.modifierFlags.contains(.control) { popupMenu(e); return true }
            stopMotion(save: true)
            stopWalk(nil)
            down = pointer(); pressed = true
            return true
        case .leftMouseDragged:
            if dragging { followPointer(); return true }
            guard pressed else { return true }
            let p = pointer()
            if abs(p.0 - down.0) + abs(p.1 - down.1) > 4 { beginDrag() }
            followPointer()
            return true
        case .leftMouseUp:
            let was = dragging
            if dragging { endDrag() }
            let click = pressed && !was
            pressed = false
            updateIgnore()
            if click {
                let z = zoom, loc = e.locationInWindow
                let ly = (window.contentView?.bounds.height ?? h) - loc.y
                eval("handleClick('pat', \(Double((loc.x / z * 10).rounded() / 10)), \(Double((ly / z * 10).rounded() / 10)))")
            }
            return true
        case .rightMouseDown:
            popupMenu(e); return true
        case .rightMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel:
            return true
        default:
            return false
        }
    }

    // ---- 拖动和飞行：网页的帧循环算位置（pet-motion.js），这里只交鼠标轨迹、按回来的位置挪窗口 ----
    func physicsConfig() -> [String: Any] {
        var c: [String: Any] = [:]
        for k in ["gravity", "restitution", "groundFriction", "throwPower"] {
            let r = physicsRanges[k]!
            c[k] = settingNum(k, r.0, r.1, r.2)
        }
        c["ceilingBounce"] = settingOn("ceilingBounce"); c["petCollision"] = false
        return c
    }

    func motionPacket() -> [String: Any] {
        let (x0, y0, x1, y1) = bounds()
        return ["id": motionId, "physics": physicsConfig(), "enabled": settingOn("physicsEnabled"),
                "bounds": ["minX": Double(x0), "minY": Double(y0), "maxX": Double(x1), "maxY": Double(y1)]]
    }

    func beginDrag() {
        stopWalk(nil)
        stopMotion(save: false)
        guard ready else { return }
        motionMargins = bodyMargins()
        let (px, py) = pointer()
        dragOrigin = (x, y)
        dragging = true
        sawPhysical = NSEvent.pressedMouseButtons & 1 != 0
        lastMoveAt = nowMs()
        log("开始拖动：物理按键\(sawPhysical ? "按着" : "没按（三指拖移之类）")")
        var p = motionPacket()
        dragT0 = nowMs()
        p["x"] = Double(x); p["y"] = Double(y); p["downX"] = Double(down.0); p["downY"] = Double(down.1)
        p["px"] = Double(px); p["py"] = Double(py); p["time"] = 0
        lastBounds = js(p["bounds"]!)
        eval("setMotionActive(true); petMotion.begin(\(js(p)))")
        lastPtr = (px, py)
        releaseTrail = [(0, px, py)]
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.pumpPointer() }
        RunLoop.main.add(t, forMode: .common)
        dragTimer = t
    }

    func pumpPointer() {
        guard dragging else { dragTimer?.invalidate(); dragTimer = nil; return }
        followPointer()
        let down = NSEvent.pressedMouseButtons & 1 != 0
        if down { sawPhysical = true }
        let (px, py) = pointer()
        if px != lastPtr.0 || py != lastPtr.1 {
            lastPtr = (px, py)
            lastMoveAt = nowMs()
            let t = ((nowMs() - dragT0) * 10).rounded() / 10
            releaseTrail.append((t, px, py))
            if releaseTrail.count > 120 { releaseTrail.removeFirst(releaseTrail.count - 120) }
            eval("petMotion.pointer({id:\(motionId),px:\(Double(px)),py:\(Double(py)),time:\(t)})")
        } else if !down && nowMs() - lastMoveAt > 5000 {
            // 松手事件可能丢了：鼠标 5 秒没动、按键也没按着，才当作松手（三指拖移时按键状态一直是「没按」，所以不能一看到没按就结束）
            log("拖动 5 秒没动、按键也没按着：当作松手")
            endDrag(); pressed = false; updateIgnore()
        }
    }

    func endDrag() {
        guard dragging else { return }
        let (px, py) = pointer()
        let t = ((nowMs() - dragT0) * 10).rounded() / 10
        dragging = false; flying = true
        logRelease(t)
        eval("petMotion.pointer({id:\(motionId),px:\(Double(px)),py:\(Double(py)),time:\(t)}); petMotion.end({id:\(motionId),x:\(Double(x)),y:\(Double(y)),time:\(t)})")
    }

    /// 松手那一刻前 150 毫秒鼠标的速度（原版判定：要 ≥ 约 500 像素/秒才会甩出去，乘上「抛掷力度」后再比）
    func logRelease(_ t: Double) {
        let win = releaseTrail.filter { t - $0.t <= 150 }
        guard win.count >= 2, let a = win.first, let b = win.last, b.t - a.t >= 20 else {
            log("松手：最后 150 毫秒内鼠标几乎没动（\(win.count) 个采样），不会甩出去")
            return
        }
        let v = Double(hypot(b.x - a.x, b.y - a.y)) / (b.t - a.t) * 1000
        let power = settingNum("throwPower", 0.2, 2.5, 1.0)
        log("松手：速度约 \(Int(v)) 像素/秒，抛掷力度 \(power)（原版要求折算后 ≥ 500 才甩出去）")
    }

    func stopMotion(save: Bool) {
        let moved = dragging || flying
        motionId += 1
        dragging = false; flying = false
        dragTimer?.invalidate(); dragTimer = nil
        if moved {
            eval("petMotion.stop(); setMotionActive(false)")
            if save { savePosition() }
        }
    }

    func updateMotionGeometry() {
        if concealed { stopMotion(save: true); return }
        let p = motionPacket()
        let j = js(p["bounds"]!)
        if j == lastBounds { return }
        lastBounds = j
        eval("petMotion.update(\(js(p)))")
    }

    /// 拖动时窗口直接跟着鼠标走（不等网页算好再传回来，那样慢 1～3 帧）；松手后的飞行、碰边仍由网页算
    func followPointer() {
        guard dragging else { return }
        let (px, py) = pointer()
        let (x0, y0, x1, y1) = bounds()
        moveTo(min(max(dragOrigin.0 + px - down.0, x0), x1), min(max(dragOrigin.1 + py - down.1, y0), y1))
    }

    func acceptMotion(_ m: [String: Any]) {
        guard let id = (m["id"] as? NSNumber)?.intValue, id == motionId, dragging || flying,
              let phase = m["phase"] as? String, ["drag", "flight", "end"].contains(phase) else { return }
        if (phase == "drag" && !dragging) || (phase == "flight" && !flying) || (phase == "end" && dragging) { return }
        guard let nx = (m["x"] as? NSNumber)?.doubleValue, let ny = (m["y"] as? NSNumber)?.doubleValue, nx.isFinite, ny.isFinite else { return }
        if phase != "drag" { moveTo(CGFloat(nx), CGFloat(ny)) }   // 拖动阶段位置由 followPointer 管
        if phase == "end" { stopMotion(save: true); return }
        if (m["shake"] as? Bool) == true { eval("shaken()") }
        let ix = (m["impactX"] as? NSNumber)?.doubleValue ?? 0, iy = (m["impactY"] as? NSNumber)?.doubleValue ?? 0
        if max(ix, iy) > 120 {
            eval("physicsImpact(\(ix), \(iy), \(settingNum("elasticity", 0, 0.25, 0.12)))")
        }
    }

    // ---- 自己走路 ----
    func handleWalk(_ wk: [String: Any]?) {
        guard let wk = wk else { stopWalk(nil); return }
        guard let d = (wk["dir"] as? NSNumber)?.doubleValue, let sp = (wk["speed"] as? NSNumber)?.doubleValue,
              let ms = (wk["ms"] as? NSNumber)?.doubleValue, sp > 0, sp <= 2000, ms > 0, ms <= 60000, d == 1 || d == -1 else { return }
        stopWalk(nil)
        if dragging || flying || concealed { eval("walkEnded('blocked')"); return }
        let (x0, _, x1, _) = bounds()
        let room = d < 0 ? x - x0 : x1 - x
        if room < 24 { eval("walkEnded('blocked')"); return }
        let n = nowMs()
        walking = true; walkDir = CGFloat(d); walkSpeed = CGFloat(sp); walkX = x; walkLast = n; walkUntil = n + ms
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.walkFrame() }
        RunLoop.main.add(t, forMode: .common)
        walkTimer = t
    }

    func walkFrame() {
        guard walking else { walkTimer?.invalidate(); walkTimer = nil; return }
        if dragging || flying { stopWalk(nil); return }
        if concealed { stopWalk("done"); return }
        let n = nowMs()
        let dt = min(0.1, (n - walkLast) / 1000)
        walkLast = n
        let (x0, _, x1, _) = bounds()
        walkX += walkDir * walkSpeed * CGFloat(dt)
        var edge = false
        if walkX <= x0 { walkX = x0; edge = true }
        if walkX >= x1 { walkX = x1; edge = true }
        moveTo(walkX, y)
        if edge { stopWalk("edge"); return }
        if n >= walkUntil { stopWalk("done") }
    }

    func stopWalk(_ reason: String?) {
        guard walking else { return }
        walking = false
        walkTimer?.invalidate(); walkTimer = nil
        savePosition()
        if let r = reason { eval("walkEnded('\(r)')") }
    }

    // ---- 隐藏 / 显示 ----
    func updatePageHidden() { eval("setPageHidden(\(js(concealed || !revealed)))") }

    func setConcealed(_ c: Bool) {
        guard concealed != c else { return }
        concealed = c
        if c { stopMotion(save: true); stopWalk(nil); window.alphaValue = 0 }
        else { if revealed { window.alphaValue = 1 }; topAt = 0; keepOnTop() }
        updateIgnore(); updatePageHidden()
    }

    func setUserHidden(_ h: Bool) { userHidden = h; applyConceal() }

    // ---- 额度样式：条（默认，和视频一致）/ 文字 ----
    func quotaStyle() -> String { (settings["quotaStyle"] as? String) == "text" ? "text" : "bars" }

    // ---- 右键菜单 ----
    var menuOpen = false
    var menuKeep: NSMenu?
    var trayItem: NSStatusItem?

    func item(_ title: String, _ action: Selector, _ tag: Int = 0, on: Bool = false) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self; i.tag = tag; i.state = on ? .on : .off
        return i
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item("摸摸头", #selector(menuPat)))
        menu.addItem(item("戳一下", #selector(menuPoke)))
        menu.addItem(.separator())
        menu.addItem(item("设置…", #selector(menuSettings)))
        if let am = actionMenu() {
            let ai = NSMenuItem(title: "动作", action: nil, keyEquivalent: "")
            ai.submenu = am
            menu.addItem(ai)
        }
        menu.addItem(.separator())
        menu.addItem(item("回到默认位置", #selector(menuRecenter)))
        menu.addItem(item(userHidden ? "显示" : (Hotkey.label(hideHotkey()).map { "暂时隐藏（\($0)）" } ?? "暂时隐藏"), #selector(menuToggleHide)))
        let modeMenu = NSMenu()
        modeMenu.addItem(item("Claude 窗口里", #selector(menuMode(_:)), 1, on: wantFollow()))
        modeMenu.addItem(item("桌面上", #selector(menuMode(_:)), 0, on: !wantFollow()))
        let modeItem = NSMenuItem(title: "待在", action: nil, keyEquivalent: "")
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)
        let sizeMenu = NSMenu()
        for (label, v) in [("小 0.8", 80), ("标准 1.0", 100), ("大 1.2", 120), ("特大 1.5", 150)] {
            sizeMenu.addItem(item(label, #selector(menuSize(_:)), v, on: abs(Double(scale()) * 100 - Double(v)) < 1))
        }
        let sizeItem = NSMenuItem(title: "大小", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)
        let nMenu = NSMenu()
        for (label, key) in [("任务完成 / 出错", "notifyResults"), ("需要你确认", "notifyWaiting"), ("仅在 Claude 不在前台时", "notifyBackgroundOnly")] {
            let i = item(label, #selector(menuNotice(_:)), 0, on: settingOn(key))
            i.representedObject = key
            nMenu.addItem(i)
        }
        nMenu.addItem(.separator())
        nMenu.addItem(item("发送测试通知", #selector(menuNoticeTest)))
        let nItem = NSMenuItem(title: "通知", action: nil, keyEquivalent: "")
        nItem.submenu = nMenu
        menu.addItem(nItem)
        let layerMenu = NSMenu()
        layerMenu.addItem(item("只在 Claude 上面", #selector(menuLayer(_:)), 0, on: layerMode() == "claude"))
        layerMenu.addItem(item("总在最前", #selector(menuLayer(_:)), 1, on: layerMode() == "top"))
        let layerItem = NSMenuItem(title: "层级", action: nil, keyEquivalent: "")
        layerItem.submenu = layerMenu
        menu.addItem(layerItem)
        let qMenu = NSMenu()
        qMenu.addItem(item("条", #selector(menuQuota(_:)), 1, on: quotaStyle() == "bars"))
        qMenu.addItem(item("文字", #selector(menuQuota(_:)), 0, on: quotaStyle() == "text"))
        let qItem = NSMenuItem(title: "额度样式", action: nil, keyEquivalent: "")
        qItem.submenu = qMenu
        menu.addItem(qItem)
        menu.addItem(.separator())
        let plug = Connect.pluginInstalled(), mcp = Connect.mcpInstalled()
        menu.addItem(item(plug ? "撤销 Claude Code 插件" : "接入 Claude Code 插件", #selector(menuPlugin), plug ? 0 : 1))
        menu.addItem(item(mcp ? "撤销 Claude 桌面端（MCP）" : "接入 Claude 桌面端（MCP）", #selector(menuMcp), mcp ? 0 : 1))
        menu.addItem(item("菜单栏图标", #selector(menuTray), 0, on: settingOn("trayIcon")))
        menu.addItem(item("聊天模式动画（需辅助功能权限）", #selector(menuChatWatch), 0, on: settingFlag("chatWatch")))
        menu.addItem(item("打开日志", #selector(menuLog)))
        menu.addItem(item("诊断：记录 Claude 按钮 60 秒", #selector(menuAXProbe)))
        menu.addItem(.separator())
        menu.addItem(item("退出", #selector(menuQuit)))
        return menu
    }

    func popupMenu(_ e: NSEvent) {
        let menu = buildMenu()
        menuKeep = menu
        menuOpen = true
        updateIgnore()
        NSMenu.popUpContextMenu(menu, with: e, for: window.contentView ?? web)
        menuOpen = false
        updateIgnore()
    }

    @objc func menuRecenter() { recenter() }
    @objc func menuToggleHide() { setUserHidden(!userHidden) }
    @objc func menuPat() { eval("handleClick('pat')") }
    @objc func menuPoke() { eval("handleClick('poke')") }

    // ---- 隐藏快捷键（同 Windows 版 Pet.Hotkey.cs；mac 上是 ⌃⌥P / ⌃⌥H，用 Carbon 注册，不需要额外权限）----
    func hideHotkey() -> String {
        let v = settings["hideHotkey"] as? String ?? "p"
        return v == "off" || Hotkey.label(v) != nil ? v : "p"
    }
    func registerHotkey() {
        hotkey.unregister()
        hotkeyFailed = false
        let id = hideHotkey()
        guard id != "off" else { return }
        hotkeyFailed = !hotkey.register(id) { [weak self] in
            guard let me = self else { return }
            me.setUserHidden(!me.userHidden)
        }
        if hotkeyFailed { log("快捷键 \(Hotkey.label(id) ?? id) 注册失败（被别的程序占用了）") }
    }
    @objc func menuSize(_ s: NSMenuItem) {
        settings["size"] = Double(s.tag) / 100; saveSettings()
        applySizes(anchor: "feet")
    }
    @objc func menuSettings() { openSettings() }
    @objc func menuNotice(_ s: NSMenuItem) {
        guard let k = s.representedObject as? String else { return }
        settings[k] = !settingOn(k); saveSettings()
    }
    @objc func menuNoticeTest() { Notifier.post("claudia-pet 测试通知", "能看到这条，说明系统通知正常。") }
    @objc func menuLayer(_ s: NSMenuItem) {
        settings["layer"] = s.tag == 1 ? "top" : "claude"; saveSettings()
        layerBroken = false; layerFails = 0; lastFullAt = 0; lastFollowAt = 0
        if s.tag == 1 { window.level = .floating }
    }
    @objc func menuMode(_ s: NSMenuItem) { setFollowMode(s.tag == 1) }
    // ---- 动作菜单：当前角色有的动作，按分组列出，点哪个播哪个 ----
    func availableActions() -> Set<String> {
        guard let info = ((buildManifest()["characters"] as? [String: Any])?[current]) as? [String: Any] else { return [] }
        var have = Set<String>()
        for k in ((info["poses"] as? [String: Any]) ?? [:]).keys where k != "default" { have.insert(k) }
        let sheets = (info["sheets"] as? [String: Any]) ?? [:]
        if let anims = info["animations"] as? [String: Any] {
            for (k, v) in anims {
                guard let cfg = v as? [String: Any], (cfg["hidden"] as? Bool) != true,
                      let list = cfg["sheets"] as? [String] else { continue }
                if list.contains(where: { sheets[$0] != nil }) { have.insert(k) }
            }
        }
        return have
    }

    func actionMenu() -> NSMenu? {
        let have = availableActions()
        if have.isEmpty { return nil }
        let root = NSMenu()
        root.autoenablesItems = false
        var used = Set<String>()
        func add(_ parent: NSMenu, _ pose: String, _ label: String) {
            let i = NSMenuItem(title: label, action: #selector(menuAction(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = pose
            parent.addItem(i)
        }
        for (group, poses) in actionGroups {
            let sub = NSMenu(); sub.autoenablesItems = false
            for p in poses where have.contains(p) { used.insert(p); add(sub, p, actionNames[p] ?? p) }
            if sub.numberOfItems > 0 {
                let g = NSMenuItem(title: group, action: nil, keyEquivalent: "")
                g.submenu = sub
                root.addItem(g)
            }
        }
        let others = have.subtracting(used).sorted()
        if !others.isEmpty {
            let sub = NSMenu(); sub.autoenablesItems = false
            for p in others { add(sub, p, p) }
            let g = NSMenuItem(title: "其他", action: nil, keyEquivalent: "")
            g.submenu = sub
            root.addItem(g)
        }
        return root
    }

    @objc func menuAction(_ s: NSMenuItem) {
        guard let pose = s.representedObject as? String else { return }
        playAction(pose)
    }

    /// 和 Linux 版 play_action 同一段脚本：播放、能走的就走、非一次性的 6 秒后回待机
    func playAction(_ pose: String) {
        eval("(function(p){ if (typeof show !== 'function') return; show(p, true);"
           + " clearTimeout(window.__claudiaMenuTimer);"
           + " if (typeof anim === 'function' && anim(p) && anim(p).walk && typeof startWalk === 'function' && startWalk(p)) return;"
           + " if (typeof anim === 'function' && anim(p) && transientMs(p)) return;"
           + " window.__claudiaMenuTimer = setTimeout(function(){ if (pose === p) show('idle', true); }, 6000); })(\(js(pose)))")
    }

    @objc func menuQuota(_ s: NSMenuItem) {
        settings["quotaStyle"] = s.tag == 1 ? "bars" : "text"; saveSettings()
        eval("setQuotaStyle(\(js(quotaStyle())))")
    }
    func alert(_ text: String) {
        let a = NSAlert(); a.messageText = appName; a.informativeText = text; a.runModal()
    }
    @objc func menuPlugin(_ s: NSMenuItem) {
        do { alert(try Connect.setPlugin(install: s.tag == 1)) } catch { alert("出错了：\(error.localizedDescription)") }
    }
    @objc func menuMcp(_ s: NSMenuItem) {
        do { alert(try Connect.setMcp(install: s.tag == 1)) } catch { alert("出错了：\(error.localizedDescription)") }
    }
    // ---- 菜单栏图标：桌宠隐藏、被挡住时也能找到她；菜单和右键菜单是同一份 ----
    func setupTray() {
        if !settingOn("trayIcon") {
            if let t = trayItem { NSStatusBar.system.removeStatusItem(t); trayItem = nil }
            return
        }
        if trayItem != nil { return }
        let t = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = t.button {
            b.image = trayImage()
            b.toolTip = "Claudia"
        }
        let m = NSMenu()
        m.autoenablesItems = false
        m.delegate = self
        t.menu = m
        trayItem = t
    }

    /// 彩色应用图标缩到 18 点（用户选的：单色线稿缩到 18 点糊成一团）。不是模板图，不随浅色/深色菜单栏变色
    func trayImage() -> NSImage {
        let path = installRoot + "/icon/AppIcon.png"
        let src = NSImage(contentsOfFile: path) ?? NSApp.applicationIconImage
        if src == nil { log("菜单栏图标：没找到 \(path)，也没有应用图标") }
        let img = (src?.copy() as? NSImage) ?? NSImage()
        img.size = NSSize(width: 18, height: 18)
        return img
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === trayItem?.menu else { return }
        let fresh = buildMenu()
        let items = fresh.items
        fresh.removeAllItems()
        menu.removeAllItems()
        for i in items { menu.addItem(i) }
    }

    @objc func menuTray() {
        settings["trayIcon"] = !settingOn("trayIcon"); saveSettings()
        setupTray()
    }

    @objc func menuChatWatch() {
        let on = !settingFlag("chatWatch")
        settings["chatWatch"] = on; saveSettings()
        if !on { chatWatch.stop(); chatBeat?.invalidate(); chatBeat = nil; return }
        chatWatch.start()
        if !AXProbe.trusted(prompt: true) {
            alert("聊天模式动画需要辅助功能权限：系统设置 → 隐私与安全性 → 辅助功能，打开 claudia-pet（列表里没有就点 + 加 \(Bundle.main.bundlePath)）。授权后自动生效，不用重开。")
        }
    }
    @objc func menuAXProbe() {
        guard let pid = claudePid() else { alert("没找到正在运行的 Claude。"); return }
        if !AXProbe.trusted(prompt: true) {
            alert("需要辅助功能权限：系统设置 → 隐私与安全性 → 辅助功能，打开 claudia-pet（列表里没有就点 + 加 \(Bundle.main.bundlePath)）。授权后再点一次这个菜单。")
            return
        }
        alert("开始记录 60 秒。现在去 Claude 的聊天标签发一句话，等她回完。结果写在 ~/.claudia/ax-probe.log。")
        AXProbe.run(pid: pid, seconds: 60)
    }
    @objc func menuLog() { NSWorkspace.shared.open(URL(fileURLWithPath: dataDir + "/mac.log")) }
    @objc func menuQuit() {
        try? fm.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
        fm.createFile(atPath: dataDir + "/user-quit", contents: Data())   // 之后 --ensure 不再自动叫她出来，直到手动再打开一次
        if quitting { return }
        quitting = true
        // 挥手道别再走（同 Windows 版 UserQuit）：第一次退出时说明什么时候会再出来，多停一会儿让人看清
        let hint = !settingFlag("quitHinted")
        if hint { settings["quitHinted"] = true; saveSettings() }
        let when = (settings["runMode"] as? String) == "standalone" ? "下次打开我就回来" : "下次打开 Claude 我再出来"
        guard ready, !concealed else { NSApp.terminate(nil); return }
        eval(hint ? "farewell(\(js("我先走啦～" + when)), 5000)" : "farewell(null, 2000)")
        DispatchQueue.main.asyncAfter(deadline: .now() + (hint ? 5 : 2)) { NSApp.terminate(nil) }
    }
}

// MARK: - 设置窗口（加载 web/settings.html，和 Windows / Linux 版共用同一个页面）

final class SettingsController: NSObject, WKScriptMessageHandler, WKNavigationDelegate, NSWindowDelegate {
    weak var pet: Pet?
    var window: NSWindow!
    var web: WKWebView!
    var loaded = false

    init(pet: Pet) {
        self.pet = pet
        super.init()
        let conf = WKWebViewConfiguration()
        conf.setURLSchemeHandler(SchemeHandler(), forURLScheme: schemeName)
        let ucc = WKUserContentController()
        ucc.addUserScript(WKUserScript(source: shimScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.add(self, name: "claudia")
        conf.userContentController = ucc
        web = WKWebView(frame: .zero, configuration: conf)
        web.navigationDelegate = self
        let h = min(780, (NSScreen.main?.visibleFrame.height ?? 800) - 40)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: h),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(appName) 设置"
        window.minSize = NSSize(width: 420, height: 300)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = web
        window.center()
        web.load(URLRequest(url: URL(string: "\(schemeName)://app/settings.html")!))
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func push() {
        guard loaded, let pet = pet else { return }
        web.evaluateJavaScript("setState(\(js(pet.settingsState())))", completionHandler: nil)
    }

    func toast(_ text: String) { web.evaluateJavaScript("toast(\(js(text)))", completionHandler: nil) }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let u = action.request.url, u.scheme == schemeName, u.host == "app" { decisionHandler(.allow) } else { decisionHandler(.cancel) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true; push() }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let s = message.body as? String, let d = s.data(using: .utf8),
              let m = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return }
        pet?.handleSettings(m)
        push()
    }

    func windowWillClose(_ n: Notification) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "claudia")
        pet?.settingsController = nil
    }
}

extension Pet {
    func openSettings() {
        if settingsController == nil { settingsController = SettingsController(pet: self) }
        settingsController?.show()
    }

    func displayName() -> String {
        let chars = (buildManifest()["characters"] as? [String: Any]) ?? [:]
        return ((chars[current] as? [String: Any])?["name"] as? String) ?? current
    }

    func settingsState() -> [String: Any] {
        var chars: [[String: Any]] = []
        let all = (buildManifest()["characters"] as? [String: Any]) ?? [:]
        for cid in all.keys.sorted() {
            let info = readJSON(charactersDir + "/" + cid + "/character.json") ?? [:]
            let def = (info["name"] as? String) ?? cid
            let custom = ((settings["names"] as? [String: Any])?[cid] as? String) ?? ""
            chars.append(["id": cid, "name": custom.isEmpty ? def : custom, "defaultName": def,
                          "accent": info["accent"] ?? NSNull(), "custom": custom])
        }
        var physics: [String: Any] = [:]
        for (k, r) in physicsRanges { physics[k] = settingNum(k, r.0, r.1, r.2) }
        var freq = "normal"
        if let f = settings["idleFrequency"] as? String, ["quiet", "normal", "lively"].contains(f) { freq = f }
        var aura = "auto"
        if let a = settings["auraMode"] as? String, ["on", "off"].contains(a) { aura = a }
        return [
            "version": appVersion() + " macOS", "platform": "mac", "appVersion": appVersion(), "claudeWindow": true,
            "size": Double(scale()), "textSize": settingNum("textSize", 0.6, 1.6, 1.0), "textLinked": (settings["textLinked"] as? Bool) ?? true,
            "showName": (settings["showName"] as? Bool) ?? true, "aura": aura, "powerSave": settingFlag("powerSave"),
            "quotaStyle": quotaStyle(),
            "clickBounce": settingOn("clickBounce"), "tumbleActions": settingOn("tumbleActions"),
            "idleEnabled": settingOn("idleEnabled"), "idleFrequency": freq,
            "notifyResults": settingOn("notifyResults"), "notifyWaiting": settingOn("notifyWaiting"),
            "notifyBackgroundOnly": settingOn("notifyBackgroundOnly"),
            "physicsEnabled": settingOn("physicsEnabled"), "ceilingBounce": settingOn("ceilingBounce"), "physics": physics,
            "character": current, "characters": chars,
            "integrations": Connect.integrations(),
            "runMode": (settings["runMode"] as? String) == "standalone" ? "standalone" : "claude",
            "pets": [["id": "main", "index": 1, "self": true, "name": displayName(), "mode": wantFollow() ? "claude" : "desktop"]],
            "maxPets": 1,
            "hideHotkey": hideHotkey(), "hotkeyFailed": hotkeyFailed,
            "hotkeys": [["id": "off", "label": "不用快捷键"]] + Hotkey.choices.map { ["id": $0.id, "label": $0.label] },
            "hotkeyHint": "按一下藏起来，再按一下出来；也可以从菜单栏图标的菜单里叫她出来",
        ]
    }

    func handleSettings(_ msg: [String: Any]) {
        let cmd = msg["cmd"] as? String
        if cmd == "set", let key = msg["key"] as? String {
            let value = msg["value"]
            let on = (value as? Bool) == true
            let num = (value as? NSNumber).flatMap { ($0.doubleValue).isFinite ? $0.doubleValue : nil }
            switch key {
            case "clickBounce", "tumbleActions", "idleEnabled":
                if let b = value as? Bool { settings[key] = b; saveSettings(); pushBehavior() }
            case "idleFrequency":
                if let v = value as? String, ["quiet", "normal", "lively"].contains(v) { settings[key] = v; saveSettings(); pushBehavior() }
            case "notifyResults", "notifyWaiting", "notifyBackgroundOnly":
                if let b = value as? Bool { settings[key] = b; saveSettings() }
            case "physicsEnabled", "ceilingBounce":
                if let b = value as? Bool {
                    settings[key] = b; saveSettings()
                    if key == "physicsEnabled" && !b { stopMotion(save: true) }
                    else if dragging || flying { eval("petMotion.update(\(js(motionPacket())))") }
                }
            case "throwPower", "gravity", "restitution", "groundFriction", "elasticity":
                if let n = num, let r = physicsRanges[key], n >= r.0, n <= r.1 {
                    settings[key] = n; saveSettings()
                    if dragging || flying { eval("petMotion.update(\(js(motionPacket())))") }
                }
            case "size":
                if let n = num { settings["size"] = min(max((n * 100).rounded() / 100, 0.6), 1.6); saveSettings(); applySizes(anchor: "feet") }
            case "textSize":
                if let n = num { settings["textSize"] = min(max((n * 100).rounded() / 100, 0.6), 1.6); settings["textLinked"] = false; saveSettings(); applySizes(anchor: "feet") }
            case "textLinked":
                settings["textLinked"] = (value as? Bool) != false; saveSettings(); applySizes(anchor: "feet")
            case "showName":
                settings["showName"] = on; saveSettings(); eval("setShowName(\(js(on)))")
            case "quotaStyle":
                if let v = value as? String, ["text", "bars"].contains(v) { settings["quotaStyle"] = v; saveSettings(); eval("setQuotaStyle(\(js(v)))") }
            case "hideHotkey":
                if let v = value as? String, v == "off" || Hotkey.label(v) != nil { settings["hideHotkey"] = v; saveSettings(); registerHotkey() }
            case "runMode":
                if let v = value as? String, ["claude", "standalone"].contains(v) { settings["runMode"] = v; saveSettings() }
            case "powerSave":
                settings["powerSave"] = on; saveSettings(); eval("setPowerSave(\(js(on)))")
            case "aura":
                if let v = value as? String, ["auto", "on", "off"].contains(v) { settings["auraMode"] = v; saveSettings(); eval("setAuraMode(\(js(v)))") }
            default: break
            }
        } else if cmd == "resetPhysics" {
            stopMotion(save: true)
            for k in Array(physicsRanges.keys) + ["physicsEnabled", "ceilingBounce"] { settings.removeValue(forKey: k) }
            saveSettings()
        } else if cmd == "rename", let id = msg["id"] as? String {
            let name = ((msg["name"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            var names = (settings["names"] as? [String: Any]) ?? [:]
            if name.isEmpty { names.removeValue(forKey: id) } else { names[id] = name }
            settings["names"] = names; saveSettings()
            let shown = ((buildManifest()["characters"] as? [String: Any])?[id] as? [String: Any])?["name"] as? String ?? id
            eval("setName(\(js(id)), \(js(shown)))")
        } else if cmd == "pet", let action = msg["action"] as? String {
            if action == "rename" {
                let name = ((msg["value"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
                handleSettings(["cmd": "rename", "id": current, "name": name])
            } else if action == "mode", let v = msg["value"] as? String { setFollowMode(v == "claude") }
            // add / dismiss：mac 版暂时没有多开
        } else if cmd == "integrate", let target = msg["target"] as? String, let action = msg["action"] as? String {
            do {
                let text = target == "plugin" ? try Connect.setPlugin(install: action == "install") : try Connect.setMcp(install: action == "install")
                log("接入 \(target) \(action)：" + text.replacingOccurrences(of: "\n", with: " "))
                alert(text)
            } catch { alert("没有完成：\(error.localizedDescription)") }
        } else if cmd == "action", let name = msg["name"] as? String {
            var target: String? = nil
            switch name {
            case "openCharacters": target = charactersDir
            case "openData": try? fm.createDirectory(atPath: dataDir, withIntermediateDirectories: true); target = dataDir
            case "openUpstream": target = "https://github.com/lokicorvus/crosspet"
            case "openDshPet": target = "https://github.com/PC2005-cloud/dsh-pet"
            case "openAboutmePets": target = "https://github.com/hunmer/aboutme-pets"
            default: break
            }
            if let t = target { NSWorkspace.shared.open(t.contains("://") ? URL(string: t)! : URL(fileURLWithPath: t)) }
        }
    }

    func pushBehavior() {
        let freq = ["quiet", "normal", "lively"].contains(settings["idleFrequency"] as? String ?? "") ? settings["idleFrequency"] as! String : "normal"
        let b: [String: Any] = ["idleEnabled": settingOn("idleEnabled"), "idleFrequency": freq,
                                "clickBounce": settingOn("clickBounce"), "tumbleActions": settingOn("tumbleActions")]
        eval("setBehavior(\(js(b)))")
    }
}

// MARK: - 接入 Claude（对应 Linux 版 claude.py）

enum ConnectError: LocalizedError {
    case msg(String)
    var errorDescription: String? { if case .msg(let s) = self { return s }; return nil }
}

enum Connect {
    static var pluginDir: String { installRoot + "/plugin" }
    static var claudeSettings: String { (envVar("CLAUDE_CONFIG_DIR") ?? homeDir + "/.claude") + "/settings.json" }
    static var desktopConfig: String { homeDir + "/Library/Application Support/Claude/claude_desktop_config.json" }

    static func samePath(_ a: String, _ b: String) -> Bool {
        let x = URL(fileURLWithPath: (a.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath).resolvingSymlinksInPath().path
        return x == URL(fileURLWithPath: b).resolvingSymlinksInPath().path
    }

    static func pluginDirs(_ s: [String: Any]?) -> [String] {
        guard let env = s?["env"] as? [String: Any], let v = env["CLAUDE_CODE_PLUGIN_DIRS"] as? String else { return [] }
        return v.split(separator: ":").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    static func pluginInstalled() -> Bool { pluginDirs(readJSON(claudeSettings)).contains { samePath($0, pluginDir) } }
    static func mcpInstalled() -> Bool { ((readJSON(desktopConfig)?["mcpServers"] as? [String: Any])?[appName]) != nil }

    static func seenText() -> String {
        guard let t = readText(stateDir + "/seen-plugin"), let ts = Double(t.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return "还没收到过消息：新开一个 Code 会话、让她干点活试试"
        }
        let ago = Date().timeIntervalSince1970 - ts
        let when = ago < 60 ? "刚刚" : ago < 3600 ? "\(Int(ago / 60)) 分钟前" : ago < 86400 ? "\(Int(ago / 3600)) 小时前" : "\(Int(ago / 86400)) 天前"
        return "上次收到消息：" + when
    }

    static func integrations() -> [[String: Any]] {
        let plug = pluginInstalled(), mcp = mcpInstalled()
        var a: [String: Any] = ["id": "plugin", "label": "Claude Code 插件", "installed": plug,
                                "note": "Code 会话的工作状态和额度；会话开始时叫她出来。新开的会话生效"]
        if plug { a["detail"] = seenText() }
        let b: [String: Any] = ["id": "mcp", "label": "Claude 桌面端（MCP）", "installed": mcp,
                                "note": "Claude 一打开就叫她出来，只用对话时也在（对话里没有工作状态）。重开 Claude 生效"]
        return [a, b]
    }

    static func backup(_ path: String) -> String? {
        guard fm.fileExists(atPath: path) else { return nil }
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmmss"
        let copy = path + ".bak-claudia-" + df.string(from: Date())
        try? fm.copyItem(atPath: path, toPath: copy)
        let dir = (path as NSString).deletingLastPathComponent, base = (path as NSString).lastPathComponent + ".bak-claudia-"
        let olds = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix(base) }.sorted(by: >)
        for o in olds.dropFirst(3) { try? fm.removeItem(atPath: dir + "/" + o) }
        return copy
    }

    static func setPlugin(install: Bool) throws -> String {
        if install && !fm.fileExists(atPath: pluginDir + "/.claude-plugin/plugin.json") {
            throw ConnectError.msg("没找到插件文件夹：\(pluginDir)")
        }
        if !install && !pluginInstalled() { return "没有接入过 Claude Code 插件，不用撤销。" }
        let f = claudeSettings
        var settings = readJSON(f) ?? [:]
        if readJSON(f) == nil && fm.fileExists(atPath: f) { throw ConnectError.msg("读不懂 \(f)，这次没有改。") }
        var dirs = pluginDirs(settings).filter { !samePath($0, pluginDir) }
        if install { dirs.append(pluginDir) }
        var env = (settings["env"] as? [String: Any]) ?? [:]
        if dirs.isEmpty { env.removeValue(forKey: "CLAUDE_CODE_PLUGIN_DIRS") } else { env["CLAUDE_CODE_PLUGIN_DIRS"] = dirs.joined(separator: ":") }
        if env.isEmpty { settings.removeValue(forKey: "env") } else { settings["env"] = env }
        let b = backup(f)
        try writeJSON(f, settings, pretty: true)
        return (install ? "已接入 Claude Code 插件。新开的 Code 会话生效。" : "已撤销 Claude Code 插件。") + "\n\n改了：\(f)" + (b.map { "\n备份：\($0)" } ?? "")
    }

    static func setMcp(install: Bool) throws -> String {
        if !install && !mcpInstalled() { return "没有接入过 Claude 桌面端，不用撤销。" }
        let f = desktopConfig
        var cfg = readJSON(f) ?? [:]
        if readJSON(f) == nil && fm.fileExists(atPath: f) { throw ConnectError.msg("读不懂 \(f)，这次没有改。") }
        var servers = (cfg["mcpServers"] as? [String: Any]) ?? [:]
        if install { servers[appName] = ["command": exePath, "args": ["--mcp"]] } else { servers.removeValue(forKey: appName) }
        if servers.isEmpty { cfg.removeValue(forKey: "mcpServers") } else { cfg["mcpServers"] = servers }
        let b = backup(f)
        try writeJSON(f, cfg, pretty: true)
        return (install ? "已接入 Claude 桌面端。完全退出 Claude 再打开后生效。" : "已撤销 Claude 桌面端的接入。重开 Claude 后生效。") + "\n\n改了：\(f)" + (b.map { "\n备份：\($0)" } ?? "")
    }
}

// MARK: - 任务通知（去重和节流照搬 Windows 版 TaskNoticePolicy.cs）

// ---- 全局快捷键：Carbon 的 RegisterEventHotKey，系统级、不需要辅助功能权限 ----
final class Hotkey {
    static let choices: [(id: String, label: String, key: Int)] = [("p", "⌃⌥P", kVK_ANSI_P), ("h", "⌃⌥H", kVK_ANSI_H)]
    static func label(_ id: String) -> String? { choices.first { $0.id == id }?.label }
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?

    func register(_ id: String, _ action: @escaping () -> Void) -> Bool {
        guard let c = Hotkey.choices.first(where: { $0.id == id }) else { return false }
        self.action = action
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let me = Unmanaged.passUnretained(self).toOpaque()
            InstallEventHandler(GetApplicationEventTarget(), { _, _, data in
                guard let data = data else { return noErr }
                let hk = Unmanaged<Hotkey>.fromOpaque(data).takeUnretainedValue()
                DispatchQueue.main.async { hk.action?() }
                return noErr
            }, 1, &spec, me, &handler)
        }
        let hid = EventHotKeyID(signature: OSType(0x434C5044), id: 1)   // 'CLPD'
        let st = RegisterEventHotKey(UInt32(c.key), UInt32(controlKey | optionKey), hid, GetApplicationEventTarget(), 0, &ref)
        return st == noErr
    }
    func unregister() {
        if let r = ref { UnregisterEventHotKey(r); ref = nil }
    }
}

// ---- 聊天模式（非 Code）的动画：Claude 回复时输入框旁的「发送消息」按钮会换成「停止回复」，回完换回来 ----
// 2026-11-19 用诊断记录确认过（中文界面）。Code 标签里的停止按钮叫「停止」，不会混。英文界面的名字没验证过，是猜的。
// 只读按钮的名字，不读聊天正文。需要辅助功能权限；Electron 默认不给辅助功能树，要设 AXManualAccessibility 打开
final class ChatWatch {
    static let stopLabels: Set<String> = ["停止回复", "Stop response"]
    static let sendLabels: Set<String> = ["发送消息", "Send message"]
    private let queue = DispatchQueue(label: "claudia.chatwatch", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var pid: pid_t = 0
    private var app: AXUIElement?
    private var composer: AXUIElement?   // 发送 / 停止按钮的父元素：找到一次后只看它的子元素，省得每次扫整棵树
    private var lastFullScan = 0.0
    private var streaming = false
    /// 在主线程回调：true = 开始回复，false = 回完了
    var onChange: ((Bool) -> Void)?
    var pidProvider: (() -> pid_t?)?

    func start() {
        if timer != nil { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 0.7)
        t.setEventHandler { [weak self] in self?.step() }
        t.resume(); timer = t
    }
    func stop() {
        timer?.cancel(); timer = nil
        queue.async { [weak self] in
            guard let me = self else { return }
            me.app = nil; me.composer = nil; me.pid = 0; me.streaming = false   // 关掉时不报「回完了」
        }
    }

    private func label(_ e: AXUIElement) -> String {
        let d = AXProbe.str(e, kAXDescriptionAttribute)
        return d.isEmpty ? AXProbe.str(e, kAXTitleAttribute) : d
    }
    /// 在这些子元素里找发送 / 停止按钮：nil = 都没有，true = 停止，false = 发送
    private func check(_ kids: [AXUIElement]) -> Bool? {
        var sawSend = false
        for k in kids where AXProbe.str(k, kAXRoleAttribute) == "AXButton" {
            let l = label(k)
            if ChatWatch.stopLabels.contains(l) { return true }
            if ChatWatch.sendLabels.contains(l) { sawSend = true }
        }
        return sawSend ? false : nil
    }
    /// 扫整棵树找按钮，记下它的父元素
    private func fullScan(_ app: AXUIElement) -> Bool? {
        var stack: [(AXUIElement, Int)] = ((AXProbe.attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []).map { ($0, 0) }
        var seen = 0
        while let (e, depth) = stack.popLast(), seen < 30000 {
            seen += 1
            guard depth < 80, let kids = AXProbe.attr(e, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            if let r = check(kids) { composer = e; return r }
            for k in kids { stack.append((k, depth + 1)) }
        }
        return nil
    }

    private var lastNote = ""
    /// 状态变了才写日志，排查用
    private func note(_ s: String) { if s != lastNote { lastNote = s; DispatchQueue.main.async { log("聊天监视：" + s) } } }

    private func step() {
        guard AXProbe.trusted(prompt: false) else {
            note("没有辅助功能权限（\(Bundle.main.bundlePath)）")
            app = nil; composer = nil; pid = 0
            set(false); return
        }
        guard let p = DispatchQueue.main.sync(execute: { pidProvider?() }) else {
            note("没找到 Claude")
            app = nil; composer = nil; pid = 0
            set(false); return
        }
        if p != pid || app == nil {
            pid = p; composer = nil
            let a = AXUIElementCreateApplication(p)
            AXUIElementSetAttributeValue(a, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            app = a
        }
        var now: Bool? = nil
        if let c = composer, let kids = AXProbe.attr(c, kAXChildrenAttribute) as? [AXUIElement] { now = check(kids) }
        if now == nil {
            composer = nil
            // 输入框不在（切到 Code 标签、设置页之类）：整棵树最多每 3 秒扫一次（一次 60–270 毫秒）
            let t = ProcessInfo.processInfo.systemUptime
            if t - lastFullScan >= 3, let a = app {
                lastFullScan = t; now = fullScan(a)
                note(now == nil ? "看不到聊天输入框的发送 / 停止按钮" : "找到聊天输入框")
            }
        }
        // 看不到输入框时状态不动：中途切走不算回完（真卡住了网页 3 分钟后自己回待机）
        if let s = now { set(s) }
    }
    private func set(_ s: Bool) {
        if s == streaming { return }
        streaming = s
        DispatchQueue.main.async { [weak self] in self?.onChange?(s) }
    }
}

// ---- 诊断：用辅助功能读 Claude 窗口里的按钮，找「正在回复」的信号（只读按钮名和 DOM 标识，不读聊天正文） ----
enum AXProbe {
    static func trusted(prompt: Bool) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }
    static func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }
    static func str(_ e: AXUIElement, _ name: String) -> String {
        if let s = attr(e, name) as? String { return s }
        if let a = attr(e, name) as? [String] { return a.joined(separator: ".") }
        return ""
    }
    /// 所有按钮的描述，一行一个：角色 | 标题 | 描述 | DOM id | DOM class
    static func buttons(_ app: AXUIElement) -> (Set<String>, Int) {
        var out = Set<String>(), seen = 0
        var stack: [(AXUIElement, Int)] = ((attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []).map { ($0, 0) }
        while let (e, depth) = stack.popLast(), seen < 30000 {
            seen += 1
            let role = str(e, kAXRoleAttribute)
            if role == "AXButton" || role == "AXMenuButton" || role == "AXPopUpButton" {
                let parts = [role, str(e, kAXTitleAttribute), str(e, kAXDescriptionAttribute), str(e, "AXDOMIdentifier"), str(e, "AXDOMClassList")]
                out.insert(parts.joined(separator: " | "))
            }
            if depth < 80, let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] {
                for k in kids { stack.append((k, depth + 1)) }
            }
        }
        return (out, seen)
    }
    static func run(pid: pid_t, seconds: Int) {
        let path = dataDir + "/ax-probe.log"
        DispatchQueue.global(qos: .utility).async {
            let app = AXUIElementCreateApplication(pid)
            // Electron 默认不给辅助功能树，要主动打开
            let r1 = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            let r2 = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            var text = "==== \(Date()) 开始记录，Claude pid \(pid)，AXManualAccessibility=\(r1.rawValue) AXEnhancedUserInterface=\(r2.rawValue)\n"
            Thread.sleep(forTimeInterval: 1.5)
            var prev = Set<String>()
            let df = DateFormatter(); df.dateFormat = "HH:mm:ss.S"
            for i in 0..<(seconds * 2) {
                let t0 = Date()
                let (now, seen) = buttons(app)
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                if i == 0 {
                    text += "\(df.string(from: Date())) 共 \(seen) 个节点，\(now.count) 个按钮，用时 \(ms) 毫秒：\n" + now.sorted().map { "    " + $0 }.joined(separator: "\n") + "\n"
                } else if now != prev {
                    text += "\(df.string(from: Date())) 节点 \(seen)，用时 \(ms) 毫秒\n"
                    for b in now.subtracting(prev).sorted() { text += "  + " + b + "\n" }
                    for b in prev.subtracting(now).sorted() { text += "  - " + b + "\n" }
                }
                prev = now
                try? text.write(toFile: path, atomically: true, encoding: .utf8)
                Thread.sleep(forTimeInterval: max(0, 0.5 - Date().timeIntervalSince(t0)))
            }
            text += "==== 结束\n"
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
            DispatchQueue.main.async { Notifier.post("claudia-pet 诊断", "按钮记录完成，见 ~/.claudia/ax-probe.log") }
        }
    }
}

final class TaskNoticePolicy {
    let started: Double
    var seen = Set<String>()
    var shown: [String: Double] = [:]
    init(started: Double) { self.started = started }

    func accept(_ nid: String, _ kind: String, _ ts: Double, _ now: Double, enabled: Bool, foreground: Bool, backgroundOnly: Bool) -> Bool {
        if nid.isEmpty || seen.contains(nid) { return false }
        seen.insert(nid)
        if seen.count > 2000 { seen = [nid] }
        guard ["complete", "error", "waiting"].contains(kind) else { return false }
        if ts.isNaN || ts < started || ts > now + 5 || now - ts > 60 { return false }
        if !enabled || (backgroundOnly && foreground) { return false }
        // 一小段时间里来好几条（重复的信号）只弹一次，也不攒着补弹
        if let t = shown[kind], now - t < 8 { return false }
        shown[kind] = now
        return true
    }
}

final class NotifDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler h: @escaping (UNNotificationPresentationOptions) -> Void) {
        h([.banner, .sound])
    }
    /// 点通知：回到 Claude
    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse, withCompletionHandler h: @escaping () -> Void) {
        claudeApp()?.activate(options: [])
        h()
    }
}

enum Notifier {
    /// 只有打成 .app 包（有 bundle id）才能用系统通知中心；直接跑裸二进制时退回 osascript
    static var native: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }
    static let delegate = NotifDelegate()

    static func setup() {
        guard native else { return }
        let c = UNUserNotificationCenter.current()
        c.delegate = delegate
        c.requestAuthorization(options: [.alert, .sound]) { ok, err in
            log("通知授权：\(ok ? "已允许" : "未允许")" + (err.map { "（\($0.localizedDescription)）" } ?? ""))
        }
    }

    static func post(_ title: String, _ body: String) {
        guard native else { return viaScript(title, body) }
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)) { err in
            if let e = err { log("系统通知失败：\(e.localizedDescription)"); viaScript(title, body) }
        }
    }

    static func viaScript(_ title: String, _ body: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "on run argv", "-e", "display notification (item 1 of argv) with title (item 2 of argv)", "-e", "end run", body, title]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}

// MARK: - Claude 桌面端进程

func claudeApp() -> NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first {
        $0.bundleIdentifier == "com.anthropic.claudefordesktop"
            || ($0.localizedName == "Claude" && ($0.bundleIdentifier ?? "").hasPrefix("com.anthropic"))
    }
}

// MARK: - 单实例、--ensure、--mcp

var lockFD: Int32 = -1

func takeLock() -> Bool {
    try? fm.createDirectory(atPath: runDir, withIntermediateDirectories: true)
    let fd = open(runDir + "/main.lock", O_RDWR | O_CREAT, 0o600)
    if fd < 0 { return true }
    if flock(fd, LOCK_EX | LOCK_NB) != 0 { close(fd); return false }
    lockFD = fd
    return true
}

func petRunning() -> Bool {
    try? fm.createDirectory(atPath: runDir, withIntermediateDirectories: true)
    let fd = open(runDir + "/main.lock", O_RDWR | O_CREAT, 0o600)
    if fd < 0 { return false }
    defer { close(fd) }
    if flock(fd, LOCK_EX | LOCK_NB) == 0 { flock(fd, LOCK_UN); return false }
    return true
}

/// 起一个独立会话的进程：插件和 MCP 都是 Claude 的子进程，Claude 关掉时不能把她一起带走
func launchDetached(_ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    let bundleExe = exePath.contains(".app/Contents/MacOS/") ? exePath
        : (exePath as NSString).deletingLastPathComponent + "/claudia-pet.app/Contents/MacOS/claudia-pet"
    p.arguments = ["-MPOSIX", "-e", "POSIX::setsid(); exec @ARGV", fm.isExecutableFile(atPath: bundleExe) ? bundleExe : exePath] + args
    p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    p.currentDirectoryURL = URL(fileURLWithPath: homeDir)
    do { try p.run(); return "已打开" } catch { return "打开失败：\(error.localizedDescription)" }
}

func ensure() -> String {
    if petRunning() { return "已经在跑" }
    let flag = dataDir + "/user-quit"
    if let a = try? fm.attributesOfItem(atPath: flag), let quitAt = a[.modificationDate] as? Date {
        // 菜单退出之后，只有「那之前就开着的 Claude」不再叫她；Claude 重新打开过就恢复
        if let launched = claudeApp()?.launchDate, launched > quitAt { try? fm.removeItem(atPath: flag) }
        else { return "不打开：你从菜单退出过，这个 Claude 是在那之前就开着的" }
    }
    return launchDetached(["--by-claude"])
}

func mcpServe() {
    log("MCP 服务启动：" + ensure())
    while let line = readLine() {
        guard let d = line.data(using: .utf8), let msg = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let id = msg["id"] else { continue }   // 通知不用回
        var reply: [String: Any] = ["jsonrpc": "2.0", "id": id]
        switch msg["method"] as? String ?? "" {
        case "initialize":
            let pv = ((msg["params"] as? [String: Any])?["protocolVersion"] as? String) ?? "2024-11-05"
            reply["result"] = ["protocolVersion": pv, "capabilities": ["tools": [String: Any]()],
                               "serverInfo": ["name": appName, "version": appVersion()],
                               "instructions": "\(appName) 是 Claude 娘桌宠，只借这个连接跟着 Claude 打开和关闭，不提供工具。"]
        case "ping": reply["result"] = [String: Any]()
        case "tools/list": reply["result"] = ["tools": [Any]()]
        default: reply["error"] = ["code": -32601, "message": "\(appName) 不提供这个功能"]
        }
        if let out = try? JSONSerialization.data(withJSONObject: reply, options: [.withoutEscapingSlashes]) {
            FileHandle.standardOutput.write(out + Data([10]))
        }
    }
    log("MCP 服务结束")
}

// MARK: - 入口

final class AppDelegate: NSObject, NSApplicationDelegate {
    var pet: Pet!
    func applicationDidFinishLaunching(_ n: Notification) {
        Notifier.setup()
        installMainMenu()
        pet = Pet()
        pet.followClaude = CommandLine.arguments.contains("--by-claude")
        pet.start()
        pet.setupTray()
    }
    /// 没有主菜单的话设置页里的输入框用不了 ⌘C / ⌘V
    func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appItem.submenu = appMenu
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }
}

/// 打成 .app 包的二进制才有 bundle id（系统通知要用）。从符号链接或裸二进制启动时，换到包里的那份重新启动自己
func reexecIntoBundleIfNeeded() {
    guard Bundle.main.bundleIdentifier == nil, envVar("CLAUDIA_REEXEC") == nil else { return }
    let inside = exePath.contains(".app/Contents/MacOS/")
    let be = inside ? exePath : (exePath as NSString).deletingLastPathComponent + "/claudia-pet.app/Contents/MacOS/claudia-pet"
    guard fm.isExecutableFile(atPath: be) else { return }
    setenv("CLAUDIA_REEXEC", "1", 1)
    var cargs: [UnsafeMutablePointer<CChar>?] = ([be] + Array(CommandLine.arguments.dropFirst())).map { strdup($0) } + [nil]
    execv(be, &cargs)
}

func runMain() {
    reexecIntoBundleIfNeeded()
    let args = Array(CommandLine.arguments.dropFirst())
    func has(_ a: String) -> Bool { args.contains(a) }
    func targetAfter(_ flag: String) -> String {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count, !args[i + 1].hasPrefix("--") else { return "all" }
        return args[i + 1]
    }
    if has("--mcp") { mcpServe(); exit(0) }
    if has("--ensure") { print(ensure()); exit(0) }
    for (flag, install) in [("--connect", true), ("--disconnect", false)] where has(flag) {
        let t = targetAfter(flag)
        do {
            if t == "plugin" || t == "all" { print(try Connect.setPlugin(install: install)) }
            if t == "mcp" || t == "all" { print(try Connect.setMcp(install: install)) }
        } catch { print("出错了：\(error.localizedDescription)"); exit(1) }
        exit(0)
    }
    if !has("--by-claude") { try? fm.removeItem(atPath: dataDir + "/user-quit") }   // 手动打开：恢复自动叫出
    if !takeLock() { print("\(appName) 已经在运行"); exit(0) }
    log("启动 \(appName) mac 版 \(appVersion())，安装目录 \(installRoot)")
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)   // 不进 Dock、不抢焦点
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}

runMain()
