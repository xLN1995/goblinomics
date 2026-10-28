if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Flips/AuctionHints.lua
-- Flip hints at the auction house (setting auctionHints):
--   sell     a box under the price of Blizzard's sell frames: cost basis of the
--            open lots, break-even after the cut, profit at the entered price
--   buy      one line above Blizzard's buy lists: your flip record of the item
--   tooltip  the same figures in the item tooltip while the auction house is
--            open, so they show in TSM and Auctionator too
-- Blizzard_AuctionHouseUI loads on demand; the frames are decorated once it is
-- there. The sell box polls the entered price four times a second, only while a
-- sell frame is shown. Hooks are permanent and check `active`.
local _, ns = ...

local Hints = {}
ns.AuctionHints = Hints

local API = ns.API
local L = API.L

local module
local active = false
local decorated = false
local tooltipHooked = false

local function Enabled()
    return active and module.db.settings.auctionHints
end

local function Money(copper) return API.Money.Format(math.floor(copper + 0.5)) end

--- Flip statistics of every key with the same base item (all time), summed.
function Hints.Record(key)
    local base = API.ItemKey.Base(key)
    local total
    for k, s in pairs(ns.Stats.ByItem({})) do
        if API.ItemKey.Base(k) == base then
            if not total then
                total = { soldQty = 0, profit = 0, sold = 0, ends = 0, holdSum = 0, openQty = 0 }
            end
            total.soldQty = total.soldQty + s.soldQty
            total.profit = total.profit + s.profit
            total.sold = total.sold + s.sold
            total.ends = total.ends + s.expired + s.cancelled
            total.holdSum = total.holdSum + s.holdSum
            total.openQty = total.openQty + s.openQty
        end
    end
    if not total or (total.soldQty == 0 and total.openQty == 0) then return nil end
    total.perUnit = total.soldQty > 0 and total.profit / total.soldQty or nil
    total.saleRate = (total.sold + total.ends) > 0 and total.sold / (total.sold + total.ends) or nil
    total.holdTime = total.soldQty > 0 and total.holdSum / total.soldQty or nil
    return total
end

--- Lines of the sell box for key at unitPrice x quantity, or nil without open lots:
-- { lines, gain } (gain = profit per unit at that price, nil without a price).
function Hints.Sell(key, unitPrice, quantity)
    local basis, open = ns.FlipsDetail.CostBasis(key)
    if not basis then return nil end
    local lots = #ns.Store.OpenLots(key)
    local breakEven = ns.FlipsDetail.BreakEven(basis)
    local lines = {
        API.Lf("Cost basis %s  (%d open, %d lots)", Money(basis), open, lots),
        API.Lf("Break-even %s  (after the 5%% cut)", Money(breakEven)),
    }
    local gain
    if unitPrice and unitPrice > 0 then
        gain = unitPrice * (1 - ns.Backfill.CUT) - basis
        local n = quantity or 1
        local text = API.Lf("At %s: %s per unit = %s total (%s)", Money(unitPrice),
            API.Money.Format(math.floor(gain + 0.5), { color = true, sign = true }),
            API.Money.Format(math.floor(gain * n + 0.5), { color = true, sign = true }),
            ns.FlipsUI.Percent(gain / basis, true))
        lines[#lines + 1] = text
    end
    return { lines = lines, gain = gain }
end

--- The buy line for key, or nil without a flip record.
function Hints.Buy(key, name)
    local r = Hints.Record(key)
    if not r then return nil end
    return API.Lf("Flips %s: avg %s per unit  |  rate %s  |  avg %s  |  %d open", name or "",
        r.perUnit and API.Money.Format(math.floor(r.perUnit + 0.5), { color = true, sign = true }) or "-",
        ns.FlipsUI.Percent(r.saleRate), ns.FlipsUI.Hold(r.holdTime), r.openQty)
end

--- Tooltip lines for key: { { left, right } }.
function Hints.TooltipLines(key)
    local out = {}
    local basis, open = ns.FlipsDetail.CostBasis(key)
    if basis then
        out[#out + 1] = { L["Flips cost basis"], Money(basis) .. "  (" .. API.Lf("%d open", open) .. ")" }
        out[#out + 1] = { L["Flips break-even"], Money(ns.FlipsDetail.BreakEven(basis)) }
    end
    local r = Hints.Record(key)
    if r and r.perUnit then
        out[#out + 1] = { L["Flips profit per unit"], API.Money.Format(math.floor(r.perUnit + 0.5), { color = true, sign = true })
            .. "  " .. API.Lf("rate %s, %s", ns.FlipsUI.Percent(r.saleRate), ns.FlipsUI.Hold(r.holdTime)) }
    end
    return out
end

-- Sell frames ---------------------------------------------------------------------------------
local function SellState(frame)
    local location = frame.GetItem and frame:GetItem()
    if not location then return nil end
    local link = C_Item.GetItemLink and C_Item.GetItemLink(location)
    local key = link and API.ItemKey.FromLink(link)
    if not key then return nil end
    local price = frame.PriceInput and frame.PriceInput.GetAmount and frame.PriceInput:GetAmount()
    local quantity = frame.GetQuantity and frame:GetQuantity() or 1
    return key, price, quantity
end

local function DecorateSell(frame)
    if not frame or frame.goblinomicsFlips then return end
    local Theme = API.Theme
    local C, S = Theme.colors, Theme.space
    local box = CreateFrame("Frame", nil, frame)
    local _, edge = Theme.Backdrop(box, C.panel, C.border)
    box:SetSize(280, 3 * 14 + 2 * S.SM)
    box:SetPoint("TOPLEFT", frame.PriceInput or frame, "BOTTOMLEFT", 0, -S.XS)
    box:SetFrameLevel(frame:GetFrameLevel() + 10)
    box.text = Theme.Text(box, "small", C.text)
    box.text:SetPoint("TOPLEFT", S.SM, -S.SM)
    box.text:SetPoint("RIGHT", box, "RIGHT", -S.SM, 0)
    box.text:SetJustifyH("LEFT")
    box:Hide()
    -- the driver stays shown with the sell frame; the box hides when there is nothing to say
    local driver = CreateFrame("Frame", nil, frame)
    local elapsed, last = 0, nil
    driver:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + dt
        if elapsed < 0.25 then return end
        elapsed = 0
        local key, price, quantity
        if Enabled() then key, price, quantity = SellState(frame) end
        local stamp = tostring(key) .. ":" .. tostring(price) .. ":" .. tostring(quantity)
        if stamp == last then return end
        last = stamp
        local hint = key and Hints.Sell(key, price, quantity)
        if not hint then
            box:Hide()
            return
        end
        box.text:SetText(table.concat(hint.lines, "\n"))
        local border = hint.gain == nil and C.border or (hint.gain >= 0 and C.accent or C.loss)
        edge:SetColor(border[1], border[2], border[3], 1)
        box:SetHeight(#hint.lines * 14 + 2 * S.SM)
        box:Show()
    end)
    frame.goblinomicsFlips = box
end

-- Buy frames ----------------------------------------------------------------------------------
local function DecorateBuy(frame)
    if not frame or frame.goblinomicsFlips then return end
    local Theme = API.Theme
    local line = Theme.Text(frame, "small", Theme.colors.text)
    line:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", Theme.space.SM, Theme.space.XS)
    line:SetPoint("RIGHT", frame, "RIGHT", -Theme.space.SM, 0)
    line:SetJustifyH("LEFT")
    line:SetWordWrap(false)
    frame.goblinomicsFlips = line
end

local function SetBuyLine(frame, itemID)
    local line = frame and frame.goblinomicsFlips
    if not line then return end
    local text
    if Enabled() and itemID then
        local name = C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)
        text = Hints.Buy("i:" .. itemID, name)
    end
    line:SetText(text or "")
    line:SetShown(text ~= nil)
end

local function OnCommoditySearch(_, itemID)
    if AuctionHouseFrame then SetBuyLine(AuctionHouseFrame.CommoditiesBuyFrame, itemID) end
end

local function OnItemSearch(_, itemKey)
    if AuctionHouseFrame then SetBuyLine(AuctionHouseFrame.ItemBuyFrame, type(itemKey) == "table" and itemKey.itemID or nil) end
end

local function Decorate()
    if decorated or not AuctionHouseFrame then return end
    decorated = true
    DecorateSell(AuctionHouseFrame.CommoditiesSellFrame)
    DecorateSell(AuctionHouseFrame.ItemSellFrame)
    DecorateBuy(AuctionHouseFrame.CommoditiesBuyFrame)
    DecorateBuy(AuctionHouseFrame.ItemBuyFrame)
end

-- Tooltip -------------------------------------------------------------------------------------
local function OnTooltip(tooltip)
    if not Enabled() or not API.Context:IsOpen("auction") then return end
    local link
    if TooltipUtil and TooltipUtil.GetDisplayedItem then
        link = select(2, TooltipUtil.GetDisplayedItem(tooltip))
    elseif tooltip.GetItem then
        link = select(2, tooltip:GetItem())
    end
    local key = link and API.ItemKey.FromLink(link)
    if not key then return end
    local lines = Hints.TooltipLines(key)
    if #lines == 0 then return end
    local gold = API.Theme.colors.gold
    for _, l in ipairs(lines) do
        tooltip:AddDoubleLine(l[1], l[2], gold[1], gold[2], gold[3], 1, 1, 1)
    end
end

local function HookTooltip()
    if tooltipHooked or not (TooltipDataProcessor and Enum.TooltipDataType) then return end
    tooltipHooked = true
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, OnTooltip)
end

function Hints.Enable(m)
    module = m
    active = true
    HookTooltip()
    if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("Blizzard_AuctionHouseUI") then Decorate() end
    m:RegisterEvent("ADDON_LOADED", function(_, name)
        if name == "Blizzard_AuctionHouseUI" then Decorate() end
    end, "flipsHints")
    m:RegisterEvent("AUCTION_HOUSE_SHOW", Decorate)
    m:RegisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED", OnCommoditySearch)
    m:RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED", OnItemSearch)
end

function Hints.Disable()
    active = false
end
