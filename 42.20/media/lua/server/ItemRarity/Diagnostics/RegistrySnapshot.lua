require "ItemRarity/RarityUtils"

-- Read-only forensic snapshot. This module deliberately has no top-level
-- dependency on the scanner or calculator, so Build 42 load order cannot
-- affect normal runtime behavior.
ItemRarityRegistrySnapshot = ItemRarityRegistrySnapshot or {}

local function stableValue(value)
    if type(value) == "number" then return string.format("%.8f", value) end
    if value == nil then return "-" end
    return tostring(value):gsub("[\t\r\n]", " ")
end

local function append(row, value)
    table.insert(row, stableValue(value))
end

function ItemRarityRegistrySnapshot.write(label)
    local scanner = ItemRarityScanner
    local results = scanner and scanner.results
    if not results or not getFileWriter then
        ItemRarityUtils.info("Registry snapshot unavailable: scanner results are not ready.")
        return false
    end
    local fullTypes = {}
    for fullType in pairs(results) do table.insert(fullTypes, fullType) end
    table.sort(fullTypes)
    label = tostring(label or "CURRENT"):gsub("[^%w_%-]", "_")
    local writer = getFileWriter("ItemRarity_RegistrySnapshot_" .. label .. ".tsv", true, false)
    if not writer then return false end
    writer:write("fullType\tbaseScarcityTier\trarityTier\tfinalRarityTier\trouteWeighted\trouteWeightedPercentile\tutility\tutilityPercentile\tutilityConfidence\tutilityEligible\tutilityKind\tutilitySubgroup\tutilitySubgroupRank\tutilityParentPercentile\tutilityScoreVersion\tslotQualityPercentile\tslotQualityRank\tslotRankingConfidence\tutilityAdjustmentReason\n")
    for _, fullType in ipairs(fullTypes) do
        local data = results[fullType]
        local availability = data.tableAvailability or {}
        local row = {}
        -- First fourteen fields exactly mirror RarityScanner.buildResultSignature.
        append(row, fullType)
        append(row, data.baseScarcityTier)
        append(row, data.rarityTier)
        append(row, data.finalRarityTier)
        append(row, availability.routeWeighted)
        append(row, availability.routeWeightedPercentile)
        append(row, data.utility)
        append(row, data.utilityPercentile)
        append(row, data.utilityConfidence)
        append(row, data.utilityEligible)
        append(row, data.utilityKind)
        append(row, data.utilitySubgroup)
        append(row, data.utilitySubgroupRank)
        append(row, data.utilityParentPercentile)
        -- Extra active diagnostic fields do not feed the signature.
        append(row, data.utilityScoreVersion)
        append(row, data.slotQualityPercentile)
        append(row, data.slotQualityRank)
        append(row, data.slotRankingConfidence)
        append(row, data.utilityAdjustmentReason)
        writer:write(table.concat(row, "\t") .. "\n")
    end
    writer:close()
    ItemRarityUtils.info("Registry snapshot written: " .. #fullTypes .. " items | ItemRarity_RegistrySnapshot_" .. label .. ".tsv")
    return true
end
