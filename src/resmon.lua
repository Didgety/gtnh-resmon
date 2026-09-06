local component = require("component")
local computer = require("computer")
local event = require("event")
local fs = require("filesystem")
local serialization = require("serialization")
local unicode = require("unicode")
local common = require("resmon_common")

local STATE_PATH = "/var/lib/resmon.state"
local PROGRAM_VERSION = common.getVersion()

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
local snapshotSerial = 0
local lastDaemonError = nil

----------------------------------------------------------------------
-- Logging
----------------------------------------------------------------------

local ERROR_LOG_PATH = "/var/log/resmon.log"

local function joinArgs(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[#parts + 1] = tostring(select(i, ...))
  end
  return table.concat(parts)
end

local function consoleLoggingEnabled()
  return not cfg.settings or cfg.settings.consoleLog ~= false
end

local function infoLog(...)
  if consoleLoggingEnabled() then print(joinArgs(...)) end
end

local function errorLog(...)
  local message = joinArgs(...)
  lastDaemonError = message

  -- Always retain daemon errors even when consoleLog=false, so a dedicated
  -- dashboard can be used without losing diagnostics.
  ensureParent(ERROR_LOG_PATH)
  local f = io.open(ERROR_LOG_PATH, "a")
  if f then
    f:write(string.format("[%.0fs] %s\n", computer.uptime(), message))
    f:close()
  end

  if consoleLoggingEnabled() then
    io.stderr:write(message, "\n")
  end
end

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
  headers["User-Agent"] = headers["User-Agent"] or "GTNH-OC-ResourceMonitor/" .. PROGRAM_VERSION

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

local function sendWebhookPayload(url, payloadTable)
  if not url or url == "" then return nil, "Webhook is not configured" end
  payloadTable = payloadTable or {}
  if payloadTable.username == nil then
    payloadTable.username = cfg.settings.webhookName or "GTNH Resource Monitor"
  end
  local payload = json.encode(payloadTable)
  local res, err = httpRequest("POST", url, payload, { ["Content-Type"] = "application/json" })
  if not res then return nil, err end
  if res.code and res.code >= 200 and res.code < 300 then return true end
  return nil, "Discord webhook HTTP " .. tostring(res.code) .. ": " .. tostring(res.body)
end

local function sendWebhook(url, content)
  return sendWebhookPayload(url, { content = content })
end

local function sendWebhookEmbeds(url, content, embeds)
  embeds = embeds or {}
  if #embeds == 0 then return sendWebhook(url, content or "") end

  -- Discord allows multiple embeds per webhook message, but the aggregate
  -- embed character budget is 6000. Sending one bounded embed per request is
  -- simple and avoids a large resource group crossing that shared limit.
  for i, embed in ipairs(embeds) do
    local payload = { embeds = { embed } }
    if i == 1 and content and content ~= "" then payload.content = content end
    local ok, err = sendWebhookPayload(url, payload)
    if not ok then return nil, err end
  end
  return true
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


-- Discord embed helpers -------------------------------------------------------

local EMBED_COLOR_OK = 0x57F287
local EMBED_COLOR_LOW = 0xED4245
local EMBED_COLOR_WARN = 0xFEE75C
local EMBED_COLOR_INFO = 0x5865F2

local function discordTruncate(value, maxChars)
  value = tostring(value or "")
  maxChars = tonumber(maxChars) or 0
  local len = unicode.len(value) or #value
  if len <= maxChars then return value end
  if maxChars <= 1 then return unicode.sub(value, 1, maxChars) end
  return unicode.sub(value, 1, maxChars - 1) .. "…"
end

local function progressBar(percent, width)
  if percent == nil then return nil end
  width = math.max(5, math.min(30, math.floor(tonumber(width) or 12)))
  local clamped = math.max(0, math.min(100, tonumber(percent) or 0))
  local filled = math.floor((clamped / 100) * width + 0.5)
  return "`" .. string.rep("█", filled) .. string.rep("░", width - filled) .. "`"
end

local function resourceEmbedField(row, now, group)
  local r = row.resource
  local name = discordTruncate(displayName(r), 220)

  if row.error or row.amount == nil then
    return {
      name = "⚠️ " .. name,
      value = discordTruncate("Query error: `" .. tostring(row.error or "unknown error") .. "`", 1024),
      inline = false,
    }
  end

  local m = metricsFor(row, now)
  local low = r.min ~= nil and row.amount < tonumber(r.min)
  local lines = {}
  local amountText = "**" .. humanNumber(row.amount) .. unit(r) .. "**"

  if m.target and m.percent then
    amountText = amountText .. " / " .. humanNumber(m.target) .. unit(r) ..
      "  •  **" .. string.format("%.1f", m.percent) .. "%**"
  end
  lines[#lines + 1] = amountText

  if group.progressBar == true and m.percent then
    local bar = progressBar(m.percent, group.progressWidth)
    if bar then lines[#lines + 1] = bar .. "  " .. string.format("%.1f%%", m.percent) end
  end

  if m.rateHour then
    local sign = m.rateHour >= 0 and "+" or ""
    local trend = "Trend: **" .. sign .. humanNumber(m.rateHour) .. unit(r) .. "/h**"
    if m.percentHour then trend = trend .. "  (" .. string.format("%+.1f", m.percentHour) .. "%/h)" end
    lines[#lines + 1] = trend
    if m.eta then lines[#lines + 1] = "Depletion ETA: **~" .. humanDuration(m.eta) .. "**" end
  else
    lines[#lines + 1] = "_Trend warming up_"
  end

  return {
    name = (low and "🔴 " or "🟢 ") .. name,
    value = discordTruncate(table.concat(lines, "\n"), 1024),
    inline = false,
  }
end

local function embedCharCount(embed)
  local total = 0
  total = total + (unicode.len(tostring(embed.title or "")) or 0)
  total = total + (unicode.len(tostring(embed.description or "")) or 0)
  if embed.footer then total = total + (unicode.len(tostring(embed.footer.text or "")) or 0) end
  for _, field in ipairs(embed.fields or {}) do
    total = total + (unicode.len(tostring(field.name or "")) or 0)
    total = total + (unicode.len(tostring(field.value or "")) or 0)
  end
  return total
end

local function reportSummary(rows)
  local low, errors = 0, 0
  for _, row in ipairs(rows or {}) do
    if row.error or row.amount == nil then
      errors = errors + 1
    elseif row.resource.min ~= nil and row.amount < tonumber(row.resource.min) then
      low = low + 1
    end
  end
  return low, errors
end

local function buildGroupReportEmbeds(groupId, rows, now)
  local g = cfg.groups[groupId]
  local site = tostring(cfg.settings.siteName or "GTNH")
  local groupName = tostring(g.display or groupId)
  local low, errors = reportSummary(rows)
  local color = low > 0 and EMBED_COLOR_LOW or (errors > 0 and EMBED_COLOR_WARN or EMBED_COLOR_OK)
  local summary = tostring(#rows) .. " resource" .. (#rows == 1 and "" or "s") ..
    " • " .. tostring(low) .. " low • " .. tostring(errors) .. " error" .. (errors == 1 and "" or "s")

  if #rows == 0 then
    return {{
      title = discordTruncate(site .. " — " .. groupName, 256),
      description = "_(no monitored resources in this group)_",
      color = EMBED_COLOR_INFO,
      footer = { text = "GTNH Resource Monitor v" .. PROGRAM_VERSION },
    }}
  end

  local embeds = {}
  local current = nil

  local function newEmbed()
    current = {
      title = discordTruncate(site .. " — " .. groupName, 256),
      description = (#embeds == 0) and summary or nil,
      color = color,
      fields = {},
    }
    embeds[#embeds + 1] = current
  end

  newEmbed()
  for _, row in ipairs(rows) do
    local field = resourceEmbedField(row, now, g)
    current.fields[#current.fields + 1] = field

    -- Discord permits 25 fields and 6000 total embed characters. Keep a
    -- little headroom for the page footer and any future formatting changes.
    if #current.fields > 25 or embedCharCount(current) > 5600 then
      table.remove(current.fields)
      newEmbed()
      current.fields[#current.fields + 1] = field
    end
  end

  for i, embed in ipairs(embeds) do
    embed.footer = {
      text = "GTNH Resource Monitor v" .. PROGRAM_VERSION .. " • page " .. tostring(i) .. "/" .. tostring(#embeds)
    }
  end
  return embeds
end

local function alertEventField(event, now, group)
  local row = event.row
  local r = row.resource
  local m = metricsFor(row, now)
  local icon = event.kind == "RECOVERED" and "✅" or "🚨"
  local lines = { "**" .. humanNumber(row.amount) .. unit(r) .. "**" }

  if m.target and m.percent then
    lines[1] = lines[1] .. " / " .. humanNumber(m.target) .. unit(r) ..
      "  •  **" .. string.format("%.1f", m.percent) .. "%**"
  end
  if group.progressBar == true and m.percent then
    lines[#lines + 1] = progressBar(m.percent, group.progressWidth) .. "  " .. string.format("%.1f%%", m.percent)
  end
  if m.rateHour then
    local sign = m.rateHour >= 0 and "+" or ""
    lines[#lines + 1] = "Trend: **" .. sign .. humanNumber(m.rateHour) .. unit(r) .. "/h**"
    if m.eta then lines[#lines + 1] = "Depletion ETA: **~" .. humanDuration(m.eta) .. "**" end
  end

  return {
    name = icon .. " " .. event.kind .. " — " .. discordTruncate(displayName(r), 190),
    value = discordTruncate(table.concat(lines, "\n"), 1024),
    inline = false,
  }
end

local function buildAlertEmbeds(groupId, events, now)
  local g = cfg.groups[groupId]
  local site = tostring(cfg.settings.siteName or "GTNH")
  local groupName = tostring(g.display or groupId)
  local hasLow = false
  for _, event in ipairs(events or {}) do
    if event.kind ~= "RECOVERED" then hasLow = true break end
  end

  local embeds = {}
  local current = nil
  local function newEmbed()
    current = {
      title = discordTruncate(site .. " — " .. groupName .. " Alert", 256),
      color = hasLow and EMBED_COLOR_LOW or EMBED_COLOR_OK,
      fields = {},
    }
    embeds[#embeds + 1] = current
  end

  newEmbed()
  for _, event in ipairs(events or {}) do
    local field = alertEventField(event, now, g)
    current.fields[#current.fields + 1] = field
    if #current.fields > 25 or embedCharCount(current) > 5600 then
      table.remove(current.fields)
      newEmbed()
      current.fields[#current.fields + 1] = field
    end
  end

  for i, embed in ipairs(embeds) do
    embed.footer = { text = "GTNH Resource Monitor v" .. PROGRAM_VERSION .. " • alert " .. tostring(i) .. "/" .. tostring(#embeds) }
  end
  return embeds
end

----------------------------------------------------------------------
-- Dedicated dashboard screens
----------------------------------------------------------------------

local screenRenderState = {}
local screenLastError = {}

local COLOR_BG = 0x000000
local COLOR_TEXT = 0xFFFFFF
local COLOR_HEADER = 0x55FFFF
local COLOR_OK = 0x55FF55
local COLOR_LOW = 0xFF5555
local COLOR_ERR = 0xFFFF55
local COLOR_DIM = 0xAAAAAA

local function ulen(text)
  return unicode.len(tostring(text or "")) or 0
end

local function usub(text, first, last)
  return unicode.sub(tostring(text or ""), first, last)
end

local function fitText(text, width)
  text = tostring(text or "")
  width = math.max(0, tonumber(width) or 0)
  if width == 0 then return "" end
  local len = ulen(text)
  if len > width then
    if width <= 3 then return usub(text, 1, width) end
    return usub(text, 1, width - 3) .. "..."
  end
  return text .. string.rep(" ", width - len)
end

local function clipText(text, width)
  text = tostring(text or "")
  width = math.max(0, tonumber(width) or 0)
  if width == 0 then return "" end

  local len = ulen(text)
  if len > width then
    if width <= 3 then return usub(text, 1, width) end
    return usub(text, 1, width - 3) .. "..."
  end
  return text
end

local function padRight(text, width)
  text = clipText(text, width)
  return text .. string.rep(" ", width - ulen(text))
end

local function padLeft(text, width)
  text = clipText(text, width)
  return string.rep(" ", width - ulen(text)) .. text
end

local function screenProgressBar(percent, width)
  if percent == nil then return string.rep(" ", width) end
  width = math.max(5, math.min(20, math.floor(tonumber(width) or 12)))
  local clamped = math.max(0, math.min(100, tonumber(percent) or 0))
  local filled = math.floor((clamped / 100) * width + 0.5)
  return string.rep("█", filled) .. string.rep("░", width - filled)
end

local function dashboardLayout(width, dashboard)
  local groupId = tostring(dashboard.group or "default")
  local group = cfg.groups[groupId] or cfg.groups.default or {}

  local showBar = group.progressBar == true and width >= 120
  local barWidth = showBar and math.max(5, math.min(20, tonumber(group.progressWidth) or 12)) or 0

  local layout = {
    status = 4,
    amount = 12,
    percent = 7,
    rate = 14,
    eta = 8,
    showBar = showBar,
    bar = barWidth,
  }

  local fixed =
    layout.status + 1 +
    layout.amount + 1 +
    layout.percent + 1 +
    layout.rate + 1 +
    layout.eta

  if showBar then
    fixed = fixed + 1 + layout.bar
  end

  layout.name = math.max(12, width - fixed - 1)
  return layout
end

local function dashboardHeaderText(layout)
  local parts = {
    padRight("STAT", layout.status),
    padRight("RESOURCE / GROUP", layout.name),
    padLeft("AMOUNT", layout.amount),
    padLeft("%", layout.percent),
    padLeft("RATE/H", layout.rate),
    padLeft("ETA", layout.eta),
  }

  if layout.showBar then
    parts[#parts + 1] = padRight("BAR", layout.bar)
  end

  return table.concat(parts, " ")
end

local function resolveComponentAddress(value, expectedType)
  value = tostring(value or "")
  if value == "" then return nil, "missing " .. expectedType .. " address" end

  local okType, actualType = pcall(component.type, value)
  if okType and actualType == expectedType then return value end

  local ok, address = pcall(component.get, value, expectedType)
  if ok and address then return address end
  return nil, "could not resolve " .. expectedType .. " address/prefix '" .. value .. "'"
end

local function dashboardRows(snapshot, dashboard)
  local rows = {}
  local group = tostring(dashboard.group or "*")
  for _, row in ipairs(snapshot or {}) do
    if group == "*" or tostring(row.resource.group) == group then
      rows[#rows + 1] = row
    end
  end

  -- Put low/error resources first, then preserve a predictable name ordering.
  table.sort(rows, function(a, b)
    local function rank(row)
      if row.error or row.amount == nil then return 0 end
      if row.resource.min ~= nil and row.amount < tonumber(row.resource.min) then return 1 end
      return 2
    end
    local ar, br = rank(a), rank(b)
    if ar ~= br then return ar < br end
    return tostring(displayName(a.resource)):lower() < tostring(displayName(b.resource)):lower()
  end)
  return rows
end

local function dashboardStatus(row)
  if row.error or row.amount == nil then return "ERR", COLOR_ERR end
  if row.resource.min ~= nil and row.amount < tonumber(row.resource.min) then
    return "LOW", COLOR_LOW
  end
  return "OK", COLOR_OK
end

local function dashboardResourceName(row, dashboard)
  local name = tostring(displayName(row.resource))
  if tostring(dashboard.group or "*") == "*" then
    local group = cfg.groups[row.resource.group]
    local groupName = group and (group.display or row.resource.group) or row.resource.group
    name = "[" .. tostring(groupName or "?") .. "] " .. name
  end
  return name
end

local function dashboardRowText(row, dashboard, now, width)
  local layout = dashboardLayout(width, dashboard)
  local status = dashboardStatus(row)
  local name = dashboardResourceName(row, dashboard)

  if row.error or row.amount == nil then
    local parts = {
      padRight(status, layout.status),
      padRight(name, layout.name),
      padLeft("--", layout.amount),
      padLeft("--", layout.percent),
      padLeft("ERROR", layout.rate),
      padLeft("--", layout.eta),
    }

    if layout.showBar then
      parts[#parts + 1] = padRight("", layout.bar)
    end

    return table.concat(parts, " ")
  end

  local m = metricsFor(row, now)
  local amount = humanNumber(row.amount) .. unit(row.resource)
  local percent = m.percent and string.format("%.1f%%", m.percent) or "--"

  local rate = "--"
  if m.rateHour then
    local sign = m.rateHour >= 0 and "+" or ""
    rate = sign .. humanNumber(m.rateHour) .. unit(row.resource) .. "/h"
  end

  local eta = m.eta and humanDuration(m.eta) or "--"

  local parts = {
    padRight(status, layout.status),
    padRight(name, layout.name),
    padLeft(amount, layout.amount),
    padLeft(percent, layout.percent),
    padLeft(rate, layout.rate),
    padLeft(eta, layout.eta),
  }

  if layout.showBar then
    local bar = m.percent and screenProgressBar(m.percent, layout.bar) or ""
    parts[#parts + 1] = padRight(bar, layout.bar)
  end

  return table.concat(parts, " ")
end

local function dashboardTitle(id, dashboard)
  if dashboard.title and dashboard.title ~= "" then return tostring(dashboard.title) end
  if dashboard.group and dashboard.group ~= "*" and cfg.groups[dashboard.group] then
    return tostring(cfg.groups[dashboard.group].display or dashboard.group)
  end
  return tostring(cfg.settings.siteName or "GTNH") .. " Resources"
end

local function reportScreenError(id, message)
  message = tostring(message)
  if screenLastError[id] ~= message then
    screenLastError[id] = message
    errorLog("Dashboard '", id, "': ", message)
  end
end

local function renderDashboard(id, dashboard, snapshot, now, force)
  if dashboard.enabled == false then return true end

  local screenAddress, screenErr = resolveComponentAddress(dashboard.screen, "screen")
  if not screenAddress then return nil, screenErr end
  local gpuAddress, gpuErr = resolveComponentAddress(dashboard.gpu, "gpu")
  if not gpuAddress then return nil, gpuErr end

  -- One GPU per dashboard keeps each screen continuously bound and prevents
  -- flicker/clearing during page refreshes. OpenComputers can technically
  -- rebind one GPU between screens, but a bind clears the target screen.
  for otherId, other in pairs(cfg.screens or {}) do
    if otherId ~= id and other and other.enabled ~= false then
      local otherGpu = resolveComponentAddress(other.gpu, "gpu")
      if otherGpu and otherGpu == gpuAddress then
        return nil, "GPU is also assigned to dashboard '" .. tostring(otherId) .. "'; use one dedicated GPU per dashboard"
      end
    end
  end

  -- Never steal the shell's primary GPU. Binding that GPU to another screen
  -- clears/rebinds the interactive terminal, which is exactly what dashboards
  -- are intended to avoid.
  if component.isAvailable("gpu") and component.gpu and gpuAddress == component.gpu.address then
    return nil,
      "configured GPU is the primary terminal GPU; install/use a second GPU for dashboards"
  end

  local gpu = component.proxy(gpuAddress)
  local screen = component.proxy(screenAddress)
  if not gpu or not screen then return nil, "screen or GPU proxy is unavailable" end

  if type(screen.turnOn) == "function" then pcall(screen.turnOn) end

  local okBound, currentScreen = pcall(gpu.getScreen)
  if not okBound or currentScreen ~= screenAddress then
    local ok, reason = gpu.bind(screenAddress, true)
    if not ok then return nil, "GPU bind failed: " .. tostring(reason) end
    force = true
  end

  local okMax, maxW, maxH = pcall(gpu.maxResolution)
  if not okMax or not maxW or not maxH then return nil, "could not read screen resolution" end

  local okRes, currentW, currentH = pcall(gpu.getResolution)
  if not okRes or currentW ~= maxW or currentH ~= maxH then
    local ok, reason = gpu.setResolution(maxW, maxH)
    if not ok then return nil, "could not set screen resolution: " .. tostring(reason) end
    force = true
  end

  local width, height = maxW, maxH
  local rows = dashboardRows(snapshot, dashboard)
  local capacity = math.max(1, height - 4)
  local totalPages = math.max(1, math.ceil(math.max(1, #rows) / capacity))
  local pageInterval = math.max(1, tonumber(dashboard.pageInterval) or 10)
  local page = totalPages > 1 and ((math.floor(now / pageInterval) % totalPages) + 1) or 1

  local previous = screenRenderState[id]
  if not force and previous and
      previous.page == page and
      previous.serial == snapshotSerial and
      previous.revision == tonumber(cfg.revision) then
    return true
  end

  screenRenderState[id] = {
    page = page,
    serial = snapshotSerial,
    revision = tonumber(cfg.revision),
  }
  screenLastError[id] = nil

  pcall(gpu.setBackground, COLOR_BG)
  pcall(gpu.setForeground, COLOR_TEXT)
  gpu.fill(1, 1, width, height, " ")

  pcall(gpu.setForeground, COLOR_HEADER)
  gpu.set(1, 1, fitText(
    tostring(cfg.settings.siteName or "GTNH") .. " - " .. dashboardTitle(id, dashboard),
    width
  ))

  local layout = dashboardLayout(width, dashboard)

  pcall(gpu.setForeground, COLOR_DIM)
  gpu.set(1, 2, dashboardHeaderText(layout))

  if not snapshot then
    pcall(gpu.setForeground, COLOR_TEXT)
    gpu.set(1, 3, fitText("Waiting for first AE sample...", width))
  elseif #rows == 0 then
    pcall(gpu.setForeground, COLOR_TEXT)
    gpu.set(1, 3, fitText("No monitored resources match this dashboard.", width))
  else
    local first = (page - 1) * capacity + 1
    local last = math.min(#rows, first + capacity - 1)
    local y = 3
    for index = first, last do
      local row = rows[index]
      local _, color = dashboardStatus(row)
      pcall(gpu.setForeground, color)
      gpu.set(1, y, dashboardRowText(row, dashboard, now, width))
      y = y + 1
    end
  end

  pcall(gpu.setForeground, COLOR_DIM)
  local footer = string.format(
    "page %d/%d | %d resources | uptime %.0fs",
    page, totalPages, #rows, now
  )
  if lastDaemonError and lastDaemonError ~= "" then
    footer = footer .. " | last error: " .. lastDaemonError
  end
  gpu.set(1, height, fitText(footer, width))
  pcall(gpu.setForeground, COLOR_TEXT)

  return true
end

local function renderScreens(snapshot, now, force)
  local ids = {}
  for id in pairs(cfg.screens or {}) do ids[#ids + 1] = id end
  table.sort(ids)

  for _, id in ipairs(ids) do
    local dashboard = cfg.screens[id]
    if dashboard and dashboard.enabled ~= false then
      local callOk, result, reason = pcall(renderDashboard, id, dashboard, snapshot, now, force)
      if not callOk then
        reportScreenError(id, result)
      elseif not result then
        reportScreenError(id, reason or "unknown rendering error")
      end
    end
  end
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

  if tostring(g.reportStyle or "embed"):lower() == "text" then
    local lines = {
      "**" .. tostring(cfg.settings.siteName or "GTNH") .. " — " .. tostring(g.display or groupId) .. "**",
      ""
    }
    if #rows == 0 then lines[#lines + 1] = "_(no monitored resources in this group)_" end
    for _, row in ipairs(rows) do lines[#lines + 1] = resourceLine(row, now) end
    return sendWebhookChunked(g.webhook, table.concat(lines, "\n"))
  end

  return sendWebhookEmbeds(g.webhook, nil, buildGroupReportEmbeds(groupId, rows, now))
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
        perGroup[r.group] = perGroup[r.group] or { events = {}, ping = false }
        local bucket = perGroup[r.group]
        if eventType ~= "RECOVERED" then bucket.ping = true end
        bucket.events[#bucket.events + 1] = { kind = eventType, row = row }
      end
    end
  end

  for groupId, bucket in pairs(perGroup) do
    local g = cfg.groups[groupId]
    if g then
      local webhook = (g.alertWebhook and g.alertWebhook ~= "") and g.alertWebhook or g.webhook
      local mention = bucket.ping and g.mention and g.mention ~= "" and g.mention or nil
      local ok, err

      if tostring(g.reportStyle or "embed"):lower() == "text" then
        local lines = { "**" .. tostring(cfg.settings.siteName or "GTNH") .. " — " .. tostring(g.display or groupId) .. " Alert**" }
        if mention then table.insert(lines, 1, mention) end

        for _, event in ipairs(bucket.events) do
          local row, r = event.row, event.row.resource
          local m = metricsFor(row, now)
          local line = (event.kind == "RECOVERED" and "✅" or "🚨") ..
            " **" .. event.kind .. " — " .. displayName(r) .. ":** " .. humanNumber(row.amount) .. unit(r)
          if m.percent then line = line .. " (" .. string.format("%.1f", m.percent) .. "%)" end
          if m.rateHour then
            line = line .. " | " .. string.format("%+.2f", m.rateHour) .. unit(r) .. "/h"
            if m.eta then line = line .. " | depletion ~" .. humanDuration(m.eta) end
          end
          lines[#lines + 1] = line
        end
        ok, err = sendWebhookChunked(webhook, table.concat(lines, "\n"))
      else
        ok, err = sendWebhookEmbeds(webhook, mention, buildAlertEmbeds(groupId, bucket.events, now))
      end

      if not ok then errorLog("Alert send failed for ", groupId, ": ", tostring(err)) end
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
      if not ok then errorLog("Report failed for ", groupId, ": ", tostring(err)) end
    end
  else
    local ok, err = sendGroupReport(which, lastSnapshot, now)
    if not ok then errorLog("Report failed for ", tostring(which), ": ", tostring(err)) end
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
    errorLog("Discord cursor init failed: ", tostring(err))
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

  if action and action.screenScan then
    local text, scanErr = common.scanScreens()
    if not text then
      botReply("❌ Display scan failed: " .. tostring(scanErr))
    else
      botReply(text)
    end
    return
  end

  if action and action.discovery then
    local text, discoveryErr = common.performDiscovery(me, action.discovery)
    if not text then
      botReply("❌ AE discovery failed: " .. tostring(discoveryErr))
    else
      botReply(text)
    end
    return
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
    errorLog("Discord command poll failed: ", tostring(err))
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
    errorLog("Config reload failed: ", tostring(err))
    return false
  end
  if tonumber(fresh.revision) ~= tonumber(cfg.revision) then
    local oldME = tostring(cfg.settings.meAddress or "")
    cfg = fresh
    if tostring(cfg.settings.meAddress or "") ~= oldME then me = getME() end
    infoLog("Reloaded config revision ", tostring(cfg.revision))
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

infoLog("GTNH Resource Monitor v" .. PROGRAM_VERSION)
infoLog("Config: ", common.CONFIG_PATH)
infoLog("Ctrl+C to stop. resmonctl changes hot-reload automatically.")

local now = computer.uptime()
initializeReportSchedule(now)
initializeDiscordCursor()

local nextAEPoll = now
local nextConfigReload = now + (tonumber(cfg.settings.configReloadInterval) or 5)
local nextDiscordPoll = now + 1
local nextScreenTick = now

-- Dashboard screens are useful immediately, even before the first AE poll.
renderScreens(nil, now, true)

while true do
  now = computer.uptime()
  initializeReportSchedule(now)

  if now >= nextConfigReload then
    if reloadConfigIfChanged() then
      -- New/updated resources are sampled immediately rather than waiting for
      -- the old polling deadline. Screen configuration also hot-reloads.
      nextAEPoll = now
      renderScreens(lastSnapshot, now, true)
    end
    nextConfigReload = now + (tonumber(cfg.settings.configReloadInterval) or 5)
  end

  checkTerminalReportRequest(now)

  if now >= nextAEPoll then
    lastSnapshot = readSnapshot(now)
    snapshotSerial = snapshotSerial + 1
    processAlerts(lastSnapshot, now)

    for id, g in pairs(cfg.groups or {}) do
      if now >= (nextReport[id] or now) then
        local ok, err = sendGroupReport(id, lastSnapshot, now)
        if not ok then errorLog("Report failed for ", id, ": ", tostring(err)) end
        nextReport[id] = now + (tonumber(g.reportInterval) or 1800)
      end
    end

    nextAEPoll = now + (tonumber(cfg.settings.pollInterval) or 60)
    renderScreens(lastSnapshot, now, true)
    infoLog(string.format("[%.0fs] AE resource check complete (%d resources)", now, #(cfg.resources or {})))
  end

  -- Tick once per second for automatic dashboard pagination. renderScreens is
  -- cheap when neither the page nor the AE snapshot has changed.
  if now >= nextScreenTick then
    renderScreens(lastSnapshot, now, false)
    nextScreenTick = now + 1
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
