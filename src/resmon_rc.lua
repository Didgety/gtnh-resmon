-- OpenOS rc service for GTNH Resource Monitor.
-- Installed as /etc/rc.d/resmon.lua.

local fs = require("filesystem")
local thread = require("thread")

local PROGRAM = "/usr/bin/resmon.lua"
local daemon = nil

local function isRunning()
  return daemon ~= nil and daemon:status() ~= "dead"
end

function start()
  if isRunning() then
    print("resmon is already running")
    return
  end

  if not fs.exists(PROGRAM) then
    error("resmon program not found: " .. PROGRAM)
  end

  daemon = thread.create(function()
    local ok, reason = xpcall(function()
      dofile(PROGRAM)
    end, debug.traceback)

    if not ok then
      io.stderr:write("resmon daemon crashed:\n", tostring(reason), "\n")
    end
  end)

  -- Re-parent the worker to OpenOS' init process so it survives the rc command.
  daemon:detach()
  print("resmon started")
end

function stop()
  if not isRunning() then
    daemon = nil
    print("resmon is not running")
    return
  end

  daemon:kill()
  daemon = nil
  print("resmon stopped")
end

function status()
  if isRunning() then
    print("resmon is running")
    return true
  end

  print("resmon is stopped")
  return false
end
