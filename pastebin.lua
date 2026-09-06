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

if REPOSITORY:find("YOUR_GITHUB_USERNAME", 1, true) then
  io.stderr:write("Pastebin bootstrap: configure REPOSITORY before publishing this paste.\n")
  return 1
end

local url = "https://raw.githubusercontent.com/" .. REPOSITORY .. "/refs/heads/main/installer.lua"
local temp = os.tmpname()

local ok, reason = shell.execute("wget", nil, "-fq", url, temp)
if not ok or not fs.exists(temp) then
  if fs.exists(temp) then fs.remove(temp) end
  io.stderr:write("Could not download current installer from GitHub: ", tostring(reason or "unknown error"), "\n")
  return 1
end

local forwarded = {...}
table.insert(forwarded, "--repo=" .. REPOSITORY)
local ran, runReason = shell.execute(temp, nil, table.unpack(forwarded))
fs.remove(temp)

if not ran then
  io.stderr:write("Installer failed: ", tostring(runReason or "unknown error"), "\n")
  return 1
end
