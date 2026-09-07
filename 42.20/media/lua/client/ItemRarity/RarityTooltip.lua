if isServer() then return end

require "ISUI/ISToolTipInv"
require "ItemRarity/RarityAPI"
require "ItemRarity/RarityConfig"
require "ItemRarity/RarityPresentation"
require "ItemRarity/RarityUIOptions"

ItemRarityTooltip = ItemRarityTooltip or {}

local function text(key, fallback)
    if getText then
        local value = getText(key)
        if value and value ~= key then return value end
    end
    return fallback
end

local function itemToken(item)
    if not item then return nil end
    if type(item.getID) == "function" then
        local ok, id = pcall(function() return item:getID() end)
        if ok and id ~= nil then return "id:" .. tostring(id) end
    end
    if type(item.getFullType) == "function" then
        local ok, fullType = pcall(function() return item:getFullType() end)
        if ok and fullType then return "type:" .. tostring(fullType) .. "@" .. tostring(item) end
    end
    return tostring(item)
end

local function clampFooterToScreen(tooltipPanel, nativeTooltip, height)
    local screenHeight = getCore():getScreenHeight()
    local maxY = math.max(0, screenHeight - height - 1)
    if tooltipPanel:getY() > maxY then
        tooltipPanel:setY(maxY)
        nativeTooltip:setY(maxY)
    end
end

function ItemRarityTooltip.appendToInventoryTooltip(tooltipPanel)
    if not tooltipPanel or not tooltipPanel.item then return end
    if not ItemRarityConfig.showTooltip and not ItemRarityConfig.debugTooltip then return end
    local _, finalTier = ItemRarityPresentation.getItemRarity(tooltipPanel.item)
    local visual = ItemRarityPresentation.getRarityVisual(finalTier)
    local nativeTooltip = tooltipPanel.tooltip
    if not visual or not nativeTooltip then return end
    local showBorder = ItemRarityUIOptions.isEnabled("tooltipBorder")
    local showLabel = ItemRarityUIOptions.isEnabled("tooltipLabel")
    if not showBorder and not showLabel then return end

    -- The Java InventoryItem tooltip owns its title draw call. Recoloring it
    -- after the fact requires an opaque mask, which looks wrong on translucent
    -- tooltips. Keep the vanilla title intact and make rarity a readable,
    -- self-contained footer instead.
    local font = UIFont.Small
    local footerHeight = getTextManager():getFontHeight(font) + 8
    local owner = tooltipPanel.owner
    local isHotbar = owner and (owner.Type == "ISHotbar" or (owner.attachedItems and owner.availableSlot))
    if isHotbar then
        -- B42's hotbar measures an InventoryItem tooltip before some HandWeapon
        -- lines are drawn. A footer would therefore cover unknown vanilla text.
        -- Keep the non-invasive rarity border here; inventory/container keeps
        -- the full labelled footer below, where the measurement is reliable.
        if showBorder then
            ItemRarityPresentation.drawRarityBorder(tooltipPanel, finalTier, 0, 0,
                tooltipPanel:getWidth(), tooltipPanel:getHeight())
        end
        return
    end

    if not showLabel then
        if showBorder then
            ItemRarityPresentation.drawRarityBorder(tooltipPanel, finalTier, 0, 0,
                tooltipPanel:getWidth(), tooltipPanel:getHeight())
        end
        return
    end

    -- ISToolTipInv.render() has just measured and drawn the native tooltip.
    -- Use that Java-owned height as the immutable baseline, never the panel
    -- height from a prior Item Rarity render. This makes the footer safe for
    -- repeated renders, rapid item changes, and reused tooltip panels.
    local baseHeight = nativeTooltip:getHeight()
    if not baseHeight or baseHeight <= 0 then baseHeight = tooltipPanel:getHeight() end
    local token = itemToken(tooltipPanel.item)
    local state = tooltipPanel.ItemRarityFooterState
    if not state or state.itemToken ~= token
        or state.vanillaHeight ~= baseHeight or state.footerHeight ~= footerHeight then
        state = {
            itemToken = token,
            vanillaHeight = baseHeight,
            footerHeight = footerHeight,
        }
        tooltipPanel.ItemRarityFooterState = state
    end

    local footerTop = baseHeight
    local newHeight = footerTop + footerHeight
    state.appliedHeight = newHeight
    -- Do not stack height when another render path leaves the panel extended.
    if tooltipPanel:getHeight() ~= newHeight then tooltipPanel:setHeight(newHeight) end

    -- Vanilla clamps only its own measured rectangle. Re-clamp our final
    -- rectangle once, without modifying the remembered native baseline.
    clampFooterToScreen(tooltipPanel, nativeTooltip, newHeight)

    -- Opaque footer and one-pixel shadow keep the tier legible over any world
    -- background while retaining all vanilla tooltip text and spacing.
    local label = text("UI_ItemRarity_Rarity", "Rarity") .. ": " .. text(visual.translationKey, visual.label)
    tooltipPanel:drawRect(0, footerTop, tooltipPanel:getWidth(), footerHeight, 0.92, 0.02, 0.02, 0.02)
    tooltipPanel:drawRectBorder(0, footerTop, tooltipPanel:getWidth(), footerHeight, 0.22,
        visual.color.r, visual.color.g, visual.color.b)
    tooltipPanel:drawText(label, 7, footerTop + 5, 0, 0, 0, 1, font)
    tooltipPanel:drawText(label, 6, footerTop + 4, visual.color.r, visual.color.g, visual.color.b, 1, font)
    if showBorder then
        ItemRarityPresentation.drawRarityBorder(tooltipPanel, finalTier, 0, 0, tooltipPanel:getWidth(), tooltipPanel:getHeight())
    end
end

local activeRender = ISToolTipInv.render
-- Migrate a live session from the older one-bit patch marker. Its wrapper
-- already resolves appendToInventoryTooltip through this global table, so it
-- automatically uses the new idempotent implementation after reload; wrapping
-- it again here would draw the footer twice in the same frame.
if ISToolTipInv.ItemRarityTooltipPatched and not ItemRarityTooltip.renderWrapper then
    ItemRarityTooltip.renderWrapper = activeRender
end
if type(activeRender) == "function" and activeRender ~= ItemRarityTooltip.renderWrapper then
    local previousRender = activeRender
    local wrapper = function(self)
        previousRender(self)
        ItemRarityTooltip.appendToInventoryTooltip(self)
    end
    ItemRarityTooltip.renderWrapper = wrapper
    ISToolTipInv.render = wrapper
end
