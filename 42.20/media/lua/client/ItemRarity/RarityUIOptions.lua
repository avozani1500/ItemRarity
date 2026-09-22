if isServer() then return end

-- Client-only presentation preferences. Values here never participate in a
-- scan, registry publication or FinalRarityTier calculation.
ItemRarityUIOptions = ItemRarityUIOptions or {}

local MOD_OPTIONS_ID = "ItemRarity"
local PRESET_DEFAULT, PRESET_COLORBLIND, PRESET_HIGH_CONTRAST, PRESET_CUSTOM = 1, 2, 3, 4
local booleanDefaults = {
    colorInventoryNames = true,
    tooltipBorder = true,
    tooltipLabel = true,
    hotbarRarity = true,
    commonVanillaColor = true,
}
local numberDefaults = { colorPreset = PRESET_DEFAULT, borderOpacity = 100 }
local colorDefaults = {
    customCommon = { r = 0.90, g = 0.90, b = 0.90, a = 1.00 },
    customUncommon = { r = 0.38, g = 0.82, b = 0.38, a = 1.00 },
    customRare = { r = 0.36, g = 0.60, b = 1.00, a = 1.00 },
    customEpic = { r = 0.72, g = 0.42, b = 0.94, a = 1.00 },
    customExotic = { r = 1.00, g = 0.66, b = 0.20, a = 1.00 },
}
local customColorKey = {
    COMMON = "customCommon", UNCOMMON = "customUncommon", RARE = "customRare",
    EPIC = "customEpic", EXOTIC = "customExotic",
}
local customColorOrder = { "COMMON", "UNCOMMON", "RARE", "EPIC", "EXOTIC" }
local presetColors = {
    [PRESET_COLORBLIND] = {
        COMMON = colorDefaults.customCommon,
        UNCOMMON = { r = 0.00, g = 0.62, b = 0.45, a = 1.00 },
        RARE = { r = 0.00, g = 0.45, b = 0.70, a = 1.00 },
        EPIC = { r = 0.80, g = 0.47, b = 0.65, a = 1.00 },
        EXOTIC = { r = 0.90, g = 0.62, b = 0.00, a = 1.00 },
    },
    [PRESET_HIGH_CONTRAST] = {
        COMMON = colorDefaults.customCommon,
        UNCOMMON = { r = 0.20, g = 1.00, b = 0.20, a = 1.00 },
        RARE = { r = 0.25, g = 0.65, b = 1.00, a = 1.00 },
        EPIC = { r = 1.00, g = 0.30, b = 1.00, a = 1.00 },
        EXOTIC = { r = 1.00, g = 0.78, b = 0.05, a = 1.00 },
    },
}

ItemRarityUIOptions.values = ItemRarityUIOptions.values or {}
ItemRarityUIOptions.generation = ItemRarityUIOptions.generation or 0
ItemRarityUIOptions.visualCache = ItemRarityUIOptions.visualCache or { generation = -1, values = {} }

local function clamp(value, low, high)
    value = tonumber(value) or low
    return math.max(low, math.min(high, value))
end

local function copyColor(color)
    color = type(color) == "table" and color or {}
    return { r = clamp(color.r, 0, 1), g = clamp(color.g, 0, 1), b = clamp(color.b, 0, 1), a = clamp(color.a == nil and 1 or color.a, 0, 1) }
end

local function sameColor(left, right)
    return type(left) == "table" and type(right) == "table"
        and left.r == right.r and left.g == right.g and left.b == right.b and left.a == right.a
end

local function asBoolean(value, fallback)
    if value == true or value == 1 or value == "1" or value == "true" then return true end
    if value == false or value == 0 or value == "0" or value == "false" then return false end
    return fallback
end

local function pt(bytes) return string.char(unpack(bytes)) end
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
    themeTitle = "Cores e contraste",
    preset = "Preset de cores",
    presetTip = "Escolhe uma paleta visual local para os tiers publicados.",
    defaultPreset = "Padr" .. pt({195, 163}) .. "o",
    colorblindPreset = "Dalt" .. pt({195, 195}) .. "nico",
    contrastPreset = "Alto contraste",
    customPreset = "Personalizado",
    customTitle = "Cores personalizadas",
    borderOpacity = "Opacidade da borda",
    borderOpacityTip = "Escala a opacidade das bordas de raridade de 25% a 100%.",
    customCommon = "Cor COMMON", customUncommon = "Cor UNCOMMON", customRare = "Cor RARE",
    customEpic = "Cor EPIC", customExotic = "Cor EXOTIC",
}

local function translated(key, default)
    local value = getText and getText(key) or key
    local result = tostring(value)
    if result == key or string.sub(result, 1, 15) == "UI_ItemRarity_" then return default end
    return result
end

local function changed()
    ItemRarityUIOptions.generation = ItemRarityUIOptions.generation + 1
    ItemRarityUIOptions.visualCache = { generation = -1, values = {} }
end

local refreshCustomControls

local function applyValue(id, value)
    local previous, nextValue
    if booleanDefaults[id] ~= nil then
        previous, nextValue = ItemRarityUIOptions.values[id], asBoolean(value, booleanDefaults[id])
        if previous ~= nextValue then ItemRarityUIOptions.values[id] = nextValue; changed() end
        return
    end
    if id == "colorPreset" then
        previous, nextValue = ItemRarityUIOptions.values[id], math.floor(clamp(value, PRESET_DEFAULT, PRESET_CUSTOM))
        if previous ~= nextValue then
            ItemRarityUIOptions.values[id] = nextValue
            changed()
            if refreshCustomControls then refreshCustomControls() end
        end
        return
    end
    if id == "borderOpacity" then
        previous, nextValue = ItemRarityUIOptions.values[id], clamp(value, 25, 100)
        if previous ~= nextValue then ItemRarityUIOptions.values[id] = nextValue; changed() end
        return
    end
    if colorDefaults[id] then
        previous, nextValue = ItemRarityUIOptions.values[id], copyColor(value or colorDefaults[id])
        if not sameColor(previous, nextValue) then ItemRarityUIOptions.values[id] = nextValue; changed() end
    end
end

for id, default in pairs(booleanDefaults) do if ItemRarityUIOptions.values[id] == nil then ItemRarityUIOptions.values[id] = default end end
for id, default in pairs(numberDefaults) do if ItemRarityUIOptions.values[id] == nil then ItemRarityUIOptions.values[id] = default end end
for id, default in pairs(colorDefaults) do if ItemRarityUIOptions.values[id] == nil then ItemRarityUIOptions.values[id] = copyColor(default) end end

local function optionFor(id)
    local api = PZAPI and PZAPI.ModOptions
    local options = api and api.getOptions and api:getOptions(MOD_OPTIONS_ID)
    return options and options:getOption(id) or nil
end

local function syncOption(id)
    local option = optionFor(id)
    if option and option.getValue then applyValue(id, option:getValue()) end
end

function ItemRarityUIOptions.isEnabled(id)
    syncOption(id)
    local value = ItemRarityUIOptions.values[id]
    return value == nil and booleanDefaults[id] ~= false or value == true
end

function ItemRarityUIOptions.getGeneration() return ItemRarityUIOptions.generation end

function ItemRarityUIOptions.getVisual(tier, baseVisual)
    if not tier or not baseVisual then return nil end
    local cache = ItemRarityUIOptions.visualCache
    if cache.generation ~= ItemRarityUIOptions.generation then
        cache.generation, cache.values = ItemRarityUIOptions.generation, {}
    end
    if cache.values[tier] then return cache.values[tier] end
    local preset = ItemRarityUIOptions.values.colorPreset or PRESET_DEFAULT
    local color = baseVisual.color
    if preset == PRESET_CUSTOM then
        color = ItemRarityUIOptions.values[customColorKey[tier]] or color
    elseif presetColors[preset] and presetColors[preset][tier] then
        color = presetColors[preset][tier]
    end
    local visual = { label = baseVisual.label, translationKey = baseVisual.translationKey, color = copyColor(color) }
    cache.values[tier] = visual
    return visual
end

function ItemRarityUIOptions.getBorderAlpha(defaultAlpha)
    local scale = clamp(ItemRarityUIOptions.values.borderOpacity or numberDefaults.borderOpacity, 25, 100) / 100
    return clamp((tonumber(defaultAlpha) or 0.70) * scale, 0, 1)
end

local function syncSavedValues()
    for id in pairs(booleanDefaults) do syncOption(id) end
    for id in pairs(numberDefaults) do syncOption(id) end
    for id in pairs(colorDefaults) do syncOption(id) end
end

local function setOptionMetadata(option, name, tooltip)
    if not option then return end
    option.name, option.tooltip = name, tooltip
end

refreshCustomControls = function()
    local enabled = (ItemRarityUIOptions.values.colorPreset or PRESET_DEFAULT) == PRESET_CUSTOM
    for _, tier in ipairs(customColorOrder) do
        local option = optionFor(customColorKey[tier])
        if option and option.setEnabled then option:setEnabled(enabled) end
    end
end

local function registerOptions()
    local api = PZAPI and PZAPI.ModOptions
    if not api or type(api.create) ~= "function" then return end
    local options = api:getOptions(MOD_OPTIONS_ID)
    local existing = options ~= nil
    if not options then options = api:create(MOD_OPTIONS_ID, translated("UI_ItemRarity_ModOptions", fallback.modName)) end
    options.name = translated("UI_ItemRarity_ModOptions", fallback.modName)

    local function addTick(id, key, tipKey, label, tip)
        local option = options:getOption(id)
        if not option then option = options:addTickBox(id, translated(key, label), booleanDefaults[id], translated(tipKey, tip)) end
        setOptionMetadata(option, translated(key, label), translated(tipKey, tip))
        option.onChange = function(value) applyValue(id, value) end
        option.onChangeApply = function(value) applyValue(id, value) end
    end

    if not existing then
        options:addTitle(translated("UI_ItemRarity_Presentation", fallback.presentation))
        options:addDescription(translated("UI_ItemRarity_Presentation_Description", fallback.description))
    end
    addTick("colorInventoryNames", "UI_ItemRarity_Option_ColorInventoryNames", "UI_ItemRarity_Option_ColorInventoryNames_Tooltip", fallback.inventoryNames, fallback.inventoryNamesTip)
    addTick("tooltipBorder", "UI_ItemRarity_Option_TooltipBorder", "UI_ItemRarity_Option_TooltipBorder_Tooltip", fallback.tooltipBorder, fallback.tooltipBorderTip)
    addTick("tooltipLabel", "UI_ItemRarity_Option_TooltipLabel", "UI_ItemRarity_Option_TooltipLabel_Tooltip", fallback.tooltipLabel, fallback.tooltipLabelTip)
    addTick("hotbarRarity", "UI_ItemRarity_Option_HotbarRarity", "UI_ItemRarity_Option_HotbarRarity_Tooltip", fallback.hotbar, fallback.hotbarTip)
    addTick("commonVanillaColor", "UI_ItemRarity_Option_CommonVanillaColor", "UI_ItemRarity_Option_CommonVanillaColor_Tooltip", fallback.commonVanilla, fallback.commonVanillaTip)

    local preset = options:getOption("colorPreset")
    if not preset then
        options:addSeparator()
        options:addTitle(translated("UI_ItemRarity_Theme", fallback.themeTitle))
        preset = options:addComboBox("colorPreset", translated("UI_ItemRarity_Option_ColorPreset", fallback.preset), translated("UI_ItemRarity_Option_ColorPreset_Tooltip", fallback.presetTip))
        preset:addItem("UI_ItemRarity_Preset_Default", true)
        preset:addItem("UI_ItemRarity_Preset_Colorblind", false)
        preset:addItem("UI_ItemRarity_Preset_HighContrast", false)
        preset:addItem("UI_ItemRarity_Preset_Custom", false)
    end
    local opacity = options:getOption("borderOpacity")
    if not opacity then
        opacity = options:addSlider("borderOpacity", translated("UI_ItemRarity_Option_BorderOpacity", fallback.borderOpacity), 25, 100, 5, numberDefaults.borderOpacity, translated("UI_ItemRarity_Option_BorderOpacity_Tooltip", fallback.borderOpacityTip))
    end
    setOptionMetadata(opacity, translated("UI_ItemRarity_Option_BorderOpacity", fallback.borderOpacity), translated("UI_ItemRarity_Option_BorderOpacity_Tooltip", fallback.borderOpacityTip))
    opacity.onChange = function(value) applyValue("borderOpacity", value) end
    opacity.onChangeApply = function(value) applyValue("borderOpacity", value) end
    if not options:getOption("customCommon") then
        options:addTitle(translated("UI_ItemRarity_CustomColors", fallback.customTitle))
        for _, tier in ipairs(customColorOrder) do
            local id = customColorKey[tier]
            local color = colorDefaults[id]
            local option = options:addColorPicker(id, translated("UI_ItemRarity_Option_" .. id:sub(1, 1):upper() .. id:sub(2), fallback[id]), color.r, color.g, color.b, color.a,
                translated("UI_ItemRarity_Option_" .. id:sub(1, 1):upper() .. id:sub(2) .. "_Tooltip", fallback.customTitle))
            option.onChange = function(value) applyValue(id, value) end
            option.onChangeApply = function(value) applyValue(id, value) end
        end
    end
    for _, tier in ipairs(customColorOrder) do
        local id = customColorKey[tier]
        local option = options:getOption(id)
        if option then
            setOptionMetadata(option, translated("UI_ItemRarity_Option_" .. id:sub(1, 1):upper() .. id:sub(2), fallback[id]), fallback.customTitle)
            option.onChange = function(value) applyValue(id, value) end
            option.onChangeApply = function(value) applyValue(id, value) end
        end
    end
    setOptionMetadata(preset, translated("UI_ItemRarity_Option_ColorPreset", fallback.preset), translated("UI_ItemRarity_Option_ColorPreset_Tooltip", fallback.presetTip))
    preset.onChange = function(value) applyValue("colorPreset", value) end
    preset.onChangeApply = function(value) applyValue("colorPreset", value) end
    syncSavedValues()
    refreshCustomControls()
end

pcall(require, "PZAPI/ModOptions")
if PZAPI and PZAPI.ModOptions and PZAPI.ModOptions:getOptions(MOD_OPTIONS_ID) then registerOptions() end
if Events and Events.OnGameBoot then Events.OnGameBoot.Add(registerOptions) end
if Events and Events.OnGameStart then
    Events.OnGameStart.Add(function()
        local api = PZAPI and PZAPI.ModOptions
        if not (api and api:getOptions(MOD_OPTIONS_ID)) then registerOptions() end
        api = PZAPI and PZAPI.ModOptions
        if api and type(api.load) == "function" then pcall(function() api:load() end) end
        syncSavedValues()
    end)
end
