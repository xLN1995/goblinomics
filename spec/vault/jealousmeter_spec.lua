-- M3 acceptance: correct level at every threshold, at the cap and at x2/x5/x10,
-- no toast spam around a threshold, one toast per level.
local G = 10000 -- copper per gold

describe("Vault: Jealousmeter logic", function()
    local J
    before_each(function() J = select(2, load_vault({ login = false })).Jealousmeter end)

    it("reaches every regular tier exactly at its threshold", function()
        local thresholds = { 0, 10000, 50000, 100000, 250000, 500000, 1000000, 2500000, 5000000 }
        for tier, gold in ipairs(thresholds) do
            assert.equals(tier - 1, J.Level(gold * G))
            if gold > 0 then assert.equals(tier - 2, J.Level((gold - 1) * G)) end
        end
    end)

    it("stays in tier 8 up to the gold cap and switches to GoldCap+ at the cap", function()
        assert.equals(8, J.Level(9999998 * G))
        local level = J.Level(9999999 * G)
        assert.equals(9, level)
        assert.same({ 9, 0 }, { J.Face(level) })
    end)

    it("adds prestige at x2, x5 and x10 cap", function()
        assert.same({ 9, 1 }, { J.Face(J.Level(2 * 9999999 * G)) })
        assert.same({ 9, 2 }, { J.Face(J.Level(5 * 9999999 * G)) })
        assert.same({ 9, 3 }, { J.Face(J.Level(10 * 9999999 * G)) })
        assert.equals(12, J.Level(50 * 9999999 * G))
    end)

    it("fills linearly by absolute gold towards the next level", function()
        local info = J.Info(100000 * G, 3)
        assert.equals(0, info.progress)
        assert.equals(150000, info.toNext)
        assert.equals(0.5, J.Info(175000 * G, 3).progress)
        assert.equals(0.25, J.Info(2500 * G, 0).progress)
        assert.equals(0.5, J.Info((5000000 + 2499999.5) * G, 8).progress)
        assert.equals(1, J.Info(1e12 * G, 12).progress)
        assert.is_nil(J.Info(1e12 * G, 12).toNext)
    end)

    it("keeps the level inside the 2 % hysteresis band", function()
        local level = J.Level(250000 * G)
        assert.equals(4, level)
        level = J.Level(249000 * G, level)
        assert.equals(4, level)
        level = J.Level(244000 * G, level)
        assert.equals(3, level)
    end)

    it("uses the right textures", function()
        assert.truthy(J.Texture(0):find("tier0_unimpressed$"))
        assert.truthy(J.Texture(11, true):find("tier9_hostiletakeover_64$"))
    end)
end)

describe("Vault: Jealousmeter toasts", function()
    local ns, vns, toasts

    before_each(function()
        ns, vns = load_vault()
        toasts = {}
        ns.UI.Toast = function(spec) toasts[#toasts + 1] = spec end
    end)

    it("records the first value silently and toasts each new high once", function()
        local JUI = vns.JealousmeterUI
        JUI.SetTotal(20000 * G)
        assert.equals(0, #toasts)
        assert.equals(1, GoblinomicsVaultDB.jealousmeter.highestLevel)
        JUI.SetTotal(60000 * G)
        assert.equals(1, #toasts)
        assert.truthy(toasts[1].icon:find("tier2_curious_64$"))
        for _ = 1, 5 do
            JUI.SetTotal(49500 * G)
            JUI.SetTotal(50500 * G)
        end
        assert.equals(1, #toasts)
        JUI.SetTotal(20000 * G)
        JUI.SetTotal(60000 * G)
        assert.equals(1, #toasts)
    end)

    it("measures the wealth without speculative items", function()
        local JUI = vns.JealousmeterUI
        assert.equals(60000 * G, JUI.Value({ wealth = 80000 * G, speculative = 20000 * G }))
        assert.equals(80000 * G, JUI.Value({ wealth = 80000 * G }))
        ns.API.Emit("NETWORTH_UPDATED", { wealth = 80000 * G, speculative = 60000 * G })
        assert.equals(20000 * G, (JUI.Current()))
    end)

    it("previews values without touching saved data", function()
        vns.JealousmeterUI.SetTotal(20000 * G)
        ns.EntryPoints.HandleSlash("jealous 5000000")
        assert.equals(1, #toasts)
        assert.equals(1, GoblinomicsVaultDB.jealousmeter.highestLevel)
        local _, level = vns.JealousmeterUI.Current()
        assert.equals(8, level)
        ns.EntryPoints.HandleSlash("jealous off")
        assert.equals(1, select(2, vns.JealousmeterUI.Current()))
    end)

    it("follows NETWORTH_UPDATED next to the goals (one handler per owner, in-game finding M7)", function()
        ns.Bus.Emit("NETWORTH_UPDATED", { wealth = 60000 * G })
        assert.equals(60000 * G, (vns.JealousmeterUI.Current()))
    end)

    it("shows the wealth below the bar and the gold of every mark", function()
        ns.UI.GetSidePanel().build(CreateFrame("Frame"))
        vns.JealousmeterUI.SetTotal(175000 * G)                 -- level 3: 100K .. 250K
        vns.JealousmeterUI.Refresh()
        local m = vns.JealousmeterUI.Meters()[1]
        assert.equals(ns.API.Money.Format(175000 * G, { abbreviate = true }), m.wealth:GetText())
        local labels = {}
        for i, mark in ipairs(m.marks) do labels[i] = mark.label:GetText() end
        assert.same({ "100K", "138K", "175K", "212K", "250K" }, labels)
        assert.equals("G\nA\nL\nL\nY\nW\nI\nX", vns.JealousmeterUI.Vertical("GALLYWIX"))
    end)

    it("registers the side panel and a tooltip line", function()
        assert.equals("jealousmeter", ns.UI.GetSidePanel().id)
        vns.JealousmeterUI.SetTotal(20000 * G)
        ns.EntryPoints.FillTooltip(GameTooltip)
        assert.truthy(table.concat(GameTooltip.lines, "\n"):find("tier1_amused_64", 1, true))
    end)
end)

describe("Vault: Jealousmeter on WoW: Forever", function()
    local ns, vns, J, toasts

    before_each(function()
        ns, vns = load_vault({ client = "forever" })
        J = vns.Jealousmeter
        toasts = {}
        ns.UI.Toast = function(spec) toasts[#toasts + 1] = spec end
    end)

    it("uses the Forever ladder: 50 silver to 1,000 gold, prestige at 2k, 5k and 10k", function()
        assert.equals("forever", J.SET)
        assert.equals(1000, J.CAP)
        local thresholds = { 0, 0.5, 1, 5, 10, 25, 50, 100, 250 }
        for tier, gold in ipairs(thresholds) do
            assert.equals(tier - 1, J.Level(gold * G))
            if gold > 0 then assert.equals(tier - 2, J.Level(gold * G - 1)) end
        end
        assert.equals(8, J.Level(999 * G))
        assert.same({ 9, 0 }, { J.Face(J.Level(1000 * G)) })
        assert.same({ 9, 1 }, { J.Face(J.Level(2000 * G)) })
        assert.same({ 9, 2 }, { J.Face(J.Level(5000 * G)) })
        assert.same({ 9, 3 }, { J.Face(J.Level(10000 * G)) })
    end)

    it("switches back to the retail ladder on request", function()
        J.Use("retail")
        assert.equals("retail", J.SET)
        assert.equals(9999999, J.CAP)
        assert.equals(1, J.Level(10000 * G))
        assert.equals(0, J.Level(9999 * G))
        J.Use("forever")
        assert.equals(1, J.Level(5000))
    end)

    it("fills the first level from 0 to 50 silver and keeps the hysteresis", function()
        local info = J.Info(2500, 0)   -- 25 silver
        assert.equals(0.5, info.progress)
        assert.equals(0.5, info.next)
        assert.equals(0.25, info.toNext)
        local level = J.Level(5000)
        assert.equals(1, level)
        assert.equals(1, J.Level(4900, level))   -- 49 silver: inside the 2 % band
        assert.equals(0, J.Level(4800, level))
    end)

    it("shows silver below one gold: wealth, marks, toast and preview", function()
        ns.UI.GetSidePanel().build(CreateFrame("Frame"))
        local JUI = vns.JealousmeterUI
        JUI.SetTotal(2500)   -- first value is recorded silently
        JUI.Refresh()
        local m = JUI.Meters()[1]
        assert.truthy(m.wealth:GetText():find("^25|T"))
        local labels = {}
        for i, mark in ipairs(m.marks) do labels[i] = mark.label:GetText() end
        assert.same({ "0", "13s", "25s", "38s", "50s" }, labels)
        JUI.SetTotal(6000)   -- 60 silver: level 1
        assert.equals(1, #toasts)
        assert.truthy(toasts[1].text:find("^50|T"))
        ns.EntryPoints.HandleSlash("jealous 75s")
        local copper, level = JUI.Current()
        assert.equals(7500, copper)
        assert.equals(1, level)
        ns.EntryPoints.HandleSlash("jealous 1000")
        assert.equals(9, select(2, JUI.Current()))
        ns.EntryPoints.HandleSlash("jealous off")
        assert.equals(1, select(2, JUI.Current()))
    end)
end)
