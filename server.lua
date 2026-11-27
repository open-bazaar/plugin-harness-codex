-- Codex app-server stdio JSON-RPC client and process lifecycle manager.

local json = require("bazaar.json")
local log = require("bazaar.log")
local process = require("bazaar.process")
local task = require("bazaar.task")
local P = require("./protocol")

local CodexAppServer = {}
CodexAppServer.__index = CodexAppServer

local function noop() end

function CodexAppServer.new(options)
  local opts = type(options) == "table" and options or {}
  local self = setmetatable({
    localId = opts.localId,
    proc = opts.proc,
    emit = opts.emit or noop,
    workspace = opts.workspace or "",
    sandboxPolicy = opts.sandboxPolicy or "workspace-write",
    configuredModel = P.nullOr(opts.configuredModel, nil),
    configuredEffort = P.nullOr(opts.configuredEffort, nil),
    startupTimeoutMs = opts.startupTimeoutMs or P.DEFAULT_STARTUP_TIMEOUT_MS,
    shutdownTimeoutMs = opts.shutdownTimeoutMs or P.DEFAULT_SHUTDOWN_TIMEOUT_MS,
    autoDeclineRequests = opts.autoDeclineRequests == true,
    emitSessionLifecycle = opts.emitSessionLifecycle == true,

    codexHome = nil,
    watchTargets = {},
    threadId = nil,
    providerTurnId = nil,
    activeTurnId = nil,
    turnTerminalEmitted = false,
    model = "",
    seq = 0,
    stderrTail = {},
    stderrDone = false,
    stderrWaitToken = nil,
    writing = false,
    writeWaiters = {},

    closed = false,
    closing = false,
    exited = false,
    expiredEmitted = false,
    transportError = nil,
    closeToken = nil,
    closeDone = false,

    pendingRpc = {},
    pendingApprovals = {},
    activeServerRequests = {},
    cancelledRequests = {},
    handledRequests = {},
    toolStartedAt = {},
    turnWaiter = nil,
  }, CodexAppServer)
  return self
end

function CodexAppServer:lastStderrLine()
  for i = #self.stderrTail, 1, -1 do
    local line = self.stderrTail[i]
    if line and line ~= "" then
      return line
    end
  end
  return ""
end

function CodexAppServer:pushStderrLine(raw)
  local line = P.endsWith(raw, "\r") and raw:sub(1, -2) or raw
  self.stderrTail[#self.stderrTail + 1] = line
  if #self.stderrTail > P.STDERR_TAIL_LIMIT then
    table.remove(self.stderrTail, 1)
  end
  if P.trim(line) ~= "" then
    log.debug("codex stderr", { text = line:sub(1, 500) })
  end
end

function CodexAppServer:startReaders()
  local proc = self.proc

  task.fork(function()
    while true do
      local ok, line = pcall(proc.readStderrLine, proc)
      if not ok or line == nil then
        break
      end
      if #line > P.MAX_STDERR_LINE_CHARS then
        line = line:sub(1, P.MAX_STDERR_LINE_CHARS)
      end
      self:pushStderrLine(line)
    end
    self.stderrDone = true
    if self.stderrWaitToken ~= nil then
      task.wakeup(self.stderrWaitToken)
    end
  end)

  task.fork(function()
    while true do
      local ok, line = pcall(proc.readLine, proc, P.MAX_STDOUT_BUFFER_CHARS)
      if not ok then
        if not self.closing and not self.transportError then
          local msg = P.errMessage(line)
          if msg:find("limit", 1, true) then
            msg = "Codex app-server stdout buffer exceeded 16 MiB limit"
          else
            msg = "Codex app-server stdout read failed: " .. msg
          end
          self:failTransport(P.newProtocolError(msg), { terminate = true })
        end
        break
      end
      if line == nil then
        break
      end
      if not self.transportError then
        self:processLine(line)
      end
      if self.transportError then
        break
      end
    end

    local waitOk, exitInfo = pcall(proc.wait, proc)
    if not self.stderrDone then
      self.stderrWaitToken = {}
      pcall(task.wait, self.stderrWaitToken, 100)
      self.stderrWaitToken = nil
    end
    if waitOk then
      self:onExit(exitInfo)
    else
      self:onExit({ code = -1, error = P.errMessage(exitInfo) })
    end
  end)
end

function CodexAppServer:processLine(rawLine)
  local line = P.endsWith(rawLine, "\r") and rawLine:sub(1, -2) or rawLine
  local ok, pkt = pcall(json.decode, line)
  if not ok then
    self:failTransport(
      P.newProtocolError("Malformed JSONL from codex app-server: " .. line:sub(1, 200)),
      { terminate = true }
    )
    return
  end
  if not P.isPlainObject(pkt) then
    self:failTransport(
      P.newProtocolError("Invalid JSON-RPC packet from codex app-server: " .. line:sub(1, 200)),
      { terminate = true }
    )
    return
  end
  if not P.isNull(pkt.id) and type(pkt.id) ~= "number" and type(pkt.id) ~= "string" then
    self:failTransport(
      P.newProtocolError("Invalid JSON-RPC packet id type from codex app-server"),
      { terminate = true }
    )
    return
  end
  if not P.isNull(pkt.method) and type(pkt.method) ~= "string" then
    self:failTransport(
      P.newProtocolError("Invalid JSON-RPC packet method type from codex app-server"),
      { terminate = true }
    )
    return
  end
  if not P.isNull(pkt.params) and not P.isPlainObject(pkt.params) then
    self:failTransport(
      P.newProtocolError("Invalid JSON-RPC packet params type from codex app-server"),
      { terminate = true }
    )
    return
  end
  self:handlePacket(pkt)
end

function CodexAppServer:emitSessionExpired()
  if not self.emitSessionLifecycle or self.expiredEmitted or self.closing then
    return
  end
  self.expiredEmitted = true
  self.emit({
    type = "session_expired",
    sessionId = self.localId,
  })
end

function CodexAppServer:_rejectAllWaiters(err, options)
  local opts = type(options) == "table" and options or {}

  local rpcs = self.pendingRpc
  self.pendingRpc = {}
  for _, slot in pairs(rpcs) do
    slot:reject(err)
  end

  local approvals = self.pendingApprovals
  self.pendingApprovals = {}
  for _, slot in pairs(approvals) do
    slot:resolve(P.APPROVAL_CANCELLED)
  end

  if self.turnWaiter ~= nil or (self.activeTurnId ~= nil and not self.turnTerminalEmitted) then
    local waiter = self.turnWaiter
    local turnId = self.activeTurnId or ""
    local alreadyEmitted = self.turnTerminalEmitted
    self.turnWaiter = nil
    self.activeTurnId = nil
    self.providerTurnId = nil
    self.turnTerminalEmitted = true
    self.toolStartedAt = {}

    if opts.emitTurnFailed and not alreadyEmitted then
      local failureReason = (type(err) == "table" and err.failureReason) or "connection_lost"
      local reconcile = true
      if type(err) == "table" and err.reconcile ~= nil then
        reconcile = err.reconcile == true
      end
      local event = {
        type = "turn_failed",
        sessionId = self.localId,
        turnId = turnId,
        error = P.errMessage(err),
        failureReason = failureReason,
        reconcile = reconcile,
      }
      if #self.stderrTail > 0 then
        local tail = P.newArray()
        local startIdx = math.max(1, #self.stderrTail - 15)
        for i = startIdx, #self.stderrTail do
          tail[#tail + 1] = self.stderrTail[i]
        end
        event.metadata = { stderrTail = tail }
      end
      self.emit(event)
    end
    if waiter then
      waiter:reject(err)
    end
  end
end

function CodexAppServer:failTransport(err, options)
  if self.transportError then
    return
  end
  local opts = type(options) == "table" and options or {}
  self.transportError = err
  self.closed = true
  self:_rejectAllWaiters(err, { emitTurnFailed = not self.closing })
  if not self.closing then
    self:emitSessionExpired()
  end
  if opts.terminate and not self.exited then
    local sigOk = pcall(self.proc.signal, self.proc, "SIGTERM")
    if not sigOk then
      pcall(self.proc.kill, self.proc)
    end
  end
end

function CodexAppServer:onExit(info)
  self.exited = true
  self.closed = true

  local code = (type(info) == "table" and not P.isNull(info.code)) and info.code or -1
  local sigPart = (type(info) == "table" and P.isNonEmpty(info.signal))
    and (", signal=" .. tostring(info.signal))
    or ""
  local lastErr = self:lastStderrLine()
  local msg = "Codex app-server exited (code=" .. tostring(code) .. sigPart .. ")"
  if lastErr ~= "" then
    msg = msg .. ": " .. lastErr
  elseif type(info) == "table" and P.isNonEmpty(info.error) then
    msg = msg .. ": " .. tostring(info.error)
  end
  local exitErr = P.newAppServerUnavailable(msg, { code = code })
  self:failTransport(exitErr, { terminate = false })
end

function CodexAppServer:send(packet)
  if self.transportError then
    P.raiseErr(self.transportError)
  end
  if self.closed or self.exited then
    P.raiseErr(P.newAppServerUnavailable("Codex app-server is no longer running"))
  end
  local line = json.encode(packet) .. "\n"

  if self.writing then
    local tok = {}
    self.writeWaiters[#self.writeWaiters + 1] = tok
    task.wait(tok)
  else
    self.writing = true
  end

  local ok, err = pcall(function()
    if self.transportError then
      P.raiseErr(self.transportError)
    end
    if self.closed or self.exited then
      P.raiseErr(P.newAppServerUnavailable("Codex app-server is no longer running"))
    end
    local writeOk, writeErr = pcall(self.proc.writeStdin, self.proc, line)
    if not writeOk then
      local lastErr = self:lastStderrLine()
      local detail = lastErr ~= "" and lastErr or P.errMessage(writeErr)
      P.raiseErr(P.newAppServerUnavailable("Codex app-server stdin write failed: " .. detail))
    end
  end)

  local nextTok = table.remove(self.writeWaiters, 1)
  if nextTok ~= nil then
    task.wakeup(nextTok)
  else
    self.writing = false
  end

  if not ok then
    P.raiseErr(err)
  end
end

function CodexAppServer:request(method, params, timeoutMs)
  if self.transportError then
    P.raiseErr(self.transportError)
  end
  if self.closed or self.exited then
    P.raiseErr(P.newAppServerUnavailable("Codex app-server is no longer running"))
  end
  if params == nil then
    params = {}
  end
  if timeoutMs == nil then
    timeoutMs = P.DEFAULT_RPC_TIMEOUT_MS
  end

  self.seq = self.seq + 1
  local id = self.seq
  local slot = P.newWaitSlot()
  self.pendingRpc[id] = slot

  task.fork(function()
    local sendOk, sendErr = pcall(self.send, self, { id = id, method = method, params = params })
    if not sendOk then
      if self.pendingRpc[id] == slot then
        self.pendingRpc[id] = nil
      end
      slot:reject(sendErr)
    end
  end)

  local tNum = P.toFiniteNumber(timeoutMs)
  local waitMs = (tNum ~= nil and tNum > 0) and P.toDelayMs(tNum) or nil
  local ok, val = pcall(slot.wait, slot, waitMs, "codex RPC " .. tostring(method) .. " timed out")
  if self.pendingRpc[id] == slot then
    self.pendingRpc[id] = nil
  end
  if not ok then
    P.raiseErr(val)
  end
  return val
end

function CodexAppServer:initialize(timeoutMs)
  local tMs = timeoutMs or self.startupTimeoutMs
  local result = self:request(
    "initialize",
    {
      clientInfo = P.CLIENT_INFO,
      capabilities = { experimentalApi = true },
    },
    tMs
  )
  self:send({ method = "initialized" })
  return result
end

function CodexAppServer:startWatches(timeoutMs)
  local tMs = timeoutMs or self.startupTimeoutMs
  local targets = {}
  if self.workspace ~= "" then
    targets[#targets + 1] = { "workspace", P.joinPath(self.workspace, "AGENTS.md") }
  end
  if P.isNonEmpty(self.codexHome) then
    targets[#targets + 1] = { "codex-home", P.joinPath(self.codexHome, "AGENTS.md") }
  end
  self.watchTargets = {}

  for _, pair in ipairs(targets) do
    local watchId, targetPath = pair[1], pair[2]
    local ok, resOrErr = pcall(function()
      return self:request("fs/watch", { watchId = watchId, path = targetPath }, tMs)
    end)
    if not ok then
      if type(resOrErr) == "table" and resOrErr.code == -32601 then
        log.debug("codex app-server does not support fs/watch", { watchId = watchId })
      else
        P.raiseErr(resOrErr)
      end
    else
      if type(resOrErr) ~= "table" or type(resOrErr.path) ~= "string" or resOrErr.path == "" then
        P.raiseErr(P.newProtocolError("fs/watch response missing path"))
      end
      if P.normalizePath(resOrErr.path) ~= P.normalizePath(targetPath) then
        P.raiseErr(P.newProtocolError(
          "fs/watch returned a different path (expected " .. targetPath .. ", got " .. resOrErr.path .. ")"
        ))
      end
      self.watchTargets[watchId] = targetPath
    end
  end
end

function CodexAppServer:handlePacket(pkt)
  -- 1. Response to an outgoing client RPC request.
  if P.isNull(pkt.method) and not P.isNull(pkt.id) and self.pendingRpc[pkt.id] ~= nil then
    local slot = self.pendingRpc[pkt.id]
    self.pendingRpc[pkt.id] = nil
    if not P.isNull(pkt.error) then
      local errObj = P.isPlainObject(pkt.error) and pkt.error or {}
      local message
      if type(pkt.error) == "string" then
        message = pkt.error
      elseif P.isNonEmpty(errObj.message) then
        message = tostring(errObj.message)
      else
        local encOk, encoded = pcall(json.encode, pkt.error)
        message = (encOk and encoded and encoded ~= "") and encoded or "Codex request failed"
      end
      slot:reject(P.newAppServerError(message, {
        code = P.nullOr(errObj.code, nil),
        failureReason = "execution",
      }))
    else
      slot:resolve(not P.isNull(pkt.result) and pkt.result or {})
    end
    return
  end

  if self.closed then
    return
  end

  -- 2. Server-initiated JSON-RPC request.
  if P.isNonEmpty(pkt.method) and not P.isNull(pkt.id) then
    local params = P.isPlainObject(pkt.params) and pkt.params or {}
    local turnPart = not P.isNull(params.turnId) and tostring(params.turnId) or ""
    local dedupKey = turnPart .. "::" .. type(pkt.id) .. ":" .. tostring(pkt.id)
    local reqKey = tostring(pkt.id)
    if self.handledRequests[dedupKey] or self.activeServerRequests[reqKey] then
      log.warn("Ignoring duplicate Codex server request", {
        id = pkt.id,
        method = pkt.method,
      })
      return
    end
    self.handledRequests[dedupKey] = true
    self.activeServerRequests[reqKey] = true
    task.fork(function()
      self:answerServerRequest(pkt)
    end)
    return
  end

  -- 3. Server notification.
  if P.isNonEmpty(pkt.method) then
    local params = P.isPlainObject(pkt.params) and pkt.params or {}
    if pkt.method == "serverRequest/resolved" then
      self:handleServerRequestResolved(params)
      return
    end
    self:handleNotification(pkt.method, params)
  end
end

function CodexAppServer:handleServerRequestResolved(params)
  if P.isNull(params.requestId) then
    return
  end
  local reqKey = tostring(params.requestId)
  if self.activeServerRequests[reqKey] then
    self.cancelledRequests[reqKey] = true
  end
  local slot = self.pendingApprovals[reqKey]
  if slot then
    self.pendingApprovals[reqKey] = nil
    slot:resolve(P.APPROVAL_CANCELLED)
  end
end

function CodexAppServer:answerServerRequest(pkt)
  local rawId = pkt.id
  local reqKey = tostring(rawId)
  local ok, resultOrErr = pcall(function()
    return self:_dispatchServerRequest(pkt)
  end)

  local wasCancelled = self.cancelledRequests[reqKey] == true
  self.activeServerRequests[reqKey] = nil
  self.cancelledRequests[reqKey] = nil
  self.pendingApprovals[reqKey] = nil

  local response = nil
  if ok then
    if resultOrErr == P.APPROVAL_CANCELLED or wasCancelled or self.closed then
      return
    end
    response = { id = rawId, result = resultOrErr }
  else
    if wasCancelled or self.closed then
      return
    end
    local code = (type(resultOrErr) == "table" and P.isInteger(resultOrErr.code))
      and resultOrErr.code
      or -32603
    local msg = P.errMessage(resultOrErr)
    if msg == "" then
      msg = "Internal error"
    end
    log.warn("Rejecting Codex server request", {
      id = rawId,
      method = pkt.method,
      code = code,
      error = msg,
    })
    response = {
      id = rawId,
      error = {
        code = code,
        message = msg,
      },
    }
  end

  local sendOk, sendErr = pcall(function()
    P.withTimeout(
      function()
        self:send(response)
      end,
      self.startupTimeoutMs,
      "codex response write timed out for request " .. reqKey
    )
  end)
  if not sendOk then
    log.warn("Could not send response to Codex server request", {
      id = rawId,
      error = P.errMessage(sendErr),
    })
  end
end

function CodexAppServer:_dispatchServerRequest(pkt)
  if self.autoDeclineRequests then
    return P.declineServerRequest(pkt)
  end

  local method = pkt.method
  local params = P.isPlainObject(pkt.params) and pkt.params or {}

  -- Unsupported methods must immediately return JSON-RPC -32601 without prompting.
  if
    method ~= P.METHOD_COMMAND_APPROVAL
    and method ~= P.METHOD_FILE_APPROVAL
    and method ~= P.METHOD_PERMISSIONS_APPROVAL
    and method ~= P.METHOD_USER_INPUT
    and method ~= P.METHOD_ELICITATION
  then
    return P.declineServerRequest(pkt)
  end

  -- Validate active turn, threadId, and turnId before prompting.
  if not P.isNonEmpty(self.activeTurnId) or self.turnTerminalEmitted then
    log.warn("No active turn owns Codex request", { id = pkt.id, method = method })
    return P.declineServerRequest(pkt)
  end
  if P.nullOr(params.threadId, nil) ~= self.threadId then
    log.warn("Codex request refers to a different thread", { id = pkt.id, method = method })
    return P.declineServerRequest(pkt)
  end
  local reqTurnId = params.turnId
  if not P.isNull(reqTurnId) and self.providerTurnId ~= nil and tostring(reqTurnId) ~= self.providerTurnId then
    log.warn("Codex request refers to a different turn", { id = pkt.id, method = method })
    return P.declineServerRequest(pkt)
  end

  local scopes = P.newArray({ "once" })
  local action = ""
  local title = ""
  local description = ""
  local amendment = nil

  if method == P.METHOD_COMMAND_APPROVAL or method == P.METHOD_FILE_APPROVAL then
    action = method == P.METHOD_COMMAND_APPROVAL and "command_execution" or "file_change"
    title = method == P.METHOD_COMMAND_APPROVAL and "Approve Command Execution" or "Approve File Change"
    local decisions = P.isArray(params.availableDecisions) and params.availableDecisions or {}
    if method == P.METHOD_FILE_APPROVAL or P.listContains(decisions, "acceptForSession") then
      scopes[#scopes + 1] = "session"
    end
    for _, d in ipairs(decisions) do
      if P.isPlainObject(d) then
        if not P.isNull(d.acceptWithExecpolicyAmendment) then
          amendment = d
          break
        end
        if
          type(d.applyNetworkPolicyAmendment) == "table"
          and type(d.applyNetworkPolicyAmendment.network_policy_amendment) == "table"
          and d.applyNetworkPolicyAmendment.network_policy_amendment.action == "allow"
        then
          amendment = d
          break
        end
      end
    end
    if amendment ~= nil then
      scopes[#scopes + 1] = "always"
    end
    description = tostring(
      (P.isNonEmpty(params.command) and params.command)
        or (P.isNonEmpty(params.reason) and params.reason)
        or json.encode(params):sub(1, 1000)
    )
  elseif method == P.METHOD_PERMISSIONS_APPROVAL then
    action = "permissions"
    title = "Approve Permissions"
    scopes[#scopes + 1] = "session"
    local permsPayload = not P.isNull(params.permissions) and params.permissions or params
    description = tostring(
      (P.isNonEmpty(params.reason) and params.reason)
        or json.encode(permsPayload):sub(1, 1000)
    )
  elseif method == P.METHOD_USER_INPUT then
    local questions = P.isArray(params.questions) and params.questions or {}
    local allMcpApproval = #questions > 0
    if allMcpApproval then
      for _, q in ipairs(questions) do
        if type(q) ~= "table" or type(q.id) ~= "string" or not P.startsWith(q.id, "mcp_tool_call_approval_") then
          allMcpApproval = false
          break
        end
      end
    end
    if not allMcpApproval then
      log.warn("Unsupported Codex user-input request", { id = pkt.id })
      return P.declineServerRequest(pkt)
    end
    action = "mcp_tool_approval"
    title = "Approve MCP Tool Call"
    local firstOpts = P.isArray(questions[1].options) and questions[1].options or {}
    local labels = {}
    for _, o in ipairs(firstOpts) do
      if type(o) == "table" and type(o.label) == "string" then
        labels[o.label] = true
      end
    end
    for _, s in ipairs({ "session", "always" }) do
      if labels[P.MCP_SCOPE_LABELS[s]] then
        scopes[#scopes + 1] = s
      end
    end
    description = tostring(
      (P.isNonEmpty(questions[1].question) and questions[1].question)
        or (P.isNonEmpty(questions[1].header) and questions[1].header)
        or json.encode(params):sub(1, 1000)
    )
  elseif method == P.METHOD_ELICITATION then
    local metadata = P.isPlainObject(params._meta) and params._meta or {}
    if metadata.codex_approval_kind ~= "mcp_tool_call" then
      log.warn("Unsupported Codex elicitation request", { id = pkt.id })
      return P.declineServerRequest(pkt)
    end
    action = "mcp_tool_approval"
    title = "Approve MCP Tool Call"
    local persist = P.isArray(metadata.persist) and metadata.persist or {}
    for _, s in ipairs({ "session", "always" }) do
      if P.listContains(persist, s) then
        scopes[#scopes + 1] = s
      end
    end
    description = tostring(
      (P.isNonEmpty(params.message) and params.message)
        or json.encode(params):sub(1, 1000)
    )
  end

  local requestId = tostring(pkt.id)
  local approvalSlot = P.newWaitSlot()
  self.pendingApprovals[requestId] = approvalSlot
  self.emit({
    type = "approval_requested",
    sessionId = self.localId,
    turnId = self.activeTurnId or "",
    requestId = requestId,
    action = action,
    title = title,
    description = description,
    allowedScopes = scopes,
    details = params,
  })

  local rawDecision = approvalSlot:wait()
  if rawDecision == P.APPROVAL_CANCELLED or self.cancelledRequests[requestId] then
    return P.APPROVAL_CANCELLED
  end

  local parsed = P.parseApprovalDecision(rawDecision, scopes)
  if not parsed.approved then
    return P.declineServerRequest(pkt)
  end

  if method == P.METHOD_COMMAND_APPROVAL or method == P.METHOD_FILE_APPROVAL then
    local decision = "accept"
    if parsed.scope == "session" then
      decision = "acceptForSession"
    elseif parsed.scope == "always" and amendment ~= nil then
      decision = amendment
    end
    return { decision = decision }
  end

  if method == P.METHOD_PERMISSIONS_APPROVAL then
    return {
      permissions = not P.isNull(params.permissions) and params.permissions or {},
      scope = parsed.scope == "session" and "session" or "turn",
    }
  end

  if method == P.METHOD_USER_INPUT then
    local label = P.MCP_SCOPE_LABELS[parsed.scope] or P.MCP_SCOPE_LABELS.once
    local answers = {}
    for _, q in ipairs(params.questions) do
      answers[q.id] = { answers = P.newArray({ label }) }
    end
    return { answers = answers }
  end

  if method == P.METHOD_ELICITATION then
    local response = { action = "accept", content = P.JSON_NULL }
    if parsed.scope ~= "once" then
      response._meta = { persist = parsed.scope }
    end
    return response
  end

  return P.declineServerRequest(pkt)
end

function CodexAppServer:handleNotification(method, params)
  -- Session-level notifications (no threadId).
  if method == "skills/changed" then
    self:emitSessionExpired()
    return
  end
  if method == "fs/changed" then
    local watchId = not P.isNull(params.watchId) and tostring(params.watchId) or ""
    local expected = watchId ~= "" and self.watchTargets[watchId] or nil
    local changed = P.isArray(params.changedPaths) and params.changedPaths or {}
    if expected then
      local normExpected = P.normalizePath(expected)
      for _, p in ipairs(changed) do
        if P.normalizePath(p) == normExpected then
          self:emitSessionExpired()
          break
        end
      end
    end
    return
  end

  -- Filter notifications strictly to this session's threadId and active providerTurnId.
  if not P.isNonEmpty(self.threadId) or P.nullOr(params.threadId, nil) ~= self.threadId then
    return
  end
  local incomingTurnId = params.turnId
  if P.isNull(incomingTurnId) and type(params.turn) == "table" then
    incomingTurnId = params.turn.id
  end
  if not P.isNull(incomingTurnId) then
    local tid = tostring(incomingTurnId)
    if self.providerTurnId ~= nil and tid ~= self.providerTurnId then
      return
    end
    if self.providerTurnId == nil and self.activeTurnId ~= nil then
      self.providerTurnId = tid
    end
  end

  local turnId = self.activeTurnId or ""

  if method == "turn/started" then
    self.emit({
      type = "turn_started",
      sessionId = self.localId,
      turnId = turnId,
      metadata = {
        eventName = "codex.turn.started",
        providerTurnId = self.providerTurnId ~= nil and self.providerTurnId or P.JSON_NULL,
      },
    })
    return
  end

  if method == "item/agentMessage/delta" then
    if type(params.delta) == "string" and #params.delta > 0 then
      self.emit({
        type = "content_delta",
        sessionId = self.localId,
        turnId = turnId,
        text = params.delta,
        metadata = { kind = "agent_message" },
      })
    end
    return
  end

  if method == "item/plan/delta" then
    if type(params.delta) == "string" and #params.delta > 0 then
      self.emit({
        type = "content_delta",
        sessionId = self.localId,
        turnId = turnId,
        text = params.delta,
        metadata = { kind = "plan" },
      })
    end
    return
  end

  if method == "item/reasoning/summaryTextDelta" then
    if type(params.delta) == "string" and #params.delta > 0 then
      local metadata = { kind = "reasoning_summary" }
      if P.isInteger(params.summaryIndex) then
        metadata.index = params.summaryIndex
      end
      self.emit({
        type = "thought_delta",
        sessionId = self.localId,
        turnId = turnId,
        text = params.delta,
        metadata = metadata,
      })
    end
    return
  end

  if method == "item/reasoning/textDelta" then
    if type(params.delta) == "string" and #params.delta > 0 then
      local metadata = { kind = "reasoning_text" }
      if P.isInteger(params.contentIndex) then
        metadata.index = params.contentIndex
      end
      self.emit({
        type = "thought_delta",
        sessionId = self.localId,
        turnId = turnId,
        text = params.delta,
        metadata = metadata,
      })
    end
    return
  end

  if method == "item/started" or method == "item/completed" then
    local item = params.item
    if not P.isPlainObject(item) or type(item.type) ~= "string" or item.type == "" or P.SKIPPED_ITEM_TYPES[item.type] then
      return
    end
    if type(item.id) ~= "string" or item.id == "" then
      return
    end
    if item.type == "contextCompaction" then
      self.emit({
        type = method == "item/started" and "compaction_started" or "compaction_completed",
        sessionId = self.localId,
        turnId = turnId,
        metadata = { compactionId = item.id },
      })
      return
    end

    local toolName = P.formatToolName(item)
    local detail = P.formatToolDetail(item, toolName)
    if method == "item/started" then
      if P.isInteger(params.startedAtMs) then
        self.toolStartedAt[item.id] = params.startedAtMs
      end
      self.emit({
        type = "tool_started",
        sessionId = self.localId,
        turnId = turnId,
        toolName = toolName,
        toolCallId = item.id,
        details = detail,
        metadata = { itemType = item.type, detail = detail },
      })
      return
    end

    local startedAt = self.toolStartedAt[item.id]
    self.toolStartedAt[item.id] = nil
    local durationMs = P.nullOr(item.durationMs, nil)
    if durationMs == nil and startedAt ~= nil and P.isInteger(params.completedAtMs) then
      durationMs = math.max(0, params.completedAtMs - startedAt)
    end

    local itemError = P.nullOr(item.error, nil)
    local failed =
      item.status == "failed"
      or item.status == "declined"
      or item.status == "errored"
      or itemError ~= nil
    local errorMessage = ""
    if failed then
      if type(itemError) == "string" then
        errorMessage = itemError
      elseif P.isPlainObject(itemError) and P.isNonEmpty(itemError.message) then
        errorMessage = tostring(itemError.message)
      else
        errorMessage = "tool " .. tostring(P.isNonEmpty(item.status) and item.status or "failed")
      end
    end

    local ev = {
      type = "tool_completed",
      sessionId = self.localId,
      turnId = turnId,
      toolName = toolName,
      toolCallId = item.id,
      details = detail,
      metadata = {
        itemType = item.type,
        status = P.isNonEmpty(item.status) and item.status or (failed and "failed" or "completed"),
        failed = failed,
        durationMs = durationMs ~= nil and durationMs or P.JSON_NULL,
        detail = detail,
      },
    }
    if errorMessage ~= "" then
      ev.error = errorMessage
    end
    self.emit(ev)
    return
  end

  if method == "item/fileChange/patchUpdated" then
    local rawChanges = P.isArray(params.changes) and params.changes or nil
    if not rawChanges then
      self:failTransport(P.newProtocolError("Invalid Codex file change patch"), { terminate = true })
      return
    end
    local changes = P.newArray()
    for _, c in ipairs(rawChanges) do
      local kindType = (type(c) == "table" and type(c.kind) == "table") and c.kind.type or nil
      if
        not P.isPlainObject(c)
        or type(c.path) ~= "string"
        or c.path == ""
        or type(c.diff) ~= "string"
        or (kindType ~= "add" and kindType ~= "delete" and kindType ~= "update")
      then
        self:failTransport(P.newProtocolError("Invalid Codex file change patch"), { terminate = true })
        return
      end
      changes[#changes + 1] = { path = c.path, kind = kindType, patch = c.diff }
    end
    self.emit({
      type = "tool_patch_updated",
      sessionId = self.localId,
      turnId = turnId,
      toolCallId = not P.isNull(params.itemId) and tostring(params.itemId) or "",
      metadata = { changes = changes },
    })
    return
  end

  if method == "item/commandExecution/terminalInteraction" then
    self.emit({
      type = "tool_interaction",
      sessionId = self.localId,
      turnId = turnId,
      toolCallId = not P.isNull(params.itemId) and tostring(params.itemId) or "",
      text = type(params.stdin) == "string" and params.stdin or "",
      metadata = { processId = P.nullOr(params.processId, P.JSON_NULL) },
    })
    return
  end

  if method == "model/rerouted" then
    if P.isNonEmpty(params.toModel) then
      self.model = tostring(params.toModel)
      self.emit({
        type = "model_updated",
        sessionId = self.localId,
        turnId = turnId,
        model = self.model,
      })
    end
    return
  end

  if method == "thread/tokenUsage/updated" then
    local usage = params.tokenUsage
    if not P.isPlainObject(usage) then
      return
    end
    local totalRaw = P.isPlainObject(usage.total) and usage.total or usage.totalTokenUsage
    local total = P.normalizeTokenUsage(totalRaw)
    if not total then
      return
    end
    local lastRaw = P.isPlainObject(usage.last) and usage.last or usage.lastTokenUsage
    local last = P.normalizeTokenUsage(lastRaw)
    local payload = { total = total, cumulative = true }
    if last then
      payload.last = last
    end
    if not P.isNull(usage.modelContextWindow) then
      local cw = P.toFiniteNumber(usage.modelContextWindow)
      if cw ~= nil then
        payload.modelContextWindow = cw
      end
    end
    local ev = {
      type = "usage_updated",
      sessionId = self.localId,
      turnId = turnId,
      usage = payload,
    }
    if self.model ~= "" then
      ev.model = self.model
    end
    self.emit(ev)
    return
  end

  if method == "error" then
    if type(params.willRetry) ~= "boolean" then
      self:failTransport(
        P.newProtocolError("Codex error notification params.willRetry must be a boolean"),
        { terminate = true }
      )
      return
    end
    local metadata = { will_retry = params.willRetry }
    local info = type(params.error) == "table" and P.nullOr(params.error.codexErrorInfo, nil) or nil
    if P.isPlainObject(info) then
      local keyCount = 0
      local singleKey = nil
      for k in pairs(info) do
        keyCount = keyCount + 1
        singleKey = k
      end
      if keyCount ~= 1 then
        self:failTransport(
          P.newProtocolError("Codex codexErrorInfo must contain one error type"),
          { terminate = true }
        )
        return
      end
      info = singleKey
    end
    if info ~= nil then
      metadata.provider_error_type = info
    end
    local errMsg = (type(params.error) == "table" and not P.isNull(params.error.message))
      and tostring(params.error.message)
      or ""
    self.emit({
      type = "turn_error",
      sessionId = self.localId,
      turnId = turnId,
      error = errMsg,
      metadata = metadata,
    })
    return
  end

  if method == "turn/completed" then
    local turn = P.isPlainObject(params.turn) and params.turn or {}
    local status = P.nullOr(turn.status, nil)
    local turnErr = P.nullOr(turn.error, nil)
    local waiter = self.turnWaiter
    self.turnWaiter = nil
    self.activeTurnId = nil
    self.providerTurnId = nil
    self.turnTerminalEmitted = true
    self.toolStartedAt = {}

    -- Cancel any lingering approval waiters for this completed turn.
    local approvals = self.pendingApprovals
    self.pendingApprovals = {}
    for _, slot in pairs(approvals) do
      slot:resolve(P.APPROVAL_CANCELLED)
    end

    local metadata = {
      status = status ~= nil and status or P.JSON_NULL,
      error = turnErr ~= nil and turnErr or P.JSON_NULL,
    }

    if status == "completed" then
      self.emit({
        type = "turn_completed",
        sessionId = self.localId,
        turnId = turnId,
        metadata = metadata,
      })
      if waiter then
        waiter:resolve({ status = "completed" })
      end
    elseif status == "failed" then
      local msg = tostring(
        (type(turnErr) == "table" and P.isNonEmpty(turnErr.message) and turnErr.message)
          or "codex turn failed"
      )
      self.emit({
        type = "turn_failed",
        sessionId = self.localId,
        turnId = turnId,
        error = msg,
        failureReason = "execution",
        reconcile = false,
        metadata = metadata,
      })
      if waiter then
        waiter:reject(P.newAppServerError(msg, {
          failureReason = "execution",
          reconcile = false,
          code = type(turnErr) == "table" and P.nullOr(turnErr.code, nil) or nil,
        }))
      end
    else
      local statusLabel = status ~= nil and tostring(status) or "unknown"
      local msg = "Unsupported Codex turn status: " .. statusLabel
      self.emit({
        type = "turn_failed",
        sessionId = self.localId,
        turnId = turnId,
        error = msg,
        failureReason = "protocol",
        reconcile = true,
        metadata = metadata,
      })
      if waiter then
        waiter:reject(P.newProtocolError(msg, {
          code = type(turnErr) == "table" and P.nullOr(turnErr.code, nil) or nil,
        }))
      end
    end
    return
  end

  if P.startsWith(method, "item/") then
    local suffix = method:match("/([^/]+)$") or ""
    if suffix == "progress" or suffix == "outputDelta" then
      local text = suffix == "progress" and params.message or params.delta
      if type(text) == "string" then
        self.emit({
          type = "tool_output_delta",
          sessionId = self.localId,
          turnId = turnId,
          toolCallId = not P.isNull(params.itemId) and tostring(params.itemId) or "",
          text = text,
          metadata = { kind = suffix == "progress" and "progress" or "output" },
        })
      end
    end
  end
end

function CodexAppServer:close(timeoutMs)
  if self.closeToken ~= nil then
    if not self.closeDone then
      task.multi_wait(self.closeToken)
    end
    return
  end
  self.closing = true
  self.closed = true
  self.closeToken = {}
  self.closeDone = false
  local ok, err = pcall(function()
    self:_performClose(timeoutMs ~= nil and timeoutMs or self.shutdownTimeoutMs)
  end)
  self.closeDone = true
  task.multi_wakeup(self.closeToken)
  if not ok then
    P.raiseErr(err)
  end
end

function CodexAppServer:_performClose(timeoutMs)
  local parsedBudget = P.toFiniteNumber(timeoutMs)
  local budgetMs = (parsedBudget ~= nil and parsedBudget >= 0)
    and parsedBudget
    or P.DEFAULT_SHUTDOWN_TIMEOUT_MS
  local started = P.nowMs()
  local deadline = started + budgetMs

  self:_rejectAllWaiters(P.newAppServerUnavailable("Codex app-server was closed"), {
    emitTurnFailed = false,
  })

  pcall(self.proc.closeStdin, self.proc)

  local exitTok = {}
  local procExited = self.exited
  if not procExited then
    task.fork(function()
      pcall(self.proc.wait, self.proc)
      procExited = true
      task.wakeup(exitTok)
    end)
  end

  local function waitUntil(stageDeadlineMs)
    if procExited or self.exited then
      return true
    end
    local remaining = P.toDelayMs(stageDeadlineMs - P.nowMs())
    if remaining <= 0 then
      return false
    end
    pcall(task.wait, exitTok, remaining)
    return procExited or self.exited
  end

  local stages = {
    { fraction = 0.6, action = nil },
    { fraction = 0.8, action = "SIGTERM" },
    { fraction = 0.9, action = "SIGKILL" },
  }

  for _, stage in ipairs(stages) do
    if procExited or self.exited then
      break
    end
    if stage.action == "SIGTERM" then
      pcall(self.proc.signal, self.proc, "SIGTERM")
    elseif stage.action == "SIGKILL" then
      pcall(self.proc.kill, self.proc)
    end
    if waitUntil(started + budgetMs * stage.fraction) then
      break
    end
  end

  if not (procExited or self.exited) then
    pcall(self.proc.kill, self.proc)
    local remaining = P.toDelayMs(deadline - P.nowMs())
    if remaining > 0 then
      if not waitUntil(deadline) then
        log.warn("Codex cleanup reached shutdown budget", { sessionId = self.localId })
      end
    else
      pcall(self.proc.wait, self.proc)
      procExited = true
    end
  else
    pcall(self.proc.wait, self.proc)
  end
  if procExited then
    self.exited = true
  end
end

local function spawnAppServer(options)
  local opts = type(options) == "table" and options or {}
  local spawnOpts = {
    command = "codex",
    args = P.newArray({ "app-server", "--listen", "stdio://" }),
    env = opts.env or {},
  }
  if not P.isNull(opts.workspace) and opts.workspace ~= "" then
    spawnOpts.cwd = tostring(opts.workspace)
  end
  local proc = process.spawn(spawnOpts)
  local srvOpts = {}
  for k, v in pairs(opts) do
    srvOpts[k] = v
  end
  srvOpts.proc = proc
  local srv = CodexAppServer.new(srvOpts)
  srv:startReaders()
  return srv
end

return {
  CodexAppServer = CodexAppServer,
  spawnAppServer = spawnAppServer,
}
