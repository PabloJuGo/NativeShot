#!/bin/sh
# Lists user-visible string keys used in Sources/ that have no entry in Resources/en.lproj/Localizable.strings.
# Approximate: it matches common SwiftUI/AppKit call shapes (Text("…"), Button("…"), String(localized: "…"),
# NSMenuItem(title: "…"), helper builders such as button(.x, "…")) with a regex, not a parser. It can miss
# strings built elsewhere and can flag a literal that is not shown to the user; read the list, don't trust it blindly.
# Exit status 1 when something is missing, so it can gate CI.
set -e
cd "$(dirname "$0")/.."
exec python3 - Sources Resources/en.lproj/Localizable.strings <<'PY'
import os, re, sys

src, strings = sys.argv[1], sys.argv[2]
lit = r'"((?:[^"\\]|\\.)*)"'
calls = (r'Text|Button|Label|Toggle|Picker|Section|LabeledContent|TextField|SecureField|Menu|GroupBox|DisclosureGroup|'
         r'LocalizedStringKey|navigationTitle|help|accessibilityLabel|accessibilityHint|accessibilityValue|'
         r'button|item|action|icon|topic|permissionRow|shortcutRow|slider|toolButton|row')
pats = [
    re.compile(r'\b(?:%s)\(\s*(?:Text\()?%s' % (calls, lit)),
    re.compile(r'\b(?:%s)\([^"()\n]*?,\s*%s' % (r'button|item|action|icon|topic|permissionRow|shortcutRow|slider|row', lit)),
    re.compile(r'String\(localized:\s*%s' % lit),
    re.compile(r'NSMenuItem\(title:\s*%s' % lit),
    re.compile(r'\(\.\w+,\s*%s\)' % lit),            # (action, "title") tables
    re.compile(r'\.(?:message|informativeText|messageText|title|prompt)\s*=\s*%s' % lit),
    re.compile(r'\btopic\(\s*"(?:[^"\\]|\\.)*"\s*,\s*%s' % lit),   # help topic bodies
    re.compile(r'\b(?:addButton)\(withTitle:\s*%s' % lit),
]

def unescape(s): return s.replace('\\"', '"').replace('\\n', '\n')

defined = set()
for m in re.finditer(r'^\s*"((?:[^"\\]|\\.)*)"\s*=', open(strings, encoding='utf-8').read(), re.M):
    defined.add(unescape(m.group(1)))
# A key with interpolation is stored with a format specifier, e.g. "Guardada en %@".
def norm(k):
    out, i = '', 0
    while i < len(k):
        if k.startswith('\\(', i):               # swallow a balanced \( … ) interpolation
            depth, i = 1, i + 2
            while i < len(k) and depth:
                depth += (k[i] == '(') - (k[i] == ')'); i += 1
            out += '\x01'
        else:
            out += k[i]; i += 1
    out = out.replace('%%', '\x00')
    out = re.sub(r'%(?:lld|@|d|f|ld|\d*\.?\d*f)', '\x01', out)
    return out.replace('%', '\x00')
defined_norm = {norm(k) for k in defined}

missing = {}
for root, _, files in os.walk(src):
    if os.sep + 'QA' in root: continue  # debug-only self-test harness, never shipped
    for f in files:
        if not f.endswith('.swift'): continue
        path = os.path.join(root, f)
        text = open(path, encoding='utf-8').read()
        for p in pats:
            for m in p.finditer(text):
                key = unescape(m.group(1))
                if not re.search(r'[A-Za-zÁ-ú]{2}', key): continue       # symbols, numbers, SF Symbol-less glyphs
                if key in defined or norm(key) in defined_norm: continue
                line = text.count('\n', 0, m.start()) + 1
                missing.setdefault(key, f'{path}:{line}')

for k, where in sorted(missing.items(), key=lambda kv: kv[1]):
    print(f'{where}: {k}')
print(f'\n{len(missing)} key(s) without English translation', file=sys.stderr)
sys.exit(1 if missing else 0)
PY
