local fake = require("spec.support.sources")

local GEM = "|cff0070dd|Hitem:7000::::::::80:::::|h[Gem]|h|r"
local HERB = "|cffffffff|Hitem:210796::::::::80:::::|h[Mycobloom]|h|r"

describe("Gatherer: highlights", function()
    after_each(function() assert.same({}, WoWMock.errors) end)

    local ns, pns, toasts

    local function lootLine(link, qty)
        WoWMock.fire("CHAT_MSG_LOOT", "You receive loot: " .. link .. "x" .. qty .. ".", nil, nil, nil, nil, nil, nil,
            nil, nil, nil, nil, WoWMock.player.guid)
    end

    before_each(function()
        ns, pns = load_gatherer()
        ns.Price.RegisterSource(fake("tsm", 10, { market = { ["i:7000"] = 30000000, ["i:210796"] = 100000 } }))
        toasts = {}
        ns.Toast.Show = function(spec) toasts[#toasts + 1] = spec end
    end)

    it("toasts loot worth at least 2,500 g by default, with sound", function()
        pns.Session.Start(nil)
        lootLine(GEM, 1)
        lootLine(HERB, 5)
        assert.equals(1, #toasts)
        assert.equals("Valuable loot", toasts[1].title)
        assert.equals(8000, toasts[1].icon)
        assert.equals("kit:UI_EPICLOOT_TOAST", toasts[1].sound)
        assert.equals("i:7000", pns.Session.Active().highlights[1].key)
    end)

    it("uses the stack value, the farm override and the sound setting", function()
        local farm = pns.Farms.Create({ name = "Herbs", highlightThreshold = 40 })
        GoblinomicsGathererDB.settings.highlightSound = false   -- old boolean setting: off
        pns.Session.Start(farm.id)
        lootLine(HERB, 3)   -- 30 g
        lootLine(HERB, 4)   -- 40 g
        assert.equals(1, #toasts)
        assert.is_nil(toasts[1].sound)
    end)

    it("notifies about expected highlights and watchlist items regardless of value", function()
        local farm = pns.Farms.Create({ name = "Herbs", expectedHighlights = { "i:210796" } })
        pns.Session.Start(farm.id)
        lootLine(HERB, 1)
        assert.equals("Expected highlight looted", toasts[1].title)
        pns.Session.Stop()
        pns.Highlights.SetWatched("i:210796", true)
        pns.Session.Start(nil)
        lootLine(HERB, 1)
        assert.equals(2, #toasts)
        assert.equals("Watchlist item looted", toasts[2].title)
        assert.same({ "i:210796" }, pns.Highlights.Watchlist())
    end)

    it("stays silent outside a running session and when the threshold is 0", function()
        lootLine(GEM, 1)
        pns.Session.Start(nil)
        pns.Session.Pause()
        lootLine(GEM, 1)
        pns.Session.Resume()
        GoblinomicsGathererDB.settings.highlightThreshold = 0
        lootLine(GEM, 1)
        assert.equals(0, #toasts)
    end)

    it("always highlights mounts and legendary items, whatever the value and threshold", function()
        GoblinomicsGathererDB.settings.highlightThreshold = 0
        WoWMock.items[8000] = { classID = 15, subclassID = 5 }
        WoWMock.items[8001] = { quality = 5 }
        pns.Session.Start(nil)
        lootLine("|cffa335ee|Hitem:8000::::::::80:::::|h[Reins]|h|r", 1)
        lootLine("|cffff8000|Hitem:8001::::::::80:::::|h[Legendary]|h|r", 1)
        lootLine("|cffff8000|Hitem:8002::::::::80:::::|h[Uncached Legendary]|h|r", 1)   -- only the link colour
        lootLine(HERB, 1)
        assert.equals(3, #toasts)
        assert.equals("Mount looted!", toasts[1].title)
        assert.equals("kit:UI_LEGENDARY_LOOT_TOAST", toasts[1].sound)
        assert.equals("Legendary looted!", toasts[2].title)
        assert.equals("Legendary looted!", toasts[3].title)
    end)

    it("recognises mounts through the mount journal", function()
        _G.C_MountJournal = { GetMountFromItem = function(id) return id == 8100 and 42 or nil end }
        assert.is_true(pns.Highlights.IsMount(nil, "i:8100"))
        assert.is_false(pns.Highlights.IsMount(nil, "i:8101"))
        _G.C_MountJournal = nil
    end)
end)

describe("Gatherer: highlights on WoW: Forever", function()
    it("notifies from 5 gold by default", function()
        local pns = select(2, load_gatherer({ client = "forever" }))
        assert.equals(5 * 10000, pns.Highlights.Threshold(nil))
    end)
end)
