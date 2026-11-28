-- Official Codex CLI (app-server stdio JSON-RPC) harness plugin for Bazaar Compute 0.4.

local log = require("bazaar.log")
local time = require("bazaar.time")
local P = require("./protocol")
local S = require("./server")

local sessions = {}
local lastKnownWorkspace = ""

local function inspect(ctx, config)
  local env = {}
  local apiKey = P.resolveApiKey(config)
  if apiKey ~= "" then
    env.OPENAI_API_KEY = apiKey
  end

  local workspace = tostring((type(ctx) == "table" and P.isNonEmpty(ctx.workspace) and ctx.workspace) or lastKnownWorkspace or "")
  local startupTimeoutMs = P.resolveStartupTimeoutMs(config)
  local shutdownTimeoutMs = P.resolveShutdownTimeoutMs(config)

  local ver = P.runCollect(
    "codex",
    { "--version" },
    env,
    workspace,
    math.min(startupTimeoutMs, P.DEFAULT_VERSION_TIMEOUT_MS)
  )
  local verOut = P.trim(ver.stdout)
  if ver.code ~= 0 or verOut == "" then
    local verErr = P.trim(ver.stderr)
    return {
      available = false,
      error = verErr ~= "" and verErr or ("codex --version exited (" .. tostring(ver.code) .. ")"),
    }
  end
  local version = verOut:match("(%S+)$") or "unknown"

  local models = P.newArray()
  local skills = P.newArray()
  local mcpServers = P.newArray()
  local skillErrors = {}
  local srv = nil

  local ok, err = pcall(function()
    srv = S.spawnAppServer({
      localId = "codex-inspect",
      workspace = workspace,
      env = env,
      startupTimeoutMs = startupTimeoutMs,
      shutdownTimeoutMs = shutdownTimeoutMs,
      autoDeclineRequests = true,
      emitSessionLifecycle = false,
    })
    srv:initialize(startupTimeoutMs)

    -- 1. Paginated model/list
    local seenModelCursors = {}
    local cursor = nil
    while true do
      local page = srv:request(
        "model/list",
        { cursor = cursor ~= nil and cursor or P.JSON_NULL },
        startupTimeoutMs
      )
      local items = (type(page) == "table" and P.isArray(page.data)) and page.data or {}
      for _, item in ipairs(items) do
        if P.isPlainObject(item) and item.hidden ~= true then
          local id = (not P.isNull(item.model) and tostring(item.model))
            or (not P.isNull(item.id) and tostring(item.id))
            or ""
          if id ~= "" then
            local rawEfforts = P.isArray(item.supportedReasoningEfforts) and item.supportedReasoningEfforts or {}
            local efforts = P.newArray()
            for _, opt in ipairs(rawEfforts) do
              local effort = type(opt) == "string" and opt or (type(opt) == "table" and opt.reasoningEffort or nil)
              if type(effort) == "string" and #effort > 0 then
                efforts[#efforts + 1] = effort
              end
            end
            local entry = {
              id = id,
              name = P.isNonEmpty(item.displayName) and tostring(item.displayName) or id,
              efforts = efforts,
              default = item.isDefault == true,
            }
            if P.isNonEmpty(item.defaultReasoningEffort) then
              entry.defaultEffort = tostring(item.defaultReasoningEffort)
            end
            models[#models + 1] = entry
          end
        end
      end
      local nextCursor = type(page) == "table" and P.nullOr(page.nextCursor, nil) or nil
      if nextCursor == nil or seenModelCursors[nextCursor] then
        break
      end
      seenModelCursors[nextCursor] = true
      cursor = nextCursor
    end

    -- 2. skills/list
    local skillsParams = workspace ~= "" and { cwds = P.newArray({ workspace }) } or {}
    local skillsRes = srv:request("skills/list", skillsParams, startupTimeoutMs)
    local skillEntries = (type(skillsRes) == "table" and P.isArray(skillsRes.data)) and skillsRes.data or {}
    for _, entry in ipairs(skillEntries) do
      if P.isPlainObject(entry) then
        local entrySkills = P.isArray(entry.skills) and entry.skills or {}
        for _, skill in ipairs(entrySkills) do
          if P.isPlainObject(skill) and skill.enabled ~= false then
            local name = P.isNonEmpty(skill.name) and tostring(skill.name) or ""
            if name ~= "" then
              local scope = (type(skill.scope) == "string" and P.SKILL_SCOPE_MAP[skill.scope]) or "system"
              local ifaceShort = type(skill.interface) == "table" and skill.interface.shortDescription or nil
              local description = tostring(
                (P.isNonEmpty(ifaceShort) and ifaceShort)
                  or (P.isNonEmpty(skill.shortDescription) and skill.shortDescription)
                  or (P.isNonEmpty(skill.description) and skill.description)
                  or ""
              )
              skills[#skills + 1] = {
                name = name,
                scope = scope,
                description = description,
              }
            end
          end
        end
        local entryErrors = P.isArray(entry.errors) and entry.errors or {}
        for _, errItem in ipairs(entryErrors) do
          local msg = type(errItem) == "string" and errItem or (type(errItem) == "table" and errItem.message or nil)
          if P.isNonEmpty(msg) then
            skillErrors[#skillErrors + 1] = tostring(msg)
          end
        end
      end
    end

    -- 3. Paginated mcpServerStatus/list
    local seenMcpCursors = {}
    cursor = nil
    while true do
      local page = srv:request(
        "mcpServerStatus/list",
        { cursor = cursor ~= nil and cursor or P.JSON_NULL },
        startupTimeoutMs
      )
      local items = (type(page) == "table" and P.isArray(page.data)) and page.data or {}
      for _, item in ipairs(items) do
        if P.isPlainObject(item) and P.isNonEmpty(item.name) then
          local status, errText = P.mapMcpStatus(item)
          local rawTools = item.tools
          local toolValues = {}
          if P.isArray(rawTools) then
            toolValues = rawTools
          elseif P.isPlainObject(rawTools) then
            for _, k in ipairs(P.sortedKeys(rawTools)) do
              toolValues[#toolValues + 1] = rawTools[k]
            end
          end
          local tools = P.newArray()
          for _, t in ipairs(toolValues) do
            if P.isPlainObject(t) and P.isNonEmpty(t.name) then
              local toolEntry = { name = tostring(t.name) }
              if P.isNonEmpty(t.description) then
                toolEntry.description = tostring(t.description)
              end
              if P.isPlainObject(t.inputSchema) then
                toolEntry.parameters = t.inputSchema
              end
              tools[#tools + 1] = toolEntry
            end
          end
          local serverEntry = {
            name = tostring(item.name),
            tools = tools,
          }
          if status ~= "" then
            serverEntry.status = status
          end
          if errText ~= "" then
            serverEntry.error = errText
          end
          mcpServers[#mcpServers + 1] = serverEntry
        end
      end
      local nextCursor = type(page) == "table" and P.nullOr(page.nextCursor, nil) or nil
      if nextCursor == nil or seenMcpCursors[nextCursor] then
        break
      end
      seenMcpCursors[nextCursor] = true
      cursor = nextCursor
    end
  end)

  if srv then
    pcall(function()
      srv:close(shutdownTimeoutMs)
    end)
  end

  if ok then
    local out = {
      available = true,
      version = version,
      models = models,
      skills = skills,
      mcpServers = mcpServers,
    }
    if #skillErrors > 0 then
      out.error = table.concat(skillErrors, "\n")
    end
    return out
  end

  local msg = P.errMessage(err)
  return {
    available = true,
    version = version,
    models = models,
    skills = skills,
    mcpServers = mcpServers,
    error = msg ~= "" and msg or "Codex inspection failed",
  }
end

local function readQuota(ctx, config)
  local env = {}
  local apiKey = P.resolveApiKey(config)
  if apiKey ~= "" then
    env.OPENAI_API_KEY = apiKey
  end

  local workspace = tostring((type(ctx) == "table" and P.isNonEmpty(ctx.workspace) and ctx.workspace) or lastKnownWorkspace or "")
  local startupTimeoutMs = P.resolveStartupTimeoutMs(config)
  local shutdownTimeoutMs = P.resolveShutdownTimeoutMs(config)

  local srv = nil
  local ok, result = pcall(function()
    srv = S.spawnAppServer({
      localId = "codex-quota-probe",
      workspace = workspace,
      env = env,
      startupTimeoutMs = startupTimeoutMs,
      shutdownTimeoutMs = shutdownTimeoutMs,
      autoDeclineRequests = true,
      emitSessionLifecycle = false,
    })
    srv:initialize(startupTimeoutMs)
    local rl = srv:request("account/rateLimits/read", {}, startupTimeoutMs)
    local observedAtMs = time.nowMs()
    return P.parseQuotaSnapshot(rl, observedAtMs)
  end)

  if srv then
    pcall(function()
      srv:close(shutdownTimeoutMs)
    end)
  end

  if not ok then
    return nil
  end
  return result
end

local function openSession(_ctx, config, input, emit)
  local cfg = type(config) == "table" and config or {}
  local inp = type(input) == "table" and input or {}
  local env = {}
  if type(inp.env) == "table" then
    for k, v in pairs(inp.env) do
      if not P.isNull(v) then
        env[k] = v
      end
    end
  end
  if P.isNonEmpty(env.BCN_SESSION_TOKEN) then
    P.registerSecret(tostring(env.BCN_SESSION_TOKEN))
  end
  local apiKey = P.resolveApiKey(cfg)
  if apiKey ~= "" then
    env.OPENAI_API_KEY = apiKey
  end

  local localId = P.isNonEmpty(inp.sessionId)
    and tostring(inp.sessionId)
    or ("codex-" .. tostring(time.nowMs()))
  local workspace = not P.isNull(inp.workspace) and tostring(inp.workspace) or ""
  if workspace ~= "" then
    lastKnownWorkspace = workspace
  end

  local sandboxPolicy = inp.sandboxPolicy == "danger-full-access"
    and "danger-full-access"
    or "workspace-write"
  local configuredModel = P.isNonEmpty(cfg.model) and tostring(cfg.model) or nil
  local configuredEffort = P.isNonEmpty(cfg.effort) and tostring(cfg.effort) or nil
  local startupTimeoutMs = P.resolveStartupTimeoutMs(cfg, inp)
  local shutdownTimeoutMs = P.resolveShutdownTimeoutMs(cfg, inp)

  -- Close any superseded session with the same localId.
  local previous = sessions[localId]
  if previous then
    sessions[localId] = nil
    pcall(function()
      previous:close(shutdownTimeoutMs)
    end)
  end

  local srv = nil
  for attempt = 1, 2 do
    local spawnOk, spawnedOrErr = pcall(S.spawnAppServer, {
      localId = localId,
      workspace = workspace,
      env = env,
      emit = emit,
      sandboxPolicy = sandboxPolicy,
      configuredModel = configuredModel,
      configuredEffort = configuredEffort,
      startupTimeoutMs = startupTimeoutMs,
      shutdownTimeoutMs = shutdownTimeoutMs,
      autoDeclineRequests = false,
      emitSessionLifecycle = true,
    })
    if not spawnOk then
      P.raiseBoundaryErr(spawnedOrErr)
    end
    srv = spawnedOrErr

    local initOk, initErr = pcall(function()
      local initRes = srv:initialize(startupTimeoutMs)
      if type(initRes) == "table" and P.isNonEmpty(initRes.codexHome) then
        srv.codexHome = tostring(initRes.codexHome)
        srv:startWatches(startupTimeoutMs)
      end
    end)
    if initOk then
      break
    end

    pcall(function()
      srv:close(shutdownTimeoutMs)
    end)
    srv = nil

    local isTimeout = type(initErr) == "table" and initErr.isTimeout == true
    if not isTimeout or attempt == 2 then
      P.raiseBoundaryErr(initErr)
    end
    log.warn("Retrying Codex initialization after timeout", {
      sessionId = localId,
      attempt = attempt,
    })
  end

  local ok, resultOrErr = pcall(function()
    local developerInstructions = ""
    if P.isArray(inp.instructions) then
      local parts = {}
      for _, s in ipairs(inp.instructions) do
        if not P.isNull(s) then
          parts[#parts + 1] = tostring(s)
        end
      end
      developerInstructions = table.concat(parts, "\n\n")
    elseif not P.isNull(inp.instructions) then
      developerInstructions = tostring(inp.instructions)
    end

    local threadParams = {
      cwd = workspace,
      model = configuredModel ~= nil and configuredModel or P.JSON_NULL,
      developerInstructions = developerInstructions,
      approvalPolicy = "on-request",
      sandbox = sandboxPolicy,
    }

    local threadRes
    if P.isNonEmpty(inp.resumeSessionId) then
      local expectedThreadId = tostring(inp.resumeSessionId)
      local resumeParams = { threadId = expectedThreadId }
      for k, v in pairs(threadParams) do
        resumeParams[k] = v
      end
      threadRes = srv:request("thread/resume", resumeParams, startupTimeoutMs)
      local returnedId = (type(threadRes) == "table" and type(threadRes.thread) == "table" and P.nullOr(threadRes.thread.id, nil))
        or (type(threadRes) == "table" and P.nullOr(threadRes.threadId, nil))
        or nil
      if not P.isNonEmpty(returnedId) then
        P.raiseErr(P.newProtocolError("Codex thread/resume response missing thread.id"))
      end
      if tostring(returnedId) ~= expectedThreadId then
        P.raiseErr(P.newAppServerError(
          "Codex resumed a different provider thread (expected "
            .. expectedThreadId
            .. ", got "
            .. tostring(returnedId)
            .. ")",
          { failureReason = "state_mismatch", reconcile = false }
        ))
      end
      srv.threadId = tostring(returnedId)
    else
      threadRes = srv:request("thread/start", threadParams, startupTimeoutMs)
      local returnedId = (type(threadRes) == "table" and type(threadRes.thread) == "table" and P.nullOr(threadRes.thread.id, nil))
        or (type(threadRes) == "table" and P.nullOr(threadRes.threadId, nil))
        or nil
      if not P.isNonEmpty(returnedId) then
        P.raiseErr(P.newProtocolError("Codex thread/start response missing thread.id"))
      end
      srv.threadId = tostring(returnedId)
    end

    srv.model = tostring(
      (type(threadRes) == "table" and P.isNonEmpty(threadRes.model) and threadRes.model)
        or configuredModel
        or ""
    )
    sessions[localId] = srv
    if emit then
      emit({
        type = "session_started",
        sessionId = localId,
        model = srv.model,
        metadata = { providerThreadId = srv.threadId },
      })
    end
    return { sessionId = localId, model = srv.model }
  end)

  if not ok then
    pcall(function()
      srv:close(shutdownTimeoutMs)
    end)
    P.raiseBoundaryErr(resultOrErr)
  end
  return resultOrErr
end

local function startTurn(sessionId, input)
  local srv = sessions[sessionId]
  if not srv or srv.closed or srv.exited then
    P.raiseBoundaryErr(P.newAppServerUnavailable("codex: session " .. tostring(sessionId) .. " is not open"))
  end
  if srv.activeTurnId ~= nil or srv.turnWaiter ~= nil then
    P.raiseBoundaryErr("codex: session " .. tostring(sessionId) .. " already owns an active turn")
  end

  local inp = type(input) == "table" and input or {}
  local turnId = not P.isNull(inp.turnId) and tostring(inp.turnId) or ""
  srv.activeTurnId = turnId
  srv.providerTurnId = nil
  srv.turnTerminalEmitted = false
  srv.toolStartedAt = {}

  local turnSlot = P.newWaitSlot()
  srv.turnWaiter = turnSlot

  local initialModel = P.isNonEmpty(srv.configuredModel) and srv.configuredModel or srv.model
  if P.isNonEmpty(initialModel) then
    srv.emit({
      type = "model_updated",
      sessionId = srv.localId,
      turnId = turnId,
      model = initialModel,
    })
  end

  local turnSandboxPolicy
  if srv.sandboxPolicy == "danger-full-access" then
    turnSandboxPolicy = { type = "dangerFullAccess" }
  else
    turnSandboxPolicy = {
      type = "workspaceWrite",
      writableRoots = srv.workspace ~= "" and P.newArray({ srv.workspace }) or P.newArray(),
      networkAccess = true,
    }
  end

  local ok, resultOrErr = pcall(function()
    local res = srv:request(
      "turn/start",
      {
        threadId = srv.threadId,
        input = P.buildTurnInputs(inp),
        clientUserMessageId = turnId,
        cwd = srv.workspace,
        model = srv.configuredModel ~= nil and srv.configuredModel or P.JSON_NULL,
        effort = srv.configuredEffort ~= nil and srv.configuredEffort or P.JSON_NULL,
        approvalPolicy = "on-request",
        sandboxPolicy = turnSandboxPolicy,
      },
      srv.startupTimeoutMs
    )

    if not srv.turnTerminalEmitted then
      local returnedTurnId = (type(res) == "table" and type(res.turn) == "table" and P.nullOr(res.turn.id, nil))
        or (type(res) == "table" and P.nullOr(res.turnId, nil))
        or nil
      if not P.isNonEmpty(returnedTurnId) then
        P.raiseErr(P.newProtocolError("Codex turn/start response missing turn.id"))
      end
      srv.providerTurnId = tostring(returnedTurnId)
    end

    return turnSlot:wait()
  end)

  if not ok and not srv.turnTerminalEmitted then
    srv.turnTerminalEmitted = true
    local reason = (type(resultOrErr) == "table" and resultOrErr.failureReason) or "execution"
    local reconcile
    if type(resultOrErr) == "table" and resultOrErr.reconcile ~= nil then
      reconcile = resultOrErr.reconcile == true
    else
      reconcile = reason ~= "execution"
    end
    srv.emit({
      type = "turn_failed",
      sessionId = srv.localId,
      turnId = turnId,
      error = P.errMessage(resultOrErr),
      failureReason = reason,
      reconcile = reconcile,
    })
  end

  -- Always clean up turn state and any lingering approval waiters.
  srv.turnWaiter = nil
  srv.activeTurnId = nil
  srv.providerTurnId = nil
  srv.toolStartedAt = {}
  local approvals = srv.pendingApprovals
  srv.pendingApprovals = {}
  for _, slot in pairs(approvals) do
    slot:resolve(P.APPROVAL_CANCELLED)
  end

  if not ok then
    P.raiseBoundaryErr(resultOrErr)
  end
  return resultOrErr
end

local function steerTurn(sessionId, turnId, inputText)
  local srv = sessions[sessionId]
  if not srv or srv.closed or srv.exited then
    P.raiseBoundaryErr(P.newAppServerUnavailable("codex: session " .. tostring(sessionId) .. " is not open"))
  end
  if not P.isNonEmpty(srv.activeTurnId) or not P.isNonEmpty(srv.providerTurnId) then
    P.raiseBoundaryErr("codex: session " .. tostring(sessionId) .. " has no active turn to steer")
  end
  if not P.isNull(turnId) and tostring(turnId) ~= "" and tostring(turnId) ~= srv.activeTurnId then
    P.raiseBoundaryErr(
      "codex: steer turn mismatch (expected " .. tostring(srv.activeTurnId) .. ", got " .. tostring(turnId) .. ")"
    )
  end

  local expectedTurnId = srv.providerTurnId
  local ok, resultOrErr = pcall(function()
    return srv:request(
      "turn/steer",
      {
        threadId = srv.threadId,
        expectedTurnId = expectedTurnId,
        input = P.newArray({ { type = "text", text = not P.isNull(inputText) and tostring(inputText) or "" } }),
      },
      15000
    )
  end)
  if not ok then
    P.raiseBoundaryErr(resultOrErr)
  end

  local returnedTurnId = type(resultOrErr) == "table" and P.nullOr(resultOrErr.turnId, nil) or nil
  if returnedTurnId ~= expectedTurnId then
    P.raiseBoundaryErr(P.newProtocolError(
      "codex: turn/steer returned unexpected turnId (expected "
        .. tostring(expectedTurnId)
        .. ", got "
        .. tostring(returnedTurnId)
        .. ")"
    ))
  end
  return true
end

local function cancelTurn(sessionId, turnId)
  local srv = sessions[sessionId]
  if not srv or srv.closed or srv.exited or not P.isNonEmpty(srv.providerTurnId) then
    return
  end
  if not P.isNull(turnId) and tostring(turnId) ~= "" and P.isNonEmpty(srv.activeTurnId) and tostring(turnId) ~= srv.activeTurnId then
    return
  end
  local ok, err = pcall(function()
    srv:request(
      "turn/interrupt",
      {
        threadId = srv.threadId,
        turnId = srv.providerTurnId,
      },
      10000
    )
  end)
  if not ok then
    log.debug("codex turn/interrupt failed", {
      sessionId = sessionId,
      error = P.errMessage(err),
    })
  end
end

local function respondApproval(sessionId, requestId, decision)
  local srv = sessions[sessionId]
  if not srv or P.isNull(requestId) then
    return
  end
  local key = tostring(requestId)
  local slot = srv.pendingApprovals[key]
  if slot then
    srv.pendingApprovals[key] = nil
    slot:resolve(decision)
  end
end

local function hasBackgroundJob(sessionId)
  local srv = sessions[sessionId]
  if not srv or srv.closed or srv.exited then
    return false
  end
  local ok, resultOrErr = pcall(function()
    return srv:request(
      "thread/backgroundTerminals/list",
      { threadId = srv.threadId },
      math.min(srv.startupTimeoutMs, 15000)
    )
  end)
  if not ok then
    log.warn("Could not query Codex background terminals; assuming active", {
      sessionId = sessionId,
      error = P.errMessage(resultOrErr),
    })
    return true
  end
  if type(resultOrErr) ~= "table" or not P.isArray(resultOrErr.data) then
    log.warn("Invalid Codex background-terminal response; assuming active", {
      sessionId = sessionId,
    })
    return true
  end
  return #resultOrErr.data > 0
end

local function closeSession(sessionId)
  local srv = sessions[sessionId]
  if not srv then
    return
  end
  sessions[sessionId] = nil
  srv:close()
end

return {
  inspect = inspect,
  readQuota = readQuota,
  openSession = openSession,
  startTurn = startTurn,
  steerTurn = steerTurn,
  cancelTurn = cancelTurn,
  respondApproval = respondApproval,
  hasBackgroundJob = hasBackgroundJob,
  closeSession = closeSession,
}
