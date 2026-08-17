if isServer() then return end

require "ItemRarity/RarityAPI"
require "ItemRarity/RarityConfig"

-- Presentation-only helpers. UI callers resolve fullType through the
-- published registry and never infer, calculate, or alter a rarity tier.
ItemRarityPresentation = ItemRarityPresentation or {}

function ItemRarityPresentation.getRarityVisual(tier)
    return tier and ItemRarity.getVisual(tier) or nil
end

function ItemRarityPresentation.getItemRarity(item)
    local rarity = ItemRarity.get(item)
    if not rarity then return nil, nil end
    return rarity, rarity.finalRarityTier or rarity.tier
end

function ItemRarityPresentation.getRarityColor(tier)
    local visual = ItemRarityPresentation.getRarityVisual(tier)
    return visual and visual.color or nil
end

function ItemRarityPresentation.drawRarityBorder(panel, tier, x, y, width, height)
    if not panel or tier == "COMMON" then return end
    local color = ItemRarityPresentation.getRarityColor(tier)
    if not color or not panel.drawRectBorder then return end
    x, y, width, height = x or 0, y or 0, width or panel:getWidth(), height or panel:getHeight()
    local effect = ItemRarityConfig.visualEffects and ItemRarityConfig.visualEffects[tier]
    if effect and effect.glowAlpha then
        panel:drawRectBorder(x + 1, y + 1, width - 2, height - 2, effect.glowAlpha, color.r, color.g, color.b)
    end
    panel:drawRectBorder(x, y, width, height, effect and effect.borderAlpha or 0.70, color.r, color.g, color.b)
end

function ItemRarityPresentation.drawRarityLabel(panel, tier, x, y, font)
    local visual = ItemRarityPresentation.getRarityVisual(tier)
    if not panel or not visual or not panel.drawText then return end
    local label = getText and getText("UI_ItemRarity_Rarity") or "Rarity"
    if not label or label == "UI_ItemRarity_Rarity" then label = "Rarity" end
    local tierLabel = getText and getText(visual.translationKey) or visual.label
    if not tierLabel or tierLabel == visual.translationKey then tierLabel = visual.label end
    panel:drawText(label .. ": " .. tierLabel, x or 6, y or 4, visual.color.r, visual.color.g, visual.color.b, visual.color.a, font or UIFont.Small)
end
