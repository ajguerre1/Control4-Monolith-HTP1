-- The XML and htp1/mapping.lua describe the same connections. If they disagree,
-- an input silently stops switching. Parsed with patterns rather than an XML
-- library: the check is structural, and LuaJIT ships no XML parser.

local H = require("tests.harness")
local Mapping = require("htp1.mapping")

local function readManifest()
    local handle = assert(io.open("driver.xml", "r"), "driver.xml should exist")
    local text = handle:read("*a")
    handle:close()
    return text
end

-- Returns { [id] = { name = ..., type = ..., raw = ... } } for every <connection>.
local function parseConnections(xml)
    local connections = {}
    for block in xml:gmatch("<connection.->(.-)</connection>") do
        local id = tonumber(block:match("<id>%s*(%d+)%s*</id>"))
        if id then
            connections[id] = {
                name = block:match("<connectionname>%s*(.-)%s*</connectionname>"),
                type = tonumber(block:match("<type>%s*(%d+)%s*</type>")),
                raw  = block,
            }
        end
    end
    return connections
end

return {
    {
        name = "the manifest declares the receiver proxy on binding 5001",
        fn = function()
            local xml = readManifest()
            H.isTrue(xml:find('proxybindingid="5001"', 1, true) ~= nil, "proxy binding")
            H.isTrue(xml:find(">receiver</proxy>", 1, true) ~= nil, "the receiver proxy")
        end,
    },
    {
        name = "auto update is disabled so the director cannot substitute a build",
        fn = function()
            local xml = readManifest()
            H.isTrue(xml:find("<auto_update>false</auto_update>", 1, true) ~= nil)
        end,
    },
    {
        name = "every mapped input has a connection with a matching id",
        fn = function()
            local connections = parseConnections(readManifest())
            for _, input in ipairs(Mapping.INPUTS) do
                H.isTrue(connections[input.binding] ~= nil,
                    "no <connection> for binding " .. input.binding .. " (" .. input.key .. ")")
                H.equal(connections[input.binding].name, input.name,
                    "name for binding " .. input.binding)
            end
        end,
    },
    {
        name = "every input connection in the manifest is mapped",
        fn = function()
            local connections = parseConnections(readManifest())
            -- Input connections live in the 1000 and 3000 ranges; 1008 is the
            -- hidden eARC video binding, which is deliberately unmapped.
            for id in pairs(connections) do
                local isInput = (id >= 1000 and id < 2000) or (id >= 3000 and id < 4000)
                if isInput and id ~= 1008 then
                    H.isTrue(Mapping.bindingToKey(id) ~= nil,
                        "connection " .. id .. " has no row in Mapping.INPUTS")
                end
            end
        end,
    },
    {
        name = "the proxy and control connections both exist in their own right",
        fn = function()
            local connections = parseConnections(readManifest())

            -- Test 1 only greps for proxybindingid="5001", which every input
            -- connection also carries, so the proxy's own connection block could
            -- be deleted with the suite still green.
            local proxy = connections[Mapping.PROXY_BINDING]
            H.isTrue(proxy ~= nil, "connection 5001 should exist")
            H.equal(proxy.type, 2, "the proxy connection is type 2")
            H.isTrue(proxy.raw:find("RECEIVER", 1, true) ~= nil, "class RECEIVER")

            -- Without 6001 the driver has no socket at all, and nothing else
            -- asserted its presence.
            local control = connections[Mapping.NETWORK_BINDING]
            H.isTrue(control ~= nil, "connection 6001 should exist")
            H.equal(control.type, 4, "a network connection is type 4")
            H.isTrue(control.raw:find("TCP", 1, true) ~= nil, "class TCP")
            H.isTrue(control.raw:find("<number>80</number>", 1, true) ~= nil, "port 80")
            H.equal(control.raw:find("<delimiter", 1, true), nil,
                "a delimiter would chop the byte stream the websocket framing needs intact")
        end,
    },
    {
        name = "no connection id is declared twice",
        fn = function()
            -- parseConnections keys on id, so a duplicate would silently
            -- overwrite rather than fail, and the two blocks could disagree.
            local xml = readManifest()
            local seen, ids = {}, 0
            for block in xml:gmatch("<connection.->(.-)</connection>") do
                local id = block:match("<id>%s*(%d+)%s*</id>")
                if id then
                    ids = ids + 1
                    H.equal(seen[id], nil, "connection id " .. id .. " is declared twice")
                    seen[id] = true
                end
            end
            H.isTrue(ids >= 24, "expected the full connection block, found " .. ids)
        end,
    },
    {
        name = "the room end-point carries both audio selection and volume classes",
        fn = function()
            local connections = parseConnections(readManifest())
            local endpoint = connections[Mapping.ROOM_OUTPUT]
            H.isTrue(endpoint ~= nil, "connection 7000 should exist")
            H.equal(endpoint.type, 7, "a room end-point is type 7")
            H.isTrue(endpoint.raw:find("AUDIO_SELECTION", 1, true) ~= nil, "AUDIO_SELECTION")
            H.isTrue(endpoint.raw:find("AUDIO_VOLUME", 1, true) ~= nil,
                "AUDIO_VOLUME is what makes room volume commands arrive")
        end,
    },
    {
        name = "the surround modes match the mapping, by id and name",
        fn = function()
            local xml = readManifest()
            for _, mode in ipairs(Mapping.SURROUND) do
                local pattern = "<name>" .. mode.name:gsub("([%-%.%:])", "%%%1") ..
                    "</name>%s*<id>" .. mode.id .. "</id>"
                H.isTrue(xml:find(pattern) ~= nil,
                    "no surround_mode for " .. mode.name .. " with id " .. mode.id)
            end
        end,
    },
    {
        name = "tone controls are declared absent, because the unit has none",
        fn = function()
            local xml = readManifest()
            for _, capability in ipairs({ "has_discrete_bass_control", "has_discrete_treble_control",
                                          "has_discrete_balance_control" }) do
                H.isTrue(xml:find("<" .. capability .. ">False</" .. capability .. ">", 1, true) ~= nil,
                    capability .. " must be False: the unit has EQ, not tone controls")
            end
        end,
    },
    {
        name = "every property the driver reads is declared",
        fn = function()
            local xml = readManifest()
            for _, name in ipairs({ "Driver Version", "Firmware Version", "Serial Number", "Model",
                                    "Connection Status", "Maximum Volume", "Volume Ramp Rate",
                                    "Power Off Action", "Adopt Input Labels", "Debug Mode" }) do
                H.isTrue(xml:find("<name>" .. name .. "</name>", 1, true) ~= nil,
                    "missing property: " .. name)
            end
        end,
    },
}
