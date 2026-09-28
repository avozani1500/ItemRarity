require "ItemRarity/RarityAPI"
require "ItemRarity/RarityUtils"
require "ItemRarity/UtilityIsolation"

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
        source = data.source or "LOOT",
        scarcityState = data.scarcityState or "KNOWN",
        hasLootRoute = data.hasLootRoute ~= false,
        routeWeighted = data.routeWeighted or score.routeWeighted,
        clothingMechanicalValue = data.clothingMechanicalValue,
        clothingMechanicalValueStatus = data.clothingMechanicalValueStatus,
        clothingMechanicalBaseBenefit = data.clothingMechanicalBaseBenefit,
        clothingMechanicalDurabilityFactor = data.clothingMechanicalDurabilityFactor,
        clothingMechanicalFunctionalCost = data.clothingMechanicalFunctionalCost,
        clothingMechanicalSpecialReason = data.clothingMechanicalSpecialReason,
        clothingMechanicalTierBeforeCap = data.clothingMechanicalTierBeforeCap,
        accessoryMechanicalValue = data.accessoryMechanicalValue,
        accessoryMechanicalValueStatus = data.accessoryMechanicalValueStatus,
        accessoryMechanicalBaseBenefit = data.accessoryMechanicalBaseBenefit,
        accessoryMechanicalDurabilityFactor = data.accessoryMechanicalDurabilityFactor,
        accessoryMechanicalFunctionalCost = data.accessoryMechanicalFunctionalCost,
        accessoryMechanicalSpecialReason = data.accessoryMechanicalSpecialReason,
        accessoryMechanicalTierBeforeCap = data.accessoryMechanicalTierBeforeCap,
        medicalValueStatus = data.medicalValueStatus,
        medicalDominantEffect = data.medicalDominantEffect,
        medicalUses = data.medicalUses,
        medicalDeclared = data.medicalDeclared,
        medicalProcedure = data.medicalProcedure,
        medicalUnpackRecipe = data.medicalUnpackRecipe,
        medicalOnEat = data.medicalOnEat,
        foodValueStatus = data.foodValueStatus,
        foodPartialReason = data.foodPartialReason,
        foodQuality = data.foodQuality,
        foodQualityPercentile = data.foodQualityPercentile,
        foodUtilityConfidence = data.foodUtilityConfidence,
        foodRankingConfidence = data.foodRankingConfidence,
        foodScarcityStrength = data.foodScarcityStrength,
        foodFinalScore = data.foodFinalScore,
        fishExpectedWeight = data.fishExpectedWeight,
        fishExpectedHunger = data.fishExpectedHunger,
        fishExpectedCalories = data.fishExpectedCalories,
        fishExpectedFoodYield = data.fishExpectedFoodYield,
        catchDifficulty = data.catchDifficulty,
        fishingScarcity = data.fishingScarcity,
        fishYieldTierCeiling = data.fishYieldTierCeiling,
        fishPositionTier = data.fishPositionTier,
        percentile = score.percentileWithinCategory,
        scarcityPercentile = score.percentileWithinCategory,
        tableAvailability = score.routeWeighted,
        confidence = data.confidence,
        occurrenceCoverage = data.occurrenceCoverage,
        poolCoverage = data.poolCoverage,
    }
end

function ItemRarityRegistryPublisher.publish(results)
    assert(type(results)=="table", "Registry results must be a table")
    assert(type(ItemRarity.setRegistry)=="function", "Registry sink unavailable")
    local I=ItemRarityUtilityIsolation
    local tiers={COMMON=1,UNCOMMON=2,RARE=3,EPIC=4,EXOTIC=5}
    local publication={published=0,isolated=0}
    ItemRarityRegistryPublisher.lastIsolationReport=publication
    local function serializable(value,seen)
        local kind=type(value)
        if kind=='nil' or kind=='string' or kind=='boolean' then return end
        if kind=='number' then assert(I.finite(value),'Nonfinite registry value');return end
        assert(kind=='table','Nonserializable registry value: '..kind)
        assert(not seen[value],'Cyclic registry value');seen[value]=true
        for key,child in pairs(value) do
            assert(type(key)=='string' or (type(key)=='number' and I.finite(key)),'Invalid registry field key')
            serializable(child,seen)
        end
        seen[value]=nil
    end

    local entries, count = {}, 0
    local summary = { profiles = {}, eligible = 0, promoted = 0, promotedProfiles = {}, demoted = 0 }
    for fullType, data in pairs(results) do
        local owner={data={fullType=type(fullType)=='string' and fullType or '<invalid registry key>'},kind='REGISTRY',metrics={row=data,rowType=type(data)}}
        local ok,prepared=I.run(owner,'Registry:Row',function()
            assert(type(fullType)=='string' and fullType~='', 'Invalid registry key')
            assert(type(data)=='table' and data.fullType==fullType,'Registry row identity mismatch')
            assert(data.tableAvailability==nil or type(data.tableAvailability)=='table','Invalid availability record')
            local entry=copyEntry(data)
            assert(type(entry.finalRarityTier)=='string' and tiers[entry.finalRarityTier], 'Missing/invalid final tier')
            assert(entry.baseScarcityTier==nil or tiers[entry.baseScarcityTier], 'Invalid base tier')
            for _,field in ipairs({'utility','utilityPercentile','percentile','scarcityPercentile','clothingMechanicalValue','accessoryMechanicalValue','foodQuality','foodFinalScore','fishExpectedFoodYield'}) do
                assert(entry[field]==nil or I.finite(entry[field]),'Invalid numeric registry field: '..field)
            end
            assert(data.utilityEligible==nil or type(data.utilityEligible)=='boolean','Invalid eligibility')
            assert(data.utilityProfile==nil or type(data.utilityProfile)=='string','Invalid profile')
            assert(data.utilityKind==nil or type(data.utilityKind)=='string','Invalid Utility kind')
            if entry.source=='UTILITY_ONLY' then
                assert(entry.scarcityState=='UNKNOWN' and entry.hasLootRoute==false and entry.routeWeighted=='SKIPPED','Invalid utility-only provenance')
                assert(entry.baseScarcityTier==nil and entry.scarcityPercentile==nil,'Invented utility-only scarcity')
            end
            serializable(entry,{})
            return entry
        end)
        if ok then
        entries[fullType] = prepared
        count = count + 1
        if data.utilityEligible then summary.eligible = summary.eligible + 1 end
        if data.utilityEligible and data.utilityProfile then summary.profiles[(data.utilityKind or "UNKNOWN") .. ":" .. data.utilityProfile] = true end
        -- Utility-only entries deliberately have no base Scarcity tier. They
        -- are not promotions/demotions of loot rows and must not be counted as
        -- though a synthetic COMMON tier existed.
        if data.rarityTier ~= nil and data.finalRarityTier ~= data.rarityTier then
            local finalIndex = ({ COMMON = 1, UNCOMMON = 2, RARE = 3, EPIC = 4, EXOTIC = 5 })[data.finalRarityTier] or 0
            local baseIndex = ({ COMMON = 1, UNCOMMON = 2, RARE = 3, EPIC = 4, EXOTIC = 5 })[data.rarityTier] or 0
            if finalIndex > baseIndex then
                summary.promoted = summary.promoted + 1
                if data.utilityProfile then summary.promotedProfiles[(data.utilityKind or "UNKNOWN") .. ":" .. data.utilityProfile] = true end
            elseif finalIndex < baseIndex then summary.demoted = summary.demoted + 1 end
        end
        else publication.isolated=publication.isolated+1 end
    end
    publication.published=count
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
    ItemRarityUtils.info(string.format("Registry ready | items=%d | mechanical profiles=%d | Utility eligible=%d | promoted items=%d | promoted profiles=%d | demoted items=%d.",
        count, countSet(summary.profiles), summary.eligible, summary.promoted, countSet(summary.promotedProfiles), summary.demoted))
    return entries, revision
end
