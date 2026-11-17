"""设置窗口（右键「设置…」）：加载 web/settings.html。
页面 postMessage 发 {cmd, ...}，Pet.handle_settings 改完设置后用 push 把最新状态推回页面。"""
import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gdk, Gtk, WebKit2  # noqa: E402

from . import store, web  # noqa: E402


class SettingsWindow:
    def __init__(self, pet):
        self.pet = pet
        self.loaded = False
        self.pending_tab = None
        w = self.window = Gtk.Window(title=store.APP_NAME + " 设置")
        w.set_wmclass(store.APP_NAME, store.APP_NAME)
        icon = store.INSTALL / "icon" / "AppIcon.png"
        if icon.exists():
            try:
                w.set_icon_from_file(str(icon))
            except Exception:
                pass
        mon = Gdk.Display.get_default().get_primary_monitor() or Gdk.Display.get_default().get_monitor(0)
        height = min(780, mon.get_workarea().height - 40)
        w.set_default_size(560, height)
        w.set_size_request(420, 300)
        w.set_position(Gtk.WindowPosition.CENTER)
        self.view = web.create(self.on_message)
        w.add(self.view)
        w.connect("destroy", self.on_destroy)
        self.view.connect("load-changed", self.on_load)
        self.view.load_uri(store.page_url("settings.html"))

    def on_message(self, msg):
        try:
            self.pet.handle_settings(msg)
        except Exception as e:
            store.log("设置出错: " + repr(e))

    def on_load(self, _v, event):
        if event != WebKit2.LoadEvent.FINISHED:
            return
        self.loaded = True
        self.push()
        if self.pending_tab:
            t, self.pending_tab = self.pending_tab, None
            self.show_tab(t)

    def on_destroy(self, *_):
        self.pet.settings_window = None

    def show(self):
        self.window.show_all()
        self.window.present()

    def show_tab(self, tab):
        if not self.loaded:
            self.pending_tab = tab
            return
        web.run_js(self.view, f"showTab({store.dumps(tab)})")

    def push(self):
        if self.loaded:
            web.run_js(self.view, f"setState({store.dumps(self.pet.settings_state())})")
