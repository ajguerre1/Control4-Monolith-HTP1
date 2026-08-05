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
}
