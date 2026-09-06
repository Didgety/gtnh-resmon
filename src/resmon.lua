local component = require("component")
local computer = require("computer")
local event = require("event")
local fs = require("filesystem")
local serialization = require("serialization")
local common = require("resmon_common")

local STATE_PATH = "/var/lib/resmon.state"

----------------------------------------------------------------------
-- Small JSON implementation (enough for Discord's REST API)
----------------------------------------------------------------------

local json = {}

local function jsonEscape(s)
  s = tostring(s)
  s = s:gsub("\\", "\\\\")
       :gsub('"', '\\"')
       :gsub("\b", "\\b")
       :gsub("\f", "\\f")
       :gsub("\n", "\\n")
       :gsub("\r", "\\r")
       :gsub("\t", "\\t")
  return s:gsub("[%z\1-\31]", function(c)
    return string.format("\\u%04x", string.byte(c))
  end)
end

local function isArray(t)
  local max, count = 0, 0
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then return false end
    if k > max then max = k end
    count = count + 1
  end
  return max == count
end

function json.encode(v)
  local tv = type(v)
  if tv == "nil" then return "null" end
  if tv == "boolean" then return v and "true" or "false" end
  if tv == "number" then
    if v ~= v or v == math.huge or v == -math.huge then return "null" end
    return tostring(v)
  end
  if tv == "string" then return '"' .. jsonEscape(v) .. '"' end
  if tv ~= "table" then error("cannot JSON encode " .. tv) end

  local parts = {}
  if isArray(v) then
    for i = 1, #v do parts[#parts + 1] = json.encode(v[i]) end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  for k, value in pairs(v) do
    parts[#parts + 1] = json.encode(tostring(k)) .. ":" .. json.encode(value)
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function utf8char(cp)
  if cp <= 0x7F then
    return string.char(cp)
  elseif cp <= 0x7FF then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + (cp % 0x40))
  elseif cp <= 0xFFFF then
    return string.char(
      0xE0 + math.floor(cp / 0x1000),
      0x80 + (math.floor(cp / 0x40) % 0x40),
      0x80 + (cp % 0x40)
    )
  end
  return "?"
end

function json.decode(text)
  local i, n = 1, #text

  local function skip()
    while i <= n and text:sub(i, i):match("%s") do i = i + 1 end
  end

  local parseValue

  local function parseString()
    if text:sub(i, i) ~= '"' then error("expected string at " .. i) end
    i = i + 1
    local out = {}
    while i <= n do
      local c = text:sub(i, i)
      if c == '"' then
        i = i + 1
        return table.concat(out)
      elseif c == "\\" then
        i = i + 1
        local e = text:sub(i, i)
        local map = { ['"']='"', ['\\']='\\', ['/']='/', b='\b', f='\f', n='\n', r='\r', t='\t' }
        if map[e] then
          out[#out + 1] = map[e]
          i = i + 1
        elseif e == "u" then
          local hex = text:sub(i + 1, i + 4)
          local cp = tonumber(hex, 16)
          if not cp then error("bad unicode escape at " .. i) end
          out[#out + 1] = utf8char(cp)
          i = i + 5
        else
          error("bad escape at " .. i)
        end
      else
        out[#out + 1] = c
        i = i + 1
      end
    end
    error("unterminated string")
  end

  local function parseNumber()
    local start = i
    while i <= n and text:sub(i, i):match("[%d%+%-%e%E%.]") do i = i + 1 end
    local num = tonumber(text:sub(start, i - 1))
    if num == nil then error("bad number at " .. start) end
    return num
  end

  local function parseArray()
    i = i + 1
    local out = {}
    skip()
    if text:sub(i, i) == "]" then i = i + 1 return out end
    while true do
      out[#out + 1] = parseValue()
      skip()
      local c = text:sub(i, i)
      if c == "]" then i = i + 1 return out end
      if c ~= "," then error("expected , or ] at " .. i) end
      i = i + 1
      skip()
    end
  end

  local function parseObject()
    i = i + 1
    local out = {}
    skip()
    if text:sub(i, i) == "}" then i = i + 1 return out end
    while true do
      skip()
      local key = parseString()
      skip()
      if text:sub(i, i) ~= ":" then error("expected : at " .. i) end
      i = i + 1
      out[key] = parseValue()
      skip()
      local c = text:sub(i, i)
      if c == "}" then i = i + 1 return out end
      if c ~= "," then error("expected , or } at " .. i) end
      i = i + 1
      skip()
    end
  end

  function parseValue()
    skip()
    local c = text:sub(i, i)
    if c == '"' then return parseString() end
    if c == "{" then return parseObject() end
    if c == "[" then return parseArray() end
    if text:sub(i, i + 3) == "true" then i = i + 4 return true end
    if text:sub(i, i + 4) == "false" then i = i + 5 return false end
    if text:sub(i, i + 3) == "null" then i = i + 4 return nil end
    return parseNumber()
  end

  local value = parseValue()
  skip()
  if i <= n then error("trailing JSON at " .. i) end
  return value
end

----------------------------------------------------------------------
-- State/config
----------------------------------------------------------------------

local function ensureParent(path)
  local parent = fs.path(path)
  if parent and parent ~= "" and not fs.exists(parent) then fs.makeDirectory(parent) end
end

local function loadState()
  if not fs.exists(STATE_PATH) then return {} end
  local f = io.open(STATE_PATH, "r")
  if not f then return {} end
  local data = f:read("*a")
  f:close()
  local ok, result = pcall(serialization.unserialize, data)
  return (ok and type(result) == "table") and result or {}
end

local function saveState(state)
  ensureParent(STATE_PATH)
  local f = io.open(STATE_PATH .. ".tmp", "w")
  if not f then return end
  f:write(serialization.serialize(state), "\n")
  f:close()
  if fs.exists(STATE_PATH) then fs.remove(STATE_PATH) end
  fs.rename(STATE_PATH .. ".tmp", STATE_PATH)
end

local cfg, cfgErr = common.loadConfig()
if not cfg then
  io.stderr:write(tostring(cfgErr), "\nRun: resmonctl init\n")
  return
end

local state = loadState()
local histories = {}
local historySignatures = {}
local alertState = {}
local nextReport = {}
local lastSnapshot = nil
local pendingReport = nil

----------------------------------------------------------------------
-- Components
----------------------------------------------------------------------

if not component.isAvailable("internet") then
  error("Internet Card not found")
end
local internet = component.internet

local function getME()
  local address = cfg.settings.meAddress
  if address and address ~= "" then
    local proxy = component.proxy(address)
    if not proxy then error("Configured ME component not found: " .. address) end
    return proxy
  end
  if not component.isAvailable("me_interface") then
    error("No me_interface found. Put an OC Adapter adjacent to an AE2 ME Interface.")
  end
  return component.me_interface
end

local me = getME()

----------------------------------------------------------------------
-- HTTP/Discord
----------------------------------------------------------------------

local function httpRequest(method, url, body, headers)
  headers = headers or {}
  headers["User-Agent"] = headers["User-Agent"] or "GTNH-OC-ResourceMonitor/2.0"

  local handle, reason
  if method == "GET" then
    handle, reason = internet.request(url, nil, headers)
  elseif method == "POST" then
    handle, reason = internet.request(url, body or "", headers)
  else
    return nil, "Unsupported HTTP method in OC build: " .. tostring(method)
  end
  if not handle then return nil, tostring(reason) end

  local deadline = computer.uptime() + (tonumber(cfg.settings.httpTimeout) or 15)
  while true do
    local okConnect, connected = pcall(handle.finishConnect)
    if not okConnect then handle.close() return nil, tostring(connected) end
    if connected then break end
    if computer.uptime() >= deadline then handle.close() return nil, "HTTP connection timed out" end
    os.sleep(0.05)
  end

  local chunks = {}
  while true do
    local okRead, chunk = pcall(handle.read)
    if not okRead then
      handle.close()
      return nil, tostring(chunk)
    end
    if chunk == nil then
      break
    elseif chunk ~= "" then
      chunks[#chunks + 1] = chunk
    else
      if computer.uptime() >= deadline then
        handle.close()
        return nil, "HTTP response timed out"
      end
      os.sleep(0.05)
    end
  end

  local code, message, responseHeaders = handle.response()
  handle.close()
  return {
    code = tonumber(code),
    message = message,
    headers = responseHeaders or {},
    body = table.concat(chunks),
  }
end

local function sendWebhook(url, content)
  if not url or url == "" then return nil, "Webhook is not configured" end
  local payload = json.encode({
    username = cfg.settings.webhookName or "GTNH Resource Monitor",
    content = content,
  })
  local res, err = httpRequest("POST", url, payload, { ["Content-Type"] = "application/json" })
  if not res then return nil, err end
  if res.code and res.code >= 200 and res.code < 300 then return true end
  return nil, "Discord webhook HTTP " .. tostring(res.code) .. ": " .. tostring(res.body)
end

local function sendWebhookChunked(url, content)
  local maxLen = 1850
  while #content > maxLen do
    local part = content:sub(1, maxLen)
    local split = part:match("^.*()\n")
    if not split or split < 500 then split = maxLen end
    local ok, err = sendWebhook(url, content:sub(1, split))
    if not ok then return nil, err end
    content = content:sub(split + 1)
  end
  if #content > 0 then return sendWebhook(url, content) end
  return true
end

local function botHeaders()
  local d = cfg.settings.discord or {}
  return {
    ["Authorization"] = "Bot " .. tostring(d.botToken or ""),
    ["Content-Type"] = "application/json",
  }
end

local function botApi(method, path, bodyTable)
  local d = cfg.settings.discord or {}
  local url = (d.apiBase or "https://discord.com/api/v10") .. path
  local body = bodyTable and json.encode(bodyTable) or nil
  local res, err = httpRequest(method, url, body, botHeaders())
  if not res then return nil, err end
  if res.code and res.code >= 200 and res.code < 300 then
    if res.body == "" then return true end
    local ok, parsed = pcall(json.decode, res.body)
    return ok and parsed or true
  end
  return nil, "Discord API HTTP " .. tostring(res.code) .. ": " .. tostring(res.body)
end

local function botReply(content)
  local channel = tostring((cfg.settings.discord or {}).adminChannelId or "")
  if channel == "" then return nil, "adminChannelId missing" end
  local maxLen = 1850
  while #content > maxLen do
    local part = content:sub(1, maxLen)
    local split = part:match("^.*()\n")
    if not split or split < 500 then split = maxLen end
    local _, err = botApi("POST", "/channels/" .. channel .. "/messages", {
      content = content:sub(1, split),
      allowed_mentions = { parse = {} },
    })
    if err then return nil, err end
    content = content:sub(split + 1)
  end
  local _, err = botApi("POST", "/channels/" .. channel .. "/messages", {
    content = content,
    allowed_mentions = { parse = {} },
  })
  return err and nil or true, err
end

----------------------------------------------------------------------
-- Formatting/trends
----------------------------------------------------------------------

local function trimNumber(value)
  local s = string.format("%.2f", value)
  s = s:gsub("0+$", ""):gsub("%.$", "")
  return s
end

local function humanNumber(value)
  value = tonumber(value) or 0
  local a = math.abs(value)
  if a >= 1e15 then return trimNumber(value / 1e15) .. "P" end
  if a >= 1e12 then return trimNumber(value / 1e12) .. "T" end
  if a >= 1e9 then return trimNumber(value / 1e9) .. "B" end
  if a >= 1e6 then return trimNumber(value / 1e6) .. "M" end
  if a >= 1e3 then return trimNumber(value / 1e3) .. "k" end
  return tostring(math.floor(value + (value >= 0 and 0.5 or -0.5)))
end

local function humanDuration(seconds)
  if not seconds or seconds < 0 then return "--" end
  if seconds < 60 then return "<1m" end
  local minutes = math.floor(seconds / 60 + 0.5)
  if minutes < 60 then return tostring(minutes) .. "m" end
  local hours = math.floor(minutes / 60)
  local remMin = minutes % 60
  if hours < 48 then
    return tostring(hours) .. "h" .. (remMin > 0 and (" " .. remMin .. "m") or "")
  end
  local days = math.floor(hours / 24)
  local remHours = hours % 24
  return tostring(days) .. "d" .. (remHours > 0 and (" " .. remHours .. "h") or "")
end

local function displayName(r)
  return r.display or r.label or r.name or r.id
end

local function unit(r)
  if r.unit and r.unit ~= "" then return " " .. r.unit end
  return ""
end

local function signature(r)
  return table.concat({ tostring(r.kind), tostring(r.label), tostring(r.name), tostring(r.damage) }, "|")
end

local function recordHistory(r, amount, now)
  local id = r.id
  local sig = signature(r)
  if historySignatures[id] ~= sig then
    histories[id] = {}
    historySignatures[id] = sig
  end
  local h = histories[id] or {}
  histories[id] = h
  h[#h + 1] = { t = now, amount = amount }

  local window = tonumber(r.trendWindow) or tonumber(cfg.settings.trendWindow) or 1800
  local cutoff = now - math.max(window * 1.25, window + 60)
  while #h > 2 and h[1].t < cutoff do table.remove(h, 1) end
end

local function trendFor(r, amount, now)
  local h = histories[r.id] or {}
  local window = tonumber(r.trendWindow) or tonumber(cfg.settings.trendWindow) or 1800
  local minSpan = tonumber(r.minTrendSpan) or tonumber(cfg.settings.minTrendSpan) or 300
  local cutoff = now - window
  local oldest = nil
  for _, sample in ipairs(h) do
    if sample.t >= cutoff then oldest = sample break end
  end
  if not oldest and #h > 0 then oldest = h[1] end
  if not oldest then return nil end
  local span = now - oldest.t
  if span < minSpan then return nil end
  return (amount - oldest.amount) / span, span
end

local function metricsFor(row, now)
  if row.error or row.amount == nil then return {} end
  local r = row.resource
  local target = tonumber(r.target) or tonumber(r.min)
  local percent = target and target > 0 and (row.amount / target * 100) or nil
  local rate = trendFor(r, row.amount, now)
  local rateHour = rate and rate * 3600 or nil
  local percentHour = rateHour and target and target > 0 and (rateHour / target * 100) or nil
  local eta = rate and rate < 0 and row.amount > 0 and (row.amount / -rate) or nil
  return { target = target, percent = percent, rate = rate, rateHour = rateHour, percentHour = percentHour, eta = eta }
end

local function resourceLine(row, now)
  local r = row.resource
  local name = displayName(r)
  if row.error then return "⚪ **" .. name .. ":** query error: `" .. tostring(row.error) .. "`" end

  local m = metricsFor(row, now)
  local low = r.min ~= nil and row.amount < tonumber(r.min)
  local icon = low and "🔴" or "🟢"
  local pieces = { icon .. " **" .. name .. ":** " .. humanNumber(row.amount) .. unit(r) }

  if m.target then
    pieces[#pieces + 1] = "/ " .. humanNumber(m.target) .. unit(r) .. " (" .. string.format("%.1f", m.percent) .. "%)"
  end
  if m.rateHour then
    local sign = m.rateHour >= 0 and "+" or ""
    local rateText = sign .. humanNumber(m.rateHour) .. unit(r) .. "/h"
    if m.percentHour then rateText = rateText .. " (" .. string.format("%+.1f", m.percentHour) .. "%/h)" end
    pieces[#pieces + 1] = "| " .. rateText
    if m.eta then pieces[#pieces + 1] = "| depletion ~" .. humanDuration(m.eta) end
  else
    pieces[#pieces + 1] = "| trend warming up"
  end

  return table.concat(pieces, " ")
end

----------------------------------------------------------------------
-- AE queries
----------------------------------------------------------------------

local function matches(stack, r)
  if r.label and stack.label ~= r.label then return false end
  if r.name and stack.name ~= r.name then return false end
  if r.damage ~= nil and tonumber(stack.damage) ~= tonumber(r.damage) then return false end
  return true
end

local function getItemAmount(r)
  local filter = {}
  if r.label then filter.label = r.label end
  if r.name then filter.name = r.name end
  if r.damage ~= nil then filter.damage = r.damage end
  local ok, result = pcall(me.getItemsInNetwork, filter)
  if not ok then return nil, tostring(result) end
  local total = 0
  for _, stack in ipairs(result or {}) do
    if matches(stack, r) then total = total + (tonumber(stack.size) or 0) end
  end
  return total
end

local function readSnapshot(now)
  local rows = {}
  local fluids, fluidErr = nil, nil
  local needsFluids = false
  for _, r in ipairs(cfg.resources or {}) do if r.kind == "fluid" then needsFluids = true break end end
  if needsFluids then
    local ok, result = pcall(me.getFluidsInNetwork)
    if ok then fluids = result or {} else fluidErr = tostring(result) end
  end

  for _, r in ipairs(cfg.resources or {}) do
    local amount, err
    if r.kind == "item" then
      amount, err = getItemAmount(r)
    elseif r.kind == "fluid" then
      if fluidErr then
        err = fluidErr
      else
        amount = 0
        for _, stack in ipairs(fluids or {}) do
          if matches(stack, r) then
            amount = amount + (tonumber(stack.amount) or tonumber(stack.size) or 0)
          end
        end
      end
    else
      err = "unknown resource kind"
    end
    rows[#rows + 1] = { resource = r, amount = amount, error = err }
    if amount ~= nil and not err then recordHistory(r, amount, now) end
  end
  return rows
end

----------------------------------------------------------------------
-- Reporting/alerts
----------------------------------------------------------------------

local function rowsForGroup(snapshot, groupId)
  local out = {}
  for _, row in ipairs(snapshot or {}) do
    if row.resource.group == groupId then out[#out + 1] = row end
  end
  return out
end

local function sendGroupReport(groupId, snapshot, now)
  local g = cfg.groups[groupId]
  if not g then return nil, "Unknown group " .. tostring(groupId) end
  local rows = rowsForGroup(snapshot, groupId)
  local lines = {
    "**" .. tostring(cfg.settings.siteName or "GTNH") .. " — " .. tostring(g.display or groupId) .. "**",
    ""
  }
  if #rows == 0 then lines[#lines + 1] = "_(no monitored resources in this group)_" end
  for _, row in ipairs(rows) do lines[#lines + 1] = resourceLine(row, now) end
  return sendWebhookChunked(g.webhook, table.concat(lines, "\n"))
end

local function processAlerts(snapshot, now)
  local perGroup = {}
  for _, row in ipairs(snapshot or {}) do
    local r = row.resource
    if r.min ~= nil and row.amount ~= nil and not row.error then
      local st = alertState[r.id] or { low = false, lastAlert = -math.huge }
      alertState[r.id] = st
      local min = tonumber(r.min)
      local recover = tonumber(r.recover) or min
      local g = cfg.groups[r.group]
      local repeatEvery = g and tonumber(g.alertRepeatInterval) or 7200
      local eventType = nil

      if not st.low and row.amount < min then
        st.low, st.lastAlert = true, now
        eventType = "LOW"
      elseif st.low and row.amount >= recover then
        st.low = false
        eventType = "RECOVERED"
      elseif st.low and repeatEvery and repeatEvery > 0 and now - st.lastAlert >= repeatEvery then
        st.lastAlert = now
        eventType = "STILL LOW"
      end

      if eventType then
        perGroup[r.group] = perGroup[r.group] or { lines = {}, ping = false }
        local bucket = perGroup[r.group]
        if eventType ~= "RECOVERED" then bucket.ping = true end
        local m = metricsFor(row, now)
        local line = (eventType == "RECOVERED" and "✅" or "🚨") .. " **" .. eventType .. " — " .. displayName(r) .. ":** " .. humanNumber(row.amount) .. unit(r)
        if m.percent then line = line .. " (" .. string.format("%.1f", m.percent) .. "%)" end
        if m.rateHour then
          line = line .. " | " .. string.format("%+.2f", m.rateHour) .. unit(r) .. "/h"
          if m.eta then line = line .. " | depletion ~" .. humanDuration(m.eta) end
        end
        bucket.lines[#bucket.lines + 1] = line
      end
    end
  end

  for groupId, bucket in pairs(perGroup) do
    local g = cfg.groups[groupId]
    if g then
      local webhook = (g.alertWebhook and g.alertWebhook ~= "") and g.alertWebhook or g.webhook
      local lines = { "**" .. tostring(cfg.settings.siteName or "GTNH") .. " — " .. tostring(g.display or groupId) .. " Alert**" }
      if bucket.ping and g.mention and g.mention ~= "" then table.insert(lines, 1, g.mention) end
      for _, line in ipairs(bucket.lines) do lines[#lines + 1] = line end
      local ok, err = sendWebhookChunked(webhook, table.concat(lines, "\n"))
      if not ok then io.stderr:write("Alert send failed for ", groupId, ": ", tostring(err), "\n") end
    end
  end
end

local function sendRequestedReports(which, now)
  if not lastSnapshot then
    lastSnapshot = readSnapshot(now)
    processAlerts(lastSnapshot, now)
  end
  if which == "*" or which == nil then
    for groupId in pairs(cfg.groups or {}) do
      local ok, err = sendGroupReport(groupId, lastSnapshot, now)
      if not ok then io.stderr:write("Report failed for ", groupId, ": ", tostring(err), "\n") end
    end
  else
    local ok, err = sendGroupReport(which, lastSnapshot, now)
    if not ok then io.stderr:write("Report failed for ", tostring(which), ": ", tostring(err), "\n") end
  end
end

----------------------------------------------------------------------
-- Discord administration
----------------------------------------------------------------------

local function snowflakeGreater(a, b)
  a, b = tostring(a or ""), tostring(b or "")
  if #a ~= #b then return #a > #b end
  return a > b
end

local function isAdmin(userId)
  for _, id in ipairs(((cfg.settings.discord or {}).adminUserIds or {})) do
    if tostring(id) == tostring(userId) then return true end
  end
  return false
end

local function initializeDiscordCursor()
  local d = cfg.settings.discord or {}
  if not d.enabled or d.botToken == "" or d.adminChannelId == "" then return end
  if state.discordLastMessageId and state.discordLastMessageId ~= "" then return end
  local messages, err = botApi("GET", "/channels/" .. d.adminChannelId .. "/messages?limit=1")
  if not messages then
    io.stderr:write("Discord cursor init failed: ", tostring(err), "\n")
    return
  end
  if type(messages) == "table" and messages[1] and messages[1].id then
    state.discordLastMessageId = tostring(messages[1].id)
    saveState(state)
  end
end

local function handleDiscordCommand(message, now)
  local d = cfg.settings.discord or {}
  if not message.author or message.author.bot then return end
  local content = tostring(message.content or "")
  local prefix = tostring(d.prefix or "!res")
  if content:sub(1, #prefix) ~= prefix then return end
  if #content > #prefix and not content:sub(#prefix + 1, #prefix + 1):match("%s") then return end
  if not isAdmin(message.author.id) then return end

  local rest = content:sub(#prefix + 1):gsub("^%s+", "")
  local tokens, tokErr = common.tokenize(rest)
  if not tokens then botReply("Command parse error: " .. tostring(tokErr)) return end
  if #tokens == 0 then tokens = { "help" } end

  local ok, msg, changed, action = common.applyCommand(cfg, tokens)
  if not ok then
    -- applyCommand may have touched the in-memory table before detecting a bad
    -- value; reload the persisted config to keep failed commands transactional.
    local fresh = common.loadConfig()
    if fresh then cfg = fresh end
    botReply("❌ " .. msg)
    return
  end

  if changed then
    local saved, saveErr = common.saveConfig(cfg)
    if not saved then
      botReply("❌ Could not save config: " .. tostring(saveErr))
      local fresh = common.loadConfig()
      if fresh then cfg = fresh end
      return
    end
  end

  botReply("✅ " .. msg)
  if action and action.report then sendRequestedReports(action.report, now) end
end

local function pollDiscord(now)
  local d = cfg.settings.discord or {}
  if not d.enabled or d.botToken == "" or d.adminChannelId == "" then return end
  initializeDiscordCursor()
  local path = "/channels/" .. d.adminChannelId .. "/messages?limit=100"
  if state.discordLastMessageId and state.discordLastMessageId ~= "" then
    path = path .. "&after=" .. state.discordLastMessageId
  end
  local messages, err = botApi("GET", path)
  if not messages then
    io.stderr:write("Discord command poll failed: ", tostring(err), "\n")
    return
  end
  if type(messages) ~= "table" then return end

  table.sort(messages, function(a, b) return snowflakeGreater(b.id, a.id) end)
  local newest = state.discordLastMessageId
  for _, message in ipairs(messages) do
    handleDiscordCommand(message, now)
    if not newest or snowflakeGreater(message.id, newest) then newest = tostring(message.id) end
  end
  if newest and newest ~= state.discordLastMessageId then
    state.discordLastMessageId = newest
    saveState(state)
  end
end

----------------------------------------------------------------------
-- Main scheduler
----------------------------------------------------------------------

local function initializeReportSchedule(now)
  for id, g in pairs(cfg.groups or {}) do
    if nextReport[id] == nil then
      local interval = tonumber(g.reportInterval) or 1800
      nextReport[id] = cfg.settings.reportOnStart and now or (now + interval)
    end
  end
end

local function reloadConfigIfChanged()
  local fresh, err = common.loadConfig()
  if not fresh then
    io.stderr:write("Config reload failed: ", tostring(err), "\n")
    return false
  end
  if tonumber(fresh.revision) ~= tonumber(cfg.revision) then
    local oldME = tostring(cfg.settings.meAddress or "")
    cfg = fresh
    if tostring(cfg.settings.meAddress or "") ~= oldME then me = getME() end
    print("Reloaded config revision " .. tostring(cfg.revision))
    return true
  end
  return false
end

local function checkTerminalReportRequest(now)
  if not fs.exists(common.REPORT_REQUEST_PATH) then return end
  local f = io.open(common.REPORT_REQUEST_PATH, "r")
  local which = f and f:read("*l") or "*"
  if f then f:close() end
  fs.remove(common.REPORT_REQUEST_PATH)
  sendRequestedReports((which and which ~= "") and which or "*", now)
end

print("GTNH Resource Monitor v2")
print("Config: " .. common.CONFIG_PATH)
print("Ctrl+C to stop. resmonctl changes hot-reload automatically.")

local now = computer.uptime()
initializeReportSchedule(now)
initializeDiscordCursor()

local nextAEPoll = now
local nextConfigReload = now + (tonumber(cfg.settings.configReloadInterval) or 5)
local nextDiscordPoll = now + 1

while true do
  now = computer.uptime()
  initializeReportSchedule(now)

  if now >= nextConfigReload then
    if reloadConfigIfChanged() then
      -- New/updated resources are sampled immediately rather than waiting for
      -- the old polling deadline.
      nextAEPoll = now
    end
    nextConfigReload = now + (tonumber(cfg.settings.configReloadInterval) or 5)
  end

  checkTerminalReportRequest(now)

  if now >= nextAEPoll then
    lastSnapshot = readSnapshot(now)
    processAlerts(lastSnapshot, now)

    for id, g in pairs(cfg.groups or {}) do
      if now >= (nextReport[id] or now) then
        local ok, err = sendGroupReport(id, lastSnapshot, now)
        if not ok then io.stderr:write("Report failed for ", id, ": ", tostring(err), "\n") end
        nextReport[id] = now + (tonumber(g.reportInterval) or 1800)
      end
    end

    nextAEPoll = now + (tonumber(cfg.settings.pollInterval) or 60)
    print(string.format("[%.0fs] AE resource check complete (%d resources)", now, #(cfg.resources or {})))
  end

  local d = cfg.settings.discord or {}
  if d.enabled and now >= nextDiscordPoll then
    pollDiscord(now)
    nextDiscordPoll = now + (tonumber(d.pollInterval) or 15)
  elseif not d.enabled then
    nextDiscordPoll = now + 5
  end

  event.pull(0.5)
end
