@echo off
rem ============================================================================
rem  run_mame_bridge.bat - CLAUDE-OWNED launcher for Path B (mamebridge) testing.
rem
rem  Purpose: let Claude drive the emulator under its own control. This is the
rem  file Claude launches for debugging sessions - do NOT add the bridge plugin
rem  or MAME_MCP_* to the user's launchers (C:\tools\Progs\MAME\Debug.bat /
rem  no_debug.bat); those stay clean for the user's own interactive use.
rem
rem  What it does that the user's Debug.bat does not:
rem    * runs the freshly BUILT mame.exe from the repo root (not the installed copy)
rem    * loads the mamebridge plugin from the repo plugins dir (-pluginspath)
rem    * sets MAME_MCP_* to Claude-owned scratch dirs under <repo>\.mame_mcp
rem  The machine/media args mirror Debug.bat (resync if Debug.bat's disks change).
rem ============================================================================
setlocal

set "MAME_DIR=C:\tools\msys64\src\MAME"
set "RUN_DIR=C:\tools\Progs\MAME"

rem -- Claude-owned IPC + snapshot dirs (gitignored; must match the MCP server) --
set "MAME_MCP_DIR=%MAME_DIR%\.mame_mcp\ipc"
set "MAME_MCP_SNAP_DIR=%MAME_DIR%\.mame_mcp\snap"
set "MAME_MCP_CPU=:maincpu"
if not exist "%MAME_MCP_DIR%"      mkdir "%MAME_MCP_DIR%"
if not exist "%MAME_MCP_SNAP_DIR%" mkdir "%MAME_MCP_SNAP_DIR%"

rem -- run from the user's asset dir (roms\, IMG\, cfg\, bios live here) ----------
cd /d "%RUN_DIR%"

"%MAME_DIR%\mame.exe" sprinter ^
	-kbd ms_naturl,bios=sp2k ^
	-window ^
	-keepaspect ^
	-resolution 1474x1152 ^
	-skip_gameinfo ^
	-video bgfx ^
	-nofilter ^
	-bios dev ^
	-debug ^
	-debugger auto ^
	-watchdog 0 ^
	-plugin mamebridge ^
	-pluginspath "%MAME_DIR%\plugins" ^
	-beta:wd179x:0 525qd ^
	-beta:wd179x:1 35hd ^
	-flop1 IMG\ATARIN.TRD ^
	-flop2 IMG\5.25_1.2mb.img ^
	-ata1:0 hdd -hard1 IMG\sp_disk2.img ^
	-ata1:1 hdd -hard2 IMG\test_2g.img ^
	-ata2:0 hdd -hard3 IMG\TRASH\FAT16.img ^
	-ata2:1 cdrom -cdrom IMG\TRASH\LiveCD.iso ^
	-mouse %*

endlocal
