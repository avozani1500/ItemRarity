require "ItemRarity/RarityConfig"

ItemRarityTiers = ItemRarityTiers or {}

-- Percentile direction is intentional: 0 is the least available item in its
-- category and maps to EXOTIC; 100 is the most available and maps to COMMON.
function ItemRarityTiers.getRarityTier(percentile)
    local value = tonumber(percentile)
    if not value then return nil end
    for _, tierName in ipairs(ItemRarityConfig.tierOrder) do
        local tier = ItemRarityConfig.tiers[tierName]
        if tier and value >= tier.min then
            if (tier.maxExclusive and value < tier.max) or (not tier.maxExclusive and value <= tier.max) then
                return tierName
            end
        end
    end
    return value < 0 and ItemRarityConfig.tierOrder[1] or ItemRarityConfig.tierOrder[#ItemRarityConfig.tierOrder]
end

function ItemRarityTiers.getConfidence(coverage)
    local value = tonumber(coverage) or 0
    local limits = ItemRarityConfig.routeCoverageConfidence
    if value >= limits.highMinimum then return "HIGH" end
    if value >= limits.mediumMinimum then return "MEDIUM" end
    return "LOW"
end
