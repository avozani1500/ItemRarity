require "ItemRarity/RarityAPI"
require "ItemRarity/RarityUtils"

ItemRarityRegistryPublisher = ItemRarityRegistryPublisher or {}

local function copyEntry(data)
    local score = data.tableAvailability or {}
    return {
        fullType = data.fullType,
        category = data.category,
        -- The visual tier is server-calculated FinalRarityTier. Base scarcity
        -- remains public for diagnostics, never for client-side recalculation.
        tier = data.finalRarityTier or data.rarityTier,
        baseScarcityTier = data.baseScarcityTier or data.rarityTier,
        finalRarityTier = data.finalRarityTier or data.rarityTier,
        utility = data.utility,
        utilityPercentile = data.utilityPercentile,
        utilityScoreVersion = data.utilityScoreVersion,
        utilityConfidence = data.utilityConfidence,
        utilityEligible = data.utilityEligible,
        utilitySupport = data.utilitySupport,
        utilitySubgroup = data.utilitySubgroup,
        utilitySubgroupRank = data.utilitySubgroupRank,
        utilitySubgroupSize = data.utilitySubgroupSize,
        utilityParentPercentile = data.utilityParentPercentile,
        utilitySampleClass = data.utilitySampleClass,
        utilityAdjustmentReason = data.utilityAdjustmentReason,
        percentile = score.percentileWithinCategory,
        scarcityPercentile = score.percentileWithinCategory,
        tableAvailability = score.routeWeighted,
        confidence = data.confidence,
        occurrenceCoverage = data.occurrenceCoverage,
        poolCoverage = data.poolCoverage,
    }
end

function ItemRarityRegistryPublisher.publish(results)
    if type(results) ~= "table" then return nil end

    local entries, count = {}, 0
    local summary = { profiles = {}, eligible = 0, promoted = 0, promotedProfiles = {}, demoted = 0 }
    for fullType, data in pairs(results) do
        entries[fullType] = copyEntry(data)
        count = count + 1
        if data.utilityEligible then summary.eligible = summary.eligible + 1 end
        if data.utilityEligible and data.utilityProfile then summary.profiles[(data.utilityKind or "UNKNOWN") .. ":" .. data.utilityProfile] = true end
        if data.finalRarityTier ~= data.rarityTier then
            local finalIndex = ({ COMMON = 1, UNCOMMON = 2, RARE = 3, EPIC = 4, EXOTIC = 5 })[data.finalRarityTier] or 0
            local baseIndex = ({ COMMON = 1, UNCOMMON = 2, RARE = 3, EPIC = 4, EXOTIC = 5 })[data.rarityTier] or 0
            if finalIndex > baseIndex then
                summary.promoted = summary.promoted + 1
                if data.utilityProfile then summary.promotedProfiles[(data.utilityKind or "UNKNOWN") .. ":" .. data.utilityProfile] = true end
            elseif finalIndex < baseIndex then summary.demoted = summary.demoted + 1 end
        end
    end
    local function countSet(set) local total = 0; for _ in pairs(set) do total = total + 1 end; return total end

    -- The server owns the registry. ModData makes the same compact lookup
    -- available to a local singleplayer client without re-running the scan.
    local revision = nil
    if ModData and ModData.getOrCreate then
        local data = ModData.getOrCreate(ItemRarityConfig.registryModDataKey)
        revision = (tonumber(data.revision) or 0) + 1
        for key in pairs(data) do data[key] = nil end
        data.schemaVersion = 2
        data.revision = revision
        data.entries = entries
        data.itemCount = count
        if ModData.transmit then ModData.transmit(ItemRarityConfig.registryModDataKey) end
    end

    ItemRarity.setRegistry(entries)
    ItemRarityRegistryPublisher.lastPublishedRevision = revision
    ItemRarityUtils.info(string.format("Registry ready | items=%d | mechanical profiles=%d | Utility eligible=%d | promoted items=%d | promoted profiles=%d | demoted items=%d.",
        count, countSet(summary.profiles), summary.eligible, summary.promoted, countSet(summary.promotedProfiles), summary.demoted))
    return entries, revision
end
