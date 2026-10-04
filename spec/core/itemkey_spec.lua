describe("Core/Util/ItemKey", function()
    local ItemKey

    before_each(function()
        WoWMock.reset()
        local ns = {}
        load_addon_file("Core/Util/ItemKey.lua", "Goblinomics", ns)
        ItemKey = ns.ItemKey
        ItemKey.SetBonusFilter(nil)
    end)

    it("reduces a plain item link to i:<id>", function()
        assert.equals("i:2589", ItemKey.FromLink("|cffffffff|Hitem:2589::::::::80:::::|h[Linen Cloth]|h|r"))
    end)

    it("accepts a bare item string", function()
        assert.equals("i:2589", ItemKey.FromLink("item:2589::::::::80:::::"))
        assert.equals("i:2589", ItemKey.FromLink("item:2589"))
    end)

    it("keeps an old random suffix id", function()
        assert.equals("i:15000:1234", ItemKey.FromLink("item:15000::::::1234:0:80"))
    end)

    it("keeps bonus ids sorted with their count", function()
        local link = "|cffa335ee|Hitem:212072::::::::80:105::5:3:10256:6652:1520::::::|h[Boots]|h|r"
        assert.equals("i:212072::3:1520:6652:10256", ItemKey.FromLink(link))
    end)

    it("keeps the important modifier type 9 with its value", function()
        local link = "item:212072::::::::80:105::5:3:10256:6652:1520:1:9:620"
        assert.equals("i:212072::3:1520:6652:10256:1:9:620", ItemKey.FromLink(link))
    end)

    it("keeps extra-stat modifiers 29/30 sorted and drops other modifier types", function()
        local link = "item:212072::::::::80:105::5:1:6652:3:28:2500:30:4711:29:42"
        assert.equals("i:212072::1:6652:2:29:42:30:4711", ItemKey.FromLink(link))
    end)

    it("drops ignored modifier types entirely", function()
        assert.equals("i:212072::1:6652", ItemKey.FromLink("item:212072::::::::80:105::5:1:6652:1:28:2500"))
    end)

    it("handles modifiers without bonus ids", function()
        assert.equals("i:212072:::1:9:620", ItemKey.FromLink("item:212072::::::::80:105::5:0:1:9:620"))
    end)

    it("reads crafted items whose link ends in the crafter's GUID", function()
        local link = "|cnIQ3:|Hitem:239671::::::::81:64::13:5:12249:12248:4785:12494:12667:6:28:3615:29:32:30:40:38:5"
            .. ":40:2568:48:246211::::Player-581-0AF7409A:|h[Courtly Wrists |A:Professions-ChatIcon-Quality-Tier2:17:15::1|a]|h|r"
        assert.equals("i:239671::5:4785:12248:12249:12494:12667:2:29:32:30:40", ItemKey.FromLink(link))
        assert.equals("i:239671", ItemKey.FromLink("item:239671::::::::81:64::13:0:0::::Player-581-0AF7409A:"))
    end)

    it("applies an installed bonus filter", function()
        ItemKey.SetBonusFilter(function(bonus)
            local kept = {}
            for i = 1, #bonus do
                if bonus[i] ~= 6652 then kept[#kept + 1] = bonus[i] end
            end
            return kept
        end)
        assert.equals("i:212072::2:1520:10256", ItemKey.FromLink("item:212072::::::::80:105::5:3:10256:6652:1520"))
    end)

    it("normalises caged battle pets", function()
        assert.equals("p:1234:25:3", ItemKey.FromLink("|cff0070dd|Hbattlepet:1234:25:3:1000:100:100:BattlePet-0-0000|h[Pet]|h|r"))
        assert.equals("p:1234", ItemKey.FromLink("battlepet:1234"))
    end)

    it("passes existing keys through unchanged", function()
        assert.equals("i:2589", ItemKey.FromLink("i:2589"))
        assert.equals("i:212072::3:1520:6652:10256", ItemKey.FromLink("i:212072::3:1520:6652:10256"))
        assert.equals("p:1234:25:3", ItemKey.FromLink("p:1234:25:3"))
    end)

    it("returns nil for garbage", function()
        assert.is_nil(ItemKey.FromLink(nil))
        assert.is_nil(ItemKey.FromLink(42))
        assert.is_nil(ItemKey.FromLink("hello"))
        assert.is_nil(ItemKey.FromLink("item:0"))
        assert.is_nil(ItemKey.FromLink("|Hspell:1234|h[Spell]|h"))
    end)

    it("extracts the item id and base key", function()
        assert.equals(212072, ItemKey.ToItemID("i:212072::3:1520:6652:10256"))
        assert.is_nil(ItemKey.ToItemID("p:1234:25:3"))
        assert.equals("i:212072", ItemKey.Base("i:212072::3:1520:6652:10256"))
        assert.equals("p:1234", ItemKey.Base("p:1234:25:3"))
        assert.is_true(ItemKey.IsPet("p:1234"))
        assert.is_false(ItemKey.IsPet("i:1234"))
    end)

    it("round-trips keys through ToItemString", function()
        local keys = {
            "i:2589", "i:15000:1234", "i:212072::3:1520:6652:10256",
            "i:212072::3:1520:6652:10256:1:9:620", "i:212072:::1:9:620",
            "i:212072::1:6652:2:29:42:30:4711", "p:1234:25:3", "p:1234",
        }
        for _, key in ipairs(keys) do
            assert.equals(key, ItemKey.FromLink(ItemKey.ToItemString(key)))
        end
        assert.equals("item:2589::::::::::::", ItemKey.ToItemString("i:2589"))
        assert.is_nil(ItemKey.ToItemString("garbage"))
    end)
end)
