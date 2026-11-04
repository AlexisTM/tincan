#!/usr/bin/env python3
"""Play Store images from the app renders: python3 tool/store/make_listing.py

Run `flutter test tool/store/screens_test.dart` first.
Writes tool/store/build/listing/.
"""
import html
import shutil
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageStat

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / 'tool/store/build'
SCREENS = BUILD / 'screens'
PAGES = BUILD / 'pages'
OUT = BUILD / 'listing'
ICON = OUT / 'icon-512.png'
LOGO = ROOT / 'brand/logo-color.svg'

NAME = 'Tincan'
TAGLINE = 'Private chat, straight between devices. No account, no phone number, no ads.'
TEAL, NAVY, DEEP, ORANGE = '#137C7A', '#1E2433', '#141823', '#F08B3E'
GROUND, GROUND2 = '#F6F3EE', '#E7EFEC'

PHONE = [
    ('thread', 'Chat straight<br>to your friends', 'Texts, photos, videos and reactions.'),
    ('chats', 'No account,<br>no phone number', 'Your Tincan ID is all anyone needs.'),
    ('new-chat', 'Connect with<br>a QR code', 'Share your ID, or scan theirs.'),
    ('requests', 'You choose<br>who can write', 'Accept, ignore or block every request.'),
    ('setup', 'Locked on<br>your device', 'Your chats are stored encrypted.'),
    ('thread-dark', 'Easy on<br>the eyes', 'Light and dark, as your system is set.'),
    ('profile', 'Your profile,<br>for your contacts', 'Name, status and picture, nothing more.'),
    (None, 'Private<br>by design', None),
]
FACTS = [
    ('lock', 'End-to-end encrypted'),
    ('person_off', 'No account, no sign-up'),
    ('wifi', 'Direct between devices when the network allows'),
    ('block', 'No ads, no tracking, no analytics'),
    ('desktop', 'On Android and Linux'),
]
TABLET = [
    ('tablet-thread', 'Your chats and the conversation, side by side'),
    ('tablet-new-chat', 'Start a conversation with a QR code'),
    ('tablet-dark', 'Light or dark, as you like it'),
]
FEATURE = ('chats-dark', 'thread')

# Material Symbols paths (24px viewBox), drawn inline so no icon font is needed.
ICONS = {
    'lock': 'M6 22q-.825 0-1.412-.587Q4 20.825 4 20V10q0-.825.588-1.413Q5.175 8 6 8h1V6q0-2.075 1.463-3.538Q9.925 1 12 1t3.538 1.462Q17 3.925 17 6v2h1q.825 0 1.413.587Q20 9.175 20 10v10q0 .825-.587 1.413Q18.825 22 18 22Zm6-5q.825 0 1.413-.587Q14 15.825 14 15q0-.825-.587-1.413Q12.825 13 12 13q-.825 0-1.412.587Q10 14.175 10 15q0 .825.588 1.413Q11.175 17 12 17ZM9 8h6V6q0-1.25-.875-2.125T12 3q-1.25 0-2.125.875T9 6Z',
    'person_off': 'm20.6 22.4-2.8-2.8q-.35.2-.762.3Q16.625 20 16.2 20H4v-2.8q0-.85.438-1.563.437-.712 1.162-1.087 1.15-.575 2.4-.938 1.25-.362 2.55-.487L1.6 4.2 3 2.8l19 19ZM12 11.15 8.85 8q.25-1.6 1.475-2.8Q11.55 4 13.2 4q1.65 0 2.825 1.175Q17.2 6.35 17.2 8q0 1.65-1.175 2.825Q14.85 12 13.2 12q-.375 0-.65-.05-.275-.05-.55-.8Zm6.85 6.85-3.6-3.6q.7.125 1.35.325.65.2 1.3.525.725.375 1.163 1.087.437.713.437 1.563Z',
    'block': 'M12 22q-2.075 0-3.9-.788-1.825-.787-3.175-2.137-1.35-1.35-2.137-3.175Q2 14.075 2 12t.788-3.9q.787-1.825 2.137-3.175 1.35-1.35 3.175-2.138Q9.925 2 12 2t3.9.787q1.825.788 3.175 2.138 1.35 1.35 2.137 3.175Q22 9.925 22 12t-.788 3.9q-.787 1.825-2.137 3.175-1.35 1.35-3.175 2.137Q14.075 22 12 22Zm0-2q1.35 0 2.6-.438 1.25-.437 2.3-1.262L5.7 7.1q-.825 1.05-1.262 2.3Q4 10.65 4 12q0 3.35 2.325 5.675Q8.65 20 12 20Zm6.3-3.1q.825-1.05 1.263-2.3Q20 13.35 20 12q0-3.35-2.325-5.675Q15.35 4 12 4q-1.35 0-2.6.437-1.25.438-2.3 1.263Z',
    'wifi': 'M12 21 0 9q2.375-2.35 5.45-3.675Q8.525 4 12 4t6.55 1.325Q21.625 6.65 24 9Z',
    'desktop': 'M8 21v-2h2v-2H4q-.825 0-1.412-.587Q2 15.825 2 15V5q0-.825.588-1.413Q3.175 3 4 3h16q.825 0 1.413.587Q22 4.175 22 5v10q0 .825-.587 1.413Q20.825 17 20 17h-6v2h2v2Z',
}

FONT = (ROOT / 'assets/fonts/SchibstedGrotesk.ttf').as_uri()
BASE_CSS = f"@font-face{{font-family:Schibsted;src:url('{FONT}')}}" + '''
*{margin:0;padding:0;box-sizing:border-box}
html,body{width:var(--w);height:var(--h);overflow:hidden;font-family:Schibsted,sans-serif;-webkit-font-smoothing:antialiased}
.blob{position:absolute;border-radius:50%;filter:blur(2px)}
.phone{position:absolute;background:#0D1114;border-radius:96px;padding:22px;
  box-shadow:0 60px 120px rgba(0,0,0,.45),0 0 0 3px rgba(255,255,255,.08) inset}
.phone .glass{position:relative;width:100%;height:100%;border-radius:76px;overflow:hidden;background:#000}
.phone img{display:block;width:100%}
.status{position:absolute;top:0;left:0;right:0;height:var(--sbh);display:flex;align-items:center;justify-content:space-between;
  padding:0 52px;font-weight:500;font-size:var(--sbf);z-index:2}
.status:after{content:'';position:absolute;left:50%;top:50%;width:var(--cam);height:var(--cam);border-radius:50%;background:#0D1114;transform:translate(-50%,-50%)}
.sb-icons{display:flex;gap:10px} .sb-icons svg{width:var(--sbf);height:var(--sbf)}
'''


def status_bar(ink):
    return f'''<div class="status" style="color:{ink}"><span>9:41</span><span class="sb-icons">
<svg viewBox="0 0 24 24" style="fill:{ink}"><path d="{ICONS['wifi']}"/></svg>
<svg viewBox="0 0 24 24" style="fill:{ink}"><path d="M2 22 22 2v20Z"/></svg>
<svg viewBox="0 0 24 24" style="fill:{ink}"><path d="M8 22q-.425 0-.713-.288Q7 21.425 7 21V5q0-.425.287-.713Q7.575 4 8 4h2V2h4v2h2q.425 0 .712.287Q17 4.575 17 5v16q0 .425-.288.712Q16.425 22 16 22Z"/></svg>
</span></div>'''


def ink_for(png):
    """Light status bar text over a dark top edge, dark over a light one."""
    im = Image.open(png).convert('L')
    top = im.crop((0, 0, im.width, max(1, im.height // 60)))
    return '#ECEEF2' if ImageStat.Stat(top).mean[0] < 128 else '#1B1F27'


def page(name, w, h, body, css=''):
    path = PAGES / f'{name}.html'
    path.write_text(f'<!doctype html><html><head><meta charset="utf-8"><style>:root{{--w:{w}px;--h:{h}px}}'
                    f'{BASE_CSS}{css}</style></head><body>{body}</body></html>')
    return path


def frame(key, x, y, width, sb_h, sb_font, cam, height, rotate=0):
    style = (f'left:{x}px;top:{y}px;width:{width}px;height:{height}px;'
             f'--sbh:{sb_h}px;--sbf:{sb_font}px;--cam:{cam}px')
    if rotate:
        style += f';transform:rotate({rotate}deg)'
    shot = SCREENS / f'{key}.png'
    return (f'<div class="phone" style="{style}"><div class="glass">{status_bar(ink_for(shot))}'
            f'<img src="{shot.as_uri()}"></div></div>')


def background(dark):
    if dark:
        return (f'<div style="position:absolute;inset:0;background:radial-gradient(120% 80% at 50% 0%,{NAVY} 0%,{DEEP} 70%)"></div>'
                f'<div class="blob" style="width:900px;height:900px;left:-420px;bottom:-520px;background:{TEAL};opacity:.25"></div>'
                f'<div class="blob" style="width:600px;height:600px;right:-300px;top:260px;background:{ORANGE};opacity:.10"></div>')
    return (f'<div style="position:absolute;inset:0;background:radial-gradient(120% 80% at 50% 0%,#FFFFFF 0%,{GROUND} 60%,{GROUND2} 100%)"></div>'
            f'<div class="blob" style="width:900px;height:900px;left:-420px;bottom:-520px;background:{TEAL};opacity:.08"></div>'
            f'<div class="blob" style="width:600px;height:600px;right:-300px;top:260px;background:{ORANGE};opacity:.08"></div>')


def heading(title, fg, sub=None, sub_fg=None):
    sub_html = f'<p style="margin-top:30px;font-size:42px;line-height:1.3;color:{sub_fg}">{html.escape(sub)}</p>' if sub else ''
    return f'''<div style="position:absolute;left:0;right:0;top:118px;text-align:center;padding:0 60px">
  <div style="width:84px;height:10px;border-radius:5px;background:{ORANGE};margin:0 auto 40px"></div>
  <h1 style="font-size:88px;line-height:1.06;font-weight:700;color:{fg};letter-spacing:-1px">{title}</h1>{sub_html}
</div>'''


def phone_shot(i, key, title, sub, dark):
    fg, sub_fg = ('#FFFFFF', 'rgba(255,255,255,.82)') if dark else (NAVY, '#4A5262')
    # The 1080x2340 render in an 800 px wide screen; its status bar is 24 dp = 63 px.
    screen_w = 800
    k = screen_w / 1080
    body = (background(dark) + heading(title, fg, sub, sub_fg)
            + frame(key, (1080 - screen_w - 44) // 2, 500, screen_w + 44, 63 * k, 34 * k + 8, 34 * k, 2340 * k + 44))
    return page(f'phone-{i}', 1080, 1920, body)


def facts_shot(i, title):
    rows = ''.join(
        f'''<div style="display:flex;align-items:center;gap:38px;padding:34px 0;border-bottom:2px solid rgba(255,255,255,.14)">
<div style="flex:none;width:112px;height:112px;border-radius:32px;background:rgba(255,255,255,.12);display:grid;place-items:center">
<svg viewBox="0 0 24 24" style="width:60px;height:60px;fill:#FFFFFF"><path d="{ICONS[icon]}"/></svg></div>
<div style="font-size:48px;line-height:1.2;font-weight:700;color:#FFFFFF">{html.escape(text)}</div></div>'''
        for icon, text in FACTS)
    body = f'''{background(True)}{heading(title, '#FFFFFF')}
<div style="position:absolute;left:96px;right:96px;top:520px">{rows}</div>
<div style="position:absolute;left:0;right:0;bottom:130px;display:flex;justify-content:center;align-items:center;gap:28px">
  <img src="{ICON.as_uri()}" style="width:110px;height:110px;border-radius:26px">
  <span style="font-size:52px;font-weight:700;color:#FFFFFF">{NAME}</span>
</div>'''
    return page(f'phone-{i}', 1080, 1920, body)


def tablet_shot(i, key, title):
    # The 2560x1600 render shown 1600 px wide.
    k = 1600 / 2560
    shot = SCREENS / f'{key}.png'
    body = f'''
<div style="position:absolute;inset:0;background:radial-gradient(90% 120% at 0% 0%,{TEAL} 0%,{NAVY} 60%,{DEEP} 100%)"></div>
<div class="blob" style="width:900px;height:900px;left:-380px;bottom:-560px;background:#FFFFFF;opacity:.07"></div>
<div style="position:absolute;left:0;right:0;top:64px;text-align:center">
  <h1 style="font-size:64px;font-weight:700;color:#FFFFFF;letter-spacing:-.5px">{html.escape(title)}</h1>
</div>
<div class="phone" style="left:{(1920 - 1600 - 36) // 2}px;top:190px;width:{1600 + 36}px;height:{1600 * k + 36}px;border-radius:52px;padding:18px;--sbh:{48 * k}px;--sbf:{30 * k + 6}px;--cam:{22 * k}px">
  <div class="glass" style="border-radius:36px">{status_bar(ink_for(shot))}<img src="{shot.as_uri()}"></div>
</div>'''
    return page(f'tablet-{i}', 1920, 1080, body)


def feature_graphic():
    k = 250 / 1080
    back, front = FEATURE
    phones = (frame(back, 630, 78, 270, 63 * k, 34 * k + 4, 30 * k, 2340 * k + 20, rotate=-6)
              + frame(front, 790, 48, 270, 63 * k, 34 * k + 4, 30 * k, 2340 * k + 20, rotate=5))
    body = f'''
<div style="position:absolute;inset:0;background:radial-gradient(110% 140% at 0% 0%,{TEAL} 0%,{NAVY} 65%,{DEEP} 100%)"></div>
<div class="blob" style="width:620px;height:620px;left:560px;top:-90px;background:{ORANGE};opacity:.12"></div>
{phones}
<div style="position:absolute;left:64px;top:0;bottom:0;width:540px;display:flex;flex-direction:column;justify-content:center">
  <div style="display:flex;align-items:center;gap:22px">
    <img src="{ICON.as_uri()}" style="width:84px;height:84px;border-radius:20px">
    <span style="font-size:56px;font-weight:700;color:#FFFFFF;letter-spacing:-.5px">{NAME}</span>
  </div>
  <p style="margin-top:28px;font-size:30px;line-height:1.3;color:rgba(255,255,255,.9)">{html.escape(TAGLINE)}</p>
</div>'''
    css = '.phone{border-radius:44px!important;padding:10px!important}.phone .glass{border-radius:34px!important}.status{padding:0 22px}'
    return page('feature', 1024, 500, body, css)


def icon_page():
    # The logo's tile sits 16 px inside its 256 box; Play masks the corners itself, so the tile goes full bleed.
    size = 512 * 256 / 224
    off = (size - 512) / 2
    return page('icon', 512, 512, f'<div style="position:relative;background:{TEAL};width:512px;height:512px;overflow:hidden">'
                f'<img src="{LOGO.as_uri()}" style="position:absolute;left:-{off}px;top:-{off}px;width:{size}px;height:{size}px"></div>')


def render(html_path, png_path, w, h):
    chrome = shutil.which('chromium') or shutil.which('chromium-browser') or shutil.which('google-chrome')
    if not chrome:
        sys.exit('Needs chromium or google-chrome on PATH')
    # Snap's chromium cannot write outside home, so render next to the page first.
    shot = html_path.with_suffix('.png')
    subprocess.run([chrome, '--headless', '--disable-gpu', '--hide-scrollbars', '--allow-file-access-from-files',
                    '--force-device-scale-factor=1', f'--window-size={w},{h}', f'--screenshot={shot}',
                    html_path.as_uri()], check=True, capture_output=True)
    # Play wants 24-bit PNG, no alpha.
    Image.open(shot).convert('RGB').save(png_path)


def main():
    needed = [k for k, *_ in PHONE if k] + [k for k, _ in TABLET] + list(FEATURE)
    missing = [k for k in needed if not (SCREENS / f'{k}.png').exists()]
    if missing:
        sys.exit(f'No renders for {missing}: run flutter test tool/store/screens_test.dart')
    PAGES.mkdir(parents=True, exist_ok=True)
    OUT.mkdir(parents=True, exist_ok=True)
    render(icon_page(), ICON, 512, 512)
    for i, (key, title, sub) in enumerate(PHONE, 1):
        p = facts_shot(i, title) if key is None else phone_shot(i, key, title, sub, dark=i % 2 == 0)
        render(p, OUT / f'phone-{i}.png', 1080, 1920)
    for i, (key, title) in enumerate(TABLET, 1):
        render(tablet_shot(i, key, title), OUT / f'tablet-{i}.png', 1920, 1080)
    render(feature_graphic(), OUT / 'feature-graphic.png', 1024, 500)
    print(f'Wrote {OUT}')


if __name__ == '__main__':
    main()
