-- GTNH OpenComputers Resource Monitor network installer.
--
-- Pastebin bootstrap usage:
--   pastebin run <PASTE_ID>
--   pastebin run <PASTE_ID> --enable --start
--   pastebin run <PASTE_ID> update --restart
--
-- This installer deliberately avoids GitHub Release asset archives. OpenOS
-- wget + GitHub's release-asset redirect can produce an apparently successful
-- download that is empty/unusable on some GTNH/OpenComputers setups.
--
-- Instead:
--   1. Resolve the latest GitHub release tag through the GitHub API.
--   2. Download the release's source files directly from raw.githubusercontent.
--   3. Stage them under /tmp.
--   4. Run the repository's setup.lua from that staging directory.
--
-- --tag=<tag> bypasses the latest-release lookup and installs that exact tag.

local component = require("component")
local fs = require("filesystem")
local shell = require("shell")

local args, options = shell.parse(...)
local action = args[1] or "install"

local DEFAULT_REPOSITORY = "Didgety/gtnh-resmon"

local REQUIRED_FILES = {
  "setup.lua",
  "VERSION",
  "src/resmon.lua",
  "src/resmonctl.lua",
  "src/resmon_common.lua",
  "src/resmon_rc.lua",
}

local function fail(message)
  io.stderr:write("resmon installer: ", tostring(message), "\n")
  return 1
end

local function usage()
  print([[
GTNH Resource Monitor network installer

Usage:
  installer.lua [install] [--enable] [--start] [--tag=<tag>] [--repo=<owner/repo>]
  installer.lua update [--restart] [--tag=<tag>] [--repo=<owner/repo>]

Options:
  --enable          Enable the OpenOS rc service after a fresh install.
  --start           Start the service after install (also enables it).
  --restart         Restart the service after an update.
  --tag=<tag>       Install a specific GitHub Release tag instead of latest.
  --repo=<o/r>      Override the GitHub repository.
  --keep            Keep staged temporary files for debugging.
  --help            Show this help.

Examples:
  installer.lua
  installer.lua --enable --start
  installer.lua update --restart
  installer.lua --tag=v2.6.0
]])
end

if options.help or action == "help" then
  usage()
  return
end

if action ~= "install" and action ~= "update" then
  return fail("unknown action '" .. tostring(action) .. "' (expected install or update)")
end

if not component.isAvailable("internet") then
  return fail("an Internet Card is required")
end

local repository = options.repo or DEFAULT_REPOSITORY
if not repository:match("^[%w%._%-]+/[%w%._%-]+$") then
  return fail("invalid GitHub repository '" .. tostring(repository) .. "' (expected owner/repository)")
end

local targetFs = fs.get("/usr/bin")
if not targetFs then
  return fail("could not resolve the OpenOS filesystem")
end
if targetFs.isReadOnly and targetFs.isReadOnly() then
  return fail("OpenOS is running from a read-only filesystem; run 'install' and boot from the HDD first")
end

-- OpenOS /tmp is commonly a very small tmpfs (~64 KiB in GTNH).
-- Stage downloads on the writable OpenOS disk instead.
local stagingRoot = "/var/tmp"
local workDir = fs.concat(stagingRoot, "resmon-installer")
local stageDir = fs.concat(workDir, "release")
local latestJsonPath = fs.concat(workDir, "latest.json")
local previousCwd = shell.getWorkingDirectory()

local function cleanup()
  shell.setWorkingDirectory(previousCwd)
  if not options.keep then
    shell.execute("rm -rf " .. workDir)
  else
    print("Temporary files kept on disk at " .. workDir)
  end
end

local function execute(command, ...)
  local ok, reason = shell.execute(command, nil, ...)
  if not ok then
    return nil, reason or (tostring(command) .. " failed")
  end
  return true
end

local function ensureDirectory(path)
  if fs.exists(path) then
    if not fs.isDirectory(path) then
      return nil, path .. " exists but is not a directory"
    end
    return true
  end

  local ok, reason = fs.makeDirectory(path)
  if not ok and not fs.isDirectory(path) then
    return nil, reason or ("could not create " .. path)
  end
  return true
end

local function readAll(path)
  local file, reason = io.open(path, "r")
  if not file then
    return nil, reason
  end
  local data = file:read("*a")
  file:close()
  return data
end

local function wget(url, destination)
  local parent = fs.path(destination)
  if parent and parent ~= "" then
    local ok, reason = ensureDirectory(parent)
    if not ok then
      return nil, reason
    end
  end

  if fs.exists(destination) then
    fs.remove(destination)
  end

  io.write("Downloading ", url, " ... ")
  local ok, reason = execute("wget", "-fq", url, destination)

  if not ok or not fs.exists(destination) then
    print("FAILED")
    return nil, reason or ("download did not create " .. destination)
  end

  local size = fs.size(destination) or 0
  if size <= 0 then
    print("FAILED")
    fs.remove(destination)
    return nil, "downloaded file was empty"
  end

  print("ok (", tostring(size), " bytes)")
  return true
end

local function resolveTag()
  if options.tag and tostring(options.tag) ~= "" then
    return tostring(options.tag)
  end

  local apiUrl =
    "https://api.github.com/repos/" ..
    repository ..
    "/releases/latest"

  local ok, reason = wget(apiUrl, latestJsonPath)
  if not ok then
    return nil, "could not resolve latest GitHub release: " .. tostring(reason)
  end

  local json, readReason = readAll(latestJsonPath)
  if not json then
    return nil, "could not read latest-release metadata: " .. tostring(readReason)
  end

  local tag = json:match('"tag_name"%s*:%s*"([^"]+)"')
  if not tag or tag == "" then
    return nil, "GitHub latest-release response did not contain tag_name"
  end

  return tag
end

local function rawUrl(tag, path)
  return
    "https://raw.githubusercontent.com/" ..
    repository ..
    "/" ..
    tag ..
    "/" ..
    path
end

local function stageRelease(tag)
  for _, relative in ipairs(REQUIRED_FILES) do
    local destination = fs.concat(stageDir, relative)
    local ok, reason = wget(rawUrl(tag, relative), destination)
    if not ok then
      return nil,
        "could not stage " ..
        relative ..
        " from tag " ..
        tostring(tag) ..
        ": " ..
        tostring(reason)
    end
  end

  return true
end

local function main()
  shell.execute("rm -rf " .. workDir)

  local ok, reason = ensureDirectory(stagingRoot)
  if not ok then
    return nil, "could not create disk staging directory " .. stagingRoot .. ": " .. tostring(reason)
  end

  ok, reason = ensureDirectory(workDir)
  if not ok then
    return nil, reason
  end

  ok, reason = ensureDirectory(stageDir)
  if not ok then
    return nil, reason
  end

  local tag, tagReason = resolveTag()
  if not tag then
    return nil, tagReason
  end

  print("Resolved release: " .. tag)

  local staged, stageReason = stageRelease(tag)
  if not staged then
    return nil, stageReason
  end

  local setupPath = fs.concat(stageDir, "setup.lua")
  if not fs.exists(setupPath) then
    return nil, "staging failed: setup.lua is missing"
  end

  local setupArgs = { action }

  if action == "install" then
    if options.start then
      table.insert(setupArgs, "--enable")
      table.insert(setupArgs, "--start")
    elseif options.enable then
      table.insert(setupArgs, "--enable")
    end
  elseif action == "update" and options.restart then
    table.insert(setupArgs, "--restart")
  end

  print("Running setup ...")
  shell.setWorkingDirectory(stageDir)

  local installed, installReason =
    shell.execute(setupPath, nil, table.unpack(setupArgs))

  if not installed then
    return nil, installReason or "setup.lua failed"
  end

  return true
end

local ok, result, reason = xpcall(main, debug.traceback)
cleanup()

if not ok then
  return fail(result)
elseif result ~= true then
  return fail(reason or result or "installation failed")
end

print("")
print(action == "install" and "Network installation complete." or "Network update complete.")

if action == "install" then
  print("Configure resources with: resmonctl")
  if not options.start then
    print("When ready: rc resmon enable && rc resmon start")
  end
end
