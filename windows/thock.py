"""
Thock for Windows — mechanical keyboard sound simulator.
Port of the macOS Thock app (Swift/AVFoundation) to Windows (Python).

Listens globally for key presses (never blocks/modifies typing), plays a
matching mechanical-keyboard click from the selected sound pack, panned
left/right by the key's physical position, with slight per-hit pitch and
volume randomization. Lives in the system tray.
"""

import os
import sys
import json
import math
import random
import threading
import wave
import ctypes

import numpy as np
import pygame
import keyboard
from PIL import Image, ImageDraw
import pystray

# --------------------------------------------------------------------------
# Paths
# --------------------------------------------------------------------------

def base_dir():
    if getattr(sys, "frozen", False):
        return sys._MEIPASS
    return os.path.dirname(os.path.abspath(__file__))

PACKS_DIR = os.path.join(base_dir(), "packs")

APPDATA = os.environ.get("APPDATA") or os.path.expanduser("~")
SETTINGS_DIR = os.path.join(APPDATA, "Thock")
SETTINGS_PATH = os.path.join(SETTINGS_DIR, "settings.json")

DEFAULTS = {"enabled": True, "pack": 1, "volume": 0.7, "release": True,
            "stereo": True, "startup": False}


def load_settings():
    s = dict(DEFAULTS)
    try:
        with open(SETTINGS_PATH, "r", encoding="utf-8") as f:
            s.update(json.load(f))
    except Exception:
        pass
    return s


def save_settings(s):
    try:
        os.makedirs(SETTINGS_DIR, exist_ok=True)
        with open(SETTINGS_PATH, "w", encoding="utf-8") as f:
            json.dump(s, f)
    except Exception:
        pass


# --------------------------------------------------------------------------
# Key mapping: Windows key events -> the macOS virtual keycodes used as the
# pack files' key ids (every code 0-127 has an assigned sound slice).
#
# The main alphanumeric/punctuation cluster is resolved from the hardware
# scan code (Set-1), not the character the OS reports — scan codes are
# fixed to physical key position regardless of Shift state or the active
# keyboard input layout (e.g. switching to a Bangla layout to type still
# clicks the right physical key). Control/modifier/nav/function keys and
# the numpad are resolved by name, which Windows already reports correctly
# for those regardless of layout.
# --------------------------------------------------------------------------

SCANCODE_MAP = {
    2: 18, 3: 19, 4: 20, 5: 21, 6: 23, 7: 22, 8: 26, 9: 28, 10: 25, 11: 29,
    12: 27, 13: 24,
    16: 12, 17: 13, 18: 14, 19: 15, 20: 17, 21: 16, 22: 32, 23: 34, 24: 31,
    25: 35, 26: 33, 27: 30,
    30: 0, 31: 1, 32: 2, 33: 3, 34: 5, 35: 4, 36: 38, 37: 40, 38: 37,
    39: 41, 40: 39, 41: 50,
    43: 42, 44: 6, 45: 7, 46: 8, 47: 9, 48: 11, 49: 45, 50: 46, 51: 43,
    52: 47, 53: 44,
}

# Physical numpad cluster: same key reports a digit (NumLock on) or a nav
# name (NumLock off) — map both so the click always fires either way.
KEYPAD = {
    "0": 82, "insert": 82, "1": 83, "end": 83, "2": 84, "down": 84,
    "3": 85, "page down": 85, "4": 86, "left": 86, "5": 87, "clear": 87,
    "6": 88, "right": 88, "7": 89, "home": 89, "8": 91, "up": 91,
    "9": 92, "page up": 92, "decimal": 65, "delete": 65,
    "/": 75, "*": 67, "+": 69, "-": 78, "enter": 76,
}

NAMED = {
    "space": 49, "enter": 36, "tab": 48, "backspace": 51, "esc": 53,
    "caps lock": 57,
    "shift": 56, "left shift": 56, "right shift": 60,
    "ctrl": 59, "left ctrl": 59, "right ctrl": 62,
    "alt": 58, "left alt": 58, "alt gr": 61, "right alt": 61, "right menu": 61,
    "windows": 55, "left windows": 55, "right windows": 54,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
    "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    "f13": 105, "f14": 107, "f15": 113, "f16": 106, "f17": 64, "f18": 79,
    "f19": 80, "f20": 90,
    "up": 126, "down": 125, "left": 123, "right": 124,
    "insert": 114, "home": 115, "page up": 116, "delete": 117,
    "end": 119, "page down": 121, "num lock": 71,
}


def resolve_code(scan_code, name, is_keypad):
    name = (name or "").lower()
    if is_keypad:
        return KEYPAD.get(name)
    if scan_code in SCANCODE_MAP:
        return SCANCODE_MAP[scan_code]
    return NAMED.get(name)


# --------------------------------------------------------------------------
# Audio engine
# --------------------------------------------------------------------------

RATES = (0.975, 1.0, 1.025)
TAIL = 132  # samples


def read_wav_float(path):
    with wave.open(path, "rb") as w:
        raw = w.readframes(w.getnframes())
    data = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    return data


def make_variants(src, start, length):
    total = len(src)
    n_src = min(length, total - start)
    if n_src <= 8:
        return []
    out = []
    for rate in RATES:
        n = int(n_src / rate)
        if n <= 0:
            continue
        pos = np.arange(n, dtype=np.float64) * rate
        i0 = pos.astype(np.int64)
        frac = (pos - i0).astype(np.float32)
        i0c = np.clip(i0, 0, n_src - 1)
        i1c = np.clip(i0 + 1, 0, n_src - 1)
        a = src[start + i0c]
        c = src[start + i1c]
        samp = a + (c - a) * frac
        tail = np.clip((n - np.arange(n)) / float(TAIL), 0, 1).astype(np.float32)
        samp = samp * tail
        i16 = np.clip(samp * 32767.0, -32768, 32767).astype(np.int16)
        stereo = np.ascontiguousarray(np.column_stack((i16, i16)))
        out.append(pygame.sndarray.make_sound(stereo))
    return out


class SoundEngine:
    def __init__(self, packs_meta):
        self.packs_meta = packs_meta
        self.pack = None  # {"down":{}, "up":{}, "pan":{}}
        self.channels = [pygame.mixer.Channel(i) for i in range(32)]
        self.next_ch = 0
        self.load_token = 0
        self.lock = threading.Lock()

    def load(self, index, on_done=None):
        self.load_token += 1
        token = self.load_token

        def worker():
            meta = self.packs_meta[index]
            src = read_wav_float(os.path.join(PACKS_DIR, meta["file"]))
            cache = {}

            def variants(spec):
                key = (spec[0], spec[1])
                if key not in cache:
                    cache[key] = make_variants(src, spec[0], spec[1])
                return cache[key]

            down, up, pan = {}, {}, {}
            for k, kd in meta["keys"].items():
                code = int(k)
                down[code] = variants(kd["d"])
                if kd.get("u"):
                    up[code] = variants(kd["u"])
                pan[code] = float(kd.get("x", 0.0)) * 0.45
            built = {"down": down, "up": up, "pan": pan}
            if token == self.load_token:
                with self.lock:
                    self.pack = built
                if on_done:
                    on_done()

        threading.Thread(target=worker, daemon=True).start()

    def play(self, code, down, volume, stereo):
        with self.lock:
            pack = self.pack
        if not pack:
            return
        variants = (pack["down"] if down else pack["up"]).get(code)
        if not variants:
            return
        snd = random.choice(variants)
        pan = pack["pan"].get(code, 0.0) if stereo else 0.0
        gain = volume * random.uniform(0.9, 1.0) * (1.0 if down else 0.85)
        angle = (max(-1.0, min(1.0, pan)) + 1.0) * 0.25 * math.pi
        left = gain * math.cos(angle)
        right = gain * math.sin(angle)
        ch = self.channels[self.next_ch]
        self.next_ch = (self.next_ch + 1) % len(self.channels)
        ch.set_volume(left, right)
        ch.play(snd)


# --------------------------------------------------------------------------
# App state / model
# --------------------------------------------------------------------------

class App:
    def __init__(self):
        with open(os.path.join(PACKS_DIR, "packs.json"), "r", encoding="utf-8") as f:
            self.packs_meta = json.load(f)["packs"]
        self.settings = load_settings()
        pygame.mixer.pre_init(frequency=44100, size=-16, channels=2, buffer=256)
        pygame.mixer.init()
        pygame.mixer.set_num_channels(32)
        self.engine = SoundEngine(self.packs_meta)
        self.held = set()
        self.engine.load(self.settings["pack"])
        self.icon = None

    def gain(self):
        v = self.settings["volume"]
        return v * v * 1.5

    def hit(self, code, down):
        if not self.settings["enabled"]:
            return
        if not down and not self.settings["release"]:
            return
        self.engine.play(code, down, self.gain(), self.settings["stereo"])

    def on_key_event(self, e):
        is_kp = bool(getattr(e, "is_keypad", False))
        code = resolve_code(e.scan_code, e.name, is_kp)
        if code is None:
            return
        ident = (e.scan_code, is_kp)
        if e.event_type == "down":
            if ident in self.held:
                return  # OS auto-repeat; a held key doesn't re-click
            self.held.add(ident)
            self.hit(code, True)
        elif e.event_type == "up":
            self.held.discard(ident)
            self.hit(code, False)

    def toggle_enabled(self):
        self.settings["enabled"] = not self.settings["enabled"]
        save_settings(self.settings)
        self.refresh_icon()

    def select_pack(self, i):
        self.settings["pack"] = i
        save_settings(self.settings)
        self.engine.load(i)

    def set_volume(self, v):
        self.settings["volume"] = v
        save_settings(self.settings)

    def toggle(self, key):
        self.settings[key] = not self.settings[key]
        save_settings(self.settings)
        if key == "startup":
            set_startup(self.settings["startup"])

    def refresh_icon(self):
        if self.icon:
            self.icon.icon = make_icon(self.settings["enabled"])


# --------------------------------------------------------------------------
# Startup registry entry
# --------------------------------------------------------------------------

def set_startup(enabled):
    try:
        import winreg
        key_path = r"Software\Microsoft\Windows\CurrentVersion\Run"
        key = winreg.OpenKey(winreg.HKEY_CURRENT_USER, key_path, 0, winreg.KEY_SET_VALUE)
        if enabled:
            if getattr(sys, "frozen", False):
                cmd = f'"{sys.executable}"'
            else:
                pyw = sys.executable.replace("python.exe", "pythonw.exe")
                cmd = f'"{pyw}" "{os.path.abspath(__file__)}"'
            winreg.SetValueEx(key, "Thock", 0, winreg.REG_SZ, cmd)
        else:
            try:
                winreg.DeleteValue(key, "Thock")
            except FileNotFoundError:
                pass
        winreg.CloseKey(key)
    except Exception:
        pass


# --------------------------------------------------------------------------
# Tray icon
# --------------------------------------------------------------------------

def make_icon(enabled):
    img = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    alpha = 255 if enabled else 110
    body = (90, 170, 255, alpha)
    d.rounded_rectangle((4, 18, 60, 50), radius=8, fill=body)
    for row, y in enumerate((26, 36)):
        cols = 7 if row == 0 else 6
        xs = np.linspace(10, 54, cols)
        for x in xs:
            d.rectangle((x - 2, y - 2, x + 2, y + 2), fill=(20, 30, 50, alpha))
    return img


def build_menu(app):
    def pack_item(i, meta):
        return pystray.MenuItem(
            meta["name"],
            lambda _, i=i: app.select_pack(i),
            radio=True,
            checked=lambda _, i=i: app.settings["pack"] == i,
        )

    def vol_item(v):
        return pystray.MenuItem(
            f"{int(v * 100)}%",
            lambda _, v=v: app.set_volume(v),
            radio=True,
            checked=lambda _, v=v: abs(app.settings["volume"] - v) < 1e-6,
        )

    def toggle_item(label, key):
        return pystray.MenuItem(
            label,
            lambda _: app.toggle(key),
            checked=lambda _: app.settings[key],
        )

    return pystray.Menu(
        pystray.MenuItem(
            "Enabled  (Ctrl+Alt+Win+K)",
            lambda _: app.toggle_enabled(),
            checked=lambda _: app.settings["enabled"],
        ),
        pystray.Menu.SEPARATOR,
        pystray.MenuItem("Sound Pack", pystray.Menu(
            *[pack_item(i, m) for i, m in enumerate(app.packs_meta)]
        )),
        pystray.MenuItem("Volume", pystray.Menu(
            *[vol_item(v) for v in (0.25, 0.5, 0.75, 1.0)]
        )),
        pystray.Menu.SEPARATOR,
        toggle_item("Release Sound", "release"),
        toggle_item("Stereo Position", "stereo"),
        toggle_item("Start with Windows", "startup"),
        pystray.Menu.SEPARATOR,
        pystray.MenuItem("Quit", lambda _: quit_app(app)),
    )


def quit_app(app):
    keyboard.unhook_all()
    if app.icon:
        app.icon.stop()
    os._exit(0)


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

def main():
    try:
        ctypes.windll.shcore.SetProcessDpiAwareness(1)
    except Exception:
        pass

    app = App()
    keyboard.hook(app.on_key_event)
    keyboard.add_hotkey("ctrl+alt+windows+k", app.toggle_enabled)

    icon = pystray.Icon("Thock", make_icon(app.settings["enabled"]), "Thock",
                         menu=build_menu(app))
    app.icon = icon
    icon.run()


if __name__ == "__main__":
    main()
