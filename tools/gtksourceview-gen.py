#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Generate a scheme's GtkSourceView 5 style schemes (<scheme>/gtksourceview/gnome-themes-<scheme>-{dark,light}.xml) from
its scheme.toml, so the editor area of Text Editor, Builder and every other GtkSourceView app follows the scheme (the GTK
theme does not reach it: it is a separate mechanism).

  python3 -I tools/gtksourceview-gen.py <scheme-dir> [--check]     # --check: print, write nothing

Ids: gnome-themes-<scheme>-dark and, for a scheme with a light variant, gnome-themes-<scheme>-light (a dark-only scheme has
only the -dark one: a dark scheme labelled light would lie). The display name is "<title> Dark" / "<title> Light". The
`<metadata>` block carries `variant` (dark|light) and the id of the other variant (`light-variant` / `dark-variant`), as
GtkSourceView's own Solarized pair does. A marker comment `<!-- gnome-themes: <scheme> -->` is the installer's collision guard.

Role mapping (variant roles from scheme.toml, derived ones filled in by palette-from-scheme.py):
  text = fg on bg_deep (both variants); current line = bg; line numbers = fg_dim on bg_deep; selection background = selection;
  comments = comment (italic); keywords = magenta, statements = red; strings and characters = green; numbers, constants and
  boolean = orange; types = yellow; functions = blue; special characters and constants, builtins, operators = cyan;
  preprocessor = purple; errors red, warnings yellow, notes magenta; diff added/removed/changed = green/red/yellow.
Current line: halfway between bg_deep and bg (a subtle highlight; bg itself is too far from the editor background for
syntax colours to keep their contrast on it).
Contrast rule: every foreground colour (text, line numbers, all syntax colours) must reach 4.5:1 on BOTH the editor background
(bg_deep) and the current-line background; comments and the shebang line (comment colour) need 3:1. A role colour that misses its threshold gets only its LIGHTNESS
changed (hue and saturation kept; lighter in dark variants, darker in light ones) in 1 % steps until it passes; the colours that
were moved are listed in a comment inside the file (`adjusted:`): several upstream palettes (Solarized, Catppuccin Latte ...) have
accents below 4.5:1 on their own light background, so those light variants come out darker than upstream. The selection background
is moved towards bg_deep until fg on it reaches 4.5:1 (also listed). Nothing else is changed.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))   # python3 -I does not add the script dir
import schemeroles as sr

COLORS = ('red', 'orange', 'yellow', 'green', 'cyan', 'blue', 'magenta', 'purple')

def palette(R, notes, tag):
    """The named colours of one variant after the contrast rule."""
    B, fg = R['bg_deep'], R['fg']
    CL = sr.mix(B, R['bg'], 0.5)   # current line: halfway between the editor background and the window colour
    c = {'bg-deep': B, 'bg': CL, 'fg': fg, 'selection': R['selection']}
    for name in COLORS + ('fg_dim', 'comment'):
        need = 3.0 if name == 'comment' else 4.5
        v, n = sr.nudge_to(R[name], [B, CL], need)
        if n: notes.append('%s %s %s -> %s (lightness %s%d %% for %.1f:1 on bg_deep and the current line)' % (tag, name, R[name], v, '-' if sr.lum(B) > 0.18 else '+', n, need))
        c[name.replace('_', '-')] = v
    sel, n = c['selection'], 0
    while sr.contrast(fg, sel) < 4.5 and n < 20:
        n += 1; sel = sr.mix(R['selection'], B, 0.05 * n)
    if n: notes.append('%s selection %s -> %s (%d x 5%% towards bg_deep for fg 4.5:1)' % (tag, R['selection'], sel, n))
    c['selection'] = sel
    return c

# (style name, attributes) in the order of the file; values are colour names of the palette
STYLES = [
    ('text', 'foreground="fg" background="bg-deep"'), ('selection', 'background="selection"'), ('cursor', 'foreground="fg"'),
    ('secondary-cursor', 'foreground="fg-dim"'), ('current-line', 'background="bg"'), ('current-line-number', 'foreground="fg" background="bg"'),
    ('line-numbers', 'foreground="fg-dim" background="bg-deep"'), ('snippet-focus', 'background="bg"'),
    ('bracket-match', 'foreground="fg" background="selection"'), ('bracket-mismatch', 'foreground="bg-deep" background="red"'),
    ('right-margin', 'foreground="fg-dim" background="bg"'), ('search-match', 'foreground="bg-deep" background="yellow"'),
    ('def:comment', 'foreground="comment" italic="true"'), ('def:shebang', 'foreground="comment" bold="true"'),
    ('def:doc-comment-element', 'italic="true"'),
    ('def:constant', 'foreground="orange"'), ('def:boolean', 'foreground="orange"'), ('def:special-constant', 'foreground="cyan"'),
    ('def:special-char', 'foreground="cyan"'), ('def:string', 'foreground="green"'), ('def:character', 'foreground="green"'),
    ('def:identifier', 'foreground="fg"'), ('def:function', 'foreground="blue"'), ('def:builtin', 'foreground="cyan"'),
    ('def:keyword', 'foreground="magenta"'), ('def:statement', 'foreground="red"'), ('def:type', 'foreground="yellow"'),
    ('def:operator', 'foreground="cyan"'), ('def:preprocessor', 'foreground="purple"'),
    ('def:error', 'foreground="red" underline="error"'), ('def:warning', 'foreground="yellow" underline="single"'),
    ('def:note', 'foreground="magenta" bold="true"'), ('def:underlined', 'underline="single"'), ('def:net-address', 'foreground="blue" underline="single"'),
    ('def:emphasis', 'italic="true"'), ('def:strong-emphasis', 'bold="true"'), ('def:inline-code', 'foreground="orange"'),
    ('def:link-text', 'foreground="blue"'), ('def:link-symbol', 'foreground="blue" bold="true"'),
    ('def:link-destination', 'foreground="blue" underline="single"'), ('def:heading', 'foreground="yellow" bold="true"'),
    ('def:thematic-break', 'foreground="yellow"'), ('def:preformatted-section', 'foreground="orange"'), ('def:list-marker', 'foreground="cyan"'),
    ('diff:added-line', 'foreground="green"'), ('diff:removed-line', 'foreground="red"'), ('diff:changed-line', 'foreground="yellow"'),
    ('diff:location', 'foreground="blue"'), ('diff:diff-file', 'foreground="yellow"'),
    ('json:keyname', 'foreground="blue"'),
]

def ident(scheme, slot): return 'gnome-themes-%s-%s' % (scheme, slot)

def build(scheme_dir):
    S, roles, slots = sr.load(scheme_dir)
    scheme = os.path.basename(os.path.abspath(scheme_dir))
    dual = 'light' in roles
    out = {}
    for slot, variant in slots:
        if slot == 'light' and not dual: continue
        notes = []; c = palette(roles[variant], notes, slot)
        other = 'light' if slot == 'dark' else 'dark'
        meta = '<property name="variant">%s</property>' % slot
        if dual: meta += '<property name="%s-variant">%s</property>' % (other, ident(scheme, other))
        L = ['<?xml version="1.0" encoding="UTF-8"?>',
             '<!-- SPDX-License-Identifier: MIT. Generated by tools/gtksourceview-gen.py from %s/scheme.toml (rules in the script header); do not edit. -->' % scheme,
             '<!-- gnome-themes: %s -->' % scheme]
        if notes: L.append('<!-- adjusted: %s -->' % '; '.join(notes))
        L += ['<style-scheme id="%s" _name="%s %s" version="1.0">' % (ident(scheme, slot), S['title'], slot.capitalize()),
              '  <author>gnome-themes</author>', '  <_description>%s, %s variant (gnome-themes)</_description>' % (S['title'], slot),
              '  <metadata>%s</metadata>' % meta]
        L += ['  <color name="%s" value="%s"/>' % (k, v.lower()) for k, v in c.items()]
        L += ['  <style name="%s" %s/>' % (n, a) for n, a in STYLES]
        L.append('</style-scheme>')
        out[ident(scheme, slot) + '.xml'] = '\n'.join(L) + '\n'
    return scheme, out

def main():
    if len(sys.argv) < 2: sys.exit(__doc__)
    d = sys.argv[1].rstrip('/')
    scheme, files = build(d)
    if '--check' in sys.argv:
        for n, t in files.items(): print('== ' + n); print(t)
        return
    os.makedirs(d + '/gtksourceview', exist_ok=True)
    for f in os.listdir(d + '/gtksourceview'): os.remove(os.path.join(d, 'gtksourceview', f))   # a scheme that lost its light variant leaves no stale file
    for n, t in files.items():
        with open('%s/gtksourceview/%s' % (d, n), 'w') as f: f.write(t)
        print('wrote %s/gtksourceview/%s' % (d, n))

if __name__ == '__main__': main()
