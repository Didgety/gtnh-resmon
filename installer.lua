-- GTNH OpenComputers Resource Monitor network installer.
--
-- Normally invoked through the tiny Pastebin bootstrap in pastebin.lua:
--   pastebin run <PASTE_ID>
--   pastebin run <PASTE_ID> --enable --start
--   pastebin run <PASTE_ID> update --restart
--
-- The installer downloads a GitHub Release archive into /tmp, extracts it,
-- and delegates the actual installation to setup.lua. Persistent config and
-- runtime state remain managed by setup.lua and are preserved on updates.

local component = require("component")
local fs = require("filesystem")
local shell = require("shell")

local args, options = shell.parse(...)
local action = args[1] or "install"

local DEFAULT_REPOSITORY = "Didgety/gtnh-resmon"
local ARCHIVE_NAME = "GTNHResourceMonitor.tar"

local TAR_URL = "https://raw.githubusercontent.com/mpmxyz/ocprograms/refs/heads/master/home/bin/tar.lua"

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
  --repo=<o/r>      Override the GitHub repository compiled into this installer.
  --keep            Keep downloaded/extracted temporary files for debugging.
  --help            Show this help.

Examples:
  installer.lua
  installer.lua --enable --start
  installer.lua update --restart
  installer.lua --tag=v2.2.0
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
  return fail(
    "invalid GitHub repository '" ..
    tostring(repository) ..
    "' (expected owner/repository)"
  )
end

-- /tmp may be writable even when OpenOS is still running from its read-only
-- install floppy. Check the target filesystem before downloading anything.
local targetFs = fs.get("/usr/bin")
if not targetFs then
  return fail("could not resolve the OpenOS filesystem")
end
if targetFs.isReadOnly and targetFs.isReadOnly() then
  return fail("OpenOS is running from a read-only filesystem; run 'install' and boot from the HDD first")
end

local workDir = "/tmp/resmon-installer"
local archivePath = fs.concat(workDir, ARCHIVE_NAME)
local tarPath = fs.concat(workDir, "tar.lua")
local extractDir = fs.concat(workDir, "release")
local previousCwd = shell.getWorkingDirectory()

local function cleanup()
  shell.setWorkingDirectory(previousCwd)
  if not options.keep then
    shell.execute("rm -rf " .. workDir)
  else
    print("Temporary files kept at " .. workDir)
  end
end

local function execute(command, ...)
  local ok, reason = shell.execute(command, nil, ...)
  if not ok then
    return nil, reason or (tostring(command) .. " failed")
  end
  return true
end

local function wget(url, destination)
  if fs.exists(destination) then fs.remove(destination) end
  io.write("Downloading ", url, " ... ")
  local ok, reason = execute("wget", "-fq", url, destination)
  if not ok or not fs.exists(destination) then
    print("FAILED")
    return nil, reason or "download did not create " .. destination
  end
  print("ok")
  return true
end

local function makeReleaseUrl()
  local base = "https://github.com/" .. repository .. "/releases/"
  if options.tag and tostring(options.tag) ~= "" then
    return base .. "download/" .. tostring(options.tag) .. "/" .. ARCHIVE_NAME
  end
  return base .. "latest/download/" .. ARCHIVE_NAME
end

local function main()
  shell.execute("rm -rf " .. workDir)
  local ok, reason = fs.makeDirectory(workDir)
  if not ok and not fs.isDirectory(workDir) then
    return nil, reason or "could not create temporary directory"
  end
  ok, reason = fs.makeDirectory(extractDir)
  if not ok and not fs.isDirectory(extractDir) then
    return nil, reason or "could not create extraction directory"
  end

  local downloaded, downloadReason = wget(makeReleaseUrl(), archivePath)
  if not downloaded then
    return nil,
      "could not download the release archive: " .. tostring(downloadReason) ..
      "\nMake sure the repository has a tagged GitHub Release containing " .. ARCHIVE_NAME
  end

  local tarCommand
  if fs.exists("/bin/tar.lua") then
    tarCommand = "tar"
  else
    local tarOk, tarReason = wget(TAR_URL, tarPath)
    if not tarOk then return nil, "could not obtain tar utility: " .. tostring(tarReason) end
    tarCommand = tarPath
  end

print("Extracting release ...")

  -- Do not rely on changing PWD before launching tar. OpenOS child processes
  -- do not always observe a PWD change the way we expect, while this tar
  -- implementation supports an explicit --dir option.
  local extracted, extractReason = execute(
    tarCommand,
    "--dir=" .. extractDir,
    -- "-xf",
    "-xfv", -- debug verbosity
    archivePath
  )
  if not extracted then
    return nil, "could not extract release: " .. tostring(extractReason)
  end

  local setupPath = fs.concat(extractDir, "setup.lua")

  -- Some tar producers may wrap the release in one top-level directory.
  -- Accept that layout too, but reject anything more ambiguous.
  if not fs.exists(setupPath) then
    local candidate = nil
    for name in fs.list(extractDir) do
      local child = fs.concat(extractDir, name)
      if fs.isDirectory(child) then
        local nestedSetup = fs.concat(child, "setup.lua")
        if fs.exists(nestedSetup) then
          if candidate then
            return nil, "release archive is ambiguous: multiple setup.lua candidates found"
          end
          candidate = nestedSetup
        end
      end
    end

    if candidate then
      setupPath = candidate
      extractDir = fs.path(candidate)
    else
      return nil,
        "release archive extraction completed, but setup.lua was not found under " ..
        tostring(extractDir)
    end
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
  shell.setWorkingDirectory(extractDir)
  local installed, installReason = shell.execute(setupPath, nil, table.unpack(setupArgs))
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
