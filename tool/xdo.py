#!/usr/bin/env python3
"""Tiny xdotool replacement for the dev display (XTest). Examples:
  xdo.py click 100 200 [button]     xdo.py rclick 100 200
  xdo.py move 100 200               xdo.py type "hello"
  xdo.py key Return | ctrl+s | ctrl+grave | Escape    xdo.py scroll 100 200 -3
"""
import os, sys, time
from Xlib import X, XK, display
from Xlib.ext import xtest

d = display.Display(os.environ.get('DISPLAY', ':98'))

def sync(): d.sync(); time.sleep(0.03)
def move(x, y): xtest.fake_input(d, X.MotionNotify, x=x, y=y); sync()
def button(b, press): xtest.fake_input(d, X.ButtonPress if press else X.ButtonRelease, b); sync()
def click(x, y, b=1, n=1):
    move(x, y)
    for _ in range(n):
        button(b, True); button(b, False); time.sleep(0.05)

KEYSYMS = {'ctrl': 'Control_L', 'shift': 'Shift_L', 'alt': 'Alt_L', 'meta': 'Super_L',
           'enter': 'Return', 'esc': 'Escape', 'grave': 'grave', 'tab': 'Tab', 'space': 'space',
           'backspace': 'BackSpace', 'delete': 'Delete', 'up': 'Up', 'down': 'Down', 'left': 'Left', 'right': 'Right'}

def keycode(name):
    ks = XK.string_to_keysym(KEYSYMS.get(name.lower(), name))
    if ks == 0: ks = XK.string_to_keysym(name)
    kc = d.keysym_to_keycode(ks)
    if kc == 0: raise SystemExit(f'no keycode for {name}')
    return kc

def key(combo):
    parts = combo.split('+')
    codes = [keycode(p) for p in parts]
    for c in codes: xtest.fake_input(d, X.KeyPress, c); sync()
    for c in reversed(codes): xtest.fake_input(d, X.KeyRelease, c); sync()

def type_text(s):
    for ch in s:
        if ch == '\n': key('Return'); continue
        ks = XK.string_to_keysym(ch)
        if ks == 0:
            ks = ord(ch) | 0x01000000  # unicode keysym
        kc = d.keysym_to_keycode(ks)
        # Prefer main-block keycodes over keypad ones (KP_Decimal etc.).
        if kc >= 90:
            for cand in range(8, 90):
                m = d.get_keyboard_mapping(cand, 1)[0]
                if ks in m[:2]:
                    kc = cand
                    break
        shift = False
        if kc == 0:
            # Temporarily map an unused keycode to this keysym.
            kc = 250
            d.change_keyboard_mapping(kc, [(ks, ks)]); sync()
        else:
            # Need shift if the keysym is the second entry of the mapping.
            m = d.get_keyboard_mapping(kc, 1)[0]
            shift = len(m) > 1 and m[0] != ks and m[1] == ks
        if shift: xtest.fake_input(d, X.KeyPress, keycode('shift')); sync()
        xtest.fake_input(d, X.KeyPress, kc); sync()
        xtest.fake_input(d, X.KeyRelease, kc); sync()
        if shift: xtest.fake_input(d, X.KeyRelease, keycode('shift')); sync()
        time.sleep(0.01)

cmd, args = sys.argv[1], sys.argv[2:]
if cmd == 'click': click(int(args[0]), int(args[1]), int(args[2]) if len(args) > 2 else 1)
elif cmd == 'dclick': click(int(args[0]), int(args[1]), 1, 2)
elif cmd == 'rclick': click(int(args[0]), int(args[1]), 3)
elif cmd == 'move': move(int(args[0]), int(args[1]))
elif cmd == 'drag':
    x1, y1, x2, y2 = map(int, args[:4]); move(x1, y1); button(1, True)
    steps = 10
    for i in range(1, steps + 1): move(x1 + (x2 - x1) * i // steps, y1 + (y2 - y1) * i // steps); time.sleep(0.02)
    button(1, False)
elif cmd == 'type': type_text(' '.join(args))
elif cmd == 'key':
    for k in args: key(k); time.sleep(0.05)
elif cmd == 'scroll':
    x, y, n = int(args[0]), int(args[1]), int(args[2]); move(x, y)
    for _ in range(abs(n)): button(5 if n < 0 else 4, True); button(5 if n < 0 else 4, False)
else: raise SystemExit(__doc__)
d.sync()
