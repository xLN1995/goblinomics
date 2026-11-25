describe("Ledger: rules", function()
    local R

    before_each(function()
        local _, lns = load_ledger()
        R = lns.Rules
    end)

    it("converts wildcards to anchored case-insensitive patterns", function()
        assert.equals("^gp.*$", R.WildcardToPattern("GP*"))
        assert.equals("^a%.b.c$", R.WildcardToPattern("a.b?c"))
    end)

    it("matches subject and sender rules, first enabled rule wins", function()
        local rules = {
            { field = "subject", pattern = "GP*", mode = "wildcard", category = "Mail", tag = "Boosting", enabled = false },
            { field = "subject", pattern = "gp*", mode = "wildcard", category = "Mail", tag = "Boost2" },
            { field = "sender", pattern = "PayOut*", mode = "wildcard", category = "Mail", tag = "Boosting" },
        }
        assert.equals("Boost2", R.MatchMail(rules, "Someone", "GP191").tag)
        assert.equals("Boosting", R.MatchMail(rules, "PayOutBot", "Your cut").tag)
        assert.is_nil(R.MatchMail(rules, "Friend", "Hello"))
    end)

    it("supports Lua patterns and rejects invalid ones", function()
        local rule = { field = "subject", pattern = "^GP%d+$", mode = "lua", category = "Mail", tag = "Boosting" }
        assert.equals(rule, R.MatchMail({ rule }, "x", "GP191"))
        assert.is_nil(R.MatchMail({ rule }, "x", "gp191"))
        local pattern, err = R.Compile({ pattern = "[unclosed", mode = "lua" })
        assert.is_nil(pattern)
        assert.is_string(err)
        assert.is_nil(R.MatchMail({ { field = "subject", pattern = "[bad", mode = "lua" } }, "x", "[bad"))
    end)

    it("recognises own characters with and without realm", function()
        assert.is_true(R.IsOwnCharacter("xLN"))
        assert.is_true(R.IsOwnCharacter("xLN-Blackrock"))
        assert.is_false(R.IsOwnCharacter("Stranger"))
    end)

    it("ignores the shard realm of senders with region-wide names (WoW: Forever)", function()
        WoWMock.regionalNames = true
        WoWMock.gameRules[Enum.GameRule.PvPRuleset] = true
        Goblinomics.API.v1.DB.List()[1].root.chars["Alt-PvP"] = { name = "Alt" }
        assert.is_true(R.IsOwnCharacter("Alt"))
        assert.is_true(R.IsOwnCharacter("Alt-CAMWOWEU5Realm6PvP"))
        assert.is_false(R.IsOwnCharacter("Stranger-CAMWOWEU5Realm6PvP"))
    end)
end)
