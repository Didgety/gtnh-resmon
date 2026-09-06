-- Tiny permanent Pastebin bootstrap for GTNH OpenComputers Resource Monitor.
-- Upload THIS file to Pastebin once, then install with:
--   pastebin run <PASTE_ID>
--
-- Extra arguments are forwarded to installer.lua, for example:
--   pastebin run <PASTE_ID> --enable --start
--   pastebin run <PASTE_ID> update --restart

local fs = require("filesystem")
local shell = require("shell")

local REPOSITORY = "Didgety/gtnh-resmon"

if not REPOSITORY:match("^[%w%._%-]+/[%w%._%-]+$") then
  io.stderr:write("Pastebin bootstrap: invalid GitHub repository.\n")
  return 1
end

local url = "https://raw.githubusercontent.com/" .. REPOSITORY .. "/main/installer.lua"

-- Do not place the bootstrap itself in /tmp. On GTNH/OpenOS that tmpfs may
-- only be about 64 KiB, and the installer needs that space for the shell too.
local stagingRoot = "/var/tmp"
if not fs.exists(stagingRoot) then
  local made, makeReason = fs.makeDirectory(stagingRoot)
  if not made and not fs.isDirectory(stagingRoot) then
    io.stderr:write(
      "Could not create " .. stagingRoot .. ": " ..
      tostring(makeReason or "unknown error") .. "\n"
    )
    return 1
  end
end

local temp = fs.concat(stagingRoot, "resmon-bootstrap.lua")
if fs.exists(temp) then fs.remove(temp) end

local ok, reason = shell.execute("wget", nil, "-fq", url, temp)
if not ok or not fs.exists(temp) then
  if fs.exists(temp) then fs.remove(temp) end
  io.stderr:write("Could not download current installer from GitHub: ", tostring(reason or "unknown error"), "\n")
  return 1
end

local forwarded = {...}
local hasRepo = false
for _, argument in ipairs(forwarded) do
  if tostring(argument):match("^%-%-repo=") then
    hasRepo = true
    break
  end
end
if not hasRepo then
  table.insert(forwarded, "--repo=" .. REPOSITORY)
end

local ran, runReason = shell.execute(temp, nil, table.unpack(forwarded))
fs.remove(temp)

if not ran then
  io.stderr:write("Installer failed: ", tostring(runReason or "unknown error"), "\n")
  return 1
end
