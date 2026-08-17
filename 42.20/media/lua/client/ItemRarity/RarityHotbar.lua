if isServer() then return end

require "Hotbar/ISHotbar"
require "ItemRarity/RarityAPI"
require "ItemRarity/RarityConfig"
require "ItemRarity/RarityPresentation"

-- A deliberately additive hotbar treatment. It runs after the active hotbar
-- renderer and draws only a thin frame plus a small colour marker; it neither
-- changes slot geometry nor takes ownership of item icons, input or tooltips.
ItemRarityHotbar = ItemRarityHotbar or {}

local function drawRaritySlots(hotbar)
    if ItemRarity.refreshRegistry then ItemRarity.refreshRegistry() end
    local slotX = (hotbar.margins or 0) + 1
    local slotY = (hotbar.margins or 0) + 1
    local slotWidth = hotbar.slotWidth or 0
    local slotHeight = hotbar.slotHeight or 0

    for index, _ in pairs(hotbar.availableSlot or {}) do
        local item = hotbar.attachedItems and hotbar.attachedItems[index]
        local _, tier = ItemRarityPresentation.getItemRarity(item)
        local visual = ItemRarityPresentation.getRarityVisual(tier)
        if visual and tier ~= "COMMON" then
            local color = visual.color
            local effect = ItemRarityConfig.visualEffects and ItemRarityConfig.visualEffects[tier]
            hotbar:drawRectBorderStatic(slotX, slotY, slotWidth, slotHeight,
                effect and effect.borderAlpha or 0.70, color.r, color.g, color.b)
            -- The two-pixel marker remains visible on top of icon textures but
            -- stays away from the vanilla key number and equipped-state icon.
            hotbar:drawRect(slotX + 2, slotY + slotHeight - 4, math.max(0, slotWidth - 4), 2,
                0.95, color.r, color.g, color.b)
        end
        slotX = slotX + slotWidth + (hotbar.slotPad or 0)
    end
end

local function patchHotbar()
    if type(ISHotbar) ~= "table" or ISHotbar.ItemRarityHotbarPatched then return end
    local vanillaRender = ISHotbar.render
    if type(vanillaRender) ~= "function" then return end

    ISHotbar.render = function(self)
        local result = vanillaRender(self)
        drawRaritySlots(self)
        return result
    end
    ISHotbar.ItemRarityHotbarPatched = true
end

patchHotbar()
if Events and Events.OnGameStart then Events.OnGameStart.Add(patchHotbar) end
