#!/usr/bin/env python3
"""
mame_mcp.py - MCP server that lets Claude Code drive the MAME debugger
(via mame_bridge.lua) for Z80/8080 retro-computer code.

Run standalone for a smoke test:  python mame_mcp.py
Claude Code launches it over stdio automatically (see README).

Requires:  pip install "mcp[cli]"
Optional env:
    MAME_MCP_DIR      IPC directory shared with the Lua script (default /tmp/mame_mcp)
    MAME_MCP_TIMEOUT  seconds to wait for a reply (default 10)
"""

import itertools
import os
import threading
import time

from mcp.server.fastmcp import FastMCP

DIR = os.environ.get("MAME_MCP_DIR", "/tmp/mame_mcp")
TIMEOUT = float(os.environ.get("MAME_MCP_TIMEOUT", "10"))
os.makedirs(DIR, exist_ok=True)

_ids = itertools.count(1)
_lock = threading.Lock()

mcp = FastMCP("mame-z80")


def _rpc(line: str) -> str:
    """Send one command line to the running MAME bridge and return its reply."""
    with _lock:
        rid = next(_ids)
    req = os.path.join(DIR, f"req_{rid}.txt")
    resp = os.path.join(DIR, f"resp_{rid}.txt")
    tmp = req + ".tmp"

    with open(tmp, "w") as f:
        f.write(line.strip())
    os.replace(tmp, req)

    deadline = time.time() + TIMEOUT
    while time.time() < deadline:
        if os.path.exists(resp):
            with open(resp) as f:
                out = f.read()
            for p in (resp, req):
                try:
                    os.remove(p)
                except OSError:
                    pass
            return out or "(empty reply)"
        time.sleep(0.02)

    try:
        os.remove(req)
    except OSError:
        pass
    return ("ERROR: timed out. Is MAME running with "
            "`-debug -autoboot_script mame_bridge.lua`, and is the machine running "
            "(not hard-stopped in the debugger)?")


# --------------------------------------------------------------------- tools
@mcp.tool()
def read_registers() -> str:
    """Return the Z80/8080 CPU registers (PC, SP, AF, BC, DE, HL, IX, IY, ...)."""
    return _rpc("regs")


@mcp.tool()
def read_memory(address: str, length: int = 16) -> str:
    """Read `length` bytes from the CPU program space at `address` (raw, no bank
    translation). On Sprinter the Z80 windows live at program 0x10000+; use
    read_logical_memory to read the Z80's 64K view. Hex like '0xC000' or decimal.
    Returns a contiguous hex string. Max 4096 bytes."""
    return _rpc(f"mem {address} {length}")


@mcp.tool()
def read_logical_memory(address: str, length: int = 16) -> str:
    """Read `length` bytes as the Z80 currently sees them through its banks, i.e.
    logical address 0x0000-0xFFFF (mapped to Sprinter program 0x10000|addr).
    This is what you usually want for code/data the running program touches."""
    return _rpc(f"lmem {address} {length}")


@mcp.tool()
def read_vram(address: str, length: int = 16) -> str:
    """Read `length` bytes directly from the 256K video RAM share, bypassing Z80
    banking. Use for inspecting screen pixel data, tile/mode descriptors, and the
    palette (RGB triples at offset 0x3E0 within each 1K row). Max 4096 bytes."""
    return _rpc(f"vram {address} {length}")


@mcp.tool()
def read_share(name: str, address: str, length: int = 16) -> str:
    """Read raw bytes from a named memory share (e.g. 'vram', 'fastram',
    'video_ram'). See list_shares for available tags. Max 4096 bytes."""
    return _rpc(f"share {name} {address} {length}")


@mcp.tool()
def list_shares() -> str:
    """List memory shares and regions (tags + sizes) for discovery."""
    return _rpc("shares")


@mcp.tool()
def write_memory(address: str, hex_bytes: str) -> str:
    """Write bytes to the CPU program space. `hex_bytes` is a hex string, e.g.
    '3E01CD0500'. (Note: this is raw program space; Sprinter Z80 windows are at
    0x10000+, so use 0x10000|addr to write the Z80's logical view.)"""
    return _rpc(f"setmem {address} {hex_bytes.replace(' ', '')}")


@mcp.tool()
def set_breakpoint(address: str, condition: str = "") -> str:
    """Set a PC breakpoint at `address`. Optional `condition` is a MAME debugger
    expression (e.g. 'A==0'); the break only fires when it is true.
    Returns the breakpoint index."""
    return _rpc(f"bp {address} {condition}".strip())


@mcp.tool()
def clear_breakpoint(index: int) -> str:
    """Remove the breakpoint with the given index."""
    return _rpc(f"bpclr {index}")


@mcp.tool()
def list_breakpoints() -> str:
    """List all active breakpoints."""
    return _rpc("bplist")


@mcp.tool()
def set_watchpoint(address: str, length: int, access: str = "w",
                   space: str = "program") -> str:
    """Break when memory at `address` (over `length` bytes) is accessed.
    `access` is 'r', 'w', or 'rw'. `space` selects the address space:
    'program' (default), 'data', 'io', or 'opcodes' — e.g. space='io' to catch
    Z80 IN/OUT on a port (maps to the debugger's wpiset). Returns the index."""
    return _rpc(f"wp {address} {length} {access} {space}")


@mcp.tool()
def clear_watchpoint(index: int) -> str:
    """Remove the watchpoint with the given index."""
    return _rpc(f"wpclr {index}")


@mcp.tool()
def step(count: int = 1) -> str:
    """Single-step `count` instructions (requires the machine to be stopped)."""
    return _rpc(f"step {count}")


@mcp.tool()
def step_over(count: int = 1) -> str:
    """Step over `count` instructions (CALLs run to completion)."""
    return _rpc(f"over {count}")


@mcp.tool()
def step_out() -> str:
    """Run until the current subroutine returns."""
    return _rpc("out")


@mcp.tool()
def resume() -> str:
    """Resume free-running execution."""
    return _rpc("cont")


@mcp.tool()
def pause() -> str:
    """Stop execution and break into the debugger."""
    return _rpc("pause")


@mcp.tool()
def status() -> str:
    """Report whether the CPU is running or stopped, plus the current PC."""
    return _rpc("status")


@mcp.tool()
def quit_emulator() -> str:
    """Cleanly shut down the running MAME emulator (debugger console 'exit').
    ALWAYS stop MAME this way — never kill the process. The reply may be empty or
    time out because MAME exits immediately afterwards; that is expected and means
    the shutdown succeeded."""
    return _rpc("quit")


@mcp.tool()
def disassemble(address: str, num_bytes: int = 32) -> str:
    """Disassemble `num_bytes` bytes starting at `address`."""
    return _rpc(f"dasm {address} {num_bytes}")


@mcp.tool()
def screenshot(name: str = "") -> str:
    """Save a PNG screenshot of the emulator's active screen and return its full
    path (which the caller can then open/view). With no `name`, a timestamped file
    is generated. `name` may be a bare filename (placed in the snapshot temp dir,
    /tmp/mame_snap by default, cleared on reboot) or an absolute path.
    Note: the snapshot is the last drawn frame; while the machine is hard-stopped
    the image is frozen, so resume() briefly before snapping for a fresh frame."""
    return _rpc(f"snap {name}".strip())


@mcp.tool()
def list_ports() -> str:
    """List input ports and their fields (tag, bit mask, name) for discovery —
    e.g. ':kbd:ms_naturl:*' (PC keyboard), ':IO_LINE0..7' (ZX matrix), ':JOY1/2',
    ':mouse_input1/2/3', ':rs232:microsoft_mouse:*'."""
    return _rpc("ports")


@mcp.tool()
def press_key(key: str, frames: int = 3) -> str:
    """Press a NAMED key for `frames` emulated frames, then auto-release. Drives
    BOTH the PC (ms_naturl) and ZX-Spectrum keyboards where applicable, like real
    host input. Names: a-z, 0-9, enter, space, esc, tab, backspace, up/down/left/
    right, home, end, pgup, pgdn, ins, del, f1-f12, shift, ctrl, alt, symbolshift,
    and symbols ; ' / . , - = [ ] \\ `. The machine must be RUNNING (resume first)."""
    return _rpc(f"key {key} {frames}")


@mcp.tool()
def type_text(text: str, coded: bool = False) -> str:
    """Type text via the natural keyboard. If `coded`, honours {KEY} codes like
    'dir{ENTER}'. Note: works for whichever keyboard MAME's natkeyboard targets;
    for the firmware UI prefer press_key. Machine must be RUNNING."""
    return _rpc((f"typecode {text}" if coded else f"type {text}"))


@mcp.tool()
def move_mouse(dx: int, dy: int, frames: int = 3) -> str:
    """Move BOTH mice (Kempston + RS232 COM) by relative dx,dy held over `frames`
    frames (relative axes accumulate). Machine must be RUNNING."""
    return _rpc(f"mouse {dx} {dy} {frames}")


@mcp.tool()
def click_mouse(button: str = "left", frames: int = 3) -> str:
    """Click a mouse button (left|right|middle) on BOTH mice for `frames` frames.
    Machine must be RUNNING."""
    return _rpc(f"mclick {button} {frames}")


@mcp.tool()
def press_input(port: str, mask: str, frames: int = 2) -> str:
    """Low-level: press a digital input field by port tag + bit mask for `frames`
    frames (e.g. press_input(':JOY1', '0x400') = P1 button A). See list_ports."""
    return _rpc(f"press {port} {mask} {frames}")


@mcp.tool()
def set_input(port: str, mask: str, value: int, frames: int = 0) -> str:
    """Low-level: set an input field (analog or digital) to `value`, optionally
    held for `frames` frames. Use hold/release semantics via frames=0 (set once)."""
    return _rpc(f"analog {port} {mask} {value} {frames}")


@mcp.tool()
def debugger_command(raw: str) -> str:
    """Escape hatch: run any MAME debugger console command verbatim
    (e.g. 'history', 'trace mytrace.log', 'print pc'). Returns console output."""
    return _rpc(f"cmd {raw}")


if __name__ == "__main__":
    mcp.run()
