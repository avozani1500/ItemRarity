require "ItemRarity/RarityConfig"
require "ItemRarity/RarityTiers"

ItemRarityTableAvailabilityCalculator = ItemRarityTableAvailabilityCalculator or {}

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

-- The game applies floor(declaredRolls * Sandbox RollsMultiplier), with a
-- minimum of one.  This table metric intentionally uses neutral multiplier 1;
-- live Sandbox, loot-type and zombie-density adjustments are contextual and
-- therefore excluded from TableAvailabilityScore.
local function declaredEffectiveRolls(rolls)
    return math.max(1, math.floor(tonumber(rolls) or 0))
end

local function chanceAtLeastOnce(singleRollChance, rolls)
    local chance = clamp(singleRollChance, 0, 1)
    return 1 - math.pow(1 - chance, declaredEffectiveRolls(rolls))
end

local function mergeSort(list, field)
    local count = #list
    local buffer = {}
    local width = 1
    while width < count do
        local start = 1
        while start <= count do
            local middle = math.min(start + width, count + 1)
            local finish = math.min(start + width + width, count + 1)
            local left, right, destination = start, middle, start
            while left < middle and right < finish do
                local a, b = list[left], list[right]
                if a.tableAvailability[field] < b.tableAvailability[field]
                    or (a.tableAvailability[field] == b.tableAvailability[field] and a.fullType <= b.fullType) then
                    buffer[destination] = a
                    left = left + 1
                else
                    buffer[destination] = b
                    right = right + 1
                end
                destination = destination + 1
            end
            while left < middle do buffer[destination] = list[left]; left = left + 1; destination = destination + 1 end
            while right < finish do buffer[destination] = list[right]; right = right + 1; destination = destination + 1 end
            start = start + width + width
        end
        for index = 1, count do list[index] = buffer[index] end
        width = width * 2
    end
end

local function assignCategoryPercentiles(results, field, percentileField)
    local categories = {}
    for _, data in pairs(results) do
        categories[data.category] = categories[data.category] or {}
        table.insert(categories[data.category], data)
    end
    for _, categoryItems in pairs(categories) do
        mergeSort(categoryItems, field)
        local count, index = #categoryItems, 1
        while index <= count do
            local first, score = index, categoryItems[index].tableAvailability[field]
            while index < count and categoryItems[index + 1].tableAvailability[field] == score do index = index + 1 end
            local percentile = count == 1 and 100 or ((first + index - 2) / (2 * (count - 1))) * 100
            for tieIndex = first, index do categoryItems[tieIndex].tableAvailability[percentileField] = percentile end
            index = index + 1
        end
    end
end

function ItemRarityTableAvailabilityCalculator.calculate(results)
    -- Production scans retain only the RouteWeighted/D inputs and percentile.
    -- A/B/C are comparative diagnostics, so calculating their aggregates and
    -- category percentiles here used to spend three extra sort passes on every
    -- normal scan even when reports were disabled.
    for _, data in pairs(results) do
        local routeWeightedNotFound = 1
        local byPool = {}
        local modeledOccurrences = 0
        for _, occurrence in ipairs(data.occurrencesData) do
            -- ItemPickerJava compares Rand.Next(10000) with chance * 100 in
            -- the neutral, non-contextual case: raw table weight / 100.
            local nominal = chanceAtLeastOnce((occurrence.weight or 0) / 100, occurrence.rolls)
            local poolState = byPool[occurrence.source]
            if not poolState then
                poolState = { notFound = 1, exposure = occurrence.poolExposure or 0 }
                byPool[occurrence.source] = poolState
            end
            poolState.notFound = poolState.notFound * (1 - nominal)
            local pool = ItemRarityScanner and ItemRarityScanner.pools and ItemRarityScanner.pools[occurrence.source]
            local resolution = pool and pool.routeResolution and pool.routeResolution.classification
            occurrence.hasModeledRoute = resolution ~= nil and resolution ~= "UNRESOLVED_AFTER_FINAL_MERGE"
            if occurrence.hasModeledRoute then modeledOccurrences = modeledOccurrences + 1 end
        end

        local poolCount, modeledPoolCount = 0, 0
        for source, poolState in pairs(byPool) do
            poolCount = poolCount + 1
            routeWeightedNotFound = routeWeightedNotFound * (1 - ((1 - poolState.notFound) * poolState.exposure))
            local pool = ItemRarityScanner and ItemRarityScanner.pools and ItemRarityScanner.pools[source]
            local resolution = pool and pool.routeResolution and pool.routeResolution.classification
            if resolution ~= nil and resolution ~= "UNRESOLVED_AFTER_FINAL_MERGE" then modeledPoolCount = modeledPoolCount + 1 end
        end

        data.tableAvailability = {
            -- D: B availability discounted by normalized route/pool exposure.
            -- It remains a table approximation: room/container population and
            -- runtime conditions are deliberately not world-frequency inputs.
            routeWeighted = (1 - routeWeightedNotFound) * 100,
            poolCount = poolCount,
            selectedStrategy = ItemRarityConfig.tableAvailabilityStrategy,
        }
        data.occurrenceCoverage = (modeledOccurrences / math.max(1, data.occurrences)) * 100
        data.poolCoverage = (modeledPoolCount / math.max(1, poolCount)) * 100
        data.modeledOccurrences = modeledOccurrences
        data.modeledPoolCount = modeledPoolCount
        data.confidence = ItemRarityTiers.getConfidence(data.occurrenceCoverage)
    end

    assignCategoryPercentiles(results, "routeWeighted", "routeWeightedPercentile")
    for _, data in pairs(results) do
        local percentile = data.tableAvailability.routeWeightedPercentile
        data.rarityTier = ItemRarityTiers.getRarityTier(percentile)
        data.tableAvailability.rarityTier = data.rarityTier
        data.tableAvailability.percentileWithinCategory = percentile
    end
    return results
end

-- A/B/C are intentionally computed only for an explicit development report.
-- This function is read-only with respect to the active D tier fields.
function ItemRarityTableAvailabilityCalculator.calculateDiagnosticStrategies(results)
    for _, data in pairs(results) do
        local relativeTotal, nominalTotal, poolCombined = 0, 0, 1
        local byPool = {}
        for _, occurrence in ipairs(data.occurrencesData) do
            local relative = clamp(occurrence.relativeWeight or 0, 0, 1)
            local nominal = chanceAtLeastOnce((occurrence.weight or 0) / 100, occurrence.rolls)
            occurrence.nominalRolls = declaredEffectiveRolls(occurrence.rolls)
            occurrence.nominalAvailability = nominal
            relativeTotal = relativeTotal + relative
            nominalTotal = nominalTotal + nominal
            local poolState = byPool[occurrence.source]
            if not poolState then
                poolState = { notFound = 1 }
                byPool[occurrence.source] = poolState
            end
            poolState.notFound = poolState.notFound * (1 - nominal)
        end
        for _, poolState in pairs(byPool) do poolCombined = poolCombined * poolState.notFound end

        local availability = data.tableAvailability or {}
        availability.relativeWeightOnly = (relativeTotal / math.max(1, data.occurrences)) * 100
        availability.nominalRollAware = (nominalTotal / math.max(1, data.occurrences)) * 100
        availability.equalPoolAggregate = (1 - poolCombined) * 100
        data.tableAvailability = availability
    end
    assignCategoryPercentiles(results, "relativeWeightOnly", "relativeWeightOnlyPercentile")
    assignCategoryPercentiles(results, "nominalRollAware", "nominalRollAwarePercentile")
    assignCategoryPercentiles(results, "equalPoolAggregate", "equalPoolAggregatePercentile")
    return results
end
