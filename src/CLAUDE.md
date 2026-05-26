# CLAUDE.md — MAME Z80 debugging via Claude

## Goal
Drive the MAME debugger from Claude (in VS Code) to test Z80/8080 code written
to run inside an emulated retro computer. Claude should be able to inspect/modify
registers and memory, set breakpoints/watchpoints, single-step, and disassemble.

## Two integration paths (decided in prior session)

### Path A — MAME built-in GDB stub  (`-debugger gdbstub`)
- The **C++ module** `src/osd/modules/debugger/debuggdbstub.cpp` *does* support Z80:
  shortnames `z80`, `z80n`, `z84c015` map to a Z80 register set
  (AF, BC, DE, HL, AF', BC', DE', HL', IX, IY, SP, PC). Also covers 6502 family,
  6809, 68000/020/030, ARM7, MIPS, PPC601, nios2, PSX.
- NOTE: the **Lua plugin** `plugins/gdbstub` is i386-only. Don't confuse the two.
- Launch: `mame <system> -debug -debugger gdbstub -debugger_port <port>`
  (read the actual port from MAME's startup log line `gdbstub: listening on ...`).
- Connect any GDB-remote client (e.g. `gdb-multiarch`) or an MCP wrapper over gdb.
- **Limitations that matter for retro machines:** single connection only,
  flaky reconnect (often must restart MAME per session), and **no memory bank
  paging** — sees a flat address space. Bad for ZX Spectrum 128 / MSX / banked CP/M.

### Path B — Custom Lua bridge  (files in this repo)  ← PRIMARY PATH
- `plugins/mamebridge/` (init.lua + plugin.json) + `mame_mcp.py`. Works for any CPU
  and **reads memory through MAME's live address space, so bank switching is
  handled correctly.**
- Former caveat NOW FIXED: the old `mame_bridge.lua` autoboot script polled via
  `add_machine_frame_notifier`, which does not fire while the machine is
  *hard-stopped* in the debugger. The `mamebridge` plugin instead pumps via
  `emu.register_periodic()`, which is driven by `emulator_info::periodic_check()`
  inside the debugger's `while (is_stopped())` loop (src/emu/debug/debugcpu.cpp).
  So interactive stop→step→inspect loops now work.
- `mame_bridge.lua` is kept as a fallback for live (running) inspection only.

## RESOLVED: banked vs flat memory
The target machine uses **banked memory** → Path B (Lua bridge) is the primary
path. (Path A / gdbstub sees a flat address space and can't follow bank
switching, so it's unsuitable here.)

## Files
- `plugins/mamebridge/` — the plugin (init.lua + plugin.json). Load with
  `-plugin mamebridge`. File-IPC over a shared dir. Pumps via `register_periodic`,
  so it works while the machine is stopped.
- `mame_bridge.lua` — older autoboot version (`-autoboot_script`). Fallback for
  live inspection only; goes silent when the debugger hard-stops.
- `mame_mcp.py` — FastMCP server (`pip install "mcp[cli]"`). Talks to the bridge.
  Unchanged between the two — the file-IPC protocol is identical.

## Run (Path B)
```
mame <system> -debug -plugin mamebridge
claude mcp add mame-z80 -- python ./mame_mcp.py
```
**Debugger-agnostic — VERIFIED under the native macOS Cocoa debugger.** The bridge
pump (`emu.register_periodic`) is driven by `emulator_info::periodic_check()` in the
core `while (is_stopped())` loop (debugcpu.cpp:446), which runs *before*
`wait_for_debugger` for ANY OSD debugger module. So it works the same with
`-debugger qt`, `-debugger imgui`, or `-debugger auto` (= Cocoa `debugosx` on macOS).
On 2026-05-22 all bridge commands were verified live under `-debugger auto` (Cocoa),
incl. the critical stop/step loop responding with no timeout while hard-stopped.
(Earlier the Cocoa debugger could starve the pump because its `drawRect` used
NSLayoutManager ~1.7s/redraw on the same main thread; that view is now Core-Text-
based, so the starvation is gone.)
If MAME can't find the plugin, add the repo plugins dir explicitly:
`-pluginspath /Users/tolik/Documents/GitHub/mame/plugins`.
Env (must match on both sides):
- `MAME_MCP_DIR`  IPC dir (default /tmp/mame_mcp)
- `MAME_MCP_CPU`  CPU tag (default :maincpu)
- `MAME_MCP_SNAP_DIR` screenshot dir (default /tmp/mame_snap, cleared on reboot)
- `MAME_MCP_TIMEOUT` reply wait seconds (Python side, default 10)

## MCP tools exposed
read_registers, read_memory, read_logical_memory, read_vram, read_share,
list_shares, write_memory, set_breakpoint (with optional condition expr),
clear_breakpoint, list_breakpoints, set_watchpoint, clear_watchpoint, step,
step_over, step_out, resume, pause, status, disassemble, screenshot,
list_ports, press_key, type_text, move_mouse, click_mouse, press_input,
set_input, debugger_command (raw console-command escape hatch).
Address args accept "0xC000", bare hex "C000", or decimal "49152" (the plugin's
`parse_addr` normalises all three).
`screenshot` (bridge cmd `snap`) saves a PNG of the active screen and returns its
path; open that path to view the screen. Snaps go to `MAME_MCP_SNAP_DIR`
(default `/tmp/mame_snap`, cleared on reboot). The image is the last drawn frame,
so while hard-stopped resume briefly before snapping for a fresh frame.

## Reading the screen for mouse navigation (scrpix) — what works & what's hard
- `scrpix x y w h` (bridge) reads RENDERED screen pixels via `screen:pixel(x,y)`
  (4-hex pen each, row-major, max 8192 px). This is the video output decoded from
  VRAM by the hardware — correct screen coords, no manual tile/4bpp/buffer math.
- Raw VRAM is much harder: graphics mode is TILE-BASED (16x8 tiles, 4-byte
  descriptors via `as_mode`), 4bpp (screen_x ≈ 2·vram_byte_x), TWO panels in one
  VRAM, and DOUBLE-BUFFERED — active descriptor set chosen by rgmod (read with
  `cmd print (ib@C9)`); the UI list is in the active buffer (+0x20000) while the
  mouse CURSOR is drawn in the OTHER buffer. So raw-VRAM diffs gave false cursor
  coords. Prefer scrpix.
- Finding the cursor: text AND cursor are both white (pen 0xFFFF=65535), so the
  cursor can't be isolated by colour — only by DIFF (move mouse a little, diff two
  scrpix grabs; changed pixels = cursor, click point = top-left of them).
- List structure (C:\ZX\): text rows on an 8px pitch; left panel columns ~x48-150
  (col1) and ~x166-220 (col2 with pent_*/sprinter). sprinter.zx ≈ row6 of col2.
- NOT SOLVED yet: robust closed-loop pointing. The diff-based find_cursor is
  flaky (probe move + timing/buffer issues lose the cursor) and the mouse->pixel
  scale drifts, so an automated click on a specific small item isn't reliable yet.
  Keyboard navigation (press_key, точные одиночные нажатия) is the reliable path.

## Sprinter memory & video map (from mame/sinclair/sprinter.cpp, verified live)
CPU is z84c015 with THREE spaces: program (mem), io, opcodes (fetch). Memory is
banked, so reading needs care.

**Banking — 64K Z80 logical → physical pages:**
- 4 windows of 16K. Crucially the program space is wider than 64K: the windows
  live at program 0x10000+ (`map_mem`, sprinter.cpp:1448):
  win0 Z80 0x0000-0x3FFF → program 0x10000; win1 0x4000→0x14000;
  win2 0x8000→0x18000; win3 0xC000→0x1C000.
- Reading `mem L` (raw program 0..0xFFFF) hits bootstrap_r (sprinter.cpp:1185),
  which forwards to 0x10000|L *after* the FPGA bitstream loads but returns fastram
  while loading — so it's unreliable early. Use `read_logical_memory`/`lmem`
  (reads 0x10000|L) for the Z80's real view. Verified: lmem == mem(0x10000|L) ==
  dasm at the same address.
- Physical pages are m_ram (default 64M) indexed by page<<14 (configure_entries,
  sprinter.cpp:1577). The page for each window is computed in `update_memory`
  (sprinter.cpp:327) from a tangle of ports (m_pn/7FFD, m_sc/1FFD, m_cnf, m_dos,
  m_rom_rg, ...) via the DCP table m_ram_pages. When a window's page&0xF0==0x50 it
  is the VRAM aperture: phys = (0x50<<14)+m_port_y*1024+(offset&0x3FF).

**Video (VRAM = 256K share ":vram", read with `read_vram`):**
- Mode select: m_conf (rare Game Config) → screen_update_game, else
  screen_update_graph (sprinter.cpp:404). Modes: 320x256x256, 640x256x16,
  Spectrum, text. Per-16x8-tile 4-byte "mode descriptor" at
  as_mode(a,b)=vram+(1+a*2+0x80*(m_rgmod&1))*1024+0x300+b*4 (sprinter.cpp:554).
- Pixel fetch (draw_tile, sprinter.cpp:453): color =
  vram[(y+((dy-hold.y)&7>>lowres))*1024 + x + ((dx-hold.x)&15>>(1+lowres))],
  x=(mode[0][0:4]<<6)|(mode[1][0:3]<<3), y=mode[1][3:8]<<3. 8bpp if mode[0] bit5
  else 4bpp (2 px/byte). Palette base = mode[0][6:8]<<8.
- Palette lives in VRAM: writes to laddr>=0x3E0 set pen
  (offset[2:5]*256 + offset>>10) = RGB triple at offset&~3 (vram_w sprinter.cpp:1287).
  256 pens * 8 palettes. Text pens are 0x400+.
- Easiest "see the screen": just use `screenshot`. Use read_vram for programmatic
  checks (did the program write expected pixels/palette without rendering).

**Breakpoints / watchpoints by region:**
- PC breakpoints (`set_breakpoint`) take logical 0..0xFFFF (fetch space) — works
  regardless of which physical page is banked in.
- Watchpoints default to program space: `wpset ADDR,LEN,rw`. For a specific Z80
  window use the 0x10000+ address; for raw logical use the debugger directly.
  The bridge now sets bp/wp via the NATIVE Lua debugger API
  (`cpu().debug:bpset/wpset/...`), not console strings. `wp` / `set_watchpoint`
  take an optional space: `wp ADDR LEN ACCESS [program|data|io|opcodes]`
  (→ `cpu().debug:wpset(cpu().spaces[space], type, addr, len)`). NOTE: the native
  wpset address is LITERAL in the chosen space (no bank translation) — to watch a
  Z80 window in program space pass the 0x10000+ address (e.g. 0x18000 = window 2),
  exactly like write_memory/mem. (The old console `wpset 0x8000` quirkily relocated
  to 0x18000; native is literal/predictable.)
- To catch BANK SWITCHES, set an IO watchpoint on the paging ports. Current MAME
  uses a SPACE-SPECIFIC command — `wpiset` for io space (the old
  `wpset ADDR,1,w,1,1,i` form is rejected as "too many parameters"). E.g.
  `set_watchpoint("0xc1",1,"w",space="io")`, or via
  debugger_command: `wpiset 0xc1,1,w` (port 0xC1=m_pn) or 0xC0 (m_sc),
  0xC4 (m_port_y), 0xC5 (m_rgmod), 0xC6 (m_cnf). (`wpset`=program, `wpdset`=data,
  `wpiset`=io.) NOTE: ports written internally via the FPGA/DCP — e.g. rgmod 0xC9 —
  are NOT seen by an io watchpoint, since they aren't reached by a Z80 OUT; an io
  wp only catches actual IN/OUT on that port.
- Note: m_pages/m_pn/etc. are private C++ members, NOT exposed to Lua. To inspect
  current banking, watch the ports or read the DCP copies in m_ram.

## Sprinter input injection (verified live)
Input is only processed while the machine is RUNNING — frame notifiers and the
natkeyboard timer don't tick while hard-stopped. So `resume` before sending input
(and `pause` after if needed). The plugin holds each press for N frames via a
frame notifier that re-applies set_value(1) every frame (MAME re-polls per frame).

**Two of everything.** On the real host one keypress goes to BOTH keyboards and
mouse motion to BOTH mice, so `press_key`/`move_mouse`/`click_mouse` drive both:
- Keyboards: PC PS/2 `:kbd:ms_naturl:P1.0..P2.7` (what Flex Navigator and most
  firmware reads — verified: cursor keys/Tab move the UI) AND ZX matrix
  `:IO_LINE0..7`. `press_key` maps named keys to both where an equivalent exists.
- Mice: Kempston `:mouse_input1/2` (X/Y mask 0xFF) + buttons `:mouse_input3`, AND
  RS232 COM `:rs232:microsoft_mouse:X/Y` (mask 0xFFF) + `:BTN`. Mouse axes are
  relative, so motion is held several frames to accumulate.
- Joysticks: `:JOY1`/`:JOY2` (e.g. A=0x400, B=0x010, Up=0x208, Down=0x104,
  Left=0x002, Right=0x001) via press_input.
`type_text` uses natkeyboard but targets only one keyboard and needs in_use; for
the firmware UI prefer `press_key`. Use `list_ports` to rediscover tags/masks.

## Environment gotchas (verified on the sprinter machine)
- `plugins/` here is symlinked from `~/Documents/MAME/plugins`, which is the
  active `pluginspath`, so editing the repo files updates the running plugin.
- Run with the real config (see `~/Documents/MAME/Debug.sh`): `-bios dev` plus the
  disk/floppy images. Without `-bios dev` the default `sp2k` BIOS ROM is missing
  and the machine refuses to start.
- The `portname` plugin used the removed `emu.register_start`; it now uses
  `emu.add_machine_reset_notifier`. If it ever crashes the boot again with
  "attempt to call a nil value", that's the regression to look at (or just run
  with `-noplugin portname`).
- Only run ONE `mamed` at a time against a given `MAME_MCP_DIR`; a second instance
  fails to start but a stale first instance keeps answering with old plugin code.

## Next actions
1. ~~Confirm banked vs flat memory.~~ DONE — banked.
2. ~~Turn `mame_bridge.lua` into a plugin (init.lua + plugin.json) for reliable
   stop/step.~~ DONE — see `plugins/mamebridge/`.
3. Smoke test: load Z80 program, `set_breakpoint` at entry, `resume`, read regs.
   Then verify the stop/step loop: at a breakpoint, `status` must reply
   `state=stop` without timing out, and `step` + `read_registers` must advance PC
   while staying stopped.
