#!/usr/bin/env python3
"""Tiny Markdown to HTML for README.md: #/##/### headings, - and 1. lists, ``` blocks, > notes, ![alt](img) figures, **bold**, `code`. Anything fancier is not supported."""
import html, re, struct, sys

def png_width(path):
    """Pixel width from the PNG header, or 0 if unreadable."""
    try:
        with open(path, "rb") as f: return struct.unpack(">I", f.read(24)[16:20])[0]
    except (OSError, struct.error): return 0


def inline(t):
    t = html.escape(t)
    t = re.sub(r"`([^`]+)`", r"<code>\1</code>", t)
    return re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", t)

out, lst, code = [], None, False
def close():
    global lst
    if lst: out.append(f"</{lst}>"); lst = None

for line in open(sys.argv[1]).read().splitlines():
    if line.startswith("```"):
        close(); out.append("</pre>" if code else "<pre>"); code = not code; continue
    if code: out.append(html.escape(line)); continue
    m = re.match(r"!\[(.*)\]\((.*)\)$", line)
    if m:
        close(); src = m[2].replace("docs/screenshots/", "screenshots/") # app bundle layout
        w = png_width(m[2]); w = w // 2 if w >= 800 else w # shortcut: wide files are assumed to be 2x retina captures, show them at half their pixel width
        size = f' width="{w}"' if w else ""
        out.append(f'<figure><img src="{html.escape(src)}"{size} alt="{html.escape(m[1])}"><figcaption>{html.escape(m[1])}</figcaption></figure>'); continue
    m = re.match(r"> (.*)", line)
    if m: close(); out.append(f"<blockquote>{inline(m[1])}</blockquote>"); continue
    m = re.match(r"(#{1,3}) (.*)", line)
    if m: close(); out.append(f"<h{len(m[1])}>{inline(m[2])}</h{len(m[1])}>"); continue
    m = re.match(r"- (.*)", line); kind = "ul"
    if not m: m = re.match(r"\d+\. (.*)", line); kind = "ol"
    if m:
        if lst != kind: close(); out.append(f"<{kind}>"); lst = kind
        out.append(f"<li>{inline(m[1])}</li>"); continue
    close()
    if line.strip(): out.append(f"<p>{inline(line)}</p>")
close()
print("""<!doctype html><meta charset="utf-8"><style>
:root{color-scheme:light dark}
body{font:14px/1.55 -apple-system,system-ui,sans-serif;max-width:720px;margin:24px auto;padding:0 24px}
h1{font-size:26px;margin:0 0 4px}h2{font-size:17px;margin:28px 0 6px;padding-top:6px;border-top:1px solid rgba(128,128,128,.3)}
p,li{margin:6px 0}ul,ol{padding-left:22px}
code,pre{font:12.5px ui-monospace,Menlo,monospace;background:rgba(128,128,128,.16);border-radius:5px}
code{padding:1px 5px}pre{padding:10px 12px;overflow-x:auto}
h3{font-size:15px;margin:22px 0 4px}
figure{margin:12px 0}img{max-width:100%;height:auto;border-radius:10px;border:1px solid rgba(128,128,128,.3)}
figcaption{font-size:12px;opacity:.65;margin-top:4px}
blockquote{margin:12px 0;padding:8px 14px;border-left:3px solid #d29a1a;background:rgba(210,154,26,.12);border-radius:0}
</style>""" + "\n".join(out))
