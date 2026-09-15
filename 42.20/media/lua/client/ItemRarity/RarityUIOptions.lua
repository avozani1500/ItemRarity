if isServer() then return end

-- Player-facing presentation preferences. These values are intentionally
-- client-only: they never participate in scanning, registry publication, or
-- FinalRarityTier calculation.
ItemRarityUIOptions = ItemRarityUIOptions or {}

local MOD_OPTIONS_ID = "ItemRarity"
local defaults = {
    colorInventoryNames = true,
    tooltipBorder = true,
    tooltipLabel = true,
    hotbarRarity = true,
    commonVanillaColor = true,
}

ItemRarityUIOptions.values = ItemRarityUIOptions.values or {}
ItemRarityUIOptions.generation = ItemRarityUIOptions.generation or 0

local function asBoolean(value, fallback)
    if value == true or value == 1 or value == "1" or value == "true" then return true end
    if value == false or value == 0 or value == "0" or value == "false" then return false end
    return fallback
end

-- B42 resolves interface strings from UI.json during boot.  This fallback is
-- also used for a live Lua reload before the translation catalogue refreshes.
-- Bytes are built explicitly so the Lua source itself remains ASCII-safe.
local function pt(bytes)
    return string.char(unpack(bytes))
end

local fallback = {
    modName = "Raridade de Itens",
    presentation = "Visuais",
    description = "Prefer" .. pt({195, 170}) .. "ncias visuais locais; n" .. pt({195, 163}) .. "o alteram loot, raridade ou tiers.",
    inventoryNames = "Colorir nomes dos itens no invent" .. pt({195, 161}) .. "rio",
    inventoryNamesTip = "Colore os nomes usando o tier de raridade.",
    tooltipBorder = "Mostrar borda de raridade nos tooltips",
    tooltipBorderTip = "Desenha uma borda colorida pela raridade.",
    tooltipLabel = "Mostrar raridade nos tooltips",
    tooltipLabelTip = "Mostra a linha de raridade no rodap" .. pt({195, 169}) .. " do tooltip.",
    hotbar = "Mostrar raridade na hotbar",
    hotbarTip = "Desenha bordas e marcadores de raridade nos slots ocupados.",
    commonVanilla = "Manter nomes COMMON na cor vanilla",
    commonVanillaTip = "Deixa nomes COMMON na cor original do jogo.",
}

local function translated(key, default)
    local value = getText and getText(key) or key
    -- getText() may return a Java-backed string in B42; compare its textual
    -- form rather than relying on Lua/Java object identity on a hot reload.
    local text = tostring(value)
    if text == key or string.sub(text, 1, 15) == "UI_ItemRarity_" then
        return default
    end
    return text
end

local function applyValue(id, value)
    local nextValue = asBoolean(value, defaults[id])
    if ItemRarityUIOptions.values[id] ~= nextValue then
        ItemRarityUIOptions.values[id] = nextValue
        ItemRarityUIOptions.generation = ItemRarityUIOptions.generation + 1
    end
end

for id, default in pairs(defaults) do
    if ItemRarityUIOptions.values[id] == nil then ItemRarityUIOptions.values[id] = default end
end

function ItemRarityUIOptions.isEnabled(id)
    -- Mod Options may finish loading after client UI scripts are required.
    -- Reading its live value here makes persisted choices effective on the
    -- first subsequent frame, independent of event registration order.
    local api = PZAPI and PZAPI.ModOptions
    local options = api and api.getOptions and api:getOptions(MOD_OPTIONS_ID)
    local option = options and options:getOption(id)
    if option and option.getValue then applyValue(id, option:getValue()) end
    local value = ItemRarityUIOptions.values[id]
    if value == nil then return defaults[id] ~= false end
    return value == true
end

function ItemRarityUIOptions.getGeneration()
    return ItemRarityUIOptions.generation
end

local function syncSavedValues()
    local api = PZAPI and PZAPI.ModOptions
    local options = api and api.getOptions and api:getOptions(MOD_OPTIONS_ID)
    if not options then return end
    for id, default in pairs(defaults) do
        local option = options:getOption(id)
        applyValue(id, option and option:getValue() or default)
    end
end

local function registerOptions()
    local api = PZAPI and PZAPI.ModOptions
    if not api or type(api.create) ~= "function" then return end

    local definitions = {
        { id = "colorInventoryNames", name = translated("UI_ItemRarity_Option_ColorInventoryNames", fallback.inventoryNames), tooltip = translated("UI_ItemRarity_Option_ColorInventoryNames_Tooltip", fallback.inventoryNamesTip) },
        { id = "tooltipBorder", name = translated("UI_ItemRarity_Option_TooltipBorder", fallback.tooltipBorder), tooltip = translated("UI_ItemRarity_Option_TooltipBorder_Tooltip", fallback.tooltipBorderTip) },
        { id = "tooltipLabel", name = translated("UI_ItemRarity_Option_TooltipLabel", fallback.tooltipLabel), tooltip = translated("UI_ItemRarity_Option_TooltipLabel_Tooltip", fallback.tooltipLabelTip) },
        { id = "hotbarRarity", name = translated("UI_ItemRarity_Option_HotbarRarity", fallback.hotbar), tooltip = translated("UI_ItemRarity_Option_HotbarRarity_Tooltip", fallback.hotbarTip) },
        { id = "commonVanillaColor", name = translated("UI_ItemRarity_Option_CommonVanillaColor", fallback.commonVanilla), tooltip = translated("UI_ItemRarity_Option_CommonVanillaColor_Tooltip", fallback.commonVanillaTip) },
    }

    local options = api:getOptions(MOD_OPTIONS_ID)
    if options then
        options.name = translated("UI_ItemRarity_ModOptions", fallback.modName)
        if options.data and options.data[1] then
            options.data[1].name = translated("UI_ItemRarity_Presentation", fallback.presentation)
        end
        if options.data and options.data[2] then
            options.data[2].text = translated("UI_ItemRarity_Presentation_Description", fallback.description)
        end
        for _, definition in ipairs(definitions) do
            local option = options:getOption(definition.id)
            if option then
                option.name = definition.name
                option.tooltip = definition.tooltip
            end
        end
        syncSavedValues()
        return
    end

    options = api:create(MOD_OPTIONS_ID, translated("UI_ItemRarity_ModOptions", fallback.modName))
    options:addTitle(translated("UI_ItemRarity_Presentation", fallback.presentation))
    options:addDescription(translated("UI_ItemRarity_Presentation_Description", fallback.description))

    for _, definition in ipairs(definitions) do
        local option = options:addTickBox(definition.id, definition.name, defaults[definition.id], definition.tooltip)
        option.onChange = function(value) applyValue(definition.id, value) end
        option.onChangeApply = function(value) applyValue(definition.id, value) end
    end

end

pcall(require, "PZAPI/ModOptions")
-- On a normal boot translations are available before this event.  A hot reload
-- gets the already-created options object immediately, without creating it
-- before the translation catalogue is ready.
if PZAPI and PZAPI.ModOptions and PZAPI.ModOptions:getOptions(MOD_OPTIONS_ID) then registerOptions() end
if Events and Events.OnGameBoot then Events.OnGameBoot.Add(registerOptions) end
if Events and Events.OnGameStart then
    Events.OnGameStart.Add(function()
        local api = PZAPI and PZAPI.ModOptions
        if not (api and api:getOptions(MOD_OPTIONS_ID)) then registerOptions() end
        api = PZAPI and PZAPI.ModOptions
        -- At GameStart every OnGameBoot registration has completed, so this
        -- read does not race other mods' ModOptions registrations.
        if api and type(api.load) == "function" then pcall(function() api:load() end) end
        syncSavedValues()
    end)
end
