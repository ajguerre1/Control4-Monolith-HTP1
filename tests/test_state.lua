local H = require("tests.harness")
local State = require("htp1.state")
local F = require("tests.fixtures")

return {
    {
        name = "a fresh state is not loaded and holds no values",
        fn = function()
            local s = State.new()
            H.isFalse(s.loaded)
            H.equal(s.fields.volume, nil)
            H.equal(s.fields.input, nil)
        end,
    },
    {
        name = "applying a modern document projects every tracked scalar",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            H.isTrue(s.loaded)
            H.equal(s.fields.volume, -25)
            H.equal(s.fields.muted, false)
            H.equal(s.fields.power, true)
            H.equal(s.fields.input, "h1")
            H.equal(s.fields.upmix, "dolby")
            H.equal(s.fields.vpl, -50)
            H.equal(s.fields.vph, 0)
            H.equal(s.fields.unitName, "Processor")
        end,
    },
    {
        name = "both version fields are projected, and told apart",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            H.equal(s.fields.systemVersion, "V2.1.1", "the release the unit calls itself")
            H.equal(s.fields.avControllerVersion, "5.96",
                "the internal component version, build date and newline dropped")
            H.equal(s.fields.serial, "0001")
        end,
    },
    {
        name = "a legacy document projects the same fields",
        fn = function()
            local s = State.new()
            s:applyDocument(F.legacy())
            H.equal(s.fields.volume, -29)
            H.equal(s.fields.upmix, "dolby")
            H.equal(s.fields.vpl, -50)
            H.equal(s.fields.systemVersion, "V1.13.3")
            H.equal(s.fields.avControllerVersion, "4.91")
        end,
    },
    {
        name = "a sparse document loads without error and leaves absent fields nil",
        fn = function()
            local s = State.new()
            s:applyDocument(F.sparse())
            H.isTrue(s.loaded)
            H.equal(s.fields.volume, -10)
            H.equal(s.fields.power, false)
            H.equal(s.fields.upmix, nil, "an absent field stays absent rather than defaulting")
            H.equal(s.fields.vpl, nil)
        end,
    },
    {
        name = "input labels and visibility are projected",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            H.equal(s.inputs.h1.label, "Streamer")
            H.equal(s.inputs.h1.visible, true)
            H.equal(s.inputs.h3.visible, false)
            H.equal(s:inputLabel("a1"), "Turntable")
            H.equal(s:inputLabel("h8"), nil, "an input the unit did not report")
        end,
    },
    {
        name = "the first document reports every populated field as changed",
        fn = function()
            local s = State.new()
            local changes = s:applyDocument(F.modern())
            H.isTrue(changes.volume, "volume changed")
            H.isTrue(changes.input, "input changed")
            H.isTrue(changes.upmix, "upmix changed")
            H.isTrue(changes.inputs, "inputs changed")
        end,
    },
    {
        name = "re-applying an identical document reports no changes",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            local changes = s:applyDocument(F.modern())
            H.equal(next(changes), nil, "an unchanged document must not notify anything")
        end,
    },
    {
        name = "re-applying a document reports only what actually moved",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            local doc = F.modern()
            doc.volume = -30
            local changes = s:applyDocument(doc)
            H.isTrue(changes.volume, "volume moved")
            H.equal(changes.input, nil, "input did not move")
            H.equal(changes.inputs, nil, "labels did not move")
            H.equal(s.fields.volume, -30)
        end,
    },
    {
        name = "a changed input label is reported as an inputs change",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            local doc = F.modern()
            doc.inputs.h1.label = "Renamed"
            local changes = s:applyDocument(doc)
            H.isTrue(changes.inputs)
            H.equal(s.inputs.h1.label, "Renamed")
        end,
    },
    {
        name = "a non-table document is ignored rather than raising",
        fn = function()
            local s = State.new()
            local changes = s:applyDocument("not a document")
            H.equal(next(changes), nil)
            H.isFalse(s.loaded, "a rejected document must not mark the state loaded")
        end,
    },
    {
        name = "a replace on a tracked scalar updates it and reports the change",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            local changes = s:applyOps({ { op = "replace", path = "/volume", value = -35 } })
            H.equal(s.fields.volume, -35)
            H.isTrue(changes.volume)
        end,
    },
    {
        name = "a replace to the same value reports no change",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            local changes = s:applyOps({ { op = "replace", path = "/volume", value = -25 } })
            H.equal(next(changes), nil, "an idempotent push must not notify")
        end,
    },
    {
        name = "several operations in one update all apply",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            local changes = s:applyOps({
                { op = "replace", path = "/muted", value = true },
                { op = "replace", path = "/input", value = "a1" },
                { op = "replace", path = "/upmix/select", value = "auro" },
            })
            H.equal(s.fields.muted, true)
            H.equal(s.fields.input, "a1")
            H.equal(s.fields.upmix, "auro")
            H.isTrue(changes.muted and changes.input and changes.upmix)
        end,
    },
    {
        name = "operations on untracked paths are ignored",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            local changes = s:applyOps({
                { op = "replace", path = "/speakers/groups/lf", value = true },
                { op = "replace", path = "/peq/0/gain", value = 3 },
                { op = "add",     path = "/personalize/macros/cmda", value = true },
            })
            H.equal(next(changes), nil, "nothing tracked moved")
            H.equal(s.fields.volume, -25, "tracked state is untouched")
        end,
    },
    {
        name = "a remove clears the tracked field",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            local changes = s:applyOps({ { op = "remove", path = "/upmix/select" } })
            H.equal(s.fields.upmix, nil)
            H.isTrue(changes.upmix)
        end,
    },
    {
        name = "an operation with a nil value is skipped rather than clearing the field",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            local changes = s:applyOps({ { op = "replace", path = "/volume" } })
            H.equal(s.fields.volume, -25, "the previous value survives")
            H.equal(next(changes), nil)
        end,
    },
    {
        name = "replacing a container re-derives every tracked path beneath it",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            local changes = s:applyOps({
                { op = "replace", path = "/cal", value = { vpl = -40, vph = -10, zeroPoint = 0 } },
            })
            H.equal(s.fields.vpl, -40)
            H.equal(s.fields.vph, -10)
            H.isTrue(changes.vpl and changes.vph)
        end,
    },
    {
        name = "replacing the whole inputs container re-derives labels",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            local changes = s:applyOps({
                { op = "replace", path = "/inputs", value = { h1 = { label = "New", visible = true } } },
            })
            H.equal(s.inputs.h1.label, "New")
            H.isTrue(changes.inputs)
        end,
    },
    {
        name = "a single input label update is applied",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            local changes = s:applyOps({
                { op = "replace", path = "/inputs/h2/label", value = "Games" },
            })
            H.equal(s.inputs.h2.label, "Games")
            H.equal(s.inputs.h2.visible, true, "visibility is untouched")
            H.isTrue(changes.inputs)
        end,
    },
    {
        name = "a single input visibility update is applied",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            local changes = s:applyOps({
                { op = "replace", path = "/inputs/h3/visible", value = true },
            })
            H.equal(s.inputs.h3.visible, true)
            H.isTrue(changes.inputs)
        end,
    },
    {
        name = "an update naming an input the unit never reported creates it",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            s:applyOps({ { op = "add", path = "/inputs/h8/label", value = "Spare" } })
            H.equal(s.inputs.h8.label, "Spare")
        end,
    },
    {
        name = "malformed operations are skipped without raising",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            local changes = s:applyOps({
                "not a table",
                {},
                { op = "replace" },
                { path = "/volume", value = -1 },
                { op = "replace", path = 42, value = 1 },
                { op = "replace", path = "/volume", value = -33 },
            })
            H.equal(s.fields.volume, -33, "the one good operation still applied")
            H.isTrue(changes.volume)
        end,
    },
    {
        name = "a non-array argument is ignored",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            H.equal(next(s:applyOps(nil)), nil)
            H.equal(next(s:applyOps("nonsense")), nil)
            H.equal(s.fields.volume, -25)
        end,
    },
    {
        name = "a partial container replace does not wipe fields it omits",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            H.equal(s.inputs.h1.label, "Streamer")
            -- The loop already leaves untouched any input the push does not
            -- mention; a field omitted from a mentioned entry is unspecified
            -- for the same reason, not an instruction to clear it.
            s:applyOps({
                { op = "replace", path = "/inputs", value = { h1 = { visible = false } } },
            })
            H.equal(s.inputs.h1.label, "Streamer", "the label survives")
            H.equal(s.inputs.h1.visible, false, "the stated field still applies")
            H.equal(s.inputs.h2.label, "Console", "an unmentioned input is untouched")
        end,
    },
    {
        name = "removing one input leaf leaves its sibling alone",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            s:applyOps({ { op = "remove", path = "/inputs/h1/label" } })
            H.equal(s.inputs.h1.label, nil, "the named leaf is cleared")
            H.equal(s.inputs.h1.visible, true, "its sibling is not")
        end,
    },
    {
        name = "a single operation sent unwrapped is accepted",
        fn = function()
            -- The web UI's own client handles a non-array msoupdate, so the unit
            -- evidently sends one sometimes.
            local s = State.new()
            s:applyDocument(F.modern())
            local changes = s:applyOps({ op = "replace", path = "/volume", value = -12 })
            H.equal(s.fields.volume, -12)
            H.isTrue(changes.volume)
        end,
    },
    {
        name = "applying a modern document projects every status and video field",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            H.equal(s.fields.surroundMode, "Native Dolby ATMOS")
            H.equal(s.fields.decSourceProgram, "Dolby MAT/PCM")
            H.equal(s.fields.decProgramFormat, "Object Audio")
            H.equal(s.fields.decSampleRate, "48 kHz")
            H.equal(s.fields.encListeningFormat, "5.1.2")
            H.equal(s.fields.encSampleRate, "48 kHz")
            H.equal(s.fields.diracState, "on")
            H.equal(s.fields.videoResolution, "3840x2160p60Hz")
            H.equal(s.fields.videoColorSpace, "BT2020")
            H.equal(s.fields.videoHdr, "HDR10")
        end,
    },
    {
        name = "a targeted update on one status leaf updates only that field",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            local changes = s:applyOps({
                { op = "replace", path = "/status/DECSampleRate", value = "96 kHz" },
            })
            H.equal(s.fields.decSampleRate, "96 kHz")
            H.equal(next(changes), "decSampleRate")
            H.equal(s.fields.surroundMode, "Native Dolby ATMOS", "siblings are untouched")
            H.equal(s.fields.encSampleRate, "48 kHz", "siblings are untouched")
        end,
    },
    {
        name = "a targeted update on one video leaf updates only that field",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            local changes = s:applyOps({
                { op = "replace", path = "/videostat/HDRstatus", value = "--" },
            })
            H.equal(s.fields.videoHdr, "--")
            H.isTrue(changes.videoHdr)
            H.equal(s.fields.videoResolution, "3840x2160p60Hz", "siblings are untouched")
        end,
    },
    {
        name = "a wholesale replace of /status re-derives everything beneath it",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            local changes = s:applyOps({
                { op = "replace", path = "/status", value = {
                    SurroundMode = "Dolby Surround",
                    DECSourceProgram = "PCM",
                    DECProgramFormat = "2.0.0",
                    DECSampleRate = "44.1 kHz",
                    ENCListeningFormat = "5.2.2t",
                    ENCSampleRate = "96 kHz",
                    DiracState = "off",
                    raw = { decoderSampleRateEnum = 5 },
                } },
            })
            -- All seven, since the test claims "everything beneath it". The two
            -- sample rates differ from the fixture on purpose: with the same
            -- value they would pass whether or not they were re-derived.
            local expected = {
                surroundMode = "Dolby Surround", decSourceProgram = "PCM",
                decProgramFormat = "2.0.0", decSampleRate = "44.1 kHz",
                encListeningFormat = "5.2.2t", encSampleRate = "96 kHz",
                diracState = "off",
            }
            for field, value in pairs(expected) do
                H.equal(s.fields[field], value, field)
                H.isTrue(changes[field], field .. " should be reported as changed")
            end
            H.equal(s.fields.raw, nil, "the raw sub-table is never projected")
        end,
    },
    {
        name = "a wholesale replace of /videostat re-derives everything beneath it",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            local changes = s:applyOps({
                { op = "replace", path = "/videostat", value = {
                    VideoResolution = "-----",
                    VideoColorSpace = "---",
                    HDRstatus = "--",
                } },
            })
            H.equal(s.fields.videoResolution, "-----", "the no-signal placeholder is reported as-is")
            H.equal(s.fields.videoColorSpace, "---")
            H.equal(s.fields.videoHdr, "--")
            H.isTrue(changes.videoResolution and changes.videoColorSpace and changes.videoHdr)
        end,
    },
    {
        name = "operations under /status/raw are ignored and state.fields.raw never exists",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            local changes = s:applyOps({
                { op = "replace", path = "/status/raw/decoderSampleRateEnum", value = 9 },
                { op = "replace", path = "/status/raw", value = { anything = true } },
                { op = "add",     path = "/status/raw/newKey", value = "x" },
            })
            H.equal(next(changes), nil, "nothing tracked moved")
            H.equal(s.fields.raw, nil)
            H.equal(s.fields.surroundMode, "Native Dolby ATMOS", "tracked status fields untouched")
        end,
    },
    {
        name = "a document with no videostat at all leaves those fields nil without erroring",
        fn = function()
            local s = State.new()
            local changes = s:applyDocument(F.legacy())
            H.isTrue(s.loaded)
            H.equal(s.fields.videoResolution, nil)
            H.equal(s.fields.videoColorSpace, nil)
            H.equal(s.fields.videoHdr, nil)
            H.equal(changes.videoResolution, nil, "an absent container reports no change")
            -- The legacy fixture still carries /status, so those fields do project.
            H.equal(s.fields.diracState, "off")
        end,
    },
    {
        name = "a sparse document with neither status nor videostat is absence-tolerant",
        fn = function()
            local s = State.new()
            s:applyDocument(F.sparse())
            H.isTrue(s.loaded)
            H.equal(s.fields.surroundMode, nil)
            H.equal(s.fields.diracState, nil)
            H.equal(s.fields.videoResolution, nil)
            H.equal(s.fields.raw, nil)
        end,
    },

    --------------------------------------------------------------------------
    -- Processing settings: loudness, night, dialog enhance, bass enhance,
    -- dirac slot, lip sync -- and the dirac filter slot names.
    --------------------------------------------------------------------------
    {
        name = "applying a modern document projects every processing field",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            H.equal(s.fields.loudness, "off")
            H.equal(s.fields.night, "off")
            H.equal(s.fields.dialogEnhance, 3)
            H.equal(s.fields.bassEnhance, "off")
            H.equal(s.fields.diracSlot, 0)
            H.equal(s.fields.lipSync, 20)
        end,
    },
    {
        name = "a targeted update on one processing field updates only that field",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            local changes = s:applyOps({ { op = "replace", path = "/night", value = "auto" } })
            H.equal(s.fields.night, "auto")
            H.equal(next(changes), "night")
            H.equal(s.fields.loudness, "off", "siblings are untouched")
            H.equal(s.fields.dialogEnhance, 3, "siblings are untouched")
        end,
    },
    {
        name = "replacing the /cal container re-derives diracSlot and lipSync",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            local changes = s:applyOps({
                { op = "replace", path = "/cal", value = {
                    vpl = -50, vph = 0, zeroPoint = 0, diracactive = "on",
                    currentdiracslot = 5, lipsync = 120,
                } },
            })
            H.equal(s.fields.diracSlot, 5)
            H.equal(s.fields.lipSync, 120)
            H.isTrue(changes.diracSlot and changes.lipSync)
        end,
    },
    {
        name = "a sparse document leaves the six processing fields nil rather than inventing a value",
        fn = function()
            local s = State.new()
            s:applyDocument(F.sparse())
            H.equal(s.fields.loudness, nil)
            H.equal(s.fields.night, nil)
            H.equal(s.fields.dialogEnhance, nil)
            H.equal(s.fields.bassEnhance, nil)
            H.equal(s.fields.diracSlot, nil)
            H.equal(s.fields.lipSync, nil)
        end,
    },
    {
        name = "a /cal replace carrying slots re-derives the slot names",
        fn = function()
            -- The inputs collection has this test for its own container; the
            -- slots collection was relying on the code reading correctly.
            local s = State.new()
            s:applyDocument(F.modern())
            H.equal(s.diracSlots[1].name, "Calibrated")
            local changes = s:applyOps({
                { op = "replace", path = "/cal", value = {
                    vpl = -50, vph = 0, currentdiracslot = 2, lipsync = 40,
                    slots = { { name = "Room A" }, { name = "Room B" }, { name = "" },
                              { name = "Movie" }, { name = "Music" }, { name = "Custom" } },
                } },
            })
            H.equal(s.diracSlots[1].name, "Room A", "slot names follow a /cal replace")
            H.equal(s.diracSlots[2].name, "Room B")
            H.isTrue(changes.diracSlots, "and the change is reported")
            H.equal(s.fields.diracSlot, 2, "the scalars under /cal re-derive too")
            H.equal(s.fields.lipSync, 40)
        end,
    },
    {
        name = "a replace of the slots array alone is accepted",
        fn = function()
            -- Permissive inbound parsing. If the unit never pushes at this
            -- granularity the branch never runs; if it does, the names stay
            -- live rather than going stale until the next full document.
            local s = State.new()
            s:applyDocument(F.modern())
            local changes = s:applyOps({
                { op = "replace", path = "/cal/slots", value = {
                    { name = "First" }, { name = "Second" }, { name = "" },
                    { name = "Movie" }, { name = "Music" }, { name = "Custom" },
                } },
            })
            H.equal(s.diracSlots[1].name, "First")
            H.equal(s.diracSlots[2].name, "Second")
            H.isTrue(changes.diracSlots)
            H.equal(s.fields.vpl, -50, "nothing else under /cal was disturbed")
        end,
    },
    {
        name = "Dirac filter slot names project, including an unnamed slot",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            H.equal(s.diracSlots[1].name, "Calibrated")
            H.equal(s.diracSlots[2].name, "Flat")
            H.equal(s.diracSlots[3].name, "", "an empty name still gets a row")
            H.equal(s.diracSlots[6].name, "Custom")
        end,
    },
    {
        name = "an absent slot name (the key itself missing) still gets a row",
        fn = function()
            local s = State.new()
            s:applyDocument(F.legacy())
            H.equal(s.diracSlots[1].name, "Slot 1")
            H.equal(s.diracSlots[2].name, nil, "no name key at all, but the slot still exists")
            H.isTrue(s.diracSlots[2] ~= nil, "the entry itself must not be dropped")
        end,
    },
    {
        name = "a sparse document has no dirac slots to report",
        fn = function()
            local s = State.new()
            s:applyDocument(F.sparse())
            H.equal(next(s.diracSlots), nil)
        end,
    },

    ----------------------------------------------------------------------------
    -- Macros
    ----------------------------------------------------------------------------
    {
        name = "macro names and their stored operations project from the document",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            H.equal(s.macros.cmda.name, "Movie Night")
            H.count(s.macros.cmda.ops, 2, "both stored operations are kept")
            H.equal(s.macros.cmda.ops[1].path, "/volume")
            H.equal(s.macros.cmda.ops[1].value, -22)
            H.equal(s.macros.cmda.ops[2].path, "/dialogEnh")
            H.equal(s.macros.cmda.ops[2].value, 5)
            H.equal(s.macros.cmdcustom1.name, nil, "a slot the owner never named")
            H.count(s.macros.cmdcustom1.ops, 1, "and still has its operations")
        end,
    },
    {
        name = "a named but empty macro slot keeps its name and no operations",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            H.equal(s.macros.cmdc.name, "Late Night")
            H.count(s.macros.cmdc.ops, 0, "nothing stored to replay")
        end,
    },
    {
        name = "a stored entry that is not an operation is dropped on the way in",
        fn = function()
            -- A bare string, an entry with no op, and an entry with no path are
            -- all things a driver must not forward blindly to a live processor.
            -- A remove carries no value, and this driver only writes values.
            local s = State.new()
            s:applyDocument(F.modern())
            H.count(s.macros.cmdd.ops, 1, "only the one well-formed operation survives")
            H.equal(s.macros.cmdd.ops[1].path, "/night")
            H.equal(s.macros.cmdd.ops[1].value, "auto")
        end,
    },
    {
        name = "a key under /svronly that is not a macro slot is ignored",
        fn = function()
            -- /svronly is the unit's own scratch container and holds more than
            -- macros; only the fixed slot names are read.
            local s = State.new()
            s:applyDocument(F.modern())
            H.equal(s.macros.lastUsedPage, nil)
            local slots = 0
            for _ in pairs(s.macros) do slots = slots + 1 end
            H.equal(slots, 6, "cmda-cmdd, preset1 and cmdcustom1, and nothing else")
        end,
    },
    {
        name = "a wholesale /svronly replace re-derives the macros",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            local changes = s:applyOps({
                { op = "replace", path = "/svronly", value = {
                    macroNames = { cmda = "Evening" },
                    cmda = { { op = "replace", path = "/volume", value = -18 } },
                } },
            })
            H.isTrue(changes.macros, "the change is reported")
            H.equal(s.macros.cmda.name, "Evening")
            H.count(s.macros.cmda.ops, 1)
            H.equal(s.macros.cmda.ops[1].value, -18)
            H.equal(s.macros.cmdb.name, "Listening",
                "a slot the push did not mention keeps what it had")
            H.count(s.macros.cmdb.ops, 2)
        end,
    },
    {
        name = "a targeted push replaces one slot's operations, and reports it only when " ..
               "the slot gained or lost them",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())

            -- Still non-empty afterwards: the picker shows names, not
            -- operations, so it has nothing to redraw.
            local changes = s:applyOps({
                { op = "replace", path = "/svronly/cmda",
                  value = { { op = "replace", path = "/volume", value = -12 } } },
            })
            H.equal(changes.macros, nil, "an edit that leaves the slot non-empty is not a redraw")
            H.count(s.macros.cmda.ops, 1)
            H.equal(s.macros.cmda.ops[1].value, -12)

            -- Emptied: it must leave the list.
            changes = s:applyOps({ { op = "replace", path = "/svronly/cmda", value = {} } })
            H.isTrue(changes.macros, "losing its operations changes what the picker shows")
            H.count(s.macros.cmda.ops, 0)

            -- Filled again.
            changes = s:applyOps({
                { op = "replace", path = "/svronly/cmda",
                  value = { { op = "replace", path = "/volume", value = -20 } } },
            })
            H.isTrue(changes.macros, "and so does gaining them back")
        end,
    },
    {
        name = "a targeted push renames one macro",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            local changes = s:applyOps({
                { op = "replace", path = "/svronly/macroNames/cmda", value = "Evening" },
            })
            H.isTrue(changes.macros)
            H.equal(s.macros.cmda.name, "Evening")
            H.equal(s.macros.cmdb.name, "Listening", "no other name moved")

            -- The same name again is not a change.
            changes = s:applyOps({
                { op = "replace", path = "/svronly/macroNames/cmda", value = "Evening" },
            })
            H.equal(changes.macros, nil)
        end,
    },
    {
        name = "a replace of the whole name map is accepted",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            local changes = s:applyOps({
                { op = "replace", path = "/svronly/macroNames",
                  value = { cmda = "Evening", cmdcustom1 = "Quiet" } },
            })
            H.isTrue(changes.macros)
            H.equal(s.macros.cmda.name, "Evening")
            H.equal(s.macros.cmdcustom1.name, "Quiet", "a slot that had no name gains one")
            H.count(s.macros.cmda.ops, 2, "the operations were not disturbed")
        end,
    },
    {
        name = "a push about a slot the unit does not have is ignored",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            local changes = s:applyOps({
                { op = "replace", path = "/svronly/cmdcustom17",
                  value = { { op = "replace", path = "/volume", value = -5 } } },
                { op = "replace", path = "/svronly/macroNames/nosuchslot", value = "Listening" },
                { op = "replace", path = "/svronly/lastUsedPage", value = "macros" },
            })
            H.equal(changes.macros, nil)
            H.equal(s.macros.cmdcustom17, nil)
            H.equal(s.macros.nosuchslot, nil)
        end,
    },
    {
        name = "a document with no /svronly block reports no macros",
        fn = function()
            local s = State.new()
            s:applyDocument(F.legacy())
            H.equal(next(s.macros), nil, "absence is tolerated, not invented around")
            s = State.new()
            s:applyDocument(F.sparse())
            H.equal(next(s.macros), nil)
        end,
    },
}
