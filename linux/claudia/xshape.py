"""窗口只在桌宠本体、气泡、名牌、额度上收鼠标，其余地方点击穿透到后面（X11 的 SHAPE 扩展，输入区域）。

直接用 ctypes 调 libXext：GTK 的 input_shape_combine_region 要 python3-gi-cairo，Ubuntu 默认没装。
桌宠窗口走 XWayland（GDK_BACKEND=x11），所以这里一定是 X11。
"""
import ctypes
import ctypes.util

from . import store


class _Rect(ctypes.Structure):
    _fields_ = [("x", ctypes.c_short), ("y", ctypes.c_short), ("width", ctypes.c_ushort), ("height", ctypes.c_ushort)]


_x11 = _ext = _dpy = None


def _init():
    global _x11, _ext, _dpy
    if _dpy is not None:
        return True
    try:
        _x11 = ctypes.CDLL(ctypes.util.find_library("X11") or "libX11.so.6")
        _ext = ctypes.CDLL(ctypes.util.find_library("Xext") or "libXext.so.6")
        _x11.XOpenDisplay.restype = ctypes.c_void_p
        _x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
        _x11.XFlush.argtypes = [ctypes.c_void_p]
        _ext.XShapeCombineRectangles.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_int, ctypes.c_int,
                                                 ctypes.POINTER(_Rect), ctypes.c_int, ctypes.c_int, ctypes.c_int]
        _dpy = _x11.XOpenDisplay(None)
        return bool(_dpy)
    except OSError as e:
        store.log("没能加载 X11 库，点击穿透不可用: " + str(e))
        _dpy = 0
        return False


SHAPE_INPUT, SHAPE_SET, UNSORTED = 2, 0, 0


def set_input(xid, rects):
    """rects: [(x, y, w, h), …]，窗口内的像素坐标；空列表 = 整个窗口都不收鼠标"""
    if not _init() or not xid:
        return False
    arr = (_Rect * max(1, len(rects)))()
    for i, (x, y, w, h) in enumerate(rects):
        arr[i] = _Rect(max(-32768, min(32767, int(x))), max(-32768, min(32767, int(y))),
                       max(0, min(65535, int(w))), max(0, min(65535, int(h))))
    _ext.XShapeCombineRectangles(_dpy, xid, SHAPE_INPUT, 0, 0, arr, len(rects), SHAPE_SET, UNSORTED)
    _x11.XFlush(_dpy)
    return True


SHAPE_BOUNDING = 0


def set_visible(xid, visible):
    """窗口画不画出来（SHAPE 扩展的外形区域）：False = 外形是空的，窗口在屏幕上也看不见；True = 恢复成整个窗口。
    窗口从屏幕外挪进来的头一两帧，合成器可能还拿着没画好的缓冲区，会闪一个空方块：先把外形设成空，等画好了再恢复"""
    if not _init() or not xid:
        return False
    if visible:
        _ext.XShapeCombineMask.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_int, ctypes.c_int,
                                           ctypes.c_ulong, ctypes.c_int]
        _ext.XShapeCombineMask(_dpy, xid, SHAPE_BOUNDING, 0, 0, 0, SHAPE_SET)   # 掩码给 None：恢复默认外形
    else:
        arr = (_Rect * 1)()
        _ext.XShapeCombineRectangles(_dpy, xid, SHAPE_BOUNDING, 0, 0, arr, 0, SHAPE_SET, UNSORTED)
    # 这是另一条 X 连接：等服务器处理完再回去，不然 GTK 那边接着发的「显示窗口」可能先到
    _x11.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
    _x11.XSync(_dpy, 0)
    return True
