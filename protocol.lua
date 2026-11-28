-- Codex app-server protocol constants, helpers, formatters, and process/timer utilities.

local json = require("bazaar.json")
local process = require("bazaar.process")
local secrets = require("bazaar.secrets")
local task = require("bazaar.task")
local time = require("bazaar.time")
local timers = require("bazaar.timers")

local M = {}

M.CLIENT_INFO = { name = "bazaar-plugin-codex", version = "0.4.0-rc.1" }
M.DEFAULT_STARTUP_TIMEOUT_MS = 60000
M.DEFAULT_SHUTDOWN_TIMEOUT_MS = 5000
M.DEFAULT_VERSION_TIMEOUT_MS = 10000
M.DEFAULT_RPC_TIMEOUT_MS = 30000
M.MAX_STDOUT_BUFFER_CHARS = 16 * 1024 * 1024
M.MAX_STDERR_LINE_CHARS = 64 * 1024
M.STDERR_TAIL_LIMIT = 64

M.METHOD_COMMAND_APPROVAL = "item/commandExecution/requestApproval"
M.METHOD_FILE_APPROVAL = "item/fileChange/requestApproval"
M.METHOD_PERMISSIONS_APPROVAL = "item/permissions/requestApproval"
M.METHOD_USER_INPUT = "item/tool/requestUserInput"
M.METHOD_ELICITATION = "mcpServer/elicitation/request"

M.MCP_SCOPE_LABELS = {
  once = "Allow",
  session = "Allow for this session",
  always = "Allow and don't ask me again",
}

M.SKILL_SCOPE_MAP = {
  repo = "workspace",
  user = "personal",
}

M.MCP_CONNECTION_MAP = {
  connected = "connected",
  starting = "connecting",
  notStarted = "connecting",
  disabled = "disabled",
}

M.MCP_AUTH_MAP = {
  unsupported = "none",
  notLoggedIn = "signed_out",
  bearerToken = "signed_in",
  oAuth = "signed_in",
}

M.SKIPPED_ITEM_TYPES = {
  userMessage = true,
  hookPrompt = true,
  agentMessage = true,
  plan = true,
  reasoning = true,
  enteredReviewMode = true,
  exitedReviewMode = true,
}

M.TOOL_TYPE_NAMES = {
  commandExecution = "command",
  fileChange = "file_change",
  mcpToolCall = "mcp_tool",
  dynamicToolCall = "dynamic_tool",
  collabAgentToolCall = "agent",
  subAgentActivity = "agent",
  webSearch = "web_search",
  imageView = "image_view",
  imageGeneration = "image_generation",
  sleep = "sleep",
  functionCallOutput = "function",
}

M.COMMAND_ACTIONS = {
  read = "read",
  listFiles = "list",
  search = "search",
  unknown = "other",
}

M.IMAGE_EXTENSIONS = {
  [".png"] = true,
  [".jpg"] = true,
  [".jpeg"] = true,
  [".gif"] = true,
  [".webp"] = true,
  [".bmp"] = true,
  [".tif"] = true,
  [".tiff"] = true,
  [".heic"] = true,
  [".heif"] = true,
  [".avif"] = true,
}

M.APPROVAL_CANCELLED = {}

local JSON_NULL = json.null
M.JSON_NULL = JSON_NULL

local ARRAY_MT = getmetatable(json.array())

local ERROR_MT = {
  __tostring = function(self)
    return tostring(self.message or self.name or "Error")
  end,
}

function M.isNull(v)
  return v == nil or (JSON_NULL ~= nil and v == JSON_NULL)
end

function M.nullOr(v, fallback)
  if M.isNull(v) then
    return fallback
  end
  return v
end

function M.newArray(tbl)
  return json.array(tbl or {})
end

function M.isArray(v)
  if type(v) ~= "table" then
    return false
  end
  if ARRAY_MT ~= nil and getmetatable(v) == ARRAY_MT then
    return true
  end
  local count = 0
  local maxIdx = 0
  for k in pairs(v) do
    if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then
      return false
    end
    count = count + 1
    if k > maxIdx then
      maxIdx = k
    end
  end
  return count > 0 and maxIdx == count
end

function M.isPlainObject(v)
  return type(v) == "table" and not M.isArray(v)
end

function M.isFiniteNumber(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

function M.isInteger(v)
  return M.isFiniteNumber(v) and math.floor(v) == v
end

function M.truncInt(n)
  local t = n >= 0 and math.floor(n) or math.ceil(n)
  return math.tointeger(t) or t
end

function M.trim(s)
  if M.isNull(s) then
    return ""
  end
  return (tostring(s):gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.toFiniteNumber(v)
  if type(v) == "number" then
    return M.isFiniteNumber(v) and v or nil
  end
  if type(v) == "string" then
    local s = M.trim(v)
    if s == "" then
      return nil
    end
    local n = tonumber(s)
    return M.isFiniteNumber(n) and n or nil
  end
  return nil
end

function M.isNonEmpty(v)
  return not M.isNull(v) and v ~= false and v ~= "" and v ~= 0
end

function M.startsWith(s, prefix)
  return type(s) == "string" and s:sub(1, #prefix) == prefix
end

function M.endsWith(s, suffix)
  return type(s) == "string" and (#suffix == 0 or s:sub(-#suffix) == suffix)
end

function M.listContains(list, target)
  if type(list) ~= "table" then
    return false
  end
  for _, item in ipairs(list) do
    if item == target then
      return true
    end
  end
  return false
end

function M.sortedKeys(tbl)
  local keys = {}
  for k in pairs(tbl) do
    keys[#keys + 1] = k
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  return keys
end

function M.newAppServerError(message, options)
  local opts = type(options) == "table" and options or {}
  return setmetatable({
    __codexError = true,
    name = opts.name or "AppServerError",
    message = tostring(message or ""),
    failureReason = opts.failureReason or "execution",
    code = M.nullOr(opts.code, nil),
    reconcile = opts.reconcile == true,
    isTimeout = opts.isTimeout == true,
  }, ERROR_MT)
end

function M.newAppServerUnavailable(message, options)
  local opts = type(options) == "table" and options or {}
  return M.newAppServerError(message, {
    name = "AppServerUnavailable",
    failureReason = opts.failureReason or "connection_lost",
    reconcile = opts.reconcile ~= nil and (opts.reconcile == true) or true,
    code = opts.code,
    isTimeout = opts.isTimeout == true,
  })
end

function M.newProtocolError(message, options)
  local opts = type(options) == "table" and options or {}
  return M.newAppServerError(message, {
    name = "ProtocolError",
    failureReason = opts.failureReason or "protocol",
    reconcile = opts.reconcile ~= nil and (opts.reconcile == true) or true,
    code = opts.code,
    isTimeout = opts.isTimeout == true,
  })
end

function M.newTimeoutError(message)
  return M.newAppServerError(message, {
    name = "TimeoutError",
    failureReason = "timeout",
    reconcile = true,
    isTimeout = true,
  })
end

function M.errMessage(err)
  if type(err) == "table" and not M.isNull(err.message) then
    return tostring(err.message)
  end
  if M.isNull(err) then
    return ""
  end
  return tostring(err)
end

function M.raiseErr(err)
  error(err, 0)
end

function M.raiseBoundaryErr(err)
  error(M.errMessage(err), 0)
end

function M.toDelayMs(ms)
  local n = M.toFiniteNumber(ms)
  if n == nil or n <= 0 then
    return 0
  end
  local ceiled = math.ceil(n)
  local maxDelay = M.toFiniteNumber(timers.maxDelayMs) or 2147483647
  if ceiled > maxDelay then
    ceiled = maxDelay
  end
  return M.truncInt(ceiled)
end

function M.nowMs()
  if timers.nowMs then
    return timers.nowMs()
  end
  return time.nowMs()
end

local WaitSlot = {}
WaitSlot.__index = WaitSlot

function WaitSlot:resolve(val)
  if self.done then
    return false
  end
  self.done = true
  self.ok = true
  self.value = val
  task.wakeup(self.token, val)
  return true
end

function WaitSlot:reject(err)
  if self.done then
    return false
  end
  self.done = true
  self.ok = false
  self.value = err
  task.interrupt(self.token, err)
  return true
end

function WaitSlot:wait(timeoutMs, timeoutMessage)
  if self.done then
    if self.ok then
      return self.value
    end
    M.raiseErr(self.value)
  end
  local ms = timeoutMs ~= nil and M.toDelayMs(timeoutMs) or nil
  if ms ~= nil and ms <= 0 then
    ms = nil
  end
  local ok, val = pcall(task.wait, self.token, ms)
  if ok then
    return val
  end
  if self.done then
    if self.ok then
      return self.value
    end
    M.raiseErr(self.value)
  end
  if type(val) == "table" and val.__codexError then
    M.raiseErr(val)
  end
  if ms ~= nil then
    self.done = true
    self.ok = false
    local err = M.newTimeoutError(
      timeoutMessage or ("operation timed out after " .. tostring(ms) .. "ms")
    )
    self.value = err
    M.raiseErr(err)
  end
  M.raiseErr(val)
end

function M.newWaitSlot()
  return setmetatable({
    token = {},
    done = false,
    ok = false,
    value = nil,
  }, WaitSlot)
end

function M.withTimeout(fn, timeoutMs, timeoutMessage)
  local ms = M.toDelayMs(timeoutMs)
  if ms <= 0 then
    return fn()
  end
  local slot = M.newWaitSlot()
  task.fork(function()
    local ok, val = pcall(fn)
    if ok then
      slot:resolve(val)
    else
      slot:reject(val)
    end
  end)
  return slot:wait(ms, timeoutMessage)
end

function M.registerSecret(val)
  if type(val) ~= "string" or #M.trim(val) < 4 then
    return
  end
  pcall(function()
    if secrets and secrets.register then
      secrets.register(val)
    end
  end)
end

function M.resolveApiKey(config)
  local raw = ""
  pcall(function()
    if secrets and secrets.get then
      raw = secrets.get("apiKey") or secrets.get("api_key") or ""
    end
  end)
  if M.isNull(raw) or raw == "" then
    if type(config) == "table" then
      raw = M.nullOr(config.apiKey, nil) or M.nullOr(config.api_key, nil) or ""
    else
      raw = ""
    end
  end
  local key = type(raw) == "string" and M.trim(raw) or ""
  if key ~= "" then
    M.registerSecret(key)
  end
  return key
end

function M.resolveStartupTimeoutMs(config, input)
  if type(input) == "table" and not M.isNull(input.startupTimeoutMs) then
    local fromInput = M.toFiniteNumber(input.startupTimeoutMs)
    if fromInput ~= nil and fromInput > 0 then
      return M.toDelayMs(fromInput)
    end
  end
  if type(config) == "table" and not M.isNull(config.startupTimeoutSec) then
    local sec = M.toFiniteNumber(config.startupTimeoutSec)
    if sec ~= nil and sec > 0 then
      return M.toDelayMs(sec * 1000)
    end
  end
  return M.DEFAULT_STARTUP_TIMEOUT_MS
end

function M.resolveShutdownTimeoutMs(config, input)
  if type(input) == "table" and not M.isNull(input.shutdownTimeoutMs) then
    local fromInput = M.toFiniteNumber(input.shutdownTimeoutMs)
    if fromInput ~= nil and fromInput > 0 then
      return M.toDelayMs(fromInput)
    end
  end
  if type(config) == "table" and not M.isNull(config.shutdownTimeoutSec) then
    local sec = M.toFiniteNumber(config.shutdownTimeoutSec)
    if sec ~= nil and sec > 0 then
      return M.toDelayMs(sec * 1000)
    end
  end
  return M.DEFAULT_SHUTDOWN_TIMEOUT_MS
end

function M.joinPath(dir, name)
  if M.isNull(dir) or dir == "" then
    return name
  end
  local hasBack = dir:find("\\", 1, true) ~= nil
  local hasFwd = dir:find("/", 1, true) ~= nil
  local sep = (hasBack and not hasFwd) and "\\" or "/"
  local last = dir:sub(-1)
  if last == "/" or last == "\\" then
    return dir .. name
  end
  return dir .. sep .. name
end

function M.normalizePath(p)
  if M.isNull(p) then
    return ""
  end
  local s = tostring(p):gsub("\\", "/")
  s = s:gsub("/+$", "")
  return s
end

function M.isImagePath(filePath)
  if M.isNull(filePath) then
    return false
  end
  local s = tostring(filePath):lower()
  local ext = s:match("%.[^%.]+$")
  if not ext then
    return false
  end
  return M.IMAGE_EXTENSIONS[ext] == true
end

function M.runCollect(command, args, env, cwd, timeoutMs)
  local execOpts = {
    command = command,
    args = M.newArray(args),
    env = env or {},
  }
  if not M.isNull(cwd) and cwd ~= "" then
    execOpts.cwd = tostring(cwd)
  end
  local tMs = M.toDelayMs(timeoutMs)
  if tMs > 0 then
    execOpts.timeoutMs = tMs
  end

  local ok, resOrErr = pcall(process.exec, execOpts)
  if not ok then
    return { code = -1, stdout = "", stderr = M.errMessage(resOrErr), timedOut = false }
  end

  local res = type(resOrErr) == "table" and resOrErr or {}
  local stdout = not M.isNull(res.stdout) and tostring(res.stdout) or ""
  local stderr = not M.isNull(res.stderr) and tostring(res.stderr) or ""
  local timedOut = res.timedOut == true
  local code = (not M.isNull(res.code) and type(res.code) == "number") and res.code or -1
  if timedOut then
    code = -1
    if stderr == "" then
      stderr = "timeout"
    end
  elseif code ~= 0 and stderr == "" and not M.isNull(res.error) then
    stderr = tostring(res.error)
  end
  return {
    code = code,
    stdout = stdout,
    stderr = stderr,
    timedOut = timedOut,
  }
end

function M.declineServerRequest(pkt)
  local method = type(pkt) == "table" and M.nullOr(pkt.method, nil) or nil
  local params = (type(pkt) == "table" and M.isPlainObject(pkt.params)) and pkt.params or {}
  if method == M.METHOD_COMMAND_APPROVAL or method == M.METHOD_FILE_APPROVAL then
    return { decision = "decline" }
  end
  if method == M.METHOD_PERMISSIONS_APPROVAL then
    return { permissions = {} }
  end
  if method == M.METHOD_USER_INPUT then
    local answers = {}
    local questions = M.isArray(params.questions) and params.questions or {}
    for _, q in ipairs(questions) do
      if type(q) == "table" and type(q.id) == "string" and M.startsWith(q.id, "mcp_tool_call_approval_") then
        answers[q.id] = { answers = M.newArray({ "__codex_mcp_decline__" }) }
      end
    end
    return { answers = answers }
  end
  if method == M.METHOD_ELICITATION then
    return { action = "decline", content = M.JSON_NULL }
  end
  M.raiseErr(M.newAppServerError("Unsupported Codex server request: " .. tostring(method), {
    code = -32601,
    failureReason = "protocol",
  }))
end

function M.parseApprovalDecision(rawDecision, allowedScopes)
  local s = M.trim(rawDecision):lower()
  if s == "approve" or s == "approved" or s == "approve:once" then
    return { approved = true, scope = "once" }
  end
  if s == "approve:session" then
    return {
      approved = true,
      scope = M.listContains(allowedScopes, "session") and "session" or "once",
    }
  end
  if s == "approve:always" then
    if M.listContains(allowedScopes, "always") then
      return { approved = true, scope = "always" }
    end
    if M.listContains(allowedScopes, "session") then
      return { approved = true, scope = "session" }
    end
    return { approved = true, scope = "once" }
  end
  return { approved = false, scope = nil }
end

function M.formatToolName(item)
  if M.isNonEmpty(item.server) and M.isNonEmpty(item.tool) then
    return tostring(item.server) .. "/" .. tostring(item.tool)
  end
  if M.isNonEmpty(item.tool) then
    return tostring(item.tool)
  end
  if M.isNonEmpty(item.name) then
    return tostring(item.name)
  end
  if type(item.command) == "string" then
    local trimmed = M.trim(item.command)
    if trimmed ~= "" then
      local first = trimmed:match("^(%S+)")
      if first and first ~= "" then
        return first
      end
    end
  end
  return (type(item.type) == "string" and M.TOOL_TYPE_NAMES[item.type]) or "tool"
end

function M.formatToolDetail(item, name)
  local itemType = item.type
  if itemType == "commandExecution" then
    local actions = M.newArray()
    if M.isArray(item.commandActions) then
      for _, a in ipairs(item.commandActions) do
        local isTbl = type(a) == "table"
        local entry = {
          kind = (isTbl and type(a.type) == "string" and M.COMMAND_ACTIONS[a.type]) or "other",
          command = isTbl and M.nullOr(a.command, "") or "",
        }
        if isTbl and not M.isNull(a.path) then
          entry.path = a.path
        end
        if isTbl and not M.isNull(a.query) then
          entry.query = a.query
        end
        actions[#actions + 1] = entry
      end
    end
    return {
      kind = "command",
      command = M.nullOr(item.command, ""),
      cwd = M.nullOr(item.cwd, M.JSON_NULL),
      exitCode = M.nullOr(item.exitCode, M.JSON_NULL),
      output = M.nullOr(item.aggregatedOutput, M.JSON_NULL),
      actions = actions,
    }
  end

  if itemType == "mcpToolCall" then
    local resultText = nil
    if type(item.result) == "table" and M.isArray(item.result.content) then
      local texts = {}
      for _, b in ipairs(item.result.content) do
        if type(b) == "table" and b.type == "text" and type(b.text) == "string" then
          texts[#texts + 1] = b.text
        end
      end
      if #texts > 0 then
        resultText = table.concat(texts, "\n")
      end
    end
    return {
      kind = "mcp",
      server = M.nullOr(item.server, ""),
      tool = M.nullOr(item.tool, ""),
      arguments = M.nullOr(item.arguments, M.JSON_NULL),
      result = resultText ~= nil and resultText or M.JSON_NULL,
    }
  end

  if itemType == "fileChange" then
    local changes = M.newArray()
    if M.isArray(item.changes) then
      for _, c in ipairs(item.changes) do
        local cPath = ""
        local cKind = "update"
        if type(c) == "table" then
          if not M.isNull(c.path) then
            cPath = c.path
          end
          if type(c.kind) == "table" and not M.isNull(c.kind.type) then
            cKind = c.kind.type
          elseif M.isNonEmpty(c.kind) then
            cKind = tostring(c.kind)
          end
        end
        changes[#changes + 1] = { path = cPath, kind = cKind }
      end
    end
    return { kind = "change", changes = changes }
  end

  if itemType == "webSearch" then
    local act = item.action
    if M.isPlainObject(act) then
      if act.type == "search" then
        return { kind = "web", action = "search", query = M.nullOr(act.query, M.JSON_NULL) }
      end
      if act.type == "openPage" then
        return { kind = "web", action = "open", url = M.nullOr(act.url, M.JSON_NULL) }
      end
      if act.type == "findInPage" then
        return {
          kind = "web",
          action = "find",
          url = M.nullOr(act.url, M.JSON_NULL),
          query = M.nullOr(act.pattern, M.JSON_NULL),
        }
      end
    end
    return {
      kind = "web",
      action = "search",
      query = M.isNonEmpty(item.query) and item.query or M.JSON_NULL,
    }
  end

  if itemType == "imageView" then
    return { kind = "file", action = "read", path = M.nullOr(item.path, M.JSON_NULL) }
  end

  if itemType == "collabAgentToolCall" then
    return { kind = "agent", description = M.nullOr(item.prompt, M.JSON_NULL) }
  end

  local output = M.nullOr(item.result, nil)
  if output == nil then
    output = M.nullOr(item.output, nil)
  end
  if output == nil then
    output = M.nullOr(item.contentItems, nil)
  end
  return {
    kind = "other",
    name = name,
    input = M.nullOr(item.arguments, M.JSON_NULL),
    output = output ~= nil and output or M.JSON_NULL,
  }
end

function M.normalizeTokenUsage(raw)
  if not M.isPlainObject(raw) then
    return nil
  end
  local rawInput = M.toFiniteNumber(M.nullOr(raw.inputTokens, 0))
  local cachedInput = M.toFiniteNumber(M.nullOr(raw.cachedInputTokens, 0))
  local outputTokens = M.toFiniteNumber(M.nullOr(raw.outputTokens, 0))
  local totalTokens = M.toFiniteNumber(M.nullOr(raw.totalTokens, 0))
  if rawInput == nil or cachedInput == nil or outputTokens == nil or totalTokens == nil then
    return nil
  end
  local out = {
    inputTokens = math.max(0, rawInput - cachedInput),
    cachedInputTokens = math.max(0, cachedInput),
    outputTokens = math.max(0, outputTokens),
    totalTokens = math.max(0, totalTokens),
  }
  if not M.isNull(raw.cacheWriteInputTokens) then
    local n = M.toFiniteNumber(raw.cacheWriteInputTokens)
    if n ~= nil then
      out.cacheWriteInputTokens = math.max(0, n)
    end
  end
  if not M.isNull(raw.reasoningOutputTokens) then
    local n = M.toFiniteNumber(raw.reasoningOutputTokens)
    if n ~= nil then
      out.reasoningOutputTokens = math.max(0, n)
    end
  end
  return out
end

function M.mapMcpStatus(item)
  if type(item) ~= "table" then
    return "", ""
  end
  if M.isNonEmpty(item.toolsError) then
    return "failed", tostring(item.toolsError)
  end
  local runtimeStatus = M.nullOr(item.runtimeStatus, nil)
  if runtimeStatus == "failed" or runtimeStatus == "cancelled" then
    return "failed", tostring(runtimeStatus)
  end
  if type(runtimeStatus) == "string" and M.MCP_CONNECTION_MAP[runtimeStatus] then
    return M.MCP_CONNECTION_MAP[runtimeStatus], ""
  end
  local authStatus = M.nullOr(item.authStatus, nil)
  if type(authStatus) == "string" and M.MCP_AUTH_MAP[authStatus] then
    return M.MCP_AUTH_MAP[authStatus], ""
  end
  return M.isNonEmpty(runtimeStatus) and tostring(runtimeStatus) or "", ""
end

function M.buildTurnInputs(input)
  local inputText = (type(input) == "table" and not M.isNull(input.inputText)) and tostring(input.inputText) or ""
  local inputs = M.newArray({ { type = "text", text = inputText } })
  local seenPaths = {}
  local normalized = {}

  local function collectList(list)
    if not M.isArray(list) then
      return
    end
    for _, att in ipairs(list) do
      local p = nil
      local mt = ""
      if type(att) == "string" then
        p = att
      elseif type(att) == "table" then
        p = M.nullOr(att.path, nil)
        local rawMt = M.nullOr(att.mediaType, nil) or M.nullOr(att.media_type, nil)
        mt = rawMt ~= nil and tostring(rawMt) or ""
      end
      if type(p) == "string" and p ~= "" and not seenPaths[p] then
        seenPaths[p] = true
        normalized[#normalized + 1] = { path = p, mediaType = mt }
      end
    end
  end

  if type(input) == "table" then
    collectList(input.attachmentDetails)
    collectList(input.attachments)
  end

  for _, att in ipairs(normalized) do
    local mt = M.trim(att.mediaType):lower()
    local isImg
    if mt ~= "" then
      isImg = M.startsWith(mt, "image/")
    else
      isImg = M.isImagePath(att.path)
    end
    if isImg then
      inputs[#inputs + 1] = { type = "localImage", path = att.path }
    else
      inputs[#inputs + 1] = { type = "text", text = "Attached file: " .. att.path }
    end
  end

  return inputs
end

function M.parseQuotaSnapshot(rl, observedAtMs)
  if not M.isPlainObject(rl) then
    return nil
  end
  local bucketEntries = {}
  if M.isPlainObject(rl.rateLimitsByLimitId) then
    -- Preserve default ("codex") bucket first if present, matching 0.3 insertion order without arbitrary alphabetical scramble.
    local keys = M.sortedKeys(rl.rateLimitsByLimitId)
    for _, k in ipairs(keys) do
      if tostring(k) == "codex" or tostring(k) == "default" then
        local b = rl.rateLimitsByLimitId[k]
        if M.isPlainObject(b) then
          bucketEntries[#bucketEntries + 1] = { tostring(k), b }
        end
      end
    end
    for _, k in ipairs(keys) do
      if tostring(k) ~= "codex" and tostring(k) ~= "default" then
        local b = rl.rateLimitsByLimitId[k]
        if M.isPlainObject(b) then
          bucketEntries[#bucketEntries + 1] = { tostring(k), b }
        end
      end
    end
  end
  if #bucketEntries == 0 and M.isPlainObject(rl.rateLimits) then
    bucketEntries = { { "default", rl.rateLimits } }
  end
  if #bucketEntries == 0 then
    return nil
  end

  local windows = M.newArray()
  for _, entry in ipairs(bucketEntries) do
    local bucketId, bucket = entry[1], entry[2]
    local displayName = ""
    if M.isNonEmpty(bucket.limitName) then
      displayName = tostring(bucket.limitName)
    elseif M.isNonEmpty(bucket.normalModelSlug) then
      displayName = tostring(bucket.normalModelSlug)
    elseif bucketId ~= "default" and bucketId ~= "codex" and bucketId ~= "" then
      displayName = tostring(bucketId)
    end
    local group = tostring(
      (M.isNonEmpty(bucket.limitName) and bucket.limitName)
        or (M.isNonEmpty(bucket.normalModelSlug) and bucket.normalModelSlug)
        or (M.isNonEmpty(bucketId) and bucketId)
        or "default"
    )
    local slots = {
      { "primary", bucket.primary },
      { "secondary", bucket.secondary },
    }
    for _, slot in ipairs(slots) do
      local slotName, w = slot[1], slot[2]
      if M.isPlainObject(w) then
        local usedRaw = w.usedPercent
        local usedPct = nil
        if type(usedRaw) == "number" then
          usedPct = M.isFiniteNumber(usedRaw) and usedRaw or nil
        elseif type(usedRaw) == "string" and M.trim(usedRaw) ~= "" then
          usedPct = M.toFiniteNumber(usedRaw)
        end
        if usedPct ~= nil then
          local remainingPercent = math.max(0, math.min(100, 100 - usedPct))
          local durationMinutes = nil
          local durationSeconds = nil
          if not M.isNull(w.windowDurationMins) then
            local dm = M.toFiniteNumber(w.windowDurationMins)
            if dm ~= nil then
              durationMinutes = M.truncInt(dm)
              durationSeconds = durationMinutes * 60
            end
          end
          local resetsAtMs = nil
          if not M.isNull(w.resetsAt) then
            local ra = M.toFiniteNumber(w.resetsAt)
            if ra ~= nil then
              resetsAtMs = M.truncInt(ra * 1000)
            end
          end

          local win = {
            key = bucketId .. ":" .. slotName,
            label = displayName,
            group = group,
            name = displayName,
            remainingPercent = remainingPercent,
          }
          if durationSeconds ~= nil then
            win.durationSeconds = durationSeconds
          end
          if durationMinutes ~= nil then
            win.durationMinutes = durationMinutes
          end
          if resetsAtMs ~= nil then
            win.resetsAtMs = resetsAtMs
          end
          windows[#windows + 1] = win
        end
      end
    end
  end

  if #windows > 0 then
    return { observedAtMs = observedAtMs, windows = windows }
  end
  return nil
end

return M
