local fake = require("spec.support.sources")

local HERB = "|cffffffff|Hitem:210796::::::::80:::::|h[Mycobloom]|h|r"

describe("Gatherer: session tracker", function()
    after_each(function() assert.same({}, WoWMock.errors) end)

    local ns, pns, Session, got

    local function money(delta)
        WoWMock.set_money(WoWMock.money + delta)
        WoWMock.fire("PLAYER_MONEY")
    end

    local function lootLine(link, qty)
        WoWMock.fire("CHAT_MSG_LOOT", "You receive loot: " .. link .. "x" .. qty .. ".", nil, nil, nil, nil, nil, nil,
            nil, nil, nil, nil, WoWMock.player.guid)
    end

    -- logout (or a crash: no PLAYER_LOGOUT), wait, then a /reload or a new login with
    -- the same SavedVariables and clock
    local function relog(seconds, how)
        if how ~= "crash" then WoWMock.fire("PLAYER_LOGOUT") end
        local saved, now = GoblinomicsGathererDB, WoWMock.now
        ns, pns = load_gatherer({ before = function()
            WoWMock.now = now + seconds
            _G.GoblinomicsGathererDB = saved
        end })
        Session = pns.Session
        ns.Price.RegisterSource(fake("tsm", 10, { market = { ["i:210796"] = 10000 } }))
        local reload = how == "reload"
        WoWMock.fire("PLAYER_ENTERING_WORLD", not reload, reload)
    end

    before_each(function()
        ns, pns = load_gatherer()
        Session = pns.Session
        ns.Price.RegisterSource(fake("tsm", 10, { market = { ["i:210796"] = 10000 } }))
        got = {}
        ns.Bus.On("GATHERER_SESSION", function(_, p) got[#got + 1] = p.action end, "spec")
    end)

    it("starts manually only and refuses a second session", function()
        lootLine(HERB, 2)
        assert.is_nil(Session.Active())
        assert.truthy(Session.Start(nil))
        local s, err = Session.Start(nil)
        assert.is_nil(s)
        assert.equals("active", err)
        assert.same({ "start" }, got)
    end)

    it("ignores loot and money while paused", function()
        Session.Start(nil)
        Session.Pause()
        lootLine(HERB, 2)
        WoWMock.fire("LOOT_READY"); money(500); WoWMock.fire("LOOT_CLOSED")
        assert.same({}, Session.Active().items)
        assert.equals(0, Session.Active().rawGold)
        assert.equals(0, Session.Active().realized)
    end)

    it("skips crafted items and items from merchant, mail and auction windows", function()
        Session.Start(nil)
        WoWMock.fire("CHAT_MSG_LOOT", "You create: " .. HERB .. "x2.", nil, nil, nil, nil, nil, nil, nil, nil, nil, nil,
            WoWMock.player.guid)
        WoWMock.fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", Enum.PlayerInteractionType.Merchant)
        WoWMock.fire("CHAT_MSG_LOOT", "You receive item: " .. HERB .. "x3.", nil, nil, nil, nil, nil, nil, nil, nil, nil,
            nil, WoWMock.player.guid)
        WoWMock.fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", Enum.PlayerInteractionType.Merchant)
        WoWMock.advance(5)
        lootLine(HERB, 4)
        assert.equals(4, Session.Active().items["i:210796"])
    end)

    it("skips the yield of disenchanting, but keeps loot from opened items", function()
        Session.Start(nil)
        WoWMock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", 13262)
        WoWMock.loot = { { link = HERB, sources = { "Item-0-1-2-3", 2 } } }
        WoWMock.fire("LOOT_READY")
        lootLine(HERB, 2)
        WoWMock.fire("LOOT_CLOSED")
        assert.is_nil(Session.Active().items["i:210796"])
        WoWMock.advance(10)                                             -- a box opened later is farm loot
        WoWMock.fire("LOOT_READY")
        lootLine(HERB, 3)
        assert.equals(3, Session.Active().items["i:210796"])
    end)

    it("counts non-loot gains in realized only; transfers not at all", function()
        Session.Start(nil)
        WoWMock.fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", Enum.PlayerInteractionType.Merchant)
        money(3000)          -- vendor sale
        money(-1000)         -- vendor purchase
        WoWMock.fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", Enum.PlayerInteractionType.Merchant)
        WoWMock.advance(5)
        WoWMock.warband = 50000
        WoWMock.fire("ACCOUNT_MONEY")
        local s = Session.Active()
        assert.equals(0, s.rawGold)
        assert.equals(2000, s.realized)
    end)

    it("moves a gain to raw gold when the loot chat line follows within 5 seconds", function()
        Session.Start(nil)
        money(700)
        WoWMock.fire("CHAT_MSG_MONEY", "You loot 7 Silver")
        assert.equals(700, Session.Active().rawGold)
        WoWMock.advance(4)   -- past the loot chat marker
        money(800)
        WoWMock.advance(6)
        WoWMock.fire("CHAT_MSG_MONEY", "You loot 8 Silver")
        assert.equals(700, Session.Active().rawGold)
    end)

    it("counts gold reconciled right after the restricted mode as raw gold", function()
        Session.Start(nil)
        ns.Bus.Emit("MONEY_DELTA", { scope = "player", amount = 900, context = {}, restricted = false, reconciled = true })
        assert.equals(900, Session.Active().rawGold)
    end)

    it("does not count quest rewards as raw gold", function()
        Session.Start(nil)
        WoWMock.fire("QUEST_TURNED_IN", 1, 100, 1000)
        WoWMock.fire("LOOT_READY"); money(1000); WoWMock.fire("LOOT_CLOSED")
        assert.equals(0, Session.Active().rawGold)
        assert.equals(1000, Session.Active().realized)
    end)

    it("auto-pauses after the configured idle minutes without counting them", function()
        GoblinomicsGathererDB.settings.autoPauseMinutes = 5
        Session.Start(nil)
        WoWMock.advance(120)
        lootLine(HERB, 1)
        WoWMock.advance(300)
        WoWMock.advance(1)
        local s = Session.Active()
        assert.is_nil(s.runningSince)
        assert.is_true(s.autoPaused)
        assert.equals(120, Session.Duration())
        Session.Resume()
        WoWMock.advance(60)
        assert.equals(180, Session.Duration())
    end)

    it("does not auto-pause when the option is off", function()
        Session.Start(nil)
        WoWMock.advance(7200)
        assert.is_true(Session.IsRunning())
    end)

    it("survives a reload and resumes without counting the loading time", function()
        Session.Start(nil)
        lootLine(HERB, 2)
        WoWMock.advance(100)
        relog(30, "reload")
        local s = Session.Active()
        assert.is_not_nil(s)
        assert.equals(2, s.items["i:210796"])
        assert.is_true(Session.IsRunning())
        assert.equals(100, Session.Duration())
    end)

    it("stays paused over a reload when it was paused", function()
        Session.Start(nil)
        WoWMock.advance(100)
        Session.Pause()
        relog(30, "reload")
        assert.is_not_nil(Session.Active())
        assert.is_false(Session.IsRunning())
    end)

    it("ends with the logout: the next login stores it up to the logout", function()
        local farm = pns.Farms.Create({ name = "Herbs", category = "gathering" })
        Session.Start(farm.id)
        lootLine(HERB, 2)
        WoWMock.advance(100)
        relog(60)
        assert.is_nil(Session.Active())
        local history = pns.Farms.History(farm.id)
        assert.equals(1, #history)
        assert.equals(100, history[1].duration)
        assert.equals(2, history[1].items["i:210796"])
    end)

    it("ends after a crash up to the last activity", function()
        local farm = pns.Farms.Create({ name = "Herbs", category = "gathering" })
        Session.Start(farm.id)
        WoWMock.advance(40)
        lootLine(HERB, 1)
        WoWMock.advance(500)
        relog(60, "crash")
        assert.is_nil(Session.Active())
        assert.equals(40, pns.Farms.History(farm.id)[1].duration)
    end)

    it("learns the repair rate at a merchant and counts only durability used while running", function()
        WoWMock.durability[1] = { 50, 100 }
        WoWMock.durability[5] = { 70, 120 }
        WoWMock.repairCost = 10000
        WoWMock.fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", Enum.PlayerInteractionType.Merchant)
        assert.equals(100, Session.RepairRate())   -- 10000 / 100 points
        Session.Start(nil)
        WoWMock.durability[1] = { 100, 100 }; WoWMock.durability[5] = { 120, 120 }
        WoWMock.fire("UPDATE_INVENTORY_DURABILITY")   -- repaired: nothing used
        WoWMock.durability[1] = { 95, 100 }
        WoWMock.fire("UPDATE_INVENTORY_DURABILITY")
        Session.Pause()
        WoWMock.durability[1] = { 90, 100 }
        WoWMock.fire("UPDATE_INVENTORY_DURABILITY")   -- paused: not counted
        Session.Resume()
        WoWMock.durability[5] = { 117, 120 }
        WoWMock.fire("UPDATE_INVENTORY_DURABILITY")
        assert.equals(8, Session.Active().durabilityUsed)
        assert.equals(800, Session.RepairCost())
    end)

    it("reports repair as unknown without a learned rate", function()
        Session.Start(nil)
        WoWMock.durability[1] = { 90, 100 }
        WoWMock.fire("UPDATE_INVENTORY_DURABILITY")
        local summary = Session.Stop()
        assert.equals(0, summary.repair)
        assert.is_false(summary.repairKnown)
    end)

    it("keeps ad-hoc sessions in their own history", function()
        Session.Start(nil)
        WoWMock.advance(60)
        local summary = Session.Stop()
        assert.is_nil(summary.farmId)
        assert.equals(1, #pns.Farms.History(nil))
        assert.equals("stop", got[#got])
    end)
end)
