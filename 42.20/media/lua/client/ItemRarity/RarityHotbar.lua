if isServer() then return end

require "Hotbar/ISHotbar"
require "ItemRarity/RarityAPI"
require "ItemRarity/RarityConfig"
require "ItemRarity/RarityPresentation"
require "ItemRarity/RarityUIOptions"

-- A deliberately additive hotbar treatment. It runs after the active hotbar
-- renderer and draws only a thin frame plus a small colour marker; it neither
-- changes slot geometry nor takes ownership of item icons, input or tooltips.
ItemRarityHotbar = ItemRarityHotbar or {}

local function cleanHotbarLayout(hotbar)
    -- Clean HotBar owns a different slot layout: it reserves a leading
    -- show/hide button, scales slot dimensions, and may omit empty slots.
    -- Its public config object is the opt-in signal; do not require it.
    if type(CHBConfig) ~= "table" or type(CHBConfig.getConfig) ~= "function" then return nil end
    local ok, config = pcall(CHBConfig.getConfig)
    if not ok or type(config) ~= "table" then return nil end

    local slotWidth = hotbar.slotWidth or 0
    local slotHeight = hotbar.slotHeight or 0
    if slotWidth <= 0 or slotHeight <= 0 then return nil end
    local margins, slotPad = hotbar.margins or 0, hotbar.slotPad or 0
    local toggleButtonSize = math.floor(slotWidth / 3)
    return {
        slotX = margins + 1 + toggleButtonSize + slotPad,
        slotY = margins + 1,
        slotWidth = slotWidth,
        slotHeight = slotHeight,
        slotPad = slotPad,
        hideEmptySlots = config.showEmptySlots == false,
        cleanHotbar = true,
    }
end

local function vanillaHotbarLayout(hotbar)
    return {
        slotX = (hotbar.margins or 0) + 1,
        slotY = (hotbar.margins or 0) + 1,
        slotWidth = hotbar.slotWidth or 0,
        slotHeight = hotbar.slotHeight or 0,
        slotPad = hotbar.slotPad or 0,
        hideEmptySlots = false,
    }
end

local function drawRaritySlots(hotbar)
    if not ItemRarityUIOptions.isEnabled("hotbarRarity") then return end
    if ItemRarity.refreshRegistry then ItemRarity.refreshRegistry() end
    local layout = cleanHotbarLayout(hotbar) or vanillaHotbarLayout(hotbar)
    local slotX, slotY = layout.slotX, layout.slotY
    local slotWidth, slotHeight, slotPad = layout.slotWidth, layout.slotHeight, layout.slotPad

    for index, _ in pairs(hotbar.availableSlot or {}) do
        local item = hotbar.attachedItems and hotbar.attachedItems[index]
        local visible = not (layout.hideEmptySlots and not item)
        if visible then
            local _, tier = ItemRarityPresentation.getItemRarity(item)
            local visual = ItemRarityPresentation.getRarityVisual(tier)
            if visual and tier ~= "COMMON" then
                local color = visual.color
                local effect = ItemRarityConfig.visualEffects and ItemRarityConfig.visualEffects[tier]
                hotbar:drawRectBorderStatic(slotX, slotY, slotWidth, slotHeight,
                    effect and effect.borderAlpha or 0.70, color.r, color.g, color.b)
                -- Clean Hot Bar puts the slot number at the lower edge. Keep
                -- its marker tiny and at the upper-left corner instead; the
                -- vanilla fallback preserves the existing lower marker.
                local markerY = layout.cleanHotbar and (slotY + 2) or (slotY + slotHeight - 4)
                local markerWidth = layout.cleanHotbar and math.min(6, slotWidth - 4) or (slotWidth - 4)
                hotbar:drawRect(slotX + 2, markerY, math.max(0, markerWidth), 2,
                    0.95, color.r, color.g, color.b)
            end
            slotX = slotX + slotWidth + slotPad
        end
    end
end

-- Keep the current drawer on the public table so a hot reload can preserve a
-- live wrapper while still using this version's rendering logic.
ItemRarityHotbar.drawRaritySlots = drawRaritySlots

local function patchHotbar()
    if type(ISHotbar) ~= "table" then return end
    local activeRender = ISHotbar.render
    if type(activeRender) ~= "function" then return end

    -- Another UI mod may replace ISHotbar.render after this file has loaded.
    -- Identity, rather than a permanent boolean, tells us whether our wrapper
    -- survived. Capturing the current renderer keeps the other mod in charge.
    if activeRender == ItemRarityHotbar.renderWrapper then return end
    local previousRender = activeRender
    local wrapper = function(self)
        local result = previousRender(self)
        if ItemRarityHotbar.drawRaritySlots then ItemRarityHotbar.drawRaritySlots(self) end
        return result
    end

    ItemRarityHotbar.previousRender = previousRender
    ItemRarityHotbar.renderWrapper = wrapper
    ISHotbar.render = wrapper
end

patchHotbar()
if Events and Events.OnGameStart then Events.OnGameStart.Add(patchHotbar) end
