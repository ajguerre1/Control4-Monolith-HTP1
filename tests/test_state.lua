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
        name = "the firmware version is reduced to its version number",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            H.equal(s.fields.firmware, "5.96", "the build date and newline are dropped")
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
            H.equal(s.fields.firmware, "4.91")
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
}
