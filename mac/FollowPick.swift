// 跟随 Claude 窗口时「跟哪个窗口、要不要给对话框让开」的判断。只吃数据、不碰系统接口，方便单独测试（mac/tests/FollowPickTests.swift）。
import CoreGraphics

struct FollowWindow {
    let index: Int      // 在 CGWindowList 里的位置：从前往后，越小越靠前
    let number: Int     // 窗口号
    let rect: CGRect
}

struct FollowPick {
    let main: FollowWindow
    let dialogOver: Bool   // 主窗口前面压着 Claude 自己的别的窗口（授权、确认对话框）
    let petPlaced: Bool    // 她已经排在主窗口前面（有对话框时还在对话框后面）：层级不用再动
}

/// windows：Claude 的普通窗口（第 0 层、看得见、至少 50×50），从前往后。
/// 跟定 current 就一直跟它，没了才挑最大的：Claude 的对话框也是独立的大窗口，而且在最前面，不能换成跟它
/// （2026-11-20 用户发现会跳到对话框上、只能在对话框里活动）
func pickFollowWindow(_ windows: [FollowWindow], petIndex: Int?, current: Int) -> FollowPick? {
    let big = windows.filter { $0.rect.width >= 300 && $0.rect.height >= 300 }
    guard let main = big.first(where: { $0.number == current })
            ?? big.max(by: { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }) else { return nil }
    let dialogs = windows.filter { $0.index < main.index && $0.rect.intersects(main.rect) }
    let lowest = dialogs.map { $0.index }.max() ?? -1
    let placed = petIndex.map { $0 < main.index && $0 > lowest } ?? false
    return FollowPick(main: main, dialogOver: !dialogs.isEmpty, petPlaced: placed)
}
