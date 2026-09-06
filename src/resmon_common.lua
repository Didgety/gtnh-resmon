local fs = require("filesystem")
local serialization = require("serialization")

local M = {}

M.CONFIG_PATH = "/etc/resmon.cfg"
M.REPORT_REQUEST_PATH = "/tmp/resmon.report"

local function deepcopy(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local out = {}
  seen[value] = out
  for k, v in pairs(value) do
    out[deepcopy(k, seen)] = deepcopy(v, seen)
  end
  return out
end

local DEFAULT = {
  revision = 1,

  settings = {
    siteName = "Main Base",
    webhookName = "GTNH Resource Monitor",
    meAddress = "",

    -- AE is queried at this interval.
    pollInterval = 60,

    -- Trend is calculated over this much history. A rate is not displayed
    -- until at least minTrendSpan seconds of samples exist.
    trendWindow = 30 * 60,
    minTrendSpan = 5 * 60,

    -- How often the config file is reloaded, allowing resmonctl changes to
    -- take effect without restarting the monitor.
    configReloadInterval = 5,

    reportOnStart = true,
    httpTimeout = 15,

    -- Routine daemon output can overwrite an interactive OpenOS shell because
    -- rc services inherit a terminal. Set this false when using dashboard
    -- screens; errors are still reflected on configured dashboards.
    consoleLog = true,

    discord = {
      enabled = false,
      apiBase = "https://discord.com/api/v10",
      botToken = "",
      adminChannelId = "",
      adminUserIds = {},
      prefix = "!res",
      pollInterval = 15,
    },
  },

  groups = {
    default = {
      display = "Resources",
      webhook = "",
      -- Optional; if blank, alerts use webhook.
      alertWebhook = "",
      reportInterval = 30 * 60,
      alertRepeatInterval = 2 * 60 * 60,
      mention = "",
    },
  },

  resources = {},

  -- Dedicated OC dashboard screens. A dashboard GPU should not be the primary
  -- terminal GPU. Multiple screens may share a dedicated GPU (the monitor will
  -- rebind it while refreshing), though one GPU per screen is smoother.
  screens = {},
}

function M.defaultConfig()
  return deepcopy(DEFAULT)
end

local function ensureParent(path)
  local parent = fs.path(path)
  if parent and parent ~= "" and not fs.exists(parent) then
    fs.makeDirectory(parent)
  end
end

function M.loadConfig(path)
  path = path or M.CONFIG_PATH
  if not fs.exists(path) then
    return nil, "Config does not exist: " .. path
  end

  local f, err = io.open(path, "r")
  if not f then return nil, err end
  local data = f:read("*a")
  f:close()

  local ok, cfg = pcall(serialization.unserialize, data)
  if not ok or type(cfg) ~= "table" then
    return nil, "Could not parse config: " .. tostring(cfg)
  end

  cfg.settings = cfg.settings or {}
  cfg.settings.discord = cfg.settings.discord or {}
  cfg.groups = cfg.groups or {}
  cfg.resources = cfg.resources or {}
  cfg.screens = cfg.screens or {}
  cfg.revision = tonumber(cfg.revision) or 0

  return cfg
end

function M.saveConfig(cfg, path, bumpRevision)
  path = path or M.CONFIG_PATH
  if bumpRevision ~= false then
    cfg.revision = (tonumber(cfg.revision) or 0) + 1
  end

  ensureParent(path)
  local tmp = path .. ".tmp"
  local f, err = io.open(tmp, "w")
  if not f then return nil, err end
  f:write(serialization.serialize(cfg))
  f:write("\n")
  f:close()

  if fs.exists(path) then fs.remove(path) end
  local ok, renameErr = fs.rename(tmp, path)
  if not ok then
    return nil, renameErr or "rename failed"
  end
  return true
end

function M.initConfig(path)
  local cfg = M.defaultConfig()
  local ok, err = M.saveConfig(cfg, path, false)
  if not ok then return nil, err end
  return cfg
end

local function boolValue(s)
  s = tostring(s):lower()
  if s == "true" or s == "yes" or s == "on" or s == "1" then return true end
  if s == "false" or s == "no" or s == "off" or s == "0" then return false end
  return nil
end

local NUMERIC_KEYS = {
  min = true, recover = true, target = true, damage = true,
  reportInterval = true, alertRepeatInterval = true,
  pollInterval = true, trendWindow = true, minTrendSpan = true,
  configReloadInterval = true, httpTimeout = true,
  pageInterval = true,
}

local BOOLEAN_KEYS = {
  enabled = true, reportOnStart = true, consoleLog = true,
}

local function coerce(key, value)
  if value == "nil" or value == "null" or value == "none" then
    return nil, true
  end
  if NUMERIC_KEYS[key] then
    local n = tonumber(value)
    if n == nil then return nil, false, key .. " must be numeric" end
    return n, true
  end
  if BOOLEAN_KEYS[key] then
    local b = boolValue(value)
    if b == nil then return nil, false, key .. " must be true/false" end
    return b, true
  end
  return value, true
end

local function parseKV(tokens, startIndex)
  local out = {}
  for i = startIndex, #tokens do
    local k, v = tostring(tokens[i]):match("^([%w_]+)=(.*)$")
    if not k then
      return nil, "Expected key=value, got: " .. tostring(tokens[i])
    end
    local cv, ok, err = coerce(k, v)
    if not ok then return nil, err end
    out[k] = { value = cv, wasNil = cv == nil }
  end
  return out
end

local function applyKV(target, kv, allowed)
  for k, wrapped in pairs(kv) do
    if not allowed[k] then
      return nil, "Unknown field: " .. k
    end
    target[k] = wrapped.value
  end
  return true
end

local RESOURCE_FIELDS = {
  display = true, label = true, name = true, damage = true,
  min = true, recover = true, target = true, unit = true,
  group = true, trendWindow = true, minTrendSpan = true,
}

local GROUP_FIELDS = {
  display = true, webhook = true, alertWebhook = true,
  reportInterval = true, alertRepeatInterval = true, mention = true,
}

local SCREEN_FIELDS = {
  screen = true, gpu = true, group = true, title = true,
  enabled = true, pageInterval = true,
}

local SETTINGS_FIELDS = {
  siteName = true, webhookName = true, meAddress = true, pollInterval = true,
  trendWindow = true, minTrendSpan = true,
  configReloadInterval = true, reportOnStart = true,
  httpTimeout = true, consoleLog = true,
}

local DISCORD_FIELDS = {
  enabled = true, apiBase = true, botToken = true, adminChannelId = true,
  prefix = true, pollInterval = true,
}

function M.findResource(cfg, id)
  for i, r in ipairs(cfg.resources or {}) do
    if r.id == id then return r, i end
  end
  return nil
end

local function screenListText(cfg)
  local lines = { "Dashboard screens:" }
  local ids = {}
  for id in pairs(cfg.screens or {}) do ids[#ids + 1] = id end
  table.sort(ids)

  if #ids == 0 then
    lines[#lines + 1] = "  (none)"
  else
    for _, id in ipairs(ids) do
      local d = cfg.screens[id]
      lines[#lines + 1] = string.format(
        "  %s enabled=%s group=%s screen=%s gpu=%s page=%ss",
        id,
        tostring(d.enabled ~= false),
        tostring(d.group or "*"),
        tostring(d.screen or "missing"),
        tostring(d.gpu or "missing"),
        tostring(d.pageInterval or 10)
      )
    end
  end
  return table.concat(lines, "\n")
end

local function listText(cfg)
  local lines = {
    "GTNH resource monitor config (revision " .. tostring(cfg.revision or 0) .. ")",
    "Groups:"
  }

  local groupNames = {}
  for id in pairs(cfg.groups or {}) do table.insert(groupNames, id) end
  table.sort(groupNames)
  for _, id in ipairs(groupNames) do
    local g = cfg.groups[id]
    table.insert(lines, string.format(
      "  %s (%s) report=%ss webhook=%s alertWebhook=%s",
      id, g.display or id, tostring(g.reportInterval or "default"),
      (g.webhook and g.webhook ~= "") and "set" or "missing",
      (g.alertWebhook and g.alertWebhook ~= "") and "set" or "same"
    ))
  end

  table.insert(lines, "Resources:")
  local resources = {}
  for _, r in ipairs(cfg.resources or {}) do table.insert(resources, r) end
  table.sort(resources, function(a, b) return tostring(a.id) < tostring(b.id) end)
  if #resources == 0 then
    table.insert(lines, "  (none)")
  else
    for _, r in ipairs(resources) do
      local matcher = r.label and ('label="' .. r.label .. '"') or
                      r.name and ('name="' .. r.name .. '"') or "no matcher"
      table.insert(lines, string.format(
        "  %s [%s/%s] %s min=%s target=%s",
        r.id, r.kind or "?", r.group or "?", matcher,
        tostring(r.min), tostring(r.target)
      ))
    end
  end

  table.insert(lines, "")
  table.insert(lines, screenListText(cfg))
  return table.concat(lines, "\n")
end

function M.helpText(prefix)
  prefix = prefix or "resmonctl"
  local p = prefix ~= "" and (prefix .. " ") or ""
  return table.concat({
    p .. "list",
    p .. "find <item|fluid> <query> [limit=N]",
    p .. "inspect item <name> [damage]",
    p .. "inspect fluid <name>",
    p .. "add <item|fluid> <group> <id> key=value ...",
    p .. "update <id> key=value ...",
    p .. "remove <id>",
    p .. "group add <id> key=value ...",
    p .. "group update <id> key=value ...",
    p .. "group remove <id> [force=true]",
    p .. "screen list",
    p .. "screen scan",
    p .. "screen add <id> screen=<address> gpu=<address> [group=<id|*>] [title=...] [pageInterval=10]",
    p .. "screen update <id> key=value ...",
    p .. "screen remove <id>",
    p .. "settings key=value ...",
    p .. "discord key=value ...",
    p .. "discord-admin add <userId>",
    p .. "discord-admin remove <userId>",
    p .. "report [group]",
    "",
    "Discovery prints exact name/damage matchers; item fuzzy search streams results to avoid OC OOM.",
    "Resource fields: display,label,name,damage,min,recover,target,unit,group,trendWindow,minTrendSpan",
    "Group fields: display,webhook,alertWebhook,reportInterval,alertRepeatInterval,mention",
    "Screen fields: screen,gpu,group,title,enabled,pageInterval",
    "Use a dedicated GPU for dashboards so the monitor never rebinds the interactive terminal GPU.",
    "Use field=nil to clear an optional field.",
  }, "\n")
end

function M.applyCommand(cfg, tokens)
  if #tokens == 0 or tokens[1] == "help" then
    return true, M.helpText(""), false
  end

  local cmd = tostring(tokens[1]):lower()

  if cmd == "list" then
    return true, listText(cfg), false
  end

  if cmd == "find" then
    local kind = tostring(tokens[2] or ""):lower()
    if kind ~= "item" and kind ~= "fluid" then
      return false, "Usage: find <item|fluid> <query> [limit=N]", false
    end

    local queryParts = {}
    local limit = 25
    for i = 3, #tokens do
      local token = tostring(tokens[i])
      local value = token:match("^limit=(%d+)$")
      if value then
        limit = math.max(1, math.min(100, tonumber(value) or 25))
      else
        queryParts[#queryParts + 1] = token
      end
    end

    local query = table.concat(queryParts, " ")
    if query == "" then
      return false, "Missing search query. Use '*' to list everything.", false
    end

    return true,
      "Searching live AE " .. kind .. " inventory for '" .. query .. "'...",
      false,
      { discovery = { mode = "find", kind = kind, query = query, limit = limit } }
  end

  if cmd == "inspect" then
    local kind = tostring(tokens[2] or ""):lower()
    if kind ~= "item" and kind ~= "fluid" then
      return false, "Usage: inspect item <name> [damage] | inspect fluid <name>", false
    end

    local name = tokens[3]
    if not name or tostring(name) == "" then
      return false, "Missing internal resource name", false
    end

    local damage = nil
    if kind == "item" and tokens[4] ~= nil then
      damage = tonumber(tokens[4])
      if damage == nil then
        return false, "Item damage/meta must be numeric", false
      end
    elseif kind == "fluid" and tokens[4] ~= nil then
      return false, "Fluid inspect does not take damage/meta", false
    end

    return true,
      "Inspecting live AE " .. kind .. " inventory...",
      false,
      { discovery = { mode = "inspect", kind = kind, name = tostring(name), damage = damage, limit = 100 } }
  end

  if cmd == "add" then
    local kind, group, id = tokens[2], tokens[3], tokens[4]
    if kind ~= "item" and kind ~= "fluid" then
      return false, "Kind must be item or fluid", false
    end
    if not group or not cfg.groups[group] then
      return false, "Unknown group: " .. tostring(group), false
    end
    if not id or id == "" then return false, "Missing resource id", false end
    if M.findResource(cfg, id) then return false, "Resource already exists: " .. id, false end

    local kv, err = parseKV(tokens, 5)
    if not kv then return false, err, false end
    local r = { id = id, kind = kind, group = group }
    local ok, applyErr = applyKV(r, kv, RESOURCE_FIELDS)
    if not ok then return false, applyErr, false end
    if not r.label and not r.name then
      return false, "Resource needs label=... and/or name=...", false
    end
    table.insert(cfg.resources, r)
    return true, "Added resource " .. id, true
  end

  if cmd == "update" then
    local id = tokens[2]
    local r = id and M.findResource(cfg, id) or nil
    if not r then return false, "Unknown resource: " .. tostring(id), false end
    local kv, err = parseKV(tokens, 3)
    if not kv then return false, err, false end
    local ok, applyErr = applyKV(r, kv, RESOURCE_FIELDS)
    if not ok then return false, applyErr, false end
    if r.group and not cfg.groups[r.group] then
      return false, "Unknown group: " .. tostring(r.group), false
    end
    if not r.label and not r.name then
      return false, "Resource needs label=... and/or name=...", false
    end
    return true, "Updated resource " .. id, true
  end

  if cmd == "remove" then
    local id = tokens[2]
    local _, index
    if id then _, index = M.findResource(cfg, id) end
    if not index then return false, "Unknown resource: " .. tostring(id), false end
    table.remove(cfg.resources, index)
    return true, "Removed resource " .. id, true
  end

  if cmd == "group" then
    local sub, id = tokens[2], tokens[3]
    if sub == "add" then
      if not id or id == "" then return false, "Missing group id", false end
      if cfg.groups[id] then return false, "Group already exists: " .. id, false end
      local kv, err = parseKV(tokens, 4)
      if not kv then return false, err, false end
      local g = { display = id, webhook = "", alertWebhook = "", reportInterval = 1800, alertRepeatInterval = 7200, mention = "" }
      local ok, applyErr = applyKV(g, kv, GROUP_FIELDS)
      if not ok then return false, applyErr, false end
      cfg.groups[id] = g
      return true, "Added group " .. id, true
    elseif sub == "update" then
      local g = id and cfg.groups[id]
      if not g then return false, "Unknown group: " .. tostring(id), false end
      local kv, err = parseKV(tokens, 4)
      if not kv then return false, err, false end
      local ok, applyErr = applyKV(g, kv, GROUP_FIELDS)
      if not ok then return false, applyErr, false end
      return true, "Updated group " .. id, true
    elseif sub == "remove" then
      local g = id and cfg.groups[id]
      if not g then return false, "Unknown group: " .. tostring(id), false end
      local force = false
      if tokens[4] then
        local v = tostring(tokens[4]):match("^force=(.*)$")
        if v then force = boolValue(v) == true end
      end
      for _, r in ipairs(cfg.resources) do
        if r.group == id and not force then
          return false, "Group still has resources; move/remove them or use force=true", false
        end
      end
      if force then
        for i = #cfg.resources, 1, -1 do
          if cfg.resources[i].group == id then table.remove(cfg.resources, i) end
        end
      end
      cfg.groups[id] = nil
      return true, "Removed group " .. id, true
    else
      return false, "Usage: group <add|update|remove> <id> ...", false
    end
  end

  if cmd == "screen" then
    local sub, id = tostring(tokens[2] or ""):lower(), tokens[3]

    if sub == "list" then
      return true, screenListText(cfg), false
    end

    if sub == "scan" then
      return true, "Scanning connected screen/GPU components...", false, { screenScan = true }
    end

    if sub == "add" then
      if not id or id == "" then return false, "Missing screen id", false end
      if cfg.screens[id] then return false, "Screen already exists: " .. id, false end
      local kv, err = parseKV(tokens, 4)
      if not kv then return false, err, false end
      local d = {
        screen = "", gpu = "", group = "*", title = id,
        enabled = true, pageInterval = 10,
      }
      local ok, applyErr = applyKV(d, kv, SCREEN_FIELDS)
      if not ok then return false, applyErr, false end
      if d.screen == "" or d.gpu == "" then
        return false, "screen add requires screen=<address> and gpu=<address>", false
      end
      if d.group ~= "*" and not cfg.groups[d.group] then
        return false, "Unknown group: " .. tostring(d.group), false
      end
      if tonumber(d.pageInterval) and tonumber(d.pageInterval) < 1 then
        return false, "pageInterval must be at least 1 second", false
      end
      cfg.screens[id] = d
      return true, "Added dashboard screen " .. id, true
    end

    if sub == "update" then
      local d = id and cfg.screens[id]
      if not d then return false, "Unknown screen: " .. tostring(id), false end
      local kv, err = parseKV(tokens, 4)
      if not kv then return false, err, false end
      local ok, applyErr = applyKV(d, kv, SCREEN_FIELDS)
      if not ok then return false, applyErr, false end
      if not d.screen or d.screen == "" or not d.gpu or d.gpu == "" then
        return false, "Dashboard screen requires both screen= and gpu=", false
      end
      if d.group ~= "*" and not cfg.groups[d.group] then
        return false, "Unknown group: " .. tostring(d.group), false
      end
      if tonumber(d.pageInterval) and tonumber(d.pageInterval) < 1 then
        return false, "pageInterval must be at least 1 second", false
      end
      return true, "Updated dashboard screen " .. id, true
    end

    if sub == "remove" then
      if not id or not cfg.screens[id] then
        return false, "Unknown screen: " .. tostring(id), false
      end
      cfg.screens[id] = nil
      return true, "Removed dashboard screen " .. id, true
    end

    return false, "Usage: screen <list|scan|add|update|remove> ...", false
  end

  if cmd == "settings" then
    local kv, err = parseKV(tokens, 2)
    if not kv then return false, err, false end
    local ok, applyErr = applyKV(cfg.settings, kv, SETTINGS_FIELDS)
    if not ok then return false, applyErr, false end
    return true, "Updated monitor settings", true
  end

  if cmd == "discord" then
    cfg.settings.discord = cfg.settings.discord or {}
    local kv, err = parseKV(tokens, 2)
    if not kv then return false, err, false end
    local ok, applyErr = applyKV(cfg.settings.discord, kv, DISCORD_FIELDS)
    if not ok then return false, applyErr, false end
    return true, "Updated Discord administration settings", true
  end

  if cmd == "discord-admin" then
    cfg.settings.discord = cfg.settings.discord or {}
    cfg.settings.discord.adminUserIds = cfg.settings.discord.adminUserIds or {}
    local sub, userId = tokens[2], tostring(tokens[3] or "")
    if userId == "" then return false, "Missing Discord user ID", false end
    if sub == "add" then
      for _, v in ipairs(cfg.settings.discord.adminUserIds) do
        if tostring(v) == userId then return true, "Admin already present", false end
      end
      table.insert(cfg.settings.discord.adminUserIds, userId)
      return true, "Added Discord admin " .. userId, true
    elseif sub == "remove" then
      for i = #cfg.settings.discord.adminUserIds, 1, -1 do
        if tostring(cfg.settings.discord.adminUserIds[i]) == userId then
          table.remove(cfg.settings.discord.adminUserIds, i)
          return true, "Removed Discord admin " .. userId, true
        end
      end
      return false, "Discord admin not found: " .. userId, false
    end
    return false, "Usage: discord-admin <add|remove> <userId>", false
  end

  if cmd == "report" then
    local group = tokens[2] or "*"
    if group ~= "*" and not cfg.groups[group] then
      return false, "Unknown group: " .. tostring(group), false
    end
    return true, "Report requested for " .. group, false, { report = group }
  end

  return false, "Unknown command: " .. cmd .. "\n" .. M.helpText(""), false
end

----------------------------------------------------------------------
-- Screen/GPU discovery
----------------------------------------------------------------------

function M.scanScreens()
  local component = require("component")
  local lines = {
    "Connected OpenComputers display hardware:",
    "",
    "Screens:"
  }

  local primaryGpuAddress = nil
  local primaryScreenAddress = nil
  if component.isAvailable("gpu") then
    local okGpu, primaryGpu = pcall(function() return component.gpu end)
    if okGpu and primaryGpu then
      primaryGpuAddress = primaryGpu.address
      local okScreen, bound = pcall(primaryGpu.getScreen)
      if okScreen then primaryScreenAddress = bound end
    end
  end

  local screenCount = 0
  for address in component.list("screen") do
    screenCount = screenCount + 1
    local keyboardText = ""
    local proxy = component.proxy(address)
    if proxy and type(proxy.getKeyboards) == "function" then
      local ok, keyboards = pcall(proxy.getKeyboards)
      if ok and type(keyboards) == "table" and #keyboards > 0 then
        keyboardText = " keyboards=" .. tostring(#keyboards)
      end
    end
    local primary = address == primaryScreenAddress and " [PRIMARY TERMINAL]" or ""
    lines[#lines + 1] = "  " .. address .. keyboardText .. primary
  end
  if screenCount == 0 then lines[#lines + 1] = "  (none)" end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "GPUs:"
  local gpuCount = 0
  for address in component.list("gpu") do
    gpuCount = gpuCount + 1
    local proxy = component.proxy(address)
    local bound = "unbound"
    if proxy and type(proxy.getScreen) == "function" then
      local ok, value = pcall(proxy.getScreen)
      if ok and value then bound = tostring(value) end
    end
    local primary = address == primaryGpuAddress and " [PRIMARY TERMINAL]" or ""
    lines[#lines + 1] = "  " .. address .. " bound=" .. bound .. primary
  end
  if gpuCount == 0 then lines[#lines + 1] = "  (none)" end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "Use a non-primary GPU for dashboards. One GPU per screen is smoothest;"
  lines[#lines + 1] = "a single dedicated GPU may be shared by multiple dashboard screens."
  return table.concat(lines, "\n")
end

----------------------------------------------------------------------
-- Live AE discovery helpers
----------------------------------------------------------------------

local function lower(value)
  return tostring(value or ""):lower()
end

local function shellQuoted(value)
  local s = tostring(value or "")
  s = s:gsub("\\", "\\\\"):gsub('"', '\\"')
  return '"' .. s .. '"'
end

local function humanAmount(value)
  value = tonumber(value) or 0
  local a = math.abs(value)
  local function trim(n)
    return string.format("%.2f", n):gsub("0+$", ""):gsub("%.$", "")
  end
  if a >= 1e15 then return trim(value / 1e15) .. "P" end
  if a >= 1e12 then return trim(value / 1e12) .. "T" end
  if a >= 1e9 then return trim(value / 1e9) .. "B" end
  if a >= 1e6 then return trim(value / 1e6) .. "M" end
  if a >= 1e3 then return trim(value / 1e3) .. "k" end
  return tostring(math.floor(value + 0.5))
end

function M.getME(cfg)
  local component = require("component")
  local address = cfg and cfg.settings and cfg.settings.meAddress or ""

  if address and address ~= "" then
    local proxy = component.proxy(address)
    if not proxy then
      return nil, "Configured ME component not found: " .. tostring(address)
    end
    return proxy
  end

  if not component.isAvailable("me_interface") then
    return nil, "No me_interface found. Put an OC Adapter adjacent to an AE2 ME Interface."
  end

  return component.me_interface
end

local function rowFromStack(stack, kind)
  stack = stack or {}

  if kind == "item" then
    return {
      kind = "item",
      name = tostring(stack.name or ""),
      label = tostring(stack.label or ""),
      damage = tonumber(stack.damage) or 0,
      amount = tonumber(stack.size) or 0,
    }
  end

  return {
    kind = "fluid",
    name = tostring(stack.name or ""),
    label = tostring(stack.label or ""),
    amount = tonumber(stack.amount) or tonumber(stack.size) or 0,
  }
end

local function mergeRows(stacks, kind)
  local merged = {}

  for _, stack in ipairs(stacks or {}) do
    local row = rowFromStack(stack, kind)
    local key

    if kind == "item" then
      key = row.name .. "\0" .. tostring(row.damage) .. "\0" .. row.label
    else
      key = row.name .. "\0" .. row.label
    end

    local existing = merged[key]
    if existing then
      existing.amount = existing.amount + row.amount
    else
      merged[key] = row
    end
  end

  local rows = {}
  for _, row in pairs(merged) do
    rows[#rows + 1] = row
  end
  return rows
end

local function simpleTitleCase(value)
  return (tostring(value or ""):gsub("(%a)([%w_']*)", function(first, rest)
    return first:upper() .. rest:lower()
  end))
end

local function tryExactItemLookup(me, query)
  local rows = {}
  local seen = {}

  local function addStacks(stacks)
    for _, row in ipairs(mergeRows(stacks, "item")) do
      local key = row.name .. "\0" .. tostring(row.damage) .. "\0" .. row.label
      if not seen[key] then
        seen[key] = true
        rows[#rows + 1] = row
      end
    end
  end

  -- Registry IDs can be looked up without materializing the whole ME network.
  -- GTNH OpenComputers exposes getItemsInNetworkById for this purpose.
  if tostring(query):find(":", 1, true) and type(me.getItemsInNetworkById) == "function" then
    local ok, stacks = pcall(me.getItemsInNetworkById, { tostring(query) })
    if ok and type(stacks) == "table" then
      addStacks(stacks)
    end
  end

  -- Human-readable labels can be filtered before the result is returned to
  -- the OC computer. Try the input exactly and a simple title-case variant,
  -- which makes `find item "iron bar"` useful for labels such as "Iron Bar".
  local labels = { tostring(query) }
  local title = simpleTitleCase(query)
  if title ~= labels[1] then labels[#labels + 1] = title end

  for _, label in ipairs(labels) do
    local ok, stacks = pcall(me.getItemsInNetwork, { label = label })
    if ok and type(stacks) == "table" then
      addStacks(stacks)
    end
  end

  return rows
end

local function tryExactItemInspect(me, name, damage)
  -- Prefer GTNH's direct/item-ID lookup APIs. These do not return an
  -- unfiltered table containing every item in the ME network.
  if tostring(name):find(":", 1, true) then
    if damage ~= nil and type(me.getItemInNetwork) == "function" then
      local ok, stack = pcall(me.getItemInNetwork, tostring(name), tonumber(damage) or 0)
      if ok and type(stack) == "table" then
        return { rowFromStack(stack, "item") }
      end
    end

    if type(me.getItemsInNetworkById) == "function" then
      local ok, stacks = pcall(me.getItemsInNetworkById, { tostring(name) })
      if ok and type(stacks) == "table" then
        local rows = mergeRows(stacks, "item")
        if damage == nil then return rows end

        local filtered = {}
        for _, row in ipairs(rows) do
          if tonumber(row.damage) == tonumber(damage) then
            filtered[#filtered + 1] = row
          end
        end
        return filtered
      end
    end
  end

  -- Fall back to an exact label filter, which is still memory-safe for the OC.
  local ok, stacks = pcall(me.getItemsInNetwork, { label = tostring(name) })
  if not ok then return nil, tostring(stacks) end

  local rows = mergeRows(stacks, "item")
  if damage == nil then return rows end

  local filtered = {}
  for _, row in ipairs(rows) do
    if tonumber(row.damage) == tonumber(damage) then
      filtered[#filtered + 1] = row
    end
  end
  return filtered
end

local function fluidRows(me)
  local ok, stacks = pcall(me.getFluidsInNetwork)
  if not ok then return nil, tostring(stacks) end
  return mergeRows(stacks, "fluid")
end

local function exactFluidInspect(me, name)
  if type(me.getFluidInNetwork) == "function" then
    local ok, stack = pcall(me.getFluidInNetwork, tostring(name))
    if ok and type(stack) == "table" then
      return { rowFromStack(stack, "fluid") }
    end
  end

  -- Older OC builds do not expose getFluidInNetwork. Their only fluid API
  -- returns the complete fluid list, so retain that as a compatibility fallback.
  local rows, err = fluidRows(me)
  if not rows then return nil, err end

  local wanted = lower(name)
  local matches = {}
  for _, row in ipairs(rows) do
    if lower(row.name) == wanted or lower(row.label) == wanted then
      matches[#matches + 1] = row
    end
  end
  return matches
end

local function discoveryScore(row, query)
  local q = lower(query)
  if q == "*" then return 1 end

  local name = lower(row.name)
  local label = lower(row.label)
  local damage = row.damage ~= nil and tostring(row.damage) or ""

  if name == q then return 100 end
  if label == q then return 95 end
  if damage == q then return 90 end
  if name:find(q, 1, true) then return 70 end
  if label:find(q, 1, true) then return 65 end
  if damage:find(q, 1, true) then return 50 end
  return nil
end

local function matcherText(row)
  if row.kind == "item" then
    return "name=" .. shellQuoted(row.name) .. " damage=" .. tostring(row.damage or 0)
  end
  return "name=" .. shellQuoted(row.name)
end

local function addTemplate(row)
  local display = row.label ~= "" and row.label or row.name
  if row.kind == "item" then
    return "resmonctl add item <group> <id> " .. matcherText(row) ..
      " display=" .. shellQuoted(display) .. " min=<amount> target=<amount>"
  end
  return "resmonctl add fluid <group> <id> " .. matcherText(row) ..
    " display=" .. shellQuoted(display) .. " unit=L min=<amount> target=<amount>"
end

function M.performDiscovery(me, request)
  request = request or {}
  local kind = tostring(request.kind or ""):lower()
  local limit = math.max(1, math.min(100, tonumber(request.limit) or 25))
  local matches = {}
  local totalMatches = 0

  local function sortMatches()
    table.sort(matches, function(a, b)
      if a._score ~= b._score then return a._score > b._score end
      local al, bl = lower(a.label), lower(b.label)
      if al ~= bl then return al < bl end
      local an, bn = lower(a.name), lower(b.name)
      if an ~= bn then return an < bn end
      return tonumber(a.damage or 0) < tonumber(b.damage or 0)
    end)
  end

  local function offer(row, score)
    if not score then return end
    totalMatches = totalMatches + 1
    row._score = score
    matches[#matches + 1] = row

    -- Discovery only needs the best N rows for display. Keeping the complete
    -- match set defeats the point of streaming on large AE networks.
    if #matches > limit then
      sortMatches()
      while #matches > limit do
        table.remove(matches)
      end
    end
  end

  if kind == "item" then
    if request.mode == "inspect" then
      local rows, err = tryExactItemInspect(me, request.name, request.damage)
      if not rows then return nil, err end

      for _, row in ipairs(rows) do
        offer(row, 100)
      end
    else
      local query = tostring(request.query or "")

      -- First try memory-safe exact lookups. Most discovery is done with a
      -- visible item label, so this avoids walking the network entirely.
      local exactRows = tryExactItemLookup(me, query)
      if #exactRows > 0 then
        for _, row in ipairs(exactRows) do
          offer(row, discoveryScore(row, query) or 100)
        end
      else
        -- Fuzzy/substring discovery must inspect the network. NEVER call
        -- getItemsInNetwork() without a filter here: on large GTNH networks
        -- the returned Lua table can exceed even T3.5 OC memory.
        --
        -- allItems() streams one stack at a time, so the OC only retains the
        -- matching top-N rows. This command is intentionally one-shot; do not
        -- use this iterator in the monitor's periodic polling loop.
        if type(me.allItems) ~= "function" then
          return nil,
            "No exact item match and this OpenComputers build has no allItems() iterator. " ..
            "Retry with the exact in-game label/capitalization or an internal registry ID."
        end

        local okIterator, iterator = pcall(me.allItems)
        if not okIterator or type(iterator) ~= "function" then
          return nil, "Could not open AE item iterator: " .. tostring(iterator)
        end

        while true do
          local okNext, stack = pcall(iterator)
          if not okNext then
            return nil, "AE item iterator failed: " .. tostring(stack)
          end
          if stack == nil then break end

          local row = rowFromStack(stack, "item")
          offer(row, discoveryScore(row, query))
        end
      end
    end

  elseif kind == "fluid" then
    local rows, err

    if request.mode == "inspect" then
      rows, err = exactFluidInspect(me, request.name)
    else
      -- Current GTNH OC exposes a direct fluid lookup only when the internal
      -- fluid name is already known. Fuzzy fluid discovery still needs the
      -- fluid list; unlike items, OC does not expose an allFluids iterator.
      if type(me.getFluidInNetwork) == "function" then
        local ok, stack = pcall(me.getFluidInNetwork, tostring(request.query or ""))
        if ok and type(stack) == "table" then
          rows = { rowFromStack(stack, "fluid") }
        end
      end

      if not rows then
        rows, err = fluidRows(me)
      end
    end

    if not rows then return nil, err end

    if request.mode == "inspect" then
      for _, row in ipairs(rows) do
        offer(row, 100)
      end
    else
      for _, row in ipairs(rows) do
        offer(row, discoveryScore(row, request.query or ""))
      end
    end

  else
    return nil, "Unknown discovery kind: " .. tostring(kind)
  end

  sortMatches()

  local shown = math.min(#matches, limit)
  local lines = {}

  if request.mode == "inspect" then
    lines[#lines + 1] = "AE " .. kind .. " inspection: " .. tostring(request.name)
  else
    lines[#lines + 1] = "AE " .. kind .. " search: " .. tostring(request.query)
  end

  if totalMatches == 0 then
    lines[#lines + 1] = "No matching " .. kind .. " resources found in the live AE network."
    return table.concat(lines, "\n"), { total = 0, shown = 0 }
  end

  lines[#lines + 1] =
    "Found " .. tostring(totalMatches) .. " match(es); showing " .. tostring(shown) .. "."

  for i = 1, shown do
    local row = matches[i]
    local label = row.label ~= "" and row.label or "(no label)"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "[" .. tostring(i) .. "] " .. label
    lines[#lines + 1] = "  name:   " .. (row.name ~= "" and row.name or "(missing)")

    if row.kind == "item" then
      lines[#lines + 1] = "  damage: " .. tostring(row.damage or 0)
      lines[#lines + 1] = "  stored: " .. humanAmount(row.amount)
    else
      lines[#lines + 1] = "  stored: " .. humanAmount(row.amount) .. " L"
    end

    lines[#lines + 1] = "  matcher: " .. matcherText(row)
    lines[#lines + 1] = "  add: " .. addTemplate(row)
  end

  if shown < totalMatches then
    lines[#lines + 1] = ""
    lines[#lines + 1] =
      "Narrow the query or add limit=N (maximum 100) to show more."
  end

  return table.concat(lines, "\n"),
    { total = totalMatches, shown = shown }
end

-- Quoted tokenizer for Discord commands.
function M.tokenize(line)
  local out, buf = {}, {}
  local quote, escape = nil, false
  local function flush()
    if #buf > 0 then
      table.insert(out, table.concat(buf))
      buf = {}
    end
  end

  for i = 1, #line do
    local c = line:sub(i, i)
    if escape then
      table.insert(buf, c)
      escape = false
    elseif c == "\\" then
      escape = true
    elseif quote then
      if c == quote then quote = nil else table.insert(buf, c) end
    elseif c == '"' or c == "'" then
      quote = c
    elseif c:match("%s") then
      flush()
    else
      table.insert(buf, c)
    end
  end
  if escape then table.insert(buf, "\\") end
  if quote then return nil, "Unclosed quote" end
  flush()
  return out
end

return M
