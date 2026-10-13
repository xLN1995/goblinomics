-- luacheck configuration for Goblinomics (WoW Retail 12.1+, Lua 5.1)
std = "lua51"
max_line_length = 140
codes = true
self = false

ignore = {
    "212/_.*",  -- unused argument starting with _
    "211/_.*",  -- unused variable starting with _
    "431",      -- shadowing an upvalue
    "542",      -- empty if branch
}

exclude_files = {
    "Libs/**",
    ".release/**",
    "release/**",
    ".luarocks/**",
}

-- Globals this project defines
globals = {
    "Goblinomics",
    "GOBLINOMICS_CLIENT_BLOCKED",
    "GoblinomicsDB",
    "GoblinomicsVaultDB",
    "GoblinomicsLedgerDB",
    "GoblinomicsGathererDB",
    "GoblinomicsWorkshopDB",
    "GoblinomicsInsightsDB",
    "Goblinomics_OnAddonCompartmentClick",
    "SLASH_GOBLINOMICS1",
    "SLASH_GOBLINOMICS2",
    "BINDING_CATEGORY_GOBLINOMICS",
    "BINDING_HEADER_GOBLINOMICS",
    "BINDING_NAME_GOBLINOMICS_TOGGLE",
    "BINDING_NAME_GOBLINOMICS_FARM_HUD",
    "BINDING_NAME_GOBLINOMICS_FARM_SKIP",
    "Goblinomics_OnAddonCompartmentEnter",
    "Goblinomics_OnAddonCompartmentLeave",
    "SlashCmdList",
}

-- WoW API surface used so far; extend as luacheck complains, never dump the whole API.
read_globals = {
    -- Lua extensions provided by the client
    "strsplit", "strjoin", "strmatch", "strtrim", "strlower", "strupper", "format",
    "wipe", "tinsert", "tremove", "tContains", "CopyTable", "Mixin", "unpack",
    "time", "date", "debugprofilestop", "debugstack", "geterrorhandler", "issecretvalue", "hooksecurefunc",
    "securecall", "securecallfunction", "BreakUpLargeNumbers",
    -- Frames and UI
    "CreateFrame", "CALENDAR_WEEKDAY_NAMES", "GetCursorPosition", "CreateColor", "UIParent", "GameTooltip", "ScrollUtil",
    "CreateDataProvider", "CreateScrollBoxListLinearView",
    -- Global functions
    "GetBuildInfo", "GetLocale", "GetMoney", "GetTime", "GetServerTime", "IsLoggedIn",
    "InCombatLockdown", "UnitName", "UnitGUID", "UnitClass", "UnitFactionGroup",
    "GetNormalizedRealmName", "GetRealmName", "IsFishingLoot", "PlaySound", "SOUNDKIT",
    "UpdateAddOnMemoryUsage", "GetAddOnMemoryUsage", "GetFramerate", "ReloadUI",
    "DEFAULT_CHAT_FRAME", "UISpecialFrames", "PixelUtil", "STANDARD_TEXT_FONT", "MenuUtil",
    "MenuResponse", "Settings", "SettingsPanel", "HideUIPanel", "Minimap", "GameFontNormal",
    "CreateFont", "ScrollBoxConstants", "CreateScrollBoxLinearView",
    "ATTACHMENTS_MAX_RECEIVE", "GetInboxItem", "GetInventoryItemLink", "RAID_CLASS_COLORS",
    "GetRepairAllCost", "GetSendMailMoney", "GetSendMailPrice", "GetSendMailCOD", "GetTargetTradeMoney",
    "GetPlayerTradeMoney", "GetUnitName", "ERR_TRADE_COMPLETE", "ERR_TRADE_CANCELLED", "C_TradeInfo",
    "RepairAllItems", "TakeInboxMoney", "TakeInboxItem", "AutoLootMailItem", "SendMail", "SetTradeMoney",
    "TakeTaxiNode", "TaxiNodeCost", "TaxiNodeName", "TaxiNodeGetType", "C_QuestLog", "C_CraftingOrders",
    "AUCTION_OUTBID_MAIL_SUBJECT",
    "GetInboxHeaderInfo", "GetInboxInvoiceInfo", "GetInboxNumItems", "GetInboxItemLink",
    "GetNumLootItems", "GetLootSlotInfo", "GetLootSlotLink", "GetLootSourceInfo",
    "GetInventoryItemDurability", "RequestRaidInfo", "GetNumSavedInstances", "GetSavedInstanceInfo",
    "ChatEdit_InsertLink", "ChatFrameUtil", "HandleModifiedItemClick", "SetItemButtonQuality", "ItemButtonMixin",
    "EventRegistry", "IsModifiedClick", "C_MountJournal", "PlaySoundFile", "CreateAtlasMarkup", "ItemLocation", "UnitLevel", "GetMaxLevelForPlayerExpansion", "GetDifficultyInfo",
    "EJ_GetNumTiers", "EJ_SelectTier", "EJ_GetTierInfo", "EJ_GetCurrentTier", "EJ_GetInstanceByIndex",
    "EJ_GetEncounterInfoByIndex",
    "print",
    -- Namespaces
    "C_AddOns", "C_Timer", "C_Container", "C_Bank", "C_Item", "C_Mail",
    "C_TradeSkillUI", "C_RestrictedActions", "C_PlayerInfo", "C_AuctionHouse",
    "C_CurrencyInfo", "C_Secrets", "C_Spell", "GetServerExpansionLevel", "ProfessionsFrame", "C_ChallengeMode", "C_EventUtils", "C_AddOnProfiler", "Enum",
    "C_Map", "CreateVector2D", "GetPlayerFacing", "IsInInstance",
    -- Libraries
    "LibStub",
    -- GlobalStrings
    "LOOT_ITEM_SELF", "LOOT_ITEM_SELF_MULTIPLE", "LOOT_ITEM_PUSHED_SELF",
    "LOOT_ITEM_PUSHED_SELF_MULTIPLE", "LOOT_MONEY", "YOU_LOOT_MONEY",
    "LOOT_ITEM_BONUS_ROLL_SELF", "LOOT_ITEM_BONUS_ROLL_SELF_MULTIPLE",
    "LOOT_ITEM_CREATED_SELF", "LOOT_ITEM_CREATED_SELF_MULTIPLE",
    "GOLD_AMOUNT", "SILVER_AMOUNT", "COPPER_AMOUNT",
    "AUCTION_SOLD_MAIL_SUBJECT", "AUCTION_EXPIRED_MAIL_SUBJECT",
    "AUCTION_REMOVED_MAIL_SUBJECT", "AUCTION_WON_MAIL_SUBJECT",
    "AUCTION_INVOICE_MAIL_SUBJECT", "ARTISANS_CONSORTIUM", "RETRIEVING_DATA",
    -- Third-party addons consumed via connectors
    "TSM_API", "Auctionator", "CraftSim", "CraftSimAPI", "Journalator", "TradeSkillMasterDB", "JOURNALATOR_ARCHIVE",
    "GatherMate2",
}

files["Locales/**"] = { max_line_length = false }
-- release notes keep one bullet point per line (Core/ChangelogData.lua mirrors CHANGELOG.md)
files["Core/ChangelogData.lua"] = { max_line_length = false }

files["spec/**"] = {
    std = "+busted",
    globals = { "WoWMock", "load_addon_file", "load_core", "load_vault", "load_ledger", "load_gatherer", "load_workshop", "load_insights", "load_import", "load_link", "toc_files", "GoblinomicsTestDB" },
}
