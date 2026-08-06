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

-- The documentation page, read from the path driver.xml declares rather than a
-- path repeated here -- so moving the file cannot leave a test reading a stale
-- copy while Composer renders a different one.
local function readDocumentation()
    local file = readManifest():match('<documentation%s+file%s*=%s*"([^"]+)"')
    assert(file, "driver.xml should declare a documentation file")
    local handle = assert(io.open(file, "r"), "declared but missing on disk: " .. file)
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

-- Returns { [id] = name } for every <event>.
local function parseEvents(xml)
    local events = {}
    for block in xml:gmatch("<event>(.-)</event>") do
        local id = tonumber(block:match("<id>%s*(%d+)%s*</id>"))
        local name = block:match("<name>%s*(.-)%s*</name>")
        if id and name then events[id] = name end
    end
    return events
end

-- Returns an array of every declared <command>'s <name>, in document order.
-- Scoped to the <commands> wrapper deliberately: <action> also has a child
-- element literally named <command> (its dispatch token, e.g.
-- REFRESH_FROM_DEVICE), and an unscoped <command>(.-)</command> match picks
-- those up too -- with no <name> of their own to find inside them.
local function parseCommands(xml)
    local names = {}
    local wrapper = xml:match("<commands>(.-)</commands>") or ""
    for block in wrapper:gmatch("<command>(.-)</command>") do
        local name = block:match("<name>%s*(.-)%s*</name>")
        if name then table.insert(names, name) end
    end
    return names
end

-- driver.lua's DRIVER.EVENTS table is assigned at file scope (not inside
-- buildDriver), and none of its requires touch the C4 API at load time, so a
-- bare dofile is enough to read it back -- no mock, no OnDriverInit needed.
local function loadDriverFile()
    for _, name in ipairs({ "DRIVER", "OnDriverInit", "OnDriverLateInit", "OnDriverDestroyed",
                             "OnPropertyChanged", "ExecuteCommand", "ReceivedFromProxy",
                             "OnConnectionStatusChanged", "OnBindingChanged",
                             "OnNetworkBindingChanged", "ReceivedFromNetwork" }) do
        _G[name] = nil
    end
    dofile("driver.lua")
end

local function loadVariableNames()
    loadDriverFile()
    return DRIVER.VARIABLE_NAMES
end

local function loadEventNames()
    loadDriverFile()
    local names = {}
    for _, name in pairs(DRIVER.EVENTS) do names[name] = true end
    return names
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
        name = "the driver claims no room endpoints on its own",
        fn = function()
            local xml = readManifest()
            -- The receiver proxy's own definition claims AudioSelectionDevice,
            -- AudioVolumeDevice, VideoAudioSelectionDevice,
            -- VideoAudioVolumeDevice and VideoSelectionDevice the moment the
            -- driver joins a room. An empty element here overrides that. Losing
            -- it would silently hand a processor every endpoint in the room,
            -- volume included, before anyone chose to give it any.
            local block = xml:match("<roomAutoBind>(.-)</roomAutoBind>")
            H.isTrue(block ~= nil, "an explicit roomAutoBind override should be present")
            H.equal(block:match("^%s*$") ~= nil, true,
                "it must be empty; found: " .. tostring(block))
        end,
    },
    {
        name = "every declared icon exists, is a PNG, and is the size it claims to be",
        fn = function()
            -- Composer and Navigator both fail SILENTLY on a bad icon: a missing
            -- file or a mismatched size just falls back to the stock receiver
            -- image, with nothing in any log. So the check has to be here.
            --
            -- Paths in driver.xml are relative to www/ inside the archive, which
            -- is the part that is easy to get wrong -- "icons/device_sm.png"
            -- means www/icons/device_sm.png, not icons/device_sm.png.
            local xml = readManifest()
            local declared = {}

            for path in xml:gmatch('_image="([^"]+)"') do declared[path] = true end
            for path in xml:gmatch('<small image_source="c4z">([^<]+)</small>') do
                declared[path] = true
            end
            for path in xml:gmatch('<large image_source="c4z">([^<]+)</large>') do
                declared[path] = true
            end
            H.isTrue(next(declared) ~= nil, "the driver should declare Composer icons")

            -- The Navigator ladder carries its size in the element, so each one
            -- asserts against what it itself claims rather than a list here.
            local expected = {
                ["icons/device_sm.png"] = 16,
                ["icons/device_lg.png"] = 32,
            }
            for w, h, uri in xml:gmatch('<Icon width="(%d+)"%s+height="(%d+)">([^<]+)</Icon>') do
                H.equal(w, h, "Navigator icons are square")
                local path = uri:match("^controller://driver/[^/]+/(.+)$")
                H.isTrue(path ~= nil, "unparseable icon URI: " .. uri)
                declared[path] = true
                expected[path] = tonumber(w)
            end

            for path in pairs(declared) do
                local file = "www/" .. path
                local handle = io.open(file, "rb")
                H.isTrue(handle ~= nil, "declared but missing on disk: " .. file)
                local header = handle:read(24)
                handle:close()

                H.equal(header:sub(2, 4), "PNG", file .. " should be a PNG")
                -- IHDR carries width and height as big-endian 32-bit at byte 17.
                local function be32(at)
                    local n = 0
                    for i = at, at + 3 do n = n * 256 + header:byte(i) end
                    return n
                end
                local width, height = be32(17), be32(21)
                H.equal(width, height, file .. " should be square")
                if expected[path] then
                    H.equal(width, expected[path], file .. " is the wrong size")
                end
            end
        end,
    },
    {
        name = "the controller:// icon paths name the archive this build produces",
        fn = function()
            -- The segment after controller://driver/ must be the .c4z file name
            -- without its extension, matched case-sensitively -- that is how the
            -- controller finds the driver's own web root. Building under a
            -- different name would break every Navigator icon at once, and the
            -- archive name is already load-bearing for a second reason: Composer
            -- identifies a driver by file name, so a rename installs a second
            -- driver rather than updating this one.
            local build = io.open("tools/build-c4z.ps1", "r")
            H.isTrue(build ~= nil, "the build script should exist")
            local script = build:read("*a")
            build:close()

            local archive = script:match("([%w%.%-_]+)%.c4z")
            H.isTrue(archive ~= nil, "could not find the archive name in the build script")
            H.equal(archive:find(" ", 1, true), nil,
                "a space in the archive name arrives URL-encoded and does not resolve")

            local seen = 0
            for uri in readManifest():gmatch('>(controller://driver/[^<]+)<') do
                local base = uri:match("^controller://driver/([^/]+)/")
                H.equal(base, archive, "icon URI names a different archive: " .. uri)
                seen = seen + 1
            end
            H.isTrue(seen > 0, "no controller:// icon URIs found to check")
        end,
    },
    {
        name = "every packaged icon is declared, and every declared icon is packaged",
        fn = function()
            -- Both directions. Declared-but-unpackaged ships a driver with no
            -- icon; packaged-but-undeclared is dead weight nobody will notice.
            local build = io.open("tools/build-c4z.ps1", "r")
            local script = build:read("*a")
            build:close()

            local packaged = {}
            for path in script:gmatch("'(www/icons/[^']+)'") do packaged[path] = true end
            H.isTrue(next(packaged) ~= nil, "the build should package the icons")

            local xml = readManifest()
            local declared = {}
            for path in xml:gmatch('_image="([^"]+)"') do declared["www/" .. path] = true end
            for path in xml:gmatch('image_source="c4z">([^<]+)<') do
                declared["www/" .. path] = true
            end
            for uri in xml:gmatch('>(controller://driver/[^<]+)<') do
                local path = uri:match("^controller://driver/[^/]+/(.+)$")
                if path then declared["www/" .. path] = true end
            end

            for path in pairs(declared) do
                H.isTrue(packaged[path], "declared in driver.xml but not packaged: " .. path)
            end
            for path in pairs(packaged) do
                H.isTrue(declared[path], "packaged but not declared in driver.xml: " .. path)
            end
        end,
    },
    {
        name = "the documentation states the driver version driver.xml declares",
        fn = function()
            -- These drifted once: the page said 104 for a 105 build. A version
            -- an installer reads off the documentation and quotes in a support
            -- conversation has to be the version they actually have, so the
            -- two are pinned together rather than kept in step by hand.
            local version = readManifest():match("<version>(%d+)</version>")
            H.isTrue(version ~= nil, "driver.xml should declare a version")

            local doc = readDocumentation()
            H.isTrue(doc:find("Driver " .. version, 1, true) ~= nil,
                "the documentation header should read 'Driver " .. version .. "'")

            -- And the changelog has to carry an entry for it, so a release
            -- cannot ship with its own changes undescribed.
            H.isTrue(doc:find("(driver " .. version .. ")", 1, true) ~= nil,
                "the changelog should have an entry for driver " .. version)
        end,
    },
    {
        name = "every shipped driver version has a changelog entry",
        fn = function()
            -- One entry per release, oldest to newest. A gap here means a
            -- version shipped whose changes nobody wrote down.
            local doc = readDocumentation()
            for v = 100, tonumber(readManifest():match("<version>(%d+)</version>")) do
                H.isTrue(doc:find("(driver " .. v .. ")", 1, true) ~= nil,
                    "no changelog entry for driver " .. v)
            end
        end,
    },
    {
        name = "the Macro property defaults to the same sentinel the driver keeps in its list",
        fn = function()
            -- A fresh install must read the same as one whose chosen macro was
            -- deleted: nothing selected. If this default drifted from the
            -- driver's own sentinel, an install that had never seen the unit
            -- would show a selection the driver would refuse to run, with no
            -- entry in the list matching it.
            local xml = readManifest()
            local block = xml:match("<name>Macro</name>(.-)</property>")
            H.isTrue(block ~= nil, "the Macro property should be declared")
            H.equal(block:match("<default>(.-)</default>"), "(none)")
            H.isTrue(block:find("<type>DYNAMIC_LIST</type>", 1, true) ~= nil)
        end,
    },
    {
        name = "power off offers a do-nothing option",
        fn = function()
            -- For a processor meant to stay powered, so a room turning off or a
            -- stray program cannot take the system down.
            local xml = readManifest()
            local items = xml:match("<name>Power Off Action</name>.-<items>(.-)</items>")
            H.isTrue(items ~= nil, "the property should declare items")
            for _, choice in ipairs({ "Standby", "Sleep", "Do Nothing" }) do
                H.isTrue(items:find("<item>" .. choice .. "</item>", 1, true) ~= nil,
                    "missing choice: " .. choice)
            end
        end,
    },
    {
        name = "the declared documentation file exists and is packaged",
        fn = function()
            local xml = readManifest()
            local file = xml:match('<documentation%s+file%s*=%s*"([^"]+)"')
            H.isTrue(file ~= nil, "driver.xml should declare a documentation file")

            -- A declared file that is not on disk gives Composer an empty tab
            -- with no error, and nothing else here would notice.
            local handle = io.open(file, "r")
            H.isTrue(handle ~= nil, "declared but missing on disk: " .. tostring(file))
            local body = handle:read("*a")
            handle:close()
            H.isTrue(#body > 2000, "the documentation looks like a stub: " .. #body .. " bytes")

            -- Self-contained on purpose: the first-party drivers render Markdown
            -- through a 1.1 MB React bundle, which would mean a build pipeline
            -- and two copies of the content free to drift apart.
            H.equal(body:find("<script", 1, true), nil,
                "the documentation should need no scripting to render")

            -- The build packs an explicit list; a file missing from it ships a
            -- driver whose Documentation tab is blank.
            local script = assert(io.open("tools/build-c4z.ps1", "r"))
            local payload = script:read("*a")
            script:close()
            H.isTrue(payload:find(file, 1, true) ~= nil,
                file .. " is declared but not in the build payload")
        end,
    },
    {
        name = "the documentation names every property, action, command, variable and event",
        fn = function()
            -- Documentation that silently falls behind the driver is worse than
            -- none: it is confidently wrong. This does not check the prose, only
            -- that nothing user-facing was added without being written up.
            local xml = readManifest()
            local file = xml:match('<documentation%s+file%s*=%s*"([^"]+)"')
            local handle = assert(io.open(file, "r"))
            local doc = handle:read("*a")
            handle:close()

            -- Each name must have ITS OWN documented entry -- the leading cell
            -- of a row in one of the tables above -- not merely appear
            -- somewhere in the prose. A substring match let the `Macro`
            -- property be satisfied by the unrelated words "Run Macro", so the
            -- property could go entirely undocumented with this test green.
            local missing = {}
            local function require_(name, kind)
                if not doc:find('<td class="name">' .. name .. "</td>", 1, true) then
                    table.insert(missing, kind .. " " .. name)
                end
            end

            for block in xml:gmatch("<property>(.-)</property>") do
                require_(block:match("<name>%s*(.-)%s*</name>"), "property")
            end
            for block in xml:gmatch("<action>(.-)</action>") do
                require_(block:match("<name>%s*(.-)%s*</name>"), "action")
            end
            for _, name in ipairs(parseCommands(xml)) do require_(name, "command") end
            for block in xml:gmatch("<event>(.-)</event>") do
                require_(block:match("<name>%s*(.-)%s*</name>"), "event")
            end
            for name in pairs(loadEventNames()) do require_(name, "fired event") end
            for _, name in ipairs(loadVariableNames()) do require_(name, "variable") end

            H.equal(#missing, 0, "undocumented: " .. table.concat(missing, ", "))
        end,
    },
    {
        name = "the documentation does not promise that a macro always runs in full",
        fn = function()
            -- Both retired claims were true only of the empty and unknown cases
            -- they were written for. A slot storing an entry this driver cannot
            -- replay DOES under-run, and the Documentation tab is the one place
            -- an installer looks before believing otherwise.
            local xml = readManifest()
            local file = xml:match('<documentation%s+file%s*=%s*"([^"]+)"')
            local handle = assert(io.open(file, "r"))
            local doc = handle:read("*a")
            handle:close()

            H.equal(doc:find("sends it as it stands", 1, true), nil,
                "the driver sends the replayable entries, not the slot as it stands")
            H.equal(doc:find("never a half-run macro", 1, true), nil,
                "an unqualified promise this driver cannot keep")
            H.isTrue(doc:find("<code>replace</code>", 1, true) ~= nil,
                "the one entry kind that is replayed should be named outright")
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
            for _, name in ipairs({ "Driver Version", "System Software Version",
                                    "AV Controller Version", "Serial Number", "Model",
                                    "Connection Status", "Maximum Volume", "Volume Ramp Rate",
                                    "Power Off Action", "Debug Mode", "Dirac Filter",
                                    "Macro" }) do
                H.isTrue(xml:find("<name>" .. name .. "</name>", 1, true) ~= nil,
                    "missing property: " .. name)
            end
        end,
    },
    {
        name = "the runtime-populated pickers are DYNAMIC_LISTs with no fixed items",
        fn = function()
            -- Both are populated at runtime via C4:UpdatePropertyList, from
            -- what the unit itself reports -- its Dirac slot names and its
            -- stored macros -- never from a list declared here.
            local xml = readManifest()
            for _, name in ipairs({ "Dirac Filter", "Macro" }) do
                local block = xml:match("<property>%s*<name>" .. name .. "</name>(.-)</property>")
                H.isTrue(block ~= nil, "the " .. name .. " property should be declared")
                H.isTrue(block:find("<type>DYNAMIC_LIST</type>", 1, true) ~= nil,
                    name .. " should be a DYNAMIC_LIST")
                H.isTrue(block:find("<readonly>false</readonly>", 1, true) ~= nil,
                    name .. " should be settable")
                H.isTrue(block:find("<items>", 1, true) == nil,
                    "a DYNAMIC_LIST declares no fixed <items>: " .. name)
            end
        end,
    },
    {
        name = "the Run Selected Macro action carries its dispatch token in the same block",
        fn = function()
            -- Composer's Actions tab sends the literal "LUA_ACTION" with this
            -- <command> in tParams.ACTION, so the pairing is what matters.
            -- Grepping the whole manifest for the two strings separately does
            -- not check the pairing at all: it stays green with the name in one
            -- <action> and the token in another, which is a shape that runs the
            -- WRONG action rather than none. Read the block, then read the
            -- token out of it.
            --
            -- That the token then reaches a handler is proven end to end, the
            -- way Composer actually invokes it, by "every action declared in
            -- driver.xml runs when Composer invokes it" in tests/test_driver.lua.
            -- Not duplicated here.
            local xml = readManifest()
            local block
            for candidate in xml:gmatch("<action>(.-)</action>") do
                if candidate:match("<name>%s*(.-)%s*</name>") == "Run Selected Macro" then
                    block = candidate
                end
            end
            H.isTrue(block ~= nil, "the action should be declared")
            H.equal(block:match("<command>%s*(.-)%s*</command>"), "RUN_SELECTED_MACRO",
                "the dispatch token driver.lua's ACTIONS table keys on, in this action's block")
        end,
    },
    {
        name = "every event the Lua fires is declared in driver.xml, and vice versa",
        fn = function()
            -- A one-directional check would miss half of what can go wrong: a
            -- typo'd event name in the Lua would be invisible to programming
            -- (fires something nobody declared), and a declared-but-never-fired
            -- event is a dead entry in the programming UI. Both directions, or
            -- neither is proven.
            local declared = {}
            for _, name in pairs(parseEvents(readManifest())) do declared[name] = true end

            local fired = loadEventNames()

            for name in pairs(fired) do
                H.isTrue(declared[name],
                    "the Lua fires '" .. name .. "' but driver.xml does not declare it")
            end
            for name in pairs(declared) do
                H.isTrue(fired[name],
                    "driver.xml declares '" .. name .. "' but the Lua never fires it")
            end
        end,
    },
    {
        name = "the six events are declared with unique, contiguous ids starting at 1",
        fn = function()
            local events = parseEvents(readManifest())
            local count = 0
            for _ in pairs(events) do count = count + 1 end
            H.equal(count, 6, "expected exactly six declared events")
            for id = 1, 6 do
                H.isTrue(events[id] ~= nil, "no <event> declared with id " .. id)
            end
        end,
    },
    {
        -- The driver cannot rename Control4's inputs (no DriverWorks call does
        -- it), so promising to via a "Adopt Input Labels" Yes/No property was
        -- withdrawn in favour of PRINT_INPUT_LABELS, which reports the unit's
        -- labels instead of applying them.
        name = "the Adopt Input Labels property is gone, and Print Input Labels replaces it",
        fn = function()
            local xml = readManifest()
            H.isTrue(xml:find("Adopt Input Labels", 1, true) == nil,
                "the property promised a rename this driver cannot perform")
            H.isTrue(xml:find("ADOPT_INPUT_LABELS", 1, true) == nil,
                "the retired command should not remain anywhere in the manifest")
            H.isTrue(xml:find("Rename Inputs From Device Labels", 1, true) == nil,
                "the retired action name should not remain anywhere in the manifest")
            H.isTrue(xml:find("<name>Print Input Labels</name>", 1, true) ~= nil,
                "the replacement action should be declared")
            H.isTrue(xml:find("<command>PRINT_INPUT_LABELS</command>", 1, true) ~= nil,
                "the replacement command should be declared")
        end,
    },
    {
        name = "loudness is a discrete and toggle control now that the proxy handles it",
        fn = function()
            local xml = readManifest()
            H.isTrue(xml:find("<has_discrete_loudness_control>True</has_discrete_loudness_control>",
                1, true) ~= nil, "has_discrete_loudness_control should be True")
            H.isTrue(xml:find("<has_toggle_loudness_control>True</has_toggle_loudness_control>",
                1, true) ~= nil, "has_toggle_loudness_control should be True")
        end,
    },
    {
        name = "the eight processing commands are declared with the right names and param shapes",
        fn = function()
            local xml = readManifest()
            local names = parseCommands(xml)
            -- "Set Dirac Processing", not "Set Dirac": it sits beside "Set Dirac
            -- Slot" in a programming dropdown, and one name being a strict
            -- prefix of the other made the wrong pick invisible.
            local expected = { "Set Dirac Processing", "Set Night Mode", "Set Dialog Enhance",
                                "Set Bass Enhance", "Toggle Bass Enhance", "Set Lip Sync Delay",
                                "Set Dirac Slot", "Run Macro" }
            H.equal(#names, #expected, "expected exactly the eight declared commands")
            for _, name in ipairs(expected) do
                local found = false
                for _, actual in ipairs(names) do if actual == name then found = true end end
                H.isTrue(found, "no <command> named " .. name)
            end

            local function commandBlock(name)
                return xml:match("<command>%s*<name>" .. name:gsub("([%-%.%:])", "%%%1") ..
                    "</name>(.-)</command>")
            end

            local function listItems(block)
                local items, itemBlock = {}, block:match("<items>(.-)</items>")
                if not itemBlock then return items end
                for item in itemBlock:gmatch("<item>%s*(.-)%s*</item>") do
                    table.insert(items, item)
                end
                return items
            end

            local diracBlock = assert(commandBlock("Set Dirac Processing"))
            H.isTrue(diracBlock:find("<name>Mode</name>", 1, true) ~= nil)
            H.isTrue(diracBlock:find("<type>LIST</type>", 1, true) ~= nil)
            local diracItems = listItems(diracBlock)
            H.equal(#diracItems, 3)
            for i, item in ipairs({ "Off", "On", "Bypass" }) do
                H.equal(diracItems[i], item, "Set Dirac Processing item " .. i)
            end

            local nightBlock = assert(commandBlock("Set Night Mode"))
            local nightItems = listItems(nightBlock)
            for i, item in ipairs({ "Off", "Auto", "On" }) do
                H.equal(nightItems[i], item, "Set Night Mode item " .. i)
            end

            local dialogBlock = assert(commandBlock("Set Dialog Enhance"))
            H.isTrue(dialogBlock:find("<name>Level</name>", 1, true) ~= nil)
            H.isTrue(dialogBlock:find("<type>RANGED_INTEGER</type>", 1, true) ~= nil)
            H.isTrue(dialogBlock:find("<minimum>0</minimum>", 1, true) ~= nil)
            H.isTrue(dialogBlock:find("<maximum>6</maximum>", 1, true) ~= nil)

            local bassBlock = assert(commandBlock("Set Bass Enhance"))
            local bassItems = listItems(bassBlock)
            for i, item in ipairs({ "Off", "On" }) do
                H.equal(bassItems[i], item, "Set Bass Enhance item " .. i)
            end

            local toggleBassBlock = assert(commandBlock("Toggle Bass Enhance"))
            H.isTrue(toggleBassBlock:find("<param>", 1, true) == nil,
                "Toggle Bass Enhance takes no parameters")

            local lipSyncBlock = assert(commandBlock("Set Lip Sync Delay"))
            H.isTrue(lipSyncBlock:find("<name>Delay</name>", 1, true) ~= nil)
            H.isTrue(lipSyncBlock:find("<type>RANGED_INTEGER</type>", 1, true) ~= nil)
            H.isTrue(lipSyncBlock:find("<minimum>0</minimum>", 1, true) ~= nil)
            H.isTrue(lipSyncBlock:find("<maximum>340</maximum>", 1, true) ~= nil)

            local diracSlotBlock = assert(commandBlock("Set Dirac Slot"))
            H.isTrue(diracSlotBlock:find("<name>Slot</name>", 1, true) ~= nil)
            H.isTrue(diracSlotBlock:find("<type>RANGED_INTEGER</type>", 1, true) ~= nil)
            H.isTrue(diracSlotBlock:find("<minimum>0</minimum>", 1, true) ~= nil)
            H.isTrue(diracSlotBlock:find("<maximum>5</maximum>", 1, true) ~= nil)

            -- A STRING, not a LIST: the macros belong to the unit, so any fixed
            -- list declared in the manifest could only be wrong.
            local runMacroBlock = assert(commandBlock("Run Macro"))
            H.isTrue(runMacroBlock:find("<name>Macro</name>", 1, true) ~= nil)
            H.isTrue(runMacroBlock:find("<type>STRING</type>", 1, true) ~= nil)
            H.equal(#listItems(runMacroBlock), 0, "no fixed list of macro names")
        end,
    },
    {
        name = "no shipped Lua source references the retired ADOPT_INPUT_LABELS command",
        fn = function()
            -- The same file list tools/build-c4z.ps1 packages: driver code only,
            -- not the test suite that is asserting the retirement.
            local sources = {
                "driver.lua", "htp1/frame.lua", "htp1/protocol.lua", "htp1/mapping.lua",
                "htp1/state.lua", "htp1/transport.lua", "htp1/session.lua", "htp1/proxy.lua",
                "htp1/log.lua", "module/json.lua",
            }
            for _, path in ipairs(sources) do
                local handle = assert(io.open(path, "r"), path .. " should exist")
                local text = handle:read("*a")
                handle:close()
                H.isTrue(text:find("ADOPT_INPUT_LABELS", 1, true) == nil,
                    path .. " should not reference the retired command")
            end
        end,
    },
}
