local task = require("bazaar.task")
local timers = require("bazaar.timers")
local http = require("bazaar.http")
local json = require("bazaar.json")
local time = require("bazaar.time")

local baseUrl = ""
local emitFn = nil
local stopping = false
local seq = 0

local function connect(_ctx, config, emit)
  baseUrl = tostring((type(config) == "table" and config.baseUrl) or ""):gsub("/+$", "")
  assert(baseUrl ~= "", "channel-e2e: baseUrl is required")
  emitFn = emit
  stopping = false

  emit({
    type = "connected",
    identity = { id = "e2e-bot", name = "E2E Bot", username = "e2e_bot" },
    timestampMs = time.nowMs(),
  })

  task.fork(function()
    while not stopping do
      local ok, res = pcall(http.request, {
        url = baseUrl .. "/poll",
        method = "GET",
        timeoutMs = 10000,
      })
      if stopping then
        break
      end
      if ok and type(res) == "table" and res.ok and type(res.body) == "string" and #res.body > 0 then
        local dok, items = pcall(json.decode, res.body)
        if dok and type(items) == "table" then
          for i = 1, #items do
            if stopping then
              break
            end
            local ev = items[i]
            if type(ev) == "table" and type(ev.type) == "string" and emitFn then
              emitFn(ev)
            end
          end
        end
      else
        timers.sleep(100)
      end
    end
  end)
end

local function send(req)
  seq = seq + 1
  local msgId = "out-" .. tostring(seq)
  local ok, res = pcall(http.request, {
    url = baseUrl .. "/outbound",
    method = "POST",
    headers = { ["Content-Type"] = "application/json" },
    body = json.encode({
      id = msgId,
      target = req.target,
      body = req.body,
      replyToId = req.replyToId,
      attachmentIds = req.attachmentIds,
      attachmentPaths = req.attachmentPaths,
    }),
    timeoutMs = 10000,
  })
  if not ok or type(res) ~= "table" or not res.ok then
    return { status = "failed", error = "outbound POST failed" }
  end
  return { status = "sent", ids = json.array({ msgId }) }
end

local function promptInteraction(prompt)
  local ok, res = pcall(http.request, {
    url = baseUrl .. "/prompt",
    method = "POST",
    headers = { ["Content-Type"] = "application/json" },
    body = json.encode(prompt),
    timeoutMs = 15000,
  })
  if not ok or type(res) ~= "table" or not res.ok then
    error("channel-e2e: prompt POST failed", 0)
  end
  if type(res.body) == "string" and #res.body > 0 then
    local dok, decision = pcall(json.decode, res.body)
    if dok and type(decision) == "table" and type(decision.actionId) == "string" and decision.actionId ~= "" then
      local responderId = (type(decision.responderId) == "string" and decision.responderId ~= "")
        and decision.responderId
        or tostring(prompt.allowedActorId or "")
      task.fork(function()
        if emitFn and not stopping then
          emitFn({
            type = "interaction_response",
            promptId = prompt.promptId,
            actionId = decision.actionId,
            responderId = responderId,
            target = prompt.target,
            timestampMs = time.nowMs(),
          })
        end
      end)
    end
  end
end

local function cancelInteraction(promptId, reason)
  pcall(http.request, {
    url = baseUrl .. "/cancel",
    method = "POST",
    headers = { ["Content-Type"] = "application/json" },
    body = json.encode({ promptId = promptId, reason = reason }),
    timeoutMs = 5000,
  })
end

local function disconnect()
  stopping = true
  if emitFn then
    emitFn({ type = "disconnected", timestampMs = time.nowMs() })
  end
  emitFn = nil
end

return {
  connect = connect,
  send = send,
  promptInteraction = promptInteraction,
  cancelInteraction = cancelInteraction,
  disconnect = disconnect,
}
