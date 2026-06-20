-- license:BSD-3-Clause
-- mamebridge plugin
-- File-IPC bridge that exposes MAME's debugger to an external MCP server.
--
-- Ported from the -autoboot_script version (src/mame_bridge.lua). The only
-- behavioural change is the pump: this plugin uses emu.register_periodic(),
-- which is driven by emulator_info::periodic_check() and therefore keeps firing
-- *even while the machine is hard-stopped in the debugger* (see the
-- while (is_stopped()) loop in src/emu/debug/debugcpu.cpp). The old frame
-- notifier went silent when stopped, breaking stop -> step -> inspect loops.
--
-- Launch:
--   mame <system> -debug -plugin mamebridge
--
-- Protocol: the MCP server drops a request file  <DIR>/req_<id>.txt  containing
-- one command line; this plugin processes it on each periodic tick and writes
-- the reply to  <DIR>/resp_<id>.txt . The file-IPC protocol is identical to the
-- autoboot script, so mame_mcp.py needs no changes.
--
-- Env vars:
--   MAME_MCP_DIR  IPC directory      (default /tmp/mame_mcp)
--   MAME_MCP_CPU  CPU device tag     (default :maincpu)

local exports = {
	name = "mamebridge",
	version = "0.0.1",
	description = "File-IPC debugger bridge for the MAME MCP server",
	license = "BSD-3-Clause",
	author = { name = "Tolik" } }

local mamebridge = exports

function mamebridge.startplugin()
	local DIR     = os.getenv("MAME_MCP_DIR") or "/tmp/mame_mcp"
	local CPUTAG  = os.getenv("MAME_MCP_CPU") or ":maincpu"
	local SPACE   = "program"
	-- Screenshots go to a temp dir that the OS clears on reboot (/tmp on macOS).
	local SNAPDIR = os.getenv("MAME_MCP_SNAP_DIR") or "/tmp/mame_snap"

	-- Last counter value per mouse axis tag, so movement is continuous between
	-- commands (a relative axis reads deltas; resetting it jumps the cursor back).
	local mouse_pos = {}

	-- Injected input held across frames: field-object -> remaining frame count,
	-- or the sentinel `true` to hold until an explicit release. A frame notifier
	-- re-applies set_value(1) each frame (MAME re-polls inputs per frame) and
	-- counts finite holds down. NOTE: input is only processed while the machine
	-- is RUNNING; frame notifiers (and the natkeyboard timer) don't tick while
	-- hard-stopped, so resume() before typing/pressing for the input to register.
	local held = {}

	-- Z80 (and 8080-ish) registers worth reporting. Missing ones are skipped.
	local REGS = { "PC","SP","AF","BC","DE","HL","IX","IY",
	               "AF2","BC2","DE2","HL2","I","R","IM","IFF1","IFF2","WZ" }

	os.execute('mkdir -p "' .. DIR .. '" 2>/dev/null')
	local lfs_ok, lfs = pcall(require, "lfs")

	------------------------------------------------------------------- helpers
	local function read_file(p)
	  local f = io.open(p, "rb"); if not f then return nil end
	  local d = f:read("*a"); f:close(); return d
	end

	local function write_atomic(path, data)
	  local tmp = path .. ".tmp"
	  local f = io.open(tmp, "wb"); if not f then return false end
	  f:write(data); f:close()
	  os.rename(tmp, path)
	  return true
	end

	local function cpu()   return manager.machine.devices[CPUTAG] end
	local function dbg()   return manager.machine.debugger end
	local function space() return cpu().spaces[SPACE] end

	-- Parse an address argument. Accepts "0x.." explicit hex, plain decimal, and
	-- bare hex (e.g. "B9", "9A09") so callers don't have to prefix 0x. (The MCP
	-- server passes addresses through verbatim, and bp/wp let MAME's debugger
	-- parse them, but mem/setmem/dasm resolve the address here in Lua.)
	local function parse_addr(s)
	  if not s then return nil end
	  if s:match("^0[xX]%x+$") then return tonumber(s) end          -- explicit hex
	  if s:match("^%d+$")      then return tonumber(s) end          -- decimal
	  if s:match("^%x+$")      then return tonumber(s, 16) end      -- bare hex
	  return tonumber(s)
	end

	-- Run a debugger console command and return any new console output it produced.
	local function run_cmd(cmdstr)
	  local d = dbg()
	  local before = #d.consolelog
	  d:command(cmdstr)
	  local lines = {}
	  for i = before + 1, #d.consolelog do lines[#lines + 1] = d.consolelog[i] end
	  return table.concat(lines, "\n")
	end

	-- Fast binary-string -> uppercase-hex via a precomputed 256-entry table.
	local HEXBYTE = {}
	for i = 0, 255 do HEXBYTE[i] = string.format("%02X", i) end
	local function hexify(bin)
	  local t = {}
	  for i = 1, #bin do t[i] = HEXBYTE[bin:byte(i)] end
	  return table.concat(t)
	end

	-- Read `len` bytes from `obj` (an address space or a memory_share) starting at
	-- `addr`, returned as a contiguous hex string. Fast path: ONE bulk
	-- read_range(start, end, 8) call (per the Lua mem API) instead of `len`
	-- per-byte read_u8 calls — a big win on large dumps (e.g. 4K VRAM reads).
	-- Falls back to a byte loop if the object has no read_range or it misbehaves
	-- (so memory_share, which may lack read_range, still works).
	local function read_block(obj, addr, len)
	  if len > 4096 then len = 4096 end
	  local ok, bin = pcall(function() return obj:read_range(addr, addr + len - 1, 8) end)
	  if ok and type(bin) == "string" and #bin == len then return hexify(bin) end
	  local t = {}
	  for i = 0, len - 1 do
	    local ok2, b = pcall(function() return obj:read_u8(addr + i) end)
	    t[#t + 1] = HEXBYTE[(ok2 and b or 0) & 0xff]
	  end
	  return table.concat(t)
	end

	------------------------------------------------------------------- actions
	local function do_regs()
	  local c, out = cpu(), {}
	  for _, r in ipairs(REGS) do
	    local ok, ent = pcall(function() return c.state[r] end)
	    if ok and ent then
	      local ok2, v = pcall(function() return ent.value end)
	      if ok2 and v then out[#out + 1] = string.format("%s=0x%X", r, v) end
	    end
	  end
	  return table.concat(out, " ")
	end

	local function do_mem(addr, len)
	  return read_block(space(), addr, len)
	end

	-- On Sprinter the Z80's 64K logical space is mapped into the CPU program
	-- space at 0x10000 (windows: 0->0x10000, 1->0x14000, 2->0x18000, 3->0x1c000).
	-- Reading program[L] also works once the FPGA bitstream is loaded, but goes
	-- through bootstrap_r (returns fastram while loading), so read 0x10000|L for a
	-- reliable view of what the CPU currently sees through the banks.
	local function do_lmem(laddr, len)
	  return do_mem(0x10000 | (laddr & 0xffff), len)
	end

	-- Read a rectangle of RENDERED screen pixels (the machine's video output,
	-- decoded from VRAM by the emulated hardware) via screen:pixel(x,y). Returns
	-- one 4-hex pen index per pixel, row-major. This is the screen as displayed
	-- (handles tile/4bpp/double-buffer for us), not raw VRAM bytes.
	local function do_scrpix(x, y, w, h)
	  local scr
	  for _, s in pairs(manager.machine.screens) do scr = s; break end
	  if not scr then return "ERROR: no screen device" end
	  w = w or 1; h = h or 1
	  if w * h > 8192 then return "ERROR: area too big (max 8192 px)" end
	  local t = {}
	  for dy = 0, h - 1 do
	    for dx = 0, w - 1 do
	      local ok, p = pcall(function() return scr:pixel(x + dx, y + dy) end)
	      t[#t + 1] = string.format("%04X", ok and (p & 0xffff) or 0)
	    end
	  end
	  return table.concat(t)
	end

	-- Find a memory_share whose tag contains `name` (e.g. "vram", "fastram").
	local function find_share(name)
	  for tag, sh in pairs(manager.machine.memory.shares) do
	    if tag:find(name, 1, true) then return sh, tag end
	  end
	  return nil
	end

	-- Read raw bytes from a memory_share (e.g. the 256K "vram"), bypassing Z80
	-- banking entirely. Useful for inspecting screen data, palette, tile/mode
	-- descriptors directly. Returns hex like do_mem.
	local function do_share(name, addr, len)
	  local sh = find_share(name)
	  if not sh then return "ERROR: no share matching '" .. tostring(name) .. "'" end
	  return read_block(sh, addr, len)
	end

	-- List memory shares and regions (tags + sizes) for discovery.
	local function do_shares()
	  local out = {}
	  for tag, sh in pairs(manager.machine.memory.shares) do
	    local ok, sz = pcall(function() return sh.size end)
	    out[#out + 1] = string.format("share %s size=%s", tag, ok and tostring(sz) or "?")
	  end
	  for tag, rg in pairs(manager.machine.memory.regions) do
	    local ok, sz = pcall(function() return rg.size end)
	    out[#out + 1] = string.format("region %s size=%s", tag, ok and tostring(sz) or "?")
	  end
	  return table.concat(out, "\n")
	end

	local function do_setmem(addr, hex)
	  local s, i = space(), 0
	  for byte in hex:gmatch("%x%x") do
	    s:write_u8(addr + i, tonumber(byte, 16)); i = i + 1
	  end
	  return "ok wrote " .. i .. " byte(s)"
	end

	local function do_status()
	  local st = dbg().execution_state
	  local pc = "?"
	  local ok, v = pcall(function() return cpu().state["PC"].value end)
	  if ok then pc = string.format("0x%X", v) end
	  return "state=" .. st .. " PC=" .. pc
	end

	local function do_dasm(addr, nbytes)
	  local tmp = DIR .. "/_dasm.tmp"
	  run_cmd(string.format("dasm %s,0x%X,%d", tmp, addr, nbytes))
	  local d = read_file(tmp) or "(no output)"
	  os.remove(tmp)
	  return d
	end

	-- Save a screenshot of the active screen to SNAPDIR and return its full path,
	-- so the caller can open the PNG. With no name, a timestamped one is generated.
	-- Note: the snapshot captures the last drawn frame; while hard-stopped the
	-- image is frozen, so resume briefly before snapping for a fresh frame.
	local snap_seq = 0
	local function do_snap(name)
	  os.execute('mkdir -p "' .. SNAPDIR .. '" 2>/dev/null')
	  local fname
	  if name and name:match("^/") then
	    fname = name                                   -- absolute path as given
	  elseif name then
	    fname = SNAPDIR .. "/" .. name                 -- bare name -> under SNAPDIR
	  else
	    snap_seq = snap_seq + 1
	    fname = string.format("%s/snap_%d_%03d.png", SNAPDIR, os.time(), snap_seq)
	  end
	  local scr
	  for _, s in pairs(manager.machine.screens) do scr = s; break end
	  if not scr then return "ERROR: no screen device" end
	  local err = scr:snapshot(fname)                  -- returns nil on success
	  if err ~= nil then return "ERROR: snapshot failed: " .. tostring(err) end
	  return fname
	end

	------------------------------------------------------------------- input
	-- Current emulated frame number (from the first screen), for timing presses.
	local function framenum()
	  for _, s in pairs(manager.machine.screens) do
	    local ok, n = pcall(function() return s:frame_number() end)
	    if ok then return n end
	  end
	  return 0
	end

	-- List input ports and their fields (tag + mask + name), for discovery.
	local function do_ports()
	  local out = {}
	  for ptag, port in pairs(manager.machine.ioport.ports) do
	    local fields = {}
	    for fname, field in pairs(port.fields) do
	      local ok, m = pcall(function() return field.mask end)
	      fields[#fields + 1] = string.format("  0x%04X %s", ok and m or 0, fname)
	    end
	    table.sort(fields)
	    out[#out + 1] = ptag .. "\n" .. table.concat(fields, "\n")
	  end
	  table.sort(out)
	  return table.concat(out, "\n")
	end

	-- Type text via the natural keyboard (uses each key's PORT_CHAR mapping).
	-- Enable in_use so the keystrokes are actually delivered.
	local function do_type(text)
	  if not text then return "ERROR: no text" end
	  local nk = manager.machine.natkeyboard
	  nk.in_use = true
	  nk:post(text)
	  return "posted " .. #text .. " char(s) (machine must be running to apply)"
	end

	-- Named keys mapped to a LIST of "porttag 0xMASK" specs (tag without leading
	-- ":"). On the real host a keypress goes to BOTH keyboards at once, so each
	-- key drives the PC PS/2 keyboard (kbd:ms_naturl:Px.y) AND, where it exists,
	-- the ZX-Spectrum matrix (IO_LINEn). Masks taken from the live `ports` dump.
	local KEYS = {
	  a={"kbd:ms_naturl:P1.6 0x04","IO_LINE1 0x01"},
	  b={"kbd:ms_naturl:P1.5 0x10","IO_LINE7 0x10"},
	  c={"kbd:ms_naturl:P1.4 0x08","IO_LINE0 0x08"},
	  d={"kbd:ms_naturl:P1.4 0x04","IO_LINE1 0x04"},
	  e={"kbd:ms_naturl:P1.4 0x20","IO_LINE2 0x04"},
	  f={"kbd:ms_naturl:P1.5 0x02","IO_LINE1 0x08"},
	  g={"kbd:ms_naturl:P1.5 0x04","IO_LINE1 0x10"},
	  h={"kbd:ms_naturl:P2.0 0x02","IO_LINE6 0x10"},
	  i={"kbd:ms_naturl:P1.4 0x01","IO_LINE5 0x04"},
	  j={"kbd:ms_naturl:P2.0 0x04","IO_LINE6 0x08"},
	  k={"kbd:ms_naturl:P1.4 0x02","IO_LINE6 0x04"},
	  l={"kbd:ms_naturl:P2.2 0x08","IO_LINE6 0x02"},
	  m={"kbd:ms_naturl:P2.0 0x10","IO_LINE7 0x04"},
	  n={"kbd:ms_naturl:P2.0 0x08","IO_LINE7 0x08"},
	  o={"kbd:ms_naturl:P2.2 0x02","IO_LINE5 0x02"},
	  p={"kbd:ms_naturl:P2.3 0x20","IO_LINE5 0x01"},
	  q={"kbd:ms_naturl:P1.6 0x02","IO_LINE2 0x01"},
	  r={"kbd:ms_naturl:P1.5 0x01","IO_LINE2 0x08"},
	  s={"kbd:ms_naturl:P1.2 0x08","IO_LINE1 0x02"},
	  t={"kbd:ms_naturl:P1.5 0x20","IO_LINE2 0x10"},
	  u={"kbd:ms_naturl:P2.0 0x20","IO_LINE5 0x08"},
	  v={"kbd:ms_naturl:P1.5 0x08","IO_LINE0 0x10"},
	  w={"kbd:ms_naturl:P1.2 0x04","IO_LINE2 0x02"},
	  x={"kbd:ms_naturl:P1.2 0x10","IO_LINE0 0x04"},
	  y={"kbd:ms_naturl:P2.0 0x01","IO_LINE5 0x10"},
	  z={"kbd:ms_naturl:P1.6 0x10","IO_LINE0 0x02"},
	  ["0"]={"kbd:ms_naturl:P2.3 0x01","IO_LINE4 0x01"},
	  ["1"]={"kbd:ms_naturl:P1.6 0x01","IO_LINE3 0x01"},
	  ["2"]={"kbd:ms_naturl:P1.2 0x02","IO_LINE3 0x02"},
	  ["3"]={"kbd:ms_naturl:P1.4 0x40","IO_LINE3 0x04"},
	  ["4"]={"kbd:ms_naturl:P1.5 0x40","IO_LINE3 0x08"},
	  ["5"]={"kbd:ms_naturl:P1.5 0x80","IO_LINE3 0x10"},
	  ["6"]={"kbd:ms_naturl:P2.0 0x40","IO_LINE4 0x10"},
	  ["7"]={"kbd:ms_naturl:P2.0 0x80","IO_LINE4 0x08"},
	  ["8"]={"kbd:ms_naturl:P1.4 0x80","IO_LINE4 0x04"},
	  ["9"]={"kbd:ms_naturl:P2.2 0x01","IO_LINE4 0x02"},
	  enter={"kbd:ms_naturl:P2.1 0x10","IO_LINE6 0x01"},
	  space={"kbd:ms_naturl:P2.4 0x80","IO_LINE7 0x01"},
	  -- ZX cursor keys live on the 5/6/7/8 matrix positions
	  up={"kbd:ms_naturl:P2.4 0x01","IO_LINE4 0x08"},
	  down={"kbd:ms_naturl:P2.3 0x10","IO_LINE4 0x10"},
	  left={"kbd:ms_naturl:P2.1 0x08","IO_LINE3 0x10"},
	  right={"kbd:ms_naturl:P2.4 0x40","IO_LINE4 0x04"},
	  shift={"kbd:ms_naturl:P1.7 0x02","IO_LINE0 0x01"},   -- ZX CAPS SHIFT
	  symbolshift={"IO_LINE7 0x02"},
	  -- PC-only keys (no ZX matrix equivalent)
	  esc={"kbd:ms_naturl:P1.6 0x40"}, tab={"kbd:ms_naturl:P1.6 0x20"},
	  backspace={"kbd:ms_naturl:P2.1 0x20"}, bs={"kbd:ms_naturl:P2.1 0x20"},
	  home={"kbd:ms_naturl:P2.5 0x01"}, ["end"]={"kbd:ms_naturl:P2.5 0x20"},
	  pgup={"kbd:ms_naturl:P1.2 0x01"}, pgdn={"kbd:ms_naturl:P1.2 0x20"},
	  ins={"kbd:ms_naturl:P2.6 0x01"}, del={"kbd:ms_naturl:P2.6 0x02"},
	  f1={"kbd:ms_naturl:P1.2 0x40"}, f2={"kbd:ms_naturl:P1.2 0x80"},
	  f3={"kbd:ms_naturl:P2.6 0x40"}, f4={"kbd:ms_naturl:P2.6 0x80"},
	  f5={"kbd:ms_naturl:P2.1 0x40"}, f6={"kbd:ms_naturl:P2.1 0x80"},
	  f7={"kbd:ms_naturl:P2.2 0x40"}, f8={"kbd:ms_naturl:P2.2 0x80"},
	  f9={"kbd:ms_naturl:P2.3 0x40"}, f10={"kbd:ms_naturl:P2.3 0x80"},
	  f11={"kbd:ms_naturl:P2.5 0x40"}, f12={"kbd:ms_naturl:P2.5 0x80"},
	  lshift={"kbd:ms_naturl:P1.7 0x02"}, rshift={"kbd:ms_naturl:P1.7 0x10"},
	  ctrl={"kbd:ms_naturl:P1.1 0x02"}, lctrl={"kbd:ms_naturl:P1.1 0x02"},
	  rctrl={"kbd:ms_naturl:P1.1 0x10"}, alt={"kbd:ms_naturl:P1.3 0x04"},
	  lalt={"kbd:ms_naturl:P1.3 0x04"}, ralt={"kbd:ms_naturl:P1.3 0x08"},
	  capslock={"kbd:ms_naturl:P1.1 0x20"},
	  [";"]={"kbd:ms_naturl:P2.3 0x02"}, ["'"]={"kbd:ms_naturl:P2.3 0x04"},
	  ["/"]={"kbd:ms_naturl:P2.3 0x08"}, ["."]={"kbd:ms_naturl:P2.2 0x10"},
	  [","]={"kbd:ms_naturl:P1.4 0x10"}, ["-"]={"kbd:ms_naturl:P2.2 0x20"},
	  ["="]={"kbd:ms_naturl:P2.1 0x01"}, ["["]={"kbd:ms_naturl:P2.2 0x04"},
	  ["]"]={"kbd:ms_naturl:P2.1 0x02"}, ["\\"]={"kbd:ms_naturl:P2.1 0x04"},
	  ["`"]={"kbd:ms_naturl:P1.6 0x80"},
	}

	-- Type text honouring {KEY} codes, e.g. "dir{ENTER}" or "{F3}".
	local function do_typecode(text)
	  if not text then return "ERROR: no text" end
	  manager.machine.natkeyboard:post_coded(text)
	  return "posted coded (machine must be running to apply)"
	end

	local function do_kbstat()
	  local nk = manager.machine.natkeyboard
	  local out = { string.format("empty=%s is_posting=%s can_post=%s in_use=%s",
	    tostring(nk.empty), tostring(nk.is_posting), tostring(nk.can_post), tostring(nk.in_use)) }
	  for _, kb in pairs(nk.keyboards) do
	    out[#out + 1] = string.format("  kbd %s [%s] enabled=%s",
	      kb.tag, kb.name, tostring(kb.enabled))
	  end
	  return table.concat(out, "\n")
	end

	-- Choose which keyboard(s) natkeyboard posts into: enable those whose tag
	-- contains `substr` (e.g. "ms_naturl" for the PC PS/2 keyboard, "IO_LINE" for
	-- the ZX matrix), disable the rest. "all" enables everything. This is what
	-- makes `type`/`typecode` land in the keyboard the running program reads, and
	-- natkeyboard sends one scan-code per key (correct timing, no SIO repeat storm).
	local function do_kbsel(substr)
	  local nk = manager.machine.natkeyboard
	  nk.in_use = true
	  local out = {}
	  for _, kb in pairs(nk.keyboards) do
	    local on = (not substr) or (substr == "all") or (kb.tag:find(substr, 1, true) ~= nil)
	    kb.enabled = on
	    if on then out[#out + 1] = "enabled " .. kb.tag end
	  end
	  return #out > 0 and table.concat(out, "\n") or "no keyboard matched '" .. tostring(substr) .. "'"
	end

	-- Resolve a field by port tag + bit mask (avoids parsing names with spaces).
	local function find_field(ptag, mask)
	  local port = manager.machine.ioport.ports[ptag]
	  if not port then return nil, "no port '" .. tostring(ptag) .. "'" end
	  for _, f in pairs(port.fields) do
	    local ok, m = pcall(function() return f.mask end)
	    if ok and m == mask then return f end
	  end
	  return nil, string.format("no field with mask 0x%X in '%s'", mask or -1, ptag)
	end

	-- Press a digital field for `frames` emulated frames, then auto-release.
	-- held[f] = { rel = <frame at/after which to release> }.
	local function do_press(ptag, mask, frames)
	  local f, err = find_field(ptag, mask)
	  if not f then return "ERROR: " .. err end
	  frames = frames or 2
	  held[f] = { rel = framenum() + frames }
	  f:set_value(1)
	  return string.format("pressing %s 0x%X for %d frame(s)", ptag, mask, frames)
	end

	-- Hold a field down until an explicit release. held[f] = { hold = true }.
	local function do_hold(ptag, mask)
	  local f, err = find_field(ptag, mask)
	  if not f then return "ERROR: " .. err end
	  held[f] = { hold = true }
	  f:set_value(1)
	  return "holding " .. ptag .. string.format(" 0x%X (call release)", mask)
	end

	local function do_release(ptag, mask)
	  local f, err = find_field(ptag, mask)
	  if not f then return "ERROR: " .. err end
	  held[f] = nil
	  f:clear_value()
	  return "released"
	end

	-- Release every held input. Called on pause so stopping the machine can't
	-- leave a key/button stuck (auto-release only ticks while running).
	local function release_all()
	  local n = 0
	  for f in pairs(held) do
	    pcall(function() f:clear_value() end)
	    held[f] = nil
	    n = n + 1
	  end
	  return n
	end

	-- Set an analog field (e.g. mouse axis) to a value, held for `frames` frames
	-- (re-applied each frame so relative axes like the mouse accumulate motion).
	local function do_analog(ptag, mask, value, frames)
	  local f, err = find_field(ptag, mask)
	  if not f then return "ERROR: " .. err end
	  if frames and frames > 0 then
	    held[f] = { v = value, rel = framenum() + frames }
	  end
	  f:set_value(value)
	  return string.format("set %s 0x%X = %s (%s frame(s))", ptag, mask, tostring(value),
	    frames and tostring(frames) or "1")
	end

	-- Press a named key for `frames` frames on BOTH keyboards it maps to.
	local function do_key(name, frames)
	  if not name then return "ERROR: no key name" end
	  local spec = KEYS[name] or KEYS[name:lower()]
	  if not spec then return "ERROR: unknown key '" .. name .. "'" end
	  frames = frames or 3
	  local out = {}
	  for _, s in ipairs(spec) do
	    local p, m = s:match("^(%S+)%s+(%S+)$")
	    out[#out + 1] = do_press(":" .. p, tonumber(m), frames)
	  end
	  return table.concat(out, "; ")
	end

	-- Move BOTH mice (Kempston :mouse_input1/2 mask 0xFF, and RS232 COM mouse
	-- :rs232:microsoft_mouse:X/Y mask 0xFFF) by relative dx,dy over `frames`
	-- frames, matching how host motion drives both at once.
	-- Start a per-frame counter on an axis (step per frame for `frames` frames).
	local function move_axis(tag, mask, step, frames)
	  local f = find_field(tag, mask)
	  if not f then return false end
	  held[f] = { mv = mouse_pos[tag] or 0, step = step, mask = mask,
	              rel = framenum() + frames, tag = tag }
	  return true
	end

	-- Move BOTH mice by stepping their axes each frame. Flex Navigator reads the
	-- COM (serial) mouse; the Kempston counter is driven too for ZX software.
	-- dx/dy are the per-frame step (signed); total travel ~ step*frames*sensitivity.
	local function do_mouse(dx, dy, frames)
	  frames = frames or 8
	  local out = {}
	  if dx and dx ~= 0 then
	    if move_axis(":rs232:microsoft_mouse:X", 0xFFF, dx, frames) then out[#out+1] = "COM.X" end
	    if move_axis(":mouse_input1", 0xFF, dx, frames) then out[#out+1] = "K.X" end
	  end
	  if dy and dy ~= 0 then
	    if move_axis(":rs232:microsoft_mouse:Y", 0xFFF, dy, frames) then out[#out+1] = "COM.Y" end
	    if move_axis(":mouse_input2", 0xFF, dy, frames) then out[#out+1] = "K.Y" end
	  end
	  return #out > 0
	    and string.format("mouse move %s step(%s,%s) x%d frames", table.concat(out, ","), tostring(dx), tostring(dy), frames)
	    or "no motion"
	end

	-- Click a mouse button on BOTH mice. btn: left|right|middle.
	local MBTN = {
	  left   = {"mouse_input3 0x01", "rs232:microsoft_mouse:BTN 0x02"},
	  right  = {"mouse_input3 0x02", "rs232:microsoft_mouse:BTN 0x01"},
	  middle = {"mouse_input3 0x04"},
	}
	local function do_mclick(btn, frames)
	  local spec = MBTN[(btn or "left"):lower()]
	  if not spec then return "ERROR: button must be left|right|middle" end
	  frames = frames or 3
	  local out = {}
	  for _, s in ipairs(spec) do
	    local p, m = s:match("^(%S+)%s+(%S+)$")
	    out[#out + 1] = do_press(":" .. p, tonumber(m), frames)
	  end
	  return table.concat(out, "; ")
	end

	------------------------------------------------------- native debugger ops
	-- Use the device_debug Lua interface (cpu().debug:bpset/wpset/step/...) instead
	-- of console-command strings: structured returns (numeric indices, tables), no
	-- console-log scraping. NOTE: over/out have no native binding, and there is no
	-- native disassemble, so those stay as console commands (run_cmd).
	local function ddbg() return cpu().debug end

	-- bpset(addr, cond, act) -> index. cond/act are required char* args in the
	-- binding, so pass "" when unused (empty = unconditional).
	local function do_bp(addr, cond)
	  local n = ddbg():bpset(addr, cond or "", "")
	  return "Breakpoint " .. n .. " set"
	end

	local function do_bpclr(n)
	  if n == nil then ddbg():bpclear(); return "Cleared all breakpoints" end
	  return ddbg():bpclear(tonumber(n)) and ("Breakpoint " .. n .. " cleared")
	    or ("ERROR: no breakpoint " .. tostring(n))
	end

	-- bplist() -> table keyed by index; values expose index/address/condition/
	-- action/enabled. Format sorted by index.
	local function do_bplist()
	  local bps, keys = ddbg():bplist(), {}
	  for idx in pairs(bps) do keys[#keys + 1] = idx end
	  table.sort(keys)
	  local out = {}
	  for _, idx in ipairs(keys) do
	    local bp = bps[idx]
	    out[#out + 1] = string.format("%d @ %04X%s%s", bp.index, bp.address,
	      (bp.condition ~= "" and bp.condition ~= "1") and (" if " .. bp.condition) or "",
	      bp.enabled and "" or " [disabled]")
	  end
	  return #out > 0 and table.concat(out, "\n") or "No breakpoints"
	end

	-- wpset(space, type, addr, len, cond, act) -> index. `space` is an address-space
	-- object from cpu().spaces[...]. The address is LITERAL in that space (no bank
	-- translation), so for a Z80 window in program space pass the 0x10000+ address
	-- (consistent with write_memory / mem). spacename: program|data|io|opcodes.
	local function do_wp(addr, len, wtype, spacename)
	  spacename = (spacename or "program"):lower()
	  local sp = cpu().spaces[spacename]
	  if not sp then return "ERROR: no '" .. spacename .. "' address space" end
	  local n = ddbg():wpset(sp, wtype, addr, len, "", "")
	  return string.format("Watchpoint %d set (%s)", n, spacename)
	end

	local function do_wpclr(n)
	  if n == nil then ddbg():wpclear(); return "Cleared all watchpoints" end
	  return ddbg():wpclear(tonumber(n)) and ("Watchpoint " .. n .. " cleared")
	    or ("ERROR: no watchpoint " .. tostring(n))
	end

	-- Single-step n instructions (native single_step). The step executes once this
	-- periodic callback returns and the debugger's stop loop resumes, so don't read
	-- PC here (it would be stale) — the caller polls status/regs afterwards.
	local function do_step(n)
	  ddbg():step(n or 1)
	  return "step " .. (n or 1)
	end

	----------------------------------------------------------------- dispatch
	local function dispatch(line)
	  if not manager.machine.debugger then
	    return "ERROR: debugger not enabled (start MAME with -debug)"
	  end
	  local words = {}
	  for w in line:gmatch("%S+") do words[#words + 1] = w end
	  local verb = words[1]

	  local ok, res = pcall(function()
	    if     verb == "regs"   then return do_regs()
	    elseif verb == "mem"    then return do_mem(parse_addr(words[2]), tonumber(words[3]))
	    elseif verb == "lmem"   then return do_lmem(parse_addr(words[2]), tonumber(words[3]))
	    elseif verb == "vram"   then return do_share("vram", parse_addr(words[2]), tonumber(words[3]))
	    elseif verb == "scrpix" then return do_scrpix(tonumber(words[2]), tonumber(words[3]), tonumber(words[4] or "1"), tonumber(words[5] or "1"))
	    elseif verb == "share"  then return do_share(words[2], parse_addr(words[3]), tonumber(words[4]))
	    elseif verb == "shares" then return do_shares()
	    elseif verb == "setmem" then return do_setmem(parse_addr(words[2]), words[3])
	    elseif verb == "bp"     then
	      local cond = line:match("^%S+%s+%S+%s+(.+)$")
	      return do_bp(parse_addr(words[2]), cond)
	    elseif verb == "bpclr"  then return do_bpclr(words[2])
	    elseif verb == "bplist" then return do_bplist()
	    elseif verb == "wp"     then
	      -- wp ADDR LEN ACCESS [space]   space: program(default)|data|io|opcodes.
	      return do_wp(parse_addr(words[2]), tonumber(words[3]), words[4], words[5])
	    elseif verb == "wpclr"  then return do_wpclr(words[2])
	    elseif verb == "step"   then return do_step(tonumber(words[2] or "1"))
	    elseif verb == "over"   then return run_cmd("over " .. (words[2] or "1"))
	    elseif verb == "out"    then return run_cmd("out")
	    elseif verb == "cont"   then dbg().execution_state = "run";  return "running"
	    elseif verb == "pause"  then local n = release_all(); dbg().execution_state = "stop"; return "stopped (released " .. n .. " input(s))"
	    elseif verb == "status" then return do_status()
	    elseif verb == "dasm"   then return do_dasm(parse_addr(words[2]), tonumber(words[3] or "32"))
	    elseif verb == "snap"   then return do_snap(line:match("^snap%s+(.+)$"))
	    elseif verb == "ports"  then return do_ports()
	    elseif verb == "type"     then return do_type(line:match("^type%s+(.+)$"))
	    elseif verb == "typecode" then return do_typecode(line:match("^typecode%s+(.+)$"))
	    elseif verb == "kbstat"   then return do_kbstat()
	    elseif verb == "kbsel"    then return do_kbsel(words[2])
	    elseif verb == "press"  then return do_press(words[2], parse_addr(words[3]), tonumber(words[4] or "2"))
	    elseif verb == "key"    then return do_key(words[2], tonumber(words[3] or "3"))
	    elseif verb == "mouse"  then return do_mouse(tonumber(words[2] or "0"), tonumber(words[3] or "0"), tonumber(words[4] or "3"))
	    elseif verb == "mclick" then return do_mclick(words[2], tonumber(words[3] or "3"))
	    elseif verb == "hold"   then return do_hold(words[2], parse_addr(words[3]))
	    elseif verb == "release" then return do_release(words[2], parse_addr(words[3]))
	    elseif verb == "analog" then return do_analog(words[2], parse_addr(words[3]), tonumber(words[4]), tonumber(words[5] or "0"))
	    elseif verb == "quit" or verb == "exit" then
	      -- Clean shutdown: the debugger console 'exit' command schedules a normal
	      -- MAME exit (breaks the hard-stop loop, tears down properly). Always stop
	      -- the emulator this way over MCP — never kill the process.
	      run_cmd("exit"); return "exiting MAME"
	    elseif verb == "cmd"    then return run_cmd(line:match("^cmd%s+(.+)$") or "")
	    else return "ERROR: unknown command '" .. tostring(verb) .. "'" end
	  end)

	  return ok and tostring(res) or ("ERROR: " .. tostring(res))
	end

	--------------------------------------------------------------------- pump
	-- Auto-release / re-apply held inputs, timed by emulated frame number. Driven
	-- from poll() (register_periodic) because add_machine_frame_notifier did NOT
	-- tick here, leaving keys stuck and causing typematic-repeat storms. Only acts
	-- while running (input needs the machine moving; pause releases everything).
	local function tick_held()
	  if next(held) == nil then return end   -- nothing held: skip (and avoid touching
	                                          -- the debugger before it exists at startup)
	  if dbg().execution_state ~= "run" then return end
	  local now = framenum()
	  for f, h in pairs(held) do
	    if h.step then
	      -- mouse counter: both the Kempston counter and the COM (serial HLE) mouse
	      -- move on a CHANGE of the axis value (constant override = no motion). So
	      -- advance the value each frame; successive reads differ by `step` =>
	      -- continuous movement. mask is 0xFF (Kempston) or 0xFFF (COM).
	      h.mv = (h.mv + h.step) & (h.mask or 0xFF)
	      f:set_value(h.mv)
	      mouse_pos[h.tag] = h.mv
	      -- When done, STOP advancing but DON'T clear: leaving the value frozen
	      -- means delta 0 (cursor holds) instead of snapping back to default.
	      if now >= h.rel then held[f] = nil end
	    elseif h.hold then
	      f:set_value(h.v or 1)
	    elseif now >= h.rel then
	      f:clear_value(); held[f] = nil
	    else
	      f:set_value(h.v or 1)
	    end
	  end
	end

	local function poll()
	  tick_held()
	  if not lfs_ok then return end
	  for entry in lfs.dir(DIR) do
	    local id = entry:match("^req_(%d+)%.txt$")
	    if id then
	      local reqp = DIR .. "/" .. entry
	      local data = read_file(reqp)
	      if data then
	        local reply = dispatch(data)
	        write_atomic(DIR .. "/resp_" .. id .. ".txt", reply)
	        os.remove(reqp)
	      end
	    end
	  end
	end

	-- Fires from emulator_info::periodic_check(), so it keeps servicing requests
	-- (and ticking held inputs) both while running and while hard-stopped.
	emu.register_periodic(poll)

	emu.print_info("mamebridge plugin active. IPC dir = " .. DIR)
end

return exports
