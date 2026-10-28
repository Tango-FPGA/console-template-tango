#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 the Tango authors
"""Core launcher pages = MiSTer's menu core (Main_MiSTer menu.cpp), page for page, in the Tango look.

Every page mirrors a MiSTer menu state; the source line is noted on each.  Rows marked ADDED are ours
(no MiSTer menu item).  Rows MiSTer has that Tango drops are not drawn.
Example data (core names, dates, sizes) is illustrative.
Usage: python3 launcher_pages.py            -> out/launcher/*.png + out/launcher_sheet.png
"""
import os, sys
from PIL import Image
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import zosd as Z
import pages as P

OUT = os.path.join(P.OUT, 'launcher'); os.makedirs(OUT, exist_ok=True)
BANNER = 'TANG CONSOLE'
KEYS_BROWSE = [('A', 'open'), ('Menu', 'settings'), ('\x83\x7f', 'page')]   # "` recent" returns with Recent Cores


# ---- About (the firmware's tango/tango_about.c): the wordmark "TANGO FPGA" in a 5 x 5 pixel font (a '#' is one 12 px cell = three 0x86 bricks), a strip, the
# web address, the firmware and core versions, a ticker on the last line; no cursor (any key goes back).  The ticker's text is the C file's (the layout check proves the two equal).
def _wordmark():
    L = {'T': ["#####", "  #  ", "  #  ", "  #  ", "  #  "], 'A': [" ### ", "#   #", "#####", "#   #", "#   #"],
         'N': ["#   #", "##  #", "# # #", "#  ##", "#   #"], 'G': [" ####", "#    ", "#  ##", "#   #", " ### "],
         'O': [" ### ", "#   #", "#   #", "#   #", " ### "], 'F': ["#####", "#    ", "#### ", "#    ", "#    "],
         'P': ["#### ", "#   #", "#### ", "#    ", "#    "]}
    return [' '.join(L[c][r] for c in 'TANGO') + '   ' + ' '.join(L[c][r] for c in 'FPGA') for r in range(5)]
WORDMARK = _wordmark()
TICKER = ("Tango FPGA is built on MiSTer's core interface and menu format and on the FPGA Companion firmware "
          "(Apache-2.0, Till Harbaum and contributors). It includes FreeRTOS (MIT), FatFs (ChaN), miniz (MIT), "
          "SDL_GameControllerDB (zlib), hdl-util/hdmi (MIT, Sameer Puri) and the Saira Condensed font "
          "(SIL Open Font License 1.1). The full list of credits and licences is in the Attributions of the Tango FPGA repository.")
STRIP = '\x84\x85' * 33
WEB = 'TangoFPGA.com'
def ticker_pos(font, step):    # tango_about_pos: starts with the text at the left edge (pos = the row's width), 3 px a step, wraps
    w = P.VX - P.TX; return (w + step * 3) % (font.width(TICKER) + w)
def about_page(banner, ver, core, step, sel=-1, font=None):
    font = font or Z.Font(*P.FONTS['saira'])
    return dict(banner=banner, title='About', sel=sel, legend=[('\x83', 'back')], rows=[('blank',)]
        + [('logo', r) for r in WORDMARK] + [('center', STRIP, P.ACC), ('blank',), ('center', WEB, P.TEXT), ('blank',),
           ('center', ver, P.TEXT), ('center', core, P.TEXT), ('blank',), ('scroll', TICKER, ticker_pos(font, step))])

PAGES = [
  # 1. MENU_FILE_SELECT with SCANO_CORES, title "Cores" [menu.cpp 1633, 5517]; root shows "_"-folders without "_"
  ('01_cores', dict(banner=BANNER, title='Cores', sel=1, legend=KEYS_BROWSE, rows=[
      ('dir', 'Arcade'), ('dir', 'Console'), ('dir', 'Computer'), ('dir', 'Utility')])),
  # 2. same browser inside _Console: "..", then cores; name minus "_YYYYMMDD" and extension, date code right [8455-8488]
  ('02_cores_console', dict(banner=BANNER, title='Cores', sel=4, legend=KEYS_BROWSE, rows=[
      ('up', '..'), ('file', 'Atari 2600', '26.08.02'), ('file', 'Game Boy', '26.09.03'), ('file', 'Master System', '26.07.19'),
      ('file', 'NES', '26.09.21'), ('file', 'PC Engine', '26.06.30'), ('file', 'SNES', '26.09.12')])),
  # 3. MENU_RECENT1, title "Recent Cores" [5797]; opened with the ` key from the browser [1430]
  ('03_recent_cores', dict(banner=BANNER, title='Recent Cores', sel=0, legend=[('A', 'load'), ('Menu', 'back')], rows=[
      ('file', 'NES'), ('file', 'Arcade Game Demo'), ('file', 'Game Boy')])),
  # 4. MENU_SYSTEM1, title "System Settings" + left arrow [7339-7415]; Left -> Misc. Options, Menu -> Cores
  ('04_system_settings', dict(banner=BANNER, title='System Settings', arrow='left', sel=6, legend=[('A', 'select'), ('Menu', 'cores'), ('\x83', 'misc.')], rows=[
      ('center', 'Tango v0.1'), ('blank',),
      ('center', 'Storage: SD card'), ('center', 'Available space: 29gb'), ('sep',),
      ('sub', 'Remap keyboard'), ('sub', 'Define joystick buttons'), ('sep',),
      ('act', 'Reboot (hold for cold reboot)'), ('blank',), ('blank',), ('blank',), ('act', 'exit')])),
  # 5. MENU_MISC1, title "Misc. Options" + right arrow [4019-4087]; Right -> System Settings
  ('05_misc_options', dict(banner=BANNER, title='Misc. Options', arrow='right', sel=8, legend=[('\x83\x7f', 'change'), ('A', 'apply'), ('\x7f', 'system')], rows=[
      ('center', 'Information', P.TEXT), ('center', '1280x720 60Hz  HDMI'), ('center', 'Scaler: 5x crop, 4:3'), ('sep',),
      ('opt', 'Config', '< Main >'), ('vol', 'Core Volume', 6, 8), ('vol', 'Global Volume', 8, 8), ('sep',),
      ('opt', 'Menu colour', '< Amber >'), ('opt', 'Boot core', '< Show cores >'), ('sub', 'Players'),   # ADDED
      ('act', 'Save settings'),                                                                            # ADDED: writes /Tango.ini
      ('act', 'exit')])),
  # 4b. what the firmware BUILDS of page 4 (the firmware's tango/tango_launcher.c build_system): the version lines are
  # this build's own, Scripts / Help / Switch to USB are dropped, and Remap keyboard is a dim
  # placeholder ("Not available yet" when selected); Define joystick buttons learns the Menu button (tango_menubtn.h)  Cursor on exit, as MiSTer opens it (menu.cpp 1642: menusub 6).
  ('04b_system_settings_built', dict(banner=BANNER, title='System Settings', arrow='left', sel=13, legend=[('A', 'select'), ('Menu', 'cores'), ('\x83', 'misc.')], rows=[
      ('blank',), ('center', 'Firmware g0f1e2d3-dirty 2026-10-12 21:30', P.TEXT), ('center', 'Menu core, version tag v260928'), ('blank',),
      ('center', 'Storage: SD card'), ('center', 'Available space: 29gb'), ('blank',),
      ('dis', 'Remap keyboard'), ('sub', 'Define joystick buttons'), ('act', 'About'), ('blank',),
      ('act', 'Reboot (hold \x7f cold reboot)'), ('blank',), ('act', 'exit')])),
  # 5b. what the firmware BUILDS of page 5 (build_misc): Information lists only what the firmware knows; Config, Boot core
  # and Players are dim placeholders; Core Volume 6 of 8 (attenuation 2) and Global Volume (attenuation 3; with no audio
  # filter in the core its bar is shorter by the core's attenuation: 6 cells).  Cursor on exit (menu.cpp 4046: menusub 3).
  ('05b_misc_options_built', dict(banner=BANNER, title='Misc. Options', arrow='right', sel=13, legend=[('\x83\x7f', 'change'), ('A', 'select'), ('Menu', 'cores')], rows=[
      ('blank',), ('center', 'Information', P.TEXT), ('center', 'HDMI 1280x720'), ('blank',), ('blank',),
      ('dis', 'Config'), ('blank',), ('vol', 'Core Volume', 6, 8), ('vol', 'Global Volume', 3, 6), ('blank',),
      ('dis', 'Boot core'), ('dis', 'Players'), ('blank',), ('act', 'exit', '\x7f')])),
  # 5c. global volume muted (menu.cpp 4082-4084 "< Mute >"), core volume full, cursor on Global Volume
  ('05c_misc_options_muted', dict(banner=BANNER, title='Misc. Options', arrow='right', sel=8, legend=[('\x83\x7f', 'change'), ('A', 'select'), ('Menu', 'cores')], rows=[
      ('blank',), ('center', 'Information', P.TEXT), ('center', 'HDMI 1280x720'), ('blank',), ('blank',),
      ('dis', 'Config'), ('blank',), ('vol', 'Core Volume', 8, 8), ('opt', 'Global Volume', '< Mute >'), ('blank',),
      ('dis', 'Boot core'), ('dis', 'Players'), ('blank',), ('act', 'exit', '\x7f')])),
  # 5d. the same with an IP address (the BL616 has one: a USB Ethernet adapter on its own USB host; MiSTer's first Information line) -- the IP line
  # is there only then.  Global volume as 05b.
  ('05d_misc_options_ip', dict(banner=BANNER, title='Misc. Options', arrow='right', sel=13, legend=[('\x83\x7f', 'change'), ('A', 'select'), ('Menu', 'cores')], rows=[
      ('blank',), ('center', 'Information', P.TEXT), ('center', 'IP: 192.0.2.10'), ('center', 'HDMI 1280x720'), ('blank',),
      ('dis', 'Config'), ('blank',), ('vol', 'Core Volume', 6, 8), ('vol', 'Global Volume', 3, 6), ('blank',),
      ('dis', 'Boot core'), ('dis', 'Players'), ('blank',), ('act', 'exit', '\x7f')])),
  # 5e. a core that has a native-rate plan active (SYS 0x70 says so): the link does not report the pixel clock or the rate back, so the line says
  # "native rate" instead of a number (and the core's own mode is not on the link at all: no line)
  ('05e_misc_options_native', dict(banner=BANNER, title='Misc. Options', arrow='right', sel=13, legend=[('\x83\x7f', 'change'), ('A', 'select'), ('Menu', 'cores')], rows=[
      ('blank',), ('center', 'Information', P.TEXT), ('center', 'HDMI 1280x720  native rate'), ('blank',), ('blank',),
      ('dis', 'Config'), ('blank',), ('vol', 'Core Volume', 6, 8), ('vol', 'Global Volume', 3, 6), ('blank',),
      ('dis', 'Boot core'), ('dis', 'Players'), ('blank',), ('act', 'exit', '\x7f')])),
  # 5f. the launcher's About (tango_about.h): the same page as a core's; the cursor on back
  ('05f_about_launcher', about_page(BANNER, 'Tango FPGA v261012 (g0f1e2d3-dirty)', 'Menu core v260928', 0)),
  # 6. MENU_KBDMAP, title "Keyboard" [7810-7852]
  ('06_keyboard', dict(banner=BANNER, title='Keyboard', sel=5, legend=[('Enter', 'finish')], rows=[
      ('blank',), ('center', 'Press key to change', P.TEXT), ('center', 'on any keyboard'), ('blank',),
      ('center', 'Enter \x7f Finish'), ('act', 'finish')])),
  # 10. ADDED: Players (MiSTer only has player_N_controller in MiSTer.ini)
  ('10_players', dict(banner=BANNER, title='Players', back=True, sel=0, legend=[('\x83\x7f', 'move'), ('A', 'pin'), ('B', 'back')], rows=[
      ('opt', 'Player 1', 'DualShock 4  (pinned)'), ('opt', 'Player 2', '8BitDo SN30 Pro'), ('dis', 'Player 3', 'none'), ('dis', 'Player 4', 'none'),
      ('sep',), ('info', 'Pins follow the pad model (VID:PID).')])),
]

# In-core pages: every core gets these from the framework (NES as the example core).
INCORE = 'NINTENDO NES'
INCORE_PAGES = [
  # 11. MENU_COMMON1, title "System" [menu.cpp 2863-2958]; Left -> back to the core's own page; Menu -> close
  ('11_incore_system', dict(banner=INCORE, title='System', sel=2, legend=[('A', 'select'), ('\x83', 'core'), ('Menu', 'close')], rows=[
      ('sub', 'Core'), ('blank',),
      ('sub', 'Define NES buttons'), ('sub', 'Button/Key remap'), ('act', 'Reset player assignment'), ('blank',),
      ('sub', 'Video processing'), ('blank',),
      ('act', 'Reset settings'), ('act', 'Save settings'), ('blank',),
      ('sub', 'Help'), ('act', 'About'), ('blank',), ('act', 'Reboot (hold \x7f cold reboot)'),   # "hold \x16" (2952)
      ('act', '\x83  exit')])),                           # STD_EXIT with OSD_ARROW_LEFT on the last line (2946)
  # 13. MENU_JOYKBDMAP, title "Button/Key remap" [4436-4466]
  ('13_incore_button_key_remap', dict(banner=INCORE, title='Button/Key remap', sel=10, legend=[('F12', 'advanced'), ('Esc', 'clear'), ('Enter', 'finish')], rows=[
      ('blank',), ('blank',), ('center', 'Supported mapping:', P.TEXT), ('blank',),
      ('center', 'Button(s)/Key(s) -> Key(s)'), ('center', 'Button(s) -> Button(s)'), ('blank',),
      ('center', 'F12 \x7f Advanced'), ('center', 'Esc \x7f Clear'), ('center', 'Enter \x7f Finish'),
      ('act', 'Cancel')])),
  # 17. About inside a core (tango_about.h): System > About; the ticker on the last line
  ('17_incore_about', about_page(INCORE, 'Tango FPGA v261012 (g0f1e2d3-dirty)', 'NES v260930', 0)),
  # 14. MENU_RESET1, title "Reset" [5909-5930]
  ('14_incore_reset_settings', dict(banner=INCORE, title='Reset', sel=3, legend=[('A', 'select')], rows=[
      ('center', 'Reset settings?', P.TEXT), ('blank',), ('act', 'yes'), ('act', 'no')])),
]

INCORE_DEFINE = dict(banner=INCORE, title='Define buttons', sel=-1, top=0, legend=[('Menu-hold', 'cancel'), ('Enter', 'finish')],
    rows=[('blank',)] * 3 + [('center', 'Press: A', P.TEXT)] + [('blank',)] * 4 + [('center', 'Menu-hold \x7f Cancel'), ('center', 'Enter \x7f Finish')])

def define_buttons(font, prompt, sub=None, hl=None, note=None, skip=False, pad=False, banner=BANNER, incore=False):
    """MENU_JOYDIGMAP [4188-4330]: title "Define buttons", "Press: <NAME>" on row 3, Esc/Enter help,
    and in the menu core an on-screen pad whose current button flashes (here: an accent pill)."""
    m = Z.Menu(font, P.PAL, P.W, P.H, P.SW, P.RH, P.TOP)
    m.banner_text(banner, P.ACCTXT, P.H - 22, (P.SW - font.cap) // 2 - (font.asc - font.cap))
    m.text(0, P.TX, 'Define buttons', P.TEXT); m.rule(0, P.RULE, P.RH - 3)
    cx = (P.TX + P.VX) // 2
    def center(r, s, col): m.text(r, cx - font.width(s) // 2, s, col)
    w1 = font.width(prompt + ' '); w2 = font.width(sub)
    x = cx - (w1 + w2) // 2; x = m.text(3, x, prompt + ' ', P.TEXT); m.text(3, x, sub, P.ACC)
    if note: center(5, note, P.DIM)
    if incore: center(7, 'Menu-hold \x7f Cancel', P.DIM)   # in a core [menu.cpp 4203]
    else: center(7, 'Esc \x7f Cancel', P.DIM)                # menu core [4199]
    center(8, 'Enter \x7f Finish', P.DIM)
    if skip: center(9, 'Space/User \x7f Skip', P.DIM)   # only during the d-pad / stick tests [menu.cpp 4232]
    if pad:
        layout = {10: [('L', -250), ('R', 250)],
                  11: [('U', -250), ('X', 250)],
                  12: [('L', -300), ('R', -200), ('Sel', -50), ('Start', 50), ('Y', 200), ('A', 300)],
                  13: [('D', -250), ('B', 250)]}
        for r, keys in layout.items():
            for name, dx in keys:
                on = (r, name, dx) == hl
                wx = font.width(name); x0 = cx + dx - wx // 2
                if on: m.bar(r, x0 - 16, x0 + wx + 16, P.BAR, 2)
                m.text(r, x0, name, P.BARTXT if on else P.TEXT)
    x = P.TX
    for k, lab in ([('Menu-hold', 'cancel')] if incore else [('Esc', 'cancel')]) + [('Enter', 'finish')]:
        x = m.text(17, x, k, P.ACC) + 6; x = m.text(17, x, lab, P.DIM) + 22
    fr = P.launcher_bg(); m.render(fr, (1280 - P.W) // 2, (720 - P.H) // 2, P.PANEL, P.ACC)
    return fr

if __name__ == '__main__':
    f = Z.Font(*P.FONTS['saira'])
    shots = []
    for name, spec in PAGES:
        im = P.render_page(f, spec); im.save(os.path.join(OUT, name + '.png')); shots.append((name, im))
    # 7-9: the Define-buttons flow in the menu core (joy_ana_map / joy_button_map / joy_bnames, menu.cpp 267-268, 7430-7448)
    for name, args in [('07_define_dpad_test', dict(prompt='DPAD test:', sub='Press RIGHT', skip=True)),
                       ('08_define_up', dict(prompt='Press:', sub='UP', hl=(11, 'U', -250), pad=True)),
                       ('09_define_menu', dict(prompt='Press:', sub='MENU', note='(can use 2-button combo)'))]:
        im = define_buttons(f, **args); im.save(os.path.join(OUT, name + '.png')); shots.append((name, im))
    for name, spec in INCORE_PAGES:
        im = P.render_page(f, spec); im.save(os.path.join(OUT, name + '.png')); shots.append((name, im))
    # 12. Define NES buttons in a core: MENU_JOYDIGMAP's rows exactly (menu.cpp 4188-4363): row 3 "Press: <name>" (the
    #     core's CONF_STR J names), rows 8-9 "Menu-hold > Cancel" / "Enter > Finish"; rows 5/7/10 (pad ID, Undefine,
    #     F12 Clear all) appear once a pad has answered (the firmware's tango/tango_padmap.c)
    im = P.render_page(f, INCORE_DEFINE)
    im.save(os.path.join(OUT, '12_incore_define_nes_buttons.png')); shots.append(('12_incore_define_nes_buttons', im))
    shots.sort()
    cols = 3; tw, th = 640, 360
    sheet = Image.new('RGB', (cols * (tw + 10), ((len(shots) + cols - 1) // cols) * (th + 10)), (40, 40, 40))
    for i, (n, im) in enumerate(shots):
        sheet.paste(im.resize((tw, th), Image.LANCZOS), ((i % cols) * (tw + 10), (i // cols) * (th + 10)))
    sheet.save(os.path.join(P.OUT, 'launcher_sheet.png'))
    print('pages:', len(shots), 'atlas BSRAM:', f.bsram(), 'cols:', f.total_cols())

# ---- a core's own pages (illustrative entries, no particular core): page 0 with an option of each kind, two sub-pages and two
# actions, 18 rows, so the page scrolls (14 visible) and the title bar shows the position, as MiSTer's 16-line OSD would scroll
# it; a sub-page with a file entry the core's menu mask greys and an option it could hide ----
EXAMPLE_PAGES = [
  ('15_core_example_page0', dict(banner='EXAMPLE', title='Example', sel=1, legend=[('A', 'change'), ('\x7f', 'system'), ('\x83', 'misc.'), ('Menu', 'close')], rows=[
      ('blank',),                                         # a separator line
      ('opt', 'Palette', 'Standard'),                     # options: label and the current choice
      ('opt', 'Border', 'Off'),
      ('opt', 'Picture', 'Colour bars'),
      ('opt', 'Frame rate', '60 Hz'),
      ('opt', 'Frame size', '320x240'),
      ('opt', 'Tone', 'Off'),
      ('opt', 'Stereo width', 'Full'),
      ('opt', 'Speed', '1x'),
      ('blank',),
      ('sub', 'More settings'),                           # a sub-page (page 1)
      ('blank',),
      ('sub', 'Extras'),                                  # a sub-page (page 2)
      ('blank',), ('blank',),
      ('act', 'Restart'),                                 # actions
      ('act', 'Restart and close'),
      ('act', '\x83  exit', '\x7f')])),                  # page-0 exit row on the last line (OSD_ARROW_RIGHT | OSD_ARROW_LEFT, menu.cpp 2219)
  ('16_core_example_page1', dict(banner='EXAMPLE', title='More settings', sel=3, legend=[('A', 'change'), ('\x83', 'back')], rows=[
      ('blank',),
      ('center', '- More settings -'),                   # a text line
      ('blank',),
      ('opt', 'Setting 1', 'Off'),
      ('dis', 'Load *.DAT'),                              # a file entry, greyed by the core's menu mask
      ('opt', 'Setting 2', 'Off'),                        # an option the menu mask could hide (shown)
      ('blank',), ('blank',), ('blank',), ('blank',), ('blank',), ('blank',), ('blank',),   # to the last line (2219)
      ('act', 'back')])),                                 # STD_BACK on the last line
]

# ---- System Settings > Define joystick buttons (the firmware's tango/tango_launcher.c, tango_padmap.c tango_pmcap_page with the menu core's flow; menu.cpp
# MENU_JOYDIGMAP rows 4195-4400): MiSTer's walk "Press: RIGHT" ... one button at a time, then the Menu entry ("(can use 2-button combo)" 4258-4262) ----
LEG_DEFS = [('Esc', 'cancel'), ('Enter', 'finish')]
def _def(rows): return dict(banner=BANNER, title='Define buttons', sel=-1, top=0, legend=LEG_DEFS, rows=rows)
PADID = ['054c:09cc']      # the Joystick ID the Define pages show (a co-simulation run sets it from its pad)
def _dw(press, pad=False, undefine=False, gp=None):   # the walk's page; gp = the four gamepad lines (None = no helper)
    r = [('blank',)] * 3 + [('center', 'Press: ' + press, P.TEXT)] + [('blank',)] * 4 + [('center', 'Esc \x7f Cancel'), ('center', 'Enter \x7f Finish')]
    if pad: r[5] = ('center', 'Joystick ID: ' + PADID[0])
    if undefine: r[7] = ('center', 'User/Space \x7f Undefine')
    if gp: r = r + [x if x else ('blank',) for x in gp]
    return r
_GP = [('center', 'L                                  R'), ('center', 'Up                                 X'),
       ('center', 'Left   Right   Select   Start   Y   A'), ('center', 'Down                               B')]
def _dm(held=None, note=None):   # the Menu step (phase 1)
    r = [('blank',)] * 3 + [('center', 'Press: Menu', P.TEXT)] + [('blank',)] * 9
    r[5] = ('center', 'Joystick ID: ' + PADID[0]); r[8] = ('center', 'Esc \x7f Cancel'); r[9] = ('center', 'Enter \x7f Finish'); r[12] = ('center', '(can use 2-button combo)')
    if held: r[7] = ('center', held, P.TEXT)
    return r
DEFINE_PAGES = [
  ('27_define_walk', _def(_dw('RIGHT', gp=_GP))),
  ('28_define_walk_id', _def(_dw('RIGHT', pad=True, gp=_GP))),
  ('29_define_walk_gamepad', _def(_dw('LEFT', pad=True, undefine=True, gp=_GP))),
  ('30_define_walk_gamepad_flash', _def(_dw('LEFT', pad=True, undefine=True, gp=[_GP[0], _GP[1], None, _GP[3]]))),
  ('31_define_menu', _def(_dm())),
  ('32_define_menu_pair', _def(_dm('L1 + R1'))),
]
if __name__ == '__main__':
    for name, spec in EXAMPLE_PAGES + DEFINE_PAGES:
        P.render_page(Z.Font(*P.FONTS['saira']), spec).save(os.path.join(OUT, name + '.png'))
    print('core pages done')
