// FollowPick.swift 的测试：sh mac/test.sh。窗口尺寸取自用户的真机（Claude 主窗口 1710×995）
import CoreGraphics
import Foundation

var failed = 0
func check(_ name: String, _ ok: Bool) {
    print((ok ? "  通过  " : "  失败  ") + name)
    if !ok { failed += 1 }
}

let mainR = CGRect(x: 0, y: 38, width: 1710, height: 995)
let dialogR = CGRect(x: 66, y: 28, width: 900, height: 680)   // 「Allow Claude to access this folder?」那种独立对话框
let MAIN = 12684, DIALOG = 13001

print("跟随窗口的挑选")
do {
    // 用户截图的情况：对话框在最前，她被浮动层顶在对话框上面（她 0、对话框 1、主窗口 2）
    let wins = [FollowWindow(index: 1, number: DIALOG, rect: dialogR), FollowWindow(index: 2, number: MAIN, rect: mainR)]
    let p = pickFollowWindow(wins, petIndex: 0, current: MAIN)
    check("对话框弹出时还跟着主窗口", p?.main.number == MAIN)
    check("发现对话框盖在主窗口上", p?.dialogOver == true)
    check("她在对话框上面：算没摆对，要挪到对话框后面", p?.petPlaced == false)

    // 挪好以后：对话框 0、她 1、主窗口 2
    let ok = pickFollowWindow([FollowWindow(index: 0, number: DIALOG, rect: dialogR), FollowWindow(index: 2, number: MAIN, rect: mainR)], petIndex: 1, current: MAIN)
    check("她夹在对话框和主窗口之间：算摆对了，不再反复挪", ok?.petPlaced == true)

    // 她在主窗口后面
    let under = pickFollowWindow([FollowWindow(index: 0, number: DIALOG, rect: dialogR), FollowWindow(index: 1, number: MAIN, rect: mainR)], petIndex: 2, current: MAIN)
    check("她被主窗口压住：算没摆对", under?.petPlaced == false)
}
do {
    // 刚启动、还没跟过任何窗口时对话框已经在了：挑最大的，不挑最前的
    let wins = [FollowWindow(index: 0, number: DIALOG, rect: dialogR), FollowWindow(index: 1, number: MAIN, rect: mainR)]
    check("还没跟过窗口：挑最大的而不是最前的", pickFollowWindow(wins, petIndex: nil, current: 0)?.main.number == MAIN)
}
do {
    // 对话框关了：只剩主窗口，她在前面
    let p = pickFollowWindow([FollowWindow(index: 1, number: MAIN, rect: mainR)], petIndex: 0, current: MAIN)
    check("对话框关了：恢复正常", p?.main.number == MAIN && p?.dialogOver == false && p?.petPlaced == true)
}
do {
    // 跟的窗口没了（关掉、最小化）：换成剩下最大的
    let other = CGRect(x: 100, y: 100, width: 1200, height: 800)
    let p = pickFollowWindow([FollowWindow(index: 0, number: 777, rect: other)], petIndex: nil, current: MAIN)
    check("跟的窗口没了：换成剩下的", p?.main.number == 777)
}
do {
    // 小窗口（关于、提示）不会被当成主窗口；不和主窗口重叠的不算对话框
    let small = CGRect(x: 500, y: 300, width: 280, height: 200)
    check("只有小窗口：不跟", pickFollowWindow([FollowWindow(index: 0, number: 5, rect: small)], petIndex: nil, current: 0) == nil)
    let far = CGRect(x: 2000, y: 100, width: 600, height: 400)   // 另一块屏幕上
    let p = pickFollowWindow([FollowWindow(index: 0, number: 9, rect: far), FollowWindow(index: 1, number: MAIN, rect: mainR)], petIndex: nil, current: MAIN)
    check("不重叠的窗口不算对话框", p?.dialogOver == false)
    let p2 = pickFollowWindow([FollowWindow(index: 0, number: 5, rect: small), FollowWindow(index: 1, number: MAIN, rect: mainR)], petIndex: nil, current: MAIN)
    check("压在主窗口上的小提示框也算对话框", p2?.dialogOver == true)
}
do {
    check("Claude 没有窗口：不跟", pickFollowWindow([], petIndex: 0, current: MAIN) == nil)
}

print(failed == 0 ? "全部通过" : "\(failed) 项失败")
exit(failed == 0 ? 0 : 1)
