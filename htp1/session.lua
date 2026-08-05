-- What happens between a live socket and the driver's state.
--
-- The transport knows how to stay connected and nothing else. This module knows
-- the conversation: ask for the document when the socket opens, fold every push
-- into the projection, and coalesce outbound writes so a hold-to-ramp does not
-- become a message per step.
--
-- The transport is injected, so this tests against a fake with no socket at all.

local Protocol = require("htp1.protocol")

local Session = {}
Session.__index = Session

-- A parse failure means the unit sent bytes this driver could not decode as
-- its own protocol -- the 38 KB mso reply is the realistic case. Below this
-- many consecutive failures the fastest recovery is just asking again; at it,
-- something is wrong enough that re-reading at line rate would only turn one
-- bad reply into an unthrottled request storm, plus a log line per iteration.
-- The reconcile timer and a fresh reconnect remain the way out.
local MAX_PARSE_FAILURES = 3

function Session.new(opts)
    return setmetatable({
        transport   = opts.transport,
        state       = opts.state,
        log         = opts.log,
        onChanges   = opts.onChanges or function() end,
        onConnected = opts.onConnected or function() end,
        flushMs     = opts.flushMs or 50,
        reconcileMs = opts.reconcileMs or 2000,
        connected   = false,
        queue       = {},   -- path -> value
        order       = {},   -- paths, in the order first queued
        pending     = {},   -- path -> value awaiting the unit's confirmation
        flushTimer  = nil,
        reconcileTimer = nil,
        parseFailures  = 0,
    }, Session)
end

function Session:start()
    self.transport:connect()
end

function Session:stop()
    self:_cancelTimers()
    self.queue, self.order, self.pending = {}, {}, {}
    self.connected = false
    self.transport:close()
end

function Session:_cancelTimers()
    if self.flushTimer then self.flushTimer:Cancel(); self.flushTimer = nil end
    if self.reconcileTimer then self.reconcileTimer:Cancel(); self.reconcileTimer = nil end
end

function Session:refresh()
    if self.transport:isOpen() then
        self.transport:send(Protocol.GET_MSO)
    end
end

function Session:onOpen()
    self.log:debug("socket open, requesting the document")
    self:refresh()
end

function Session:onClose(reason)
    self.log:debug("session down:", reason)
    self:_cancelTimers()
    -- Anything queued belongs to a conversation that no longer exists. Replaying
    -- it after a reconnect would apply a stale command minutes later.
    self.queue, self.order, self.pending = {}, {}, {}
    self.parseFailures = 0
    if self.connected then
        self.connected = false
        self.onConnected(false)
    end
end

function Session:onMessage(text)
    local message = Protocol.parse(text)

    if message.err then
        self.parseFailures = self.parseFailures + 1
        if self.parseFailures < MAX_PARSE_FAILURES then
            self.log:error("undecodable message from the unit: " .. message.err)
            self:refresh()
        elseif self.parseFailures == MAX_PARSE_FAILURES then
            -- The cap: log exactly once here, then go quiet. Re-reading a
            -- reply that keeps failing to decode would only re-request it at
            -- line rate; every failure past this one is dropped on the floor
            -- until the reconcile timer or a reconnect gives the unit a fresh
            -- chance to answer.
            self.log:error("undecodable message from the unit: " .. message.err ..
                " (" .. MAX_PARSE_FAILURES .. " consecutive failures, giving up until " ..
                "the next reconcile or reconnect)")
        end
        return
    end

    self.parseFailures = 0

    if message.verb == "mso" then
        local changes = self.state:applyDocument(message.arg)
        self.pending = {}
        if not self.connected then
            self.connected = true
            self.onConnected(true)
        end
        if next(changes) then self.onChanges(changes) end

    elseif message.verb == "msoupdate" then
        self:_clearConfirmed(message.arg)
        local changes = self.state:applyOps(message.arg)
        if next(changes) then self.onChanges(changes) end

    elseif message.verb == "error" then
        -- The unit answers junk with error "bad-verb" and keeps the socket open,
        -- so this is a log line, not a disconnect.
        self.log:error("the unit rejected a message: " .. tostring(message.arg))

    else
        self.log:debug("ignoring verb", message.verb)
    end
end

function Session:_clearConfirmed(ops)
    if type(ops) ~= "table" then return end
    local list = (ops.op ~= nil and ops.path ~= nil) and { ops } or ops
    for _, operation in ipairs(list) do
        if type(operation) == "table" and operation.path then
            self.pending[operation.path] = nil
        end
    end
    if next(self.pending) == nil and self.reconcileTimer then
        self.reconcileTimer:Cancel()
        self.reconcileTimer = nil
    end
end

-- Queue one patch operation. The value is echoed into local state immediately so
-- the room responds at once; the unit's confirming push is then idempotent.
function Session:write(path, value)
    if not self.connected then
        self.log:debug("dropping a write while disconnected:", path)
        return false
    end

    -- nil doubles as this queue's "not queued yet" sentinel, so accepting a nil
    -- value would break coalescing: Lua stores no entry, the path is appended to
    -- `order` again on the next write, and one changemso carries the same op
    -- twice. It would also encode a `replace` with no value at all. No path this
    -- driver writes takes a null, so this is a caller bug worth surfacing.
    if value == nil then
        self.log:error("refusing a nil write to " .. tostring(path))
        return false
    end

    if self.queue[path] == nil then table.insert(self.order, path) end
    self.queue[path] = value
    self.pending[path] = value

    local changes = self.state:applyOps({ { op = "replace", path = path, value = value } })
    if next(changes) then self.onChanges(changes) end

    if not self.flushTimer then
        self.flushTimer = C4:SetTimer(self.flushMs, function()
            self.flushTimer = nil
            self:flush()
        end, false)
    end
    return true
end

function Session:flush()
    if #self.order == 0 then return end

    local ops = {}
    for _, path in ipairs(self.order) do
        table.insert(ops, Protocol.op("replace", path, self.queue[path]))
    end
    self.queue, self.order = {}, {}

    self.transport:send(Protocol.encodeChange(ops))

    -- Re-armed per flush, not left running from the first one. Inheriting an
    -- older deadline would give a later write less than its full grace period
    -- and re-read the document while its confirmation was still in flight.
    if self.reconcileTimer then self.reconcileTimer:Cancel() end
    do
        self.reconcileTimer = C4:SetTimer(self.reconcileMs, function()
            self.reconcileTimer = nil
            if next(self.pending) ~= nil then
                -- The unit never confirmed. Rather than let local state drift,
                -- throw it away and re-read.
                self.log:debug("unconfirmed write, re-reading the document")
                self.pending = {}
                self:refresh()
            end
        end, false)
    end
end

return Session
