-- mame_bridge.lua
-- File-IPC bridge that exposes MAME's debugger to an external MCP server.
-- Launch MAME like:
--   mame <system> -debug -autoboot_script /path/to/mame_bridge.lua
--
-- Protocol: the MCP server drops a request file  <DIR>/req_<id>.txt  containing
-- one command line; this script processes it on each emulated frame and writes
-- the reply to  <DIR>/resp_<id>.txt .
--
-- Env vars:
--   MAME_MCP_DIR  IPC directory      (default /tmp/mame_mcp)
--   MAME_MCP_CPU  CPU device tag     (default :maincpu)

local DIR     = os.getenv("MAME_MCP_DIR") or "/tmp/mame_mcp"
local CPUTAG  = os.getenv("MAME_MCP_CPU") or ":maincpu"
local SPACE   = "program"

-- Z80 (and 8080-ish) registers worth reporting. Missing ones are skipped.
local REGS = { "PC","SP","AF","BC","DE","HL","IX","IY",
               "AF2","BC2","DE2","HL2","I","R","IM","IFF1","IFF2","WZ" }

os.execute('mkdir -p "' .. DIR .. '" 2>/dev/null')
local lfs_ok, lfs = pcall(require, "lfs")

----------------------------------------------------------------------- helpers
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

-- Run a debugger console command and return any new console output it produced.
local function run_cmd(cmdstr)
  local d = dbg()
  local before = #d.consolelog
  d:command(cmdstr)
  local lines = {}
  for i = before + 1, #d.consolelog do lines[#lines + 1] = d.consolelog[i] end
  return table.concat(lines, "\n")
end

----------------------------------------------------------------------- actions
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
  local s, t = space(), {}
  if len > 4096 then len = 4096 end
  for i = 0, len - 1 do
    local ok, b = pcall(function() return s:read_u8(addr + i) end)
    t[#t + 1] = string.format("%02X", ok and b or 0)
  end
  return table.concat(t)
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

--------------------------------------------------------------------- dispatch
local function dispatch(line)
  if not manager.machine.debugger then
    return "ERROR: debugger not enabled (start MAME with -debug)"
  end
  local words = {}
  for w in line:gmatch("%S+") do words[#words + 1] = w end
  local verb = words[1]

  local ok, res = pcall(function()
    if     verb == "regs"   then return do_regs()
    elseif verb == "mem"    then return do_mem(tonumber(words[2]), tonumber(words[3]))
    elseif verb == "setmem" then return do_setmem(tonumber(words[2]), words[3])
    elseif verb == "bp"     then
      local cond = line:match("^%S+%s+%S+%s+(.+)$")
      return run_cmd("bpset " .. words[2] .. (cond and ("," .. cond) or ""))
    elseif verb == "bpclr"  then return run_cmd("bpclear " .. words[2])
    elseif verb == "bplist" then return run_cmd("bplist")
    elseif verb == "wp"     then return run_cmd("wpset " .. words[2] .. "," .. words[3] .. "," .. words[4])
    elseif verb == "wpclr"  then return run_cmd("wpclear " .. words[2])
    elseif verb == "step"   then return run_cmd("step " .. (words[2] or "1"))
    elseif verb == "over"   then return run_cmd("over " .. (words[2] or "1"))
    elseif verb == "out"    then return run_cmd("out")
    elseif verb == "cont"   then dbg().execution_state = "run";  return "running"
    elseif verb == "pause"  then dbg().execution_state = "stop"; return "stopped"
    elseif verb == "status" then return do_status()
    elseif verb == "dasm"   then return do_dasm(tonumber(words[2]), tonumber(words[3] or "32"))
    elseif verb == "cmd"    then return run_cmd(line:match("^cmd%s+(.+)$") or "")
    else return "ERROR: unknown command '" .. tostring(verb) .. "'" end
  end)

  return ok and tostring(res) or ("ERROR: " .. tostring(res))
end

------------------------------------------------------------------------- pump
local function poll()
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

-- Keep the subscription alive for the lifetime of the script.
local _sub = emu.add_machine_frame_notifier(function() poll() end)
emu.print_info("mame_bridge.lua active. IPC dir = " .. DIR)
