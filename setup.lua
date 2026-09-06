-- GTNH OpenComputers Resource Monitor installer for OpenOS.
-- Run from the repository root with:
--   ./setup.lua install
--
-- Program files are installed in standard OpenOS local package locations:
--   /usr/bin/resmon.lua
--   /usr/bin/resmonctl.lua
--   /usr/lib/resmon_common.lua
--   /etc/rc.d/resmon.lua
--
-- Runtime data is intentionally kept outside the installation tree:
--   /etc/resmon.cfg
--   /var/lib/resmon.state

local fs = require("filesystem")
local shell = require("shell")

local args, options = shell.parse(...)
local action = args[1] or "install"

local PROGRAM_FILES = {
  { source = "src/resmon.lua",        destination = "/usr/bin/resmon.lua" },
  { source = "src/resmonctl.lua",     destination = "/usr/bin/resmonctl.lua" },
  { source = "src/resmon_common.lua", destination = "/usr/lib/resmon_common.lua" },
  { source = "src/resmon_rc.lua",     destination = "/etc/rc.d/resmon.lua" },
}

local CONFIG_PATH = "/etc/resmon.cfg"
local STATE_PATH = "/var/lib/resmon.state"

local function scriptRoot()
  local program = os.getenv("_")
  if program and program ~= "" then
    local dir = fs.path(program)
    if dir and dir ~= "" then
      return fs.canonical(dir)
    end
  end
  return fs.canonical(shell.getWorkingDirectory())
end

local ROOT = scriptRoot()

local function help()
  print([[
GTNH Resource Monitor setup

Usage:
  ./setup.lua install [--enable] [--start]
  ./setup.lua update  [--restart]
  ./setup.lua init
  ./setup.lua enable
  ./setup.lua disable
  ./setup.lua start
  ./setup.lua stop
  ./setup.lua status
  ./setup.lua uninstall [--purge]

Actions:
  install    Install/update program files and create /etc/resmon.cfg if missing.
  update     Replace program files while preserving config/state.
  init       Create the default config if it does not already exist.
  enable     Enable the OpenOS rc service at boot.
  disable    Disable the OpenOS rc service at boot.
  start      Start the monitor through rc.
  stop       Stop the monitor through rc.
  status     Show installation/config/service status.
  uninstall  Remove installed program/service files. Config/state are preserved.

Options:
  --enable   Enable the rc service after installation.
  --start    Start the service after installation (also enables it).
  --restart  Restart the service after an update.
  --purge    With uninstall, also remove /etc/resmon.cfg and state.
]])
end

local function parentDirectory(path)
  local parent = fs.path(path)
  if not parent or parent == "" then return "/" end
  return parent
end

local function ensureDirectory(path)
  if fs.exists(path) then
    if not fs.isDirectory(path) then
      return nil, path .. " exists but is not a directory"
    end
    return true
  end

  local ok, reason = fs.makeDirectory(path)
  if not ok and not fs.exists(path) then
    return nil, reason or ("could not create " .. path)
  end
  return true
end

local function readAll(path)
  local f, reason = io.open(path, "r")
  if not f then return nil, reason end
  local data = f:read("*a")
  f:close()
  return data
end

local function atomicCopy(source, destination)
  local data, reason = readAll(source)
  if not data then return nil, reason end

  local ok, dirReason = ensureDirectory(parentDirectory(destination))
  if not ok then return nil, dirReason end

  local temp = destination .. ".resmon-install-tmp"
  if fs.exists(temp) then fs.remove(temp) end

  local out, openReason = io.open(temp, "w")
  if not out then return nil, openReason end
  out:write(data)
  out:close()

  if fs.exists(destination) then
    local removed, removeReason = fs.remove(destination)
    if not removed then
      fs.remove(temp)
      return nil, removeReason or ("could not replace " .. destination)
    end
  end

  local renamed, renameReason = fs.rename(temp, destination)
  if not renamed then
    fs.remove(temp)
    return nil, renameReason or ("could not install " .. destination)
  end

  return true
end

local function sourcePath(relative)
  return fs.concat(ROOT, relative)
end

local function validateSources()
  for _, entry in ipairs(PROGRAM_FILES) do
    local path = sourcePath(entry.source)
    if not fs.exists(path) then
      return nil, "missing repository file: " .. path .. "\nRun setup.lua from the repository checkout."
    end
  end
  return true
end

local function installFiles()
  local ok, reason = validateSources()
  if not ok then return nil, reason end

  for _, entry in ipairs(PROGRAM_FILES) do
    local source = sourcePath(entry.source)
    io.write("Installing ", entry.destination, " ... ")
    local copied, copyReason = atomicCopy(source, entry.destination)
    if not copied then
      print("FAILED")
      return nil, copyReason
    end
    print("ok")
  end

  ensureDirectory("/var/lib")
  return true
end

local function loadInstalledCommon()
  local path = "/usr/lib/resmon_common.lua"
  if not fs.exists(path) then
    return nil, "resmon_common is not installed; run setup install first"
  end

  local chunk, reason = loadfile(path)
  if not chunk then return nil, reason end

  local ok, common = pcall(chunk)
  if not ok then return nil, common end
  if type(common) ~= "table" then return nil, "resmon_common did not return a module table" end
  return common
end

local function initializeConfig()
  if fs.exists(CONFIG_PATH) then
    print("Config already exists; preserving " .. CONFIG_PATH)
    return true
  end

  local common, reason = loadInstalledCommon()
  if not common then return nil, reason end

  local cfg, initReason = common.initConfig(CONFIG_PATH)
  if not cfg then return nil, initReason end
  print("Created " .. CONFIG_PATH)
  return true
end

local function isRcEnabled()
  if not fs.exists("/etc/rc.cfg") then return false end

  local env = {}
  local chunk = loadfile("/etc/rc.cfg", "t", env)
  if not chunk then return false end
  local ok = pcall(chunk)
  if not ok then return false end

  for _, name in ipairs(env.enabled or {}) do
    if name == "resmon" then return true end
  end
  return false
end

local function rc(command)
  if not fs.exists("/etc/rc.d/resmon.lua") then
    return nil, "resmon rc service is not installed"
  end

  -- OpenOS reports enable on an already-enabled service as an error. Make the
  -- setup commands idempotent instead.
  if command == "enable" and isRcEnabled() then
    print("resmon service is already enabled")
    return true
  elseif command == "disable" and not isRcEnabled() then
    print("resmon service is already disabled")
    return true
  end

  local ok, reason = shell.execute("rc resmon " .. command)
  if not ok then return nil, reason or ("rc resmon " .. command .. " failed") end
  return true
end

local function unloadRcDefinition()
  local ok, rcLib = pcall(require, "rc")
  if ok and rcLib and rcLib.unload then
    pcall(rcLib.unload, "resmon")
  end
end

local function removeIfExists(path)
  if not fs.exists(path) then
    print("Not present: " .. path)
    return true
  end
  local ok, reason = fs.remove(path)
  if not ok then return nil, reason end
  print("Removed " .. path)
  return true
end

local function doStatus()
  print("GTNH Resource Monitor")
  print("Repository: " .. ROOT)
  print("")
  print("Installed files:")
  for _, entry in ipairs(PROGRAM_FILES) do
    print(string.format("  %-31s %s", entry.destination, fs.exists(entry.destination) and "present" or "missing"))
  end
  print("")
  print("Runtime data:")
  print("  " .. CONFIG_PATH .. ": " .. (fs.exists(CONFIG_PATH) and "present" or "missing"))
  print("  " .. STATE_PATH .. ": " .. (fs.exists(STATE_PATH) and "present" or "not created yet"))
  print("")
  if fs.exists("/etc/rc.d/resmon.lua") then
    shell.execute("rc resmon status")
  else
    print("Service: not installed")
  end
end

if action == "help" or action == "-h" or action == "--help" then
  help()
  return
end

if action == "install" or action == "update" then
  if options.start then options.enable = true end
  local restartAfterUpdate = action == "update" and options.restart
  local startAfterInstall = options.start == true
  local mustReloadService = restartAfterUpdate or startAfterInstall

  -- Stop before replacing files when the caller explicitly wants a restart.
  -- This preserves the old rc environment long enough to kill its detached
  -- worker cleanly, avoiding an orphaned monitor thread.
  if mustReloadService and fs.exists("/etc/rc.d/resmon.lua") then
    rc("stop") -- best effort; a stopped service is fine
  end

  local ok, reason = installFiles()
  if not ok then
    io.stderr:write("Setup failed: ", tostring(reason), "\n")
    return 1
  end

  if action == "install" then
    local initialized, initReason = initializeConfig()
    if not initialized then
      io.stderr:write("Installed files, but config initialization failed: ", tostring(initReason), "\n")
      return 1
    end
  end

  if mustReloadService then
    unloadRcDefinition()
  end

  if options.enable then
    local enabled, enableReason = rc("enable")
    if not enabled then
      io.stderr:write("Installed successfully, but could not enable service: ", tostring(enableReason), "\n")
      return 1
    end
  end

  if startAfterInstall or restartAfterUpdate then
    local started, startReason = rc("start")
    if not started then
      io.stderr:write(action == "install" and
        "Installed successfully, but could not start service: " or
        "Updated successfully, but could not restart service: ",
        tostring(startReason), "\n")
      return 1
    end
  end

  print("")
  print(action == "install" and "Installation complete." or "Update complete.")
  print("Config: " .. CONFIG_PATH)
  print("Manage resources with: resmonctl")
  print("Service controls: rc resmon <start|stop|restart|status|enable|disable>")
  if not startAfterInstall and not restartAfterUpdate then
    print("When configuration is ready: rc resmon start")
  end
  return
end

if action == "init" then
  local ok, reason = initializeConfig()
  if not ok then
    io.stderr:write("Initialization failed: ", tostring(reason), "\n")
    return 1
  end
  return
end

if action == "enable" or action == "disable" or action == "start" or action == "stop" then
  local ok, reason = rc(action)
  if not ok then
    io.stderr:write(tostring(reason), "\n")
    return 1
  end
  return
end

if action == "status" then
  doStatus()
  return
end

if action == "uninstall" then
  -- Best effort: a stopped/disabled service is safer to remove. If it was not
  -- loaded/running, rc may report that fact; removal can still continue.
  if fs.exists("/etc/rc.d/resmon.lua") then
    pcall(rc, "stop")
    pcall(rc, "disable")
  end

  for _, entry in ipairs(PROGRAM_FILES) do
    local ok, reason = removeIfExists(entry.destination)
    if not ok then
      io.stderr:write("Could not remove ", entry.destination, ": ", tostring(reason), "\n")
      return 1
    end
  end

  if options.purge then
    local ok, reason = removeIfExists(CONFIG_PATH)
    if not ok then io.stderr:write(tostring(reason), "\n") return 1 end
    ok, reason = removeIfExists(STATE_PATH)
    if not ok then io.stderr:write(tostring(reason), "\n") return 1 end
    print("Uninstalled and purged runtime data.")
  else
    print("Uninstalled. Config/state were preserved.")
    print("Use './setup.lua uninstall --purge' to remove them too.")
  end
  return
end

io.stderr:write("Unknown setup action: ", tostring(action), "\n\n")
help()
return 1
