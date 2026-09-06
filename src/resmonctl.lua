local fs = require("filesystem")

-- OpenOS child processes inherit the shell's package.loaded cache. Force the
-- shared command/config module to reload so an in-place update is visible
-- immediately without rebooting the computer.
package.loaded["resmon_common"] = nil
local common = require("resmon_common")

local args = {...}

if #args == 0 then
  io.write(common.helpText("resmonctl"), "\n")
  return
end

if args[1] == "init" then
  if fs.exists(common.CONFIG_PATH) then
    io.stderr:write("Config already exists: ", common.CONFIG_PATH, "\n")
    return
  end
  local _, err = common.initConfig()
  if err then
    io.stderr:write("Failed to initialize config: ", tostring(err), "\n")
    return
  end
  print("Created " .. common.CONFIG_PATH)
  print("Add groups/resources with resmonctl, then start resmon.lua.")
  return
end

local cfg, err = common.loadConfig()
if not cfg then
  io.stderr:write(tostring(err), "\nRun: resmonctl init\n")
  return
end

local ok, message, changed, action = common.applyCommand(cfg, args)
if not ok then
  io.stderr:write(message, "\n")
  return
end

if changed then
  local saved, saveErr = common.saveConfig(cfg)
  if not saved then
    io.stderr:write("Could not save config: ", tostring(saveErr), "\n")
    return
  end
end

if action and action.screenScan then
  local text, scanErr = common.scanScreens()
  if not text then
    io.stderr:write("Display scan failed: ", tostring(scanErr), "\n")
    return
  end
  print(text)
  return
end

if action and action.discovery then
  local me, meErr = common.getME(cfg)
  if not me then
    io.stderr:write("Could not access AE network: ", tostring(meErr), "\n")
    return
  end

  local text, discoveryErr = common.performDiscovery(me, action.discovery)
  if not text then
    io.stderr:write("AE discovery failed: ", tostring(discoveryErr), "\n")
    return
  end

  print(text)
  return
end

if action and action.report then
  local f, openErr = io.open(common.REPORT_REQUEST_PATH, "w")
  if not f then
    io.stderr:write("Could not request report: ", tostring(openErr), "\n")
    return
  end
  f:write(action.report, "\n")
  f:close()
end

print(message)
