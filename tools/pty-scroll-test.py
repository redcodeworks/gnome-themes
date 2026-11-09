#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Scrolling test of the terminal checklist picker (tools/themectl.sh `_tui_run`), run in a pty with a tiny terminal emulator.

  python3 -I tools/pty-scroll-test.py [rows ...]       # default rows: 10 24; exits 1 on any failure

The picker is started (`themectl.sh themes install`, every scheme listed), keys are sent one at a time, and after each key the emulated screen
must show exactly one highlighted (reverse video) row whose entry is the one the key sequence has to select, plus the header and the footer
(`N-M of T`), with no more rows than the terminal has. Scenarios per height: down past the window, up, last/first (G/g, End/Home), page down/up,
a `/` filter, ticks made off-screen, and a terminal resize while the picker is open. Needs the usual themectl environment variables
(THEMES_DEST etc.) to point at temp dirs; tools/test.sh sets them.
"""
import os, pty, select, sys, time, fcntl, termios, struct, re, subprocess, signal

HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
KEYS = {'down': b'\x1b[B', 'up': b'\x1b[A', 'space': b' ', 'enter': b'\r', 'esc': b'\x1b', 'slash': b'/', 'home': b'\x1b[H', 'end': b'\x1b[F',
        'pgup': b'\x1b[5~', 'pgdn': b'\x1b[6~', 'q': b'q'}

class Screen:
    def __init__(self, rows, cols): self.R, self.C = rows, cols; self.g = [[(' ', False)] * cols for _ in range(rows)]; self.r = self.c = 0; self.rev = False; self.buf = ''
    def resize(self, rows, cols):
        while self.r >= rows: self.g.pop(0); self.r -= 1; self.R -= 1     # like a real terminal: the cursor row stays on screen, the top scrolls away
        g = [row[:cols] + [(' ', False)] * (cols - len(row)) for row in self.g[:rows]]
        g += [[(' ', False)] * cols for _ in range(rows - len(g))]
        self.g, self.R, self.C = g, rows, cols; self.r = min(self.r, rows - 1); self.c = min(self.c, cols - 1)
    def newline(self):
        self.r += 1
        if self.r >= self.R: self.g.pop(0); self.g.append([(' ', False)] * self.C); self.r = self.R - 1
    def feed(self, data):
        s = self.buf + data.decode('utf-8', 'replace'); self.buf = ''; i = 0
        while i < len(s):
            ch = s[i]
            if ch == '\x1b':
                m = re.compile(r'\x1b\[([0-9;?]*)([A-Za-z])').match(s, i)
                if not m:
                    if len(s) - i < 12: self.buf = s[i:]; return
                    i += 1; continue
                arg, op = m.groups(); i = m.end()
                n = int(arg) if arg.isdigit() else 1
                if op == 'A': self.r = max(0, self.r - n)
                elif op == 'K': self.g[self.r][self.c:] = [(' ', False)] * (self.C - self.c)
                elif op == 'J' and arg == '2':
                    self.g = [[(' ', False)] * self.C for _ in range(self.R)]
                elif op == 'J':
                    self.g[self.r][self.c:] = [(' ', False)] * (self.C - self.c)
                    for rr in range(self.r + 1, self.R): self.g[rr] = [(' ', False)] * self.C
                elif op == 'H': self.r = self.c = 0
                elif op == 'm': self.rev = '7' in arg.split(';') or (self.rev and arg not in ('0', ''))
                continue
            i += 1
            if ch == '\r': self.c = 0
            elif ch == '\n': self.newline()
            elif ch >= ' ':
                if self.c >= self.C: self.c = 0; self.newline()
                self.g[self.r][self.c] = (ch, self.rev); self.c += 1
    def rows_text(self): return [''.join(c for c, _ in row).rstrip() for row in self.g]
    def highlighted(self): return [''.join(c for c, _ in row).rstrip() for row in self.g if any(r for _, r in row)]

class Picker:
    def __init__(self, rows, cols, env_extra=None):
        self.scr = Screen(rows, cols)
        pid, fd = pty.fork()
        if pid == 0:
            os.chdir(ROOT); os.execvp('tools/themectl.sh', ['tools/themectl.sh', 'themes', 'install'])
        self.pid, self.fd = pid, fd; self.size(rows, cols); self.settle(0.8)
    def size(self, rows, cols):
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
    def resize(self, rows, cols): self.size(rows, cols); self.scr.resize(rows, cols); self.settle(0.5)
    def settle(self, quiet=0.3, limit=6):
        t0 = last = time.time()
        while time.time() - last < quiet and time.time() - t0 < limit:
            r, _, _ = select.select([self.fd], [], [], 0.05)
            if r:
                try: d = os.read(self.fd, 65536)
                except OSError: return
                if not d: return
                self.scr.feed(d); last = time.time()
    def key(self, k):
        os.write(self.fd, KEYS.get(k, k.encode())); self.settle()
    def type(self, text):
        for ch in text: self.key(ch)
    def close(self):
        try: os.kill(self.pid, signal.SIGKILL); os.waitpid(self.pid, 0)
        except (ProcessLookupError, ChildProcessError): pass
        os.close(self.fd)

def names_in_order():
    env = dict(os.environ)
    out = subprocess.run(['tools/themectl.sh', 'themes', 'list'], cwd=ROOT, capture_output=True, text=True, env=env).stdout
    lines = [re.sub(r'^[✓ ]*\s*(★\s*)?', '', l) for l in out.splitlines() if l.strip()]
    return [l.split()[0] for l in lines], [l.lower() for l in lines]

fails = 0
def check(p, want, what, expect_total=None):
    """Exactly one highlighted row showing entry `want`, header and footer present, no more rows used than the terminal has."""
    global fails
    hl = p.scr.highlighted(); txt = p.scr.rows_text(); bad = []
    if len(hl) != 1: bad.append('%d highlighted rows' % len(hl))
    elif ' ' + want + ' ' not in ' ' + hl[0] + ' ': bad.append('highlighted "%s", wanted "%s"' % (hl[0].strip()[:40], want))
    if not any(re.search(r'\d+-\d+ of \d+', t) for t in txt): bad.append('no "N-M of T" footer')
    if not any('Themes to install' in t for t in txt): bad.append('header scrolled away')
    if expect_total and not any(re.search(r'of %d\b' % expect_total, t) for t in txt): bad.append('footer total != %d' % expect_total)
    if bad: fails += 1; print('  FAIL %s: %s' % (what, '; '.join(bad))); print('\n'.join('    | ' + t for t in txt))
    else: print('  PASS %s' % what)

def run(rows, names, labels):
    n = len(names); cols = 80; p = Picker(rows, cols); H = rows - 2
    print('== %d rows, %d columns, %d entries (list height %d)' % (rows, cols, n, H))
    try:
        check(p, names[0], 'start: first entry highlighted', n)
        for k in range(1, H + 4):
            p.key('down'); check(p, names[k], 'down %d' % k)
        for k in range(H + 3, H - 1, -1):
            p.key('up'); check(p, names[k - 1], 'up to %d' % (k - 1))
        p.key('G'); check(p, names[-1], 'G: last entry')
        p.key('home'); check(p, names[0], 'Home: first entry')
        p.key('end'); check(p, names[-1], 'End: last entry')
        p.key('g'); check(p, names[0], 'g: first entry')
        p.key('pgdn'); check(p, names[min(H, n - 1)], 'PgDn moves one page')
        p.key('pgup'); check(p, names[0], 'PgUp moves back one page')
        p.key('up'); check(p, names[-1], 'up from the first entry wraps to the last')
        p.key('down'); check(p, names[0], 'down from the last entry wraps to the first')
        # ticks made off-screen survive scrolling; the footer counts them
        p.key('space'); p.key('G'); p.key('space'); p.key('g')
        if not any('2 ticked' in t for t in p.scr.rows_text()): global fails; fails += 1; print('  FAIL footer does not show "2 ticked"')
        else: print('  PASS ticks made off-screen are counted')
        # filter: narrow with '/', scroll inside the filtered list, clear with Esc
        p.key('slash'); p.type('NI'); p.key('enter')      # upper case on purpose: the filter ignores case and matches the whole label
        flt = [x for x, l in zip(names, labels) if 'ni' in l]
        check(p, flt[0], 'filter "NI": first match highlighted')
        for k in range(1, min(len(flt), H + 3)):
            p.key('down'); check(p, flt[k], 'filtered down %d' % k)
        p.key('G'); check(p, flt[-1], 'filtered G: last match')
        p.key('slash'); p.key('esc'); p.key('g'); check(p, names[0], 'Esc clears the filter')
        # resize while open: the cursor row stays visible and the window follows the new height
        for _ in range(H + 2): p.key('down')
        p.resize(max(5, rows - 3), cols); check(p, names[H + 2], 'resize to %d rows keeps the cursor visible' % max(5, rows - 3))
        p.resize(rows + 8, cols); check(p, names[H + 2], 'resize to %d rows keeps the cursor visible' % (rows + 8))
        p.key('q')
    finally: p.close()

if __name__ == '__main__':
    names, labels = names_in_order()
    for r in [int(x) for x in sys.argv[1:]] or [10, 24]: run(r, names, labels)
    print('scroll test: %s' % ('%d FAIL' % fails if fails else 'all passed')); sys.exit(1 if fails else 0)
