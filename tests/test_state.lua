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
                    DECSampleRate = "48 kHz",
                    ENCListeningFormat = "5.2.2t",
                    ENCSampleRate = "48 kHz",
                    DiracState = "off",
                    raw = { decoderSampleRateEnum = 5 },
                } },
            })
            H.equal(s.fields.surroundMode, "Dolby Surround")
            H.equal(s.fields.decSourceProgram, "PCM")
            H.equal(s.fields.decProgramFormat, "2.0.0")
            H.equal(s.fields.encListeningFormat, "5.2.2t")
            H.equal(s.fields.diracState, "off")
            H.isTrue(changes.surroundMode and changes.decSourceProgram and
                changes.decProgramFormat and changes.encListeningFormat and changes.diracState)
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
}
