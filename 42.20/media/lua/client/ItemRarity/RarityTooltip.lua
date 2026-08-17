if isServer() then return end

require "ISUI/ISToolTipInv"
require "ItemRarity/RarityAPI"
require "ItemRarity/RarityConfig"
require "ItemRarity/RarityPresentation"

ItemRarityTooltip = ItemRarityTooltip or {}

local function text(key, fallback)
    if getText then
        local value = getText(key)
        if value and value ~= key then return value end
    end
    return fallback
end

function ItemRarityTooltip.appendToInventoryTooltip(tooltipPanel)
    if not tooltipPanel or not tooltipPanel.item then return end
    if not ItemRarityConfig.showTooltip and not ItemRarityConfig.debugTooltip then return end
    local _, finalTier = ItemRarityPresentation.getItemRarity(tooltipPanel.item)
    local visual = ItemRarityPresentation.getRarityVisual(finalTier)
    local nativeTooltip = tooltipPanel.tooltip
    if not visual or not nativeTooltip then return end

    -- The Java InventoryItem tooltip owns its title draw call. Recoloring it
    -- after the fact requires an opaque mask, which looks wrong on translucent
    -- tooltips. Keep the vanilla title intact and make rarity a readable,
    -- self-contained footer instead.
    local baseHeight = nativeTooltip:getHeight()
    local font = UIFont.Small
    local footerHeight = getTextManager():getFontHeight(font) + 8
    local owner = tooltipPanel.owner
    local isHotbar = owner and (owner.Type == "ISHotbar" or (owner.attachedItems and owner.availableSlot))
    if isHotbar then
        -- B42's hotbar measures an InventoryItem tooltip before some HandWeapon
        -- lines are drawn. A footer would therefore cover unknown vanilla text.
        -- Keep the non-invasive rarity border here; inventory/container keeps
        -- the full labelled footer below, where the measurement is reliable.
        ItemRarityPresentation.drawRarityBorder(tooltipPanel, finalTier, 0, 0,
            tooltipPanel:getWidth(), tooltipPanel:getHeight())
        return
    end

    local footerTop = baseHeight
    local newHeight = footerTop + footerHeight
    local label = text("UI_ItemRarity_Rarity", "Rarity") .. ": " .. text(visual.translationKey, visual.label)
    tooltipPanel:setHeight(newHeight)

    -- ISToolTipInv clamps the vanilla height before our native rarity row is
    -- appended. Re-clamp after extending it so belt/back-slot tooltips do not
    -- lose the final row below the bottom of the screen.
    local screenHeight = getCore():getScreenHeight()
    local bottom = tooltipPanel:getY() + newHeight
    if bottom > screenHeight - 1 then
        local y = math.max(0, screenHeight - newHeight - 1)
        tooltipPanel:setY(y)
        nativeTooltip:setY(y)
    end

    -- Opaque footer and one-pixel shadow keep the tier legible over any world
    -- background while retaining all vanilla tooltip text and spacing.
    tooltipPanel:drawRect(0, footerTop, tooltipPanel:getWidth(), footerHeight, 0.92, 0.02, 0.02, 0.02)
    tooltipPanel:drawRectBorder(0, footerTop, tooltipPanel:getWidth(), footerHeight, 0.22,
        visual.color.r, visual.color.g, visual.color.b)
    tooltipPanel:drawText(label, 7, footerTop + 5, 0, 0, 0, 1, font)
    tooltipPanel:drawText(label, 6, footerTop + 4, visual.color.r, visual.color.g, visual.color.b, 1, font)
    ItemRarityPresentation.drawRarityBorder(tooltipPanel, finalTier, 0, 0, tooltipPanel:getWidth(), tooltipPanel:getHeight())
end

if not ISToolTipInv.ItemRarityTooltipPatched then
    local vanillaRender = ISToolTipInv.render
    function ISToolTipInv:render()
        vanillaRender(self)
        ItemRarityTooltip.appendToInventoryTooltip(self)
    end
    ISToolTipInv.ItemRarityTooltipPatched = true
end
