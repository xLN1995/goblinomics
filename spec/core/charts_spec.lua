describe("Core: time charts", function()
    local ns

    before_each(function() ns = load_core({ login = true, money = 1 }) end)
    after_each(function() assert.same({}, WoWMock.errors) end)

    it("picks 1-2-5 steps that cover the values", function()
        local s = ns.Charts.NiceScale(12, 87)
        assert.equals(20, s.step)
        assert.same({ 0, 20, 40, 60, 80, 100 }, s.ticks)
        local big = ns.Charts.NiceScale(1234567, 1987654)
        assert.equals(200000, big.step)
        assert.equals(1200000, big.min)
        assert.equals(2000000, big.max)
    end)

    it("puts a grid line on zero when the values change sign and survives flat data", function()
        local s = ns.Charts.NiceScale(-30, 70)
        local hasZero = false
        for _, v in ipairs(s.ticks) do if v == 0 then hasZero = true end end
        assert.is_true(hasZero)
        local zero = ns.Charts.NiceScale(0, 0)
        assert.is_true(zero.max > zero.min)
        local flat = ns.Charts.NiceScale(500, 500)
        assert.is_true(flat.min <= 500 and flat.max >= 500 and flat.min >= 0)
    end)

    it("labels first, last and evenly spaced days", function()
        assert.same({ 1, 2, 3 }, ns.Charts.DateTicks(3, 6))
        assert.same({ 1, 8, 16, 23, 30 }, ns.Charts.DateTicks(30, 5))
        assert.same({}, ns.Charts.DateTicks(0, 5))
    end)

    it("writes short gold labels", function()
        assert.equals("950", ns.Charts.AxisLabel(950 * 10000))
        assert.equals("2.5K", ns.Charts.AxisLabel(2500 * 10000))
        assert.equals("120K", ns.Charts.AxisLabel(120000 * 10000))
        assert.equals("1.2M", ns.Charts.AxisLabel(1200000 * 10000))
        assert.equals("-40K", ns.Charts.AxisLabel(-40000 * 10000))
    end)

    it("lays out bars around the zero line and lines through the slot centres", function()
        local series = { { kind = "bars", key = "income" }, { kind = "bars", key = "expense" }, { kind = "line", key = "net" } }
        local data = {
            { values = { income = 80, expense = -20, net = 60 } },
            { values = { income = 0, expense = -40, net = -40 } },
        }
        local l = ns.Charts.Layout(data, series, 100, 100)
        assert.equals(-50, l.scale.min)                 -- -40..80 in steps of 50
        assert.equals(100, l.scale.max)
        assert.is_near(100 * 50 / 150, l.zero, 1e-9)
        assert.equals(25, l.xs[1])
        assert.equals(75, l.xs[2])
        local up = l.bars[1].segments[1]
        assert.is_near(l.zero, up.y, 1e-9)
        assert.is_near(100 * 80 / 150, up.height, 1e-9)
        local down = l.bars[2].segments[1]
        assert.is_near(l.zero, down.y + down.height, 1e-9)
        assert.equals(2, #l.lines.net)
        assert.is_false(l.empty)
    end)

    it("fills the area with stripes that follow the line", function()
        local stripes = ns.Charts.AreaStripes({ { x = 0, y = 0 }, { x = 10, y = 10 }, { x = 20, y = 0 } }, 5)
        -- the sheared tops join without steps
        for i = 1, #stripes - 1 do assert.is_near(stripes[i].right, stripes[i + 1].left, 1e-9) end
        assert.equals(4, #stripes)
        assert.equals(2.5, stripes[1].height)
        assert.equals(7.5, stripes[2].height)
        assert.equals(7.5, stripes[3].height)
        assert.same({}, ns.Charts.AreaStripes({ { x = 0, y = 3 } }, 5))
    end)

    it("builds a chart, shows the empty hint and the crosshair tooltip", function()
        local chart = ns.Charts.TimeChart(CreateFrame("Frame"), { width = 400, height = 160, empty = "none",
            series = { { kind = "area", key = "wealth" }, { kind = "bars", key = "income" } },
            label = function(i) return "d" .. i end,
            tooltip = function(i) return "Day " .. i, {} end })
        chart:SetData({})
        assert.is_true(chart.layout.empty)
        chart:SetData({ { values = { wealth = 10, income = 5 } }, { values = { wealth = 30, income = 0 } } })
        assert.is_false(chart.layout.empty)
        assert.equals(chart.plot, chart.plot.overlay._allPoints)
        chart:Hover(2)
        assert.equals("Day 2", GameTooltip.lines[1])
    end)
end)
