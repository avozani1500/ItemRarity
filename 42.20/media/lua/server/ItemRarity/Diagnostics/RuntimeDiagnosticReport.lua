require "ItemRarity/RarityUtils"
require "ItemRarity/RarityConfig"

ItemRarityDiagnosticReport = ItemRarityDiagnosticReport or {}

local MANUAL_ITEMS = {
    "Base.Money", "Base.Screwdriver", "Base.Axe", "Base.Sledgehammer", "Base.Katana",
    "Base.M16", "Base.HollowBook_Handgun", "Base.Chainmail_SleeveFull_R",
}

local ROUTE_ANALYSIS_ITEMS = {
    "Base.Katana", "Base.Axe", "LB.Bag_LegendaryBackpack", "LK.LegendaryKatanaOrange",
    "LTW.LegendaryTacticalSword", "LTW.LegendaryTacticalSledgehammer",
}

local function add(report, used, data)
    if data and not used[data.fullType] and #report < 50 then
        used[data.fullType] = true
        table.insert(report, data)
    end
end

local function select(items, predicate, field, descending, limit, report, used)
    local selected = {}
    for _, data in pairs(items) do
        if predicate(data) and not used[data.fullType] then
            local position = #selected + 1
            for index, other in ipairs(selected) do
                local value, otherValue = data.tableAvailability[field], other.tableAvailability[field]
                if (descending and value > otherValue) or (not descending and value < otherValue)
                    or (value == otherValue and data.fullType < other.fullType) then position = index; break end
            end
            if position <= limit then
                table.insert(selected, position, data)
                if #selected > limit then table.remove(selected) end
            end
        end
    end
    for _, data in ipairs(selected) do add(report, used, data) end
end

local function logItem(data)
    local score = data.tableAvailability
    ItemRarityUtils.info("Item: " .. data.fullType)
    ItemRarityUtils.info("  module=" .. data.module .. " | category=" .. data.category .. " | loot=" .. data.lootClassification)
    ItemRarityUtils.info(string.format("  occurrences=%d | procedural=%d | static=%d | distributions=%d", data.occurrences, data.proceduralOccurrences, data.staticOccurrences, data.distributionCount))
    ItemRarityUtils.info(string.format("  weight raw total=%.3f | average=%.3f | min=%.3f | max=%.3f", data.totalWeight, data.averageWeight, data.minWeight, data.maxWeight))
    ItemRarityUtils.info("  declared rolls=" .. (#data.rollsObserved > 0 and table.concat(data.rollsObserved, ",") or "not declared"))
    ItemRarityUtils.info(string.format("  TableAvailability A(relative)=%.3f%% p%.1f | B(nominal rolls)=%.3f%% p%.1f | C(equal pools)=%.3f%% p%.1f | D(route weighted)=%.3f%% p%.1f | selected=%s",
        score.relativeWeightOnly, score.relativeWeightOnlyPercentile, score.nominalRollAware, score.nominalRollAwarePercentile,
        score.equalPoolAggregate, score.equalPoolAggregatePercentile, score.routeWeighted, score.routeWeightedPercentile, score.selectedStrategy))
    ItemRarityUtils.info(string.format("  tier=%s | OccurrenceCoverage=%.2f%% (%d/%d) | PoolCoverage=%.2f%% (%d/%d) | confidence=%s",
        tostring(data.rarityTier), data.occurrenceCoverage or 0, data.modeledOccurrences or 0, data.occurrences or 0,
        data.poolCoverage or 0, data.modeledPoolCount or 0, score.poolCount or 0, tostring(data.confidence)))
    local pools, poolLimit = {}, math.min(8, #data.distributions)
    for index = 1, poolLimit do table.insert(pools, data.distributions[index]) end
    ItemRarityUtils.info("  pools=" .. table.concat(pools, ", ") .. (#data.distributions > poolLimit and " (more omitted)" or ""))
    for index = 1, math.min(3, #data.occurrencesData) do
        local occurrence = data.occurrencesData[index]
        ItemRarityUtils.info(string.format("    #%d %s | %s | raw=%.3f | relative=%.3f%% | rolls=%s->%d | nominal=%.3f%% | routes=%d",
            index, occurrence.distribution, occurrence.section, occurrence.weight, occurrence.relativeWeight * 100,
            tostring(occurrence.rolls), occurrence.nominalRolls, occurrence.nominalAvailability * 100, occurrence.routeCount or 0))
    end
end

local function sortedKeys(map)
    local keys = {}
    for key in pairs(map) do
        local position = #keys + 1
        for index, other in ipairs(keys) do
            if tostring(key) < tostring(other) then position = index; break end
        end
        table.insert(keys, position, key)
    end
    return keys
end

local function sortItemsByName(list)
    for index = 2, #list do
        local value, position = list[index], index
        while position > 1 and list[position - 1].fullType > value.fullType do
            list[position] = list[position - 1]
            position = position - 1
        end
        list[position] = value
    end
end

local function buildTierRegistry(items)
    local registry = { categories = {}, global = {}, confidence = {} }
    for _, tier in ipairs(ItemRarityConfig.tierOrder) do registry.global[tier] = 0 end
    for _, data in pairs(items) do
        local category = registry.categories[data.category] or { total = 0, tiers = {}, itemsByTier = {} }
        if not registry.categories[data.category] then
            for _, tier in ipairs(ItemRarityConfig.tierOrder) do category.tiers[tier] = 0; category.itemsByTier[tier] = {} end
            registry.categories[data.category] = category
        end
        category.total = category.total + 1
        category.tiers[data.rarityTier] = category.tiers[data.rarityTier] + 1
        table.insert(category.itemsByTier[data.rarityTier], data)
        registry.global[data.rarityTier] = registry.global[data.rarityTier] + 1
        registry.confidence[data.confidence] = (registry.confidence[data.confidence] or 0) + 1
    end
    for _, category in pairs(registry.categories) do
        for _, tier in ipairs(ItemRarityConfig.tierOrder) do sortItemsByName(category.itemsByTier[tier]) end
    end
    return registry
end

local function logTierDistribution(registry, itemCount)
    ItemRarityUtils.info("Rarity-tier distribution by Strategy D percentile within each category:")
    for _, categoryName in ipairs(sortedKeys(registry.categories)) do
        local category = registry.categories[categoryName]
        ItemRarityUtils.info("  CATEGORY: " .. categoryName .. " | items=" .. category.total)
        for _, tier in ipairs(ItemRarityConfig.tierOrder) do
            local count = category.tiers[tier]
            ItemRarityUtils.info(string.format("    %s: %d (%.2f%%)", tier, count, count / category.total * 100))
        end
    end
    ItemRarityUtils.info("GLOBAL TIER DISTRIBUTION | items=" .. itemCount)
    for _, tier in ipairs(ItemRarityConfig.tierOrder) do
        ItemRarityUtils.info(string.format("  %s: %d (%.2f%%)", tier, registry.global[tier], registry.global[tier] / itemCount * 100))
    end
    ItemRarityUtils.info(string.format("Confidence distribution: HIGH=%d | MEDIUM=%d | LOW=%d",
        registry.confidence.HIGH or 0, registry.confidence.MEDIUM or 0, registry.confidence.LOW or 0))
end

local function writeTierDump(registry)
    if not getFileWriter then return nil end
    local writer = getFileWriter("ItemRarity_TierDump.txt", true, false)
    if not writer then return nil end
    writer:write("Item Rarity experimental tier dump\n")
    writer:write("Tiers use Strategy D percentile within functional category.\n\n")
    for _, categoryName in ipairs(sortedKeys(registry.categories)) do
        writer:write("CATEGORY: " .. categoryName .. "\n")
        local category = registry.categories[categoryName]
        for _, tier in ipairs(ItemRarityConfig.tierOrder) do
            writer:write("  " .. tier .. "\n")
            for _, data in ipairs(category.itemsByTier[tier]) do
                writer:write(string.format("    %s | D=%.6f%% | percentile=%.3f | coverage=%.2f%% | poolCoverage=%.2f%% | confidence=%s\n",
                    data.fullType, data.tableAvailability.routeWeighted, data.tableAvailability.routeWeightedPercentile,
                    data.occurrenceCoverage, data.poolCoverage, data.confidence))
            end
        end
        writer:write("\n")
    end
    writer:close()
    return "ItemRarity_TierDump.txt"
end

local function logTierLists(registry)
    local limit = 30
    for _, tier in ipairs({ "EXOTIC", "EPIC" }) do
        ItemRarityUtils.info(tier .. " items by category (console limited to " .. limit .. "; full dump written separately):")
        for _, categoryName in ipairs(sortedKeys(registry.categories)) do
            local list = registry.categories[categoryName].itemsByTier[tier]
            if #list > 0 then
                local names = {}
                for index = 1, math.min(limit, #list) do table.insert(names, list[index].fullType) end
                ItemRarityUtils.info("  " .. categoryName .. " (" .. #list .. "): " .. table.concat(names, ", ")
                    .. (#list > limit and " (more in dump)" or ""))
            end
        end
    end
end

local function logKnownItemsByCategory(items)
    local grouped = {}
    local known = {}
    for _, fullType in ipairs(MANUAL_ITEMS) do known[fullType] = true end
    for _, fullType in ipairs(ROUTE_ANALYSIS_ITEMS) do known[fullType] = true end
    for fullType in pairs(known) do
        local data = items[fullType]
        if data then
            grouped[data.category] = grouped[data.category] or {}
            grouped[data.category][data.rarityTier] = grouped[data.category][data.rarityTier] or {}
            table.insert(grouped[data.category][data.rarityTier], fullType)
        end
    end
    ItemRarityUtils.info("Known-item tier comparison, organized by calculated category/tier:")
    for _, category in ipairs(sortedKeys(grouped)) do
        ItemRarityUtils.info("  " .. category)
        for _, tier in ipairs(ItemRarityConfig.tierOrder) do
            local names = grouped[category][tier]
            if names then ItemRarityUtils.info("    " .. tier .. ": " .. table.concat(names, ", ")) end
        end
    end
end

local function logTierAnomalies(items)
    local lowExotic, commonFewRoutes, moddedCommon, boundaries = {}, {}, {}, {}
    local thresholds = { 5, 15, 35, 65 }
    for _, data in pairs(items) do
        if data.rarityTier == "EXOTIC" and data.confidence == "LOW" then table.insert(lowExotic, data) end
        if data.rarityTier == "COMMON" and (data.modeledPoolCount or 0) <= 1 then table.insert(commonFewRoutes, data) end
        if data.module ~= "Base" and string.find(string.lower(data.fullType), "legendary", 1, true) and data.rarityTier == "COMMON" then table.insert(moddedCommon, data) end
        for _, threshold in ipairs(thresholds) do
            if math.abs((data.tableAvailability.routeWeightedPercentile or 0) - threshold) <= 0.25 then
                table.insert(boundaries, { data = data, threshold = threshold })
                break
            end
        end
    end
    sortItemsByName(lowExotic); sortItemsByName(commonFewRoutes); sortItemsByName(moddedCommon)
    ItemRarityUtils.info(string.format("Tier anomalies: LOW-confidence EXOTIC=%d | COMMON with <=1 modeled pool=%d | modded 'legendary' COMMON=%d",
        #lowExotic, #commonFewRoutes, #moddedCommon))
    local function names(list, limit)
        local result = {}
        for index = 1, math.min(limit, #list) do table.insert(result, list[index].fullType) end
        return #result > 0 and table.concat(result, ", ") or "none"
    end
    ItemRarityUtils.info("  LOW-confidence EXOTIC: " .. names(lowExotic, 25))
    ItemRarityUtils.info("  COMMON with <=1 modeled pool: " .. names(commonFewRoutes, 25))
    ItemRarityUtils.info("  modded 'legendary' COMMON: " .. names(moddedCommon, 25))
    ItemRarityUtils.info("Boundary diagnostics (within 0.25 percentile point of 5/15/35/65): " .. #boundaries .. " item(s).")
    for index = 1, math.min(50, #boundaries) do
        local entry, data = boundaries[index], boundaries[index].data
        ItemRarityUtils.info(string.format("  %s | percentile=%.3f | tier=%s | boundary=%.0f | confidence=%s",
            data.fullType, data.tableAvailability.routeWeightedPercentile, data.rarityTier, entry.threshold, data.confidence))
    end
end

local function listOrNone(list)
    return list and #list > 0 and table.concat(list, ", ") or "none known"
end

local function routeConditions(route)
    local parts = {}
    if route.forceForItems then table.insert(parts, "forceForItems") end
    if route.forceForZones then table.insert(parts, "forceForZones") end
    if route.forceForTiles then table.insert(parts, "forceForTiles") end
    if route.forceForRooms then table.insert(parts, "forceForRooms") end
    return #parts > 0 and table.concat(parts, ",") or "none"
end

local function logRouteAnalysis(data)
    if not data then return end
    local score = data.tableAvailability
    local pools, seen = {}, {}
    local rooms, roomSet, containers, containerSet = {}, {}, {}, {}
    for _, occurrence in ipairs(data.occurrencesData) do
        local exposure = occurrence.poolExposureData
        if exposure then
            for _, room in ipairs(exposure.referencedByRooms) do if not roomSet[room] then roomSet[room] = true; table.insert(rooms, room) end end
            for _, container in ipairs(exposure.referencedByContainers) do if not containerSet[container] then containerSet[container] = true; table.insert(containers, container) end end
        end
        if not seen[occurrence.source] then seen[occurrence.source] = true; table.insert(pools, occurrence) end
    end
    ItemRarityUtils.info("Route analysis: " .. data.fullType)
    ItemRarityUtils.info(string.format("  occurrences=%d | pools=%d | rooms=%d (%s) | containers=%d (%s)",
        data.occurrences, #pools, #rooms, listOrNone(rooms), #containers, listOrNone(containers)))
    ItemRarityUtils.info(string.format("  score A=%.3f%% | B=%.3f%% | C=%.3f%% | D=%.3f%% | D category percentile=%.1f",
        score.relativeWeightOnly, score.nominalRollAware, score.equalPoolAggregate, score.routeWeighted, score.routeWeightedPercentile))
    for _, occurrence in ipairs(pools) do
        local exposure = occurrence.poolExposureData
        if exposure then
            ItemRarityUtils.info(string.format("  pool=%s [%s/%s] | relative=%.3f%% | raw=%.3f | rolls=%s | exposure=%.3f%% | routes=%d | rooms=%d | containers=%d | conditional=%d",
                occurrence.distribution, occurrence.distributionType, occurrence.section, occurrence.relativeWeight * 100, occurrence.weight,
                tostring(occurrence.rolls), exposure.poolExposurePercent, exposure.routeCount, exposure.uniqueRoomCount,
                exposure.uniqueContainerCount, exposure.conditionalRouteCount))
            ItemRarityUtils.info("    rooms=" .. listOrNone(exposure.referencedByRooms) .. " | containers=" .. listOrNone(exposure.referencedByContainers))
            for _, route in ipairs(exposure.routes) do
                ItemRarityUtils.info(string.format("    route room=%s container=%s | selector=%.3f share=%.3f | min=%s max=%s | conditions=%s | path=%s",
                    tostring(route.room), tostring(route.container), route.selectorWeight, route.selectorShare,
                    tostring(route.min), tostring(route.max), routeConditions(route), tostring(route.path)))
            end
        end
    end
end

local function logModdedSummary(counters)
    local modules = counters.moddedModules or {}
    local count = 0
    for _ in pairs(modules) do count = count + 1 end
    ItemRarityUtils.info(string.format("Modded loot summary: %d non-Base item types across %d module(s).", counters.moddedItemTypes or 0, count))
    for _, module in pairs(modules) do
        ItemRarityUtils.info(string.format("  module=%s | items=%d | occurrences=%d | distributions=%d | procedural=%d | static=%d | examples=%s",
            module.name, module.itemTypes, module.occurrences, #module.distributions, module.proceduralOccurrences,
            module.staticOccurrences, table.concat(module.examples, ", ")))
    end
    if count == 0 then ItemRarityUtils.info("  No non-Base ScriptItem was found in the final loot tables. This does not prove enabled mods registered no items.") end
end

local function logRouteResolution(items, counters)
    local resolution = counters.routeResolution or {}
    local classifications = resolution.classifications or {}
    ItemRarityUtils.info("Pool route resolution (final merged runtime tables):")
    ItemRarityUtils.info(string.format("  pools=%d | no direct procList route=%d | direct=%d | generic fallback=%d | special container type=%d | nested bags=%d | unresolved=%d",
        resolution.poolCount or 0, resolution.noDirectRouteCount or 0,
        classifications.DIRECT_SELECTOR or 0, classifications.GENERIC_FALLBACK or 0,
        classifications.SPECIAL_CONTAINER_TYPE or 0, classifications.NESTED_BAG_REFERENCE or 0,
        classifications.UNRESOLVED_AFTER_FINAL_MERGE or 0))

    local unresolvedExamples, unresolvedSeen = {}, {}
    for _, poolId in ipairs(counters.routeResolution and counters.routeResolution.unresolvedPoolIds or {}) do
        local pool = ItemRarityScanner and ItemRarityScanner.pools and ItemRarityScanner.pools[poolId]
        if pool and not unresolvedSeen[pool.name] and #unresolvedExamples < 20 then
            unresolvedSeen[pool.name] = true
            table.insert(unresolvedExamples, pool.name)
        end
    end
    ItemRarityUtils.info("  unresolved pool examples=" .. (#unresolvedExamples > 0 and table.concat(unresolvedExamples, ", ") or "none"))
    ItemRarityUtils.info(string.format("  unresolved entries=%d of %d (%.2f%%); named distributions=%d.",
        counters.unresolvedPoolOccurrences or 0, counters.entries or 0,
        (counters.entries or 0) > 0 and ((counters.unresolvedPoolOccurrences or 0) / counters.entries * 100) or 0,
        #(counters.unresolvedPoolNames or {})))

    local affected, affectedSet = {}, {}
    for _, data in pairs(items) do
        local unresolvedOccurrences, unresolvedPools = 0, {}
        for _, occurrence in ipairs(data.occurrencesData) do
            local pool = counters.poolRegistry and counters.poolRegistry[occurrence.source]
            local scannerPool = ItemRarityScanner and ItemRarityScanner.pools and ItemRarityScanner.pools[occurrence.source]
            local status = scannerPool and scannerPool.routeResolution and scannerPool.routeResolution.classification
            if status == "UNRESOLVED_AFTER_FINAL_MERGE" then
                unresolvedOccurrences = unresolvedOccurrences + 1
                unresolvedPools[occurrence.distribution] = true
            end
        end
        if unresolvedOccurrences > 0 then
            affectedSet[data.fullType] = { data = data, occurrences = unresolvedOccurrences, pools = unresolvedPools }
            table.insert(affected, affectedSet[data.fullType])
        end
    end
    local limit = math.min(20, #affected)
    ItemRarityUtils.info(string.format("  items with unresolved-pool occurrences=%d (showing %d; this is impact on table coverage, not world frequency).", #affected, limit))
    for index = 1, limit do
        local entry = affected[index]
        local poolNames = {}
        for name in pairs(entry.pools) do table.insert(poolNames, name) end
        ItemRarityUtils.info(string.format("    %s | unresolved occurrences=%d | A=%.3f%% B=%.3f%% C=%.3f%% D=%.3f%% | pools=%s",
            entry.data.fullType, entry.occurrences, entry.data.tableAvailability.relativeWeightOnly,
            entry.data.tableAvailability.nominalRollAware, entry.data.tableAvailability.equalPoolAggregate,
            entry.data.tableAvailability.routeWeighted, table.concat(poolNames, ", ")))
    end

    ItemRarityUtils.info("  relevant-item impact from unresolved pools:")
    local relevantSeen = {}
    for _, fullType in ipairs(MANUAL_ITEMS) do relevantSeen[fullType] = true end
    for _, fullType in ipairs(ROUTE_ANALYSIS_ITEMS) do relevantSeen[fullType] = true end
    for fullType in pairs(relevantSeen) do
        local data, unresolvedOccurrences, unresolvedNames = items[fullType], 0, {}
        if data then
            for _, occurrence in ipairs(data.occurrencesData) do
                local scannerPool = ItemRarityScanner and ItemRarityScanner.pools and ItemRarityScanner.pools[occurrence.source]
                local status = scannerPool and scannerPool.routeResolution and scannerPool.routeResolution.classification
                if status == "UNRESOLVED_AFTER_FINAL_MERGE" then
                    unresolvedOccurrences = unresolvedOccurrences + 1
                    unresolvedNames[occurrence.distribution] = true
                end
            end
            local names = {}
            for name in pairs(unresolvedNames) do table.insert(names, name) end
            ItemRarityUtils.info(string.format("    %s | unresolved occurrences=%d | unresolved pools=%s",
                fullType, unresolvedOccurrences, #names > 0 and table.concat(names, ", ") or "none"))
        end
    end
end

function ItemRarityDiagnosticReport.log(items, counters)
    local report, used = {}, {}
    for _, fullType in ipairs(MANUAL_ITEMS) do add(report, used, items[fullType]) end

    for _, fullType in ipairs(ROUTE_ANALYSIS_ITEMS) do add(report, used, items[fullType]) end

    -- Mod examples first, then explicit anomaly classes.  They supplement the
    -- fixed manual set and keep the report bounded to avoid debug-log floods.
    for _, data in pairs(items) do if data.module ~= "Base" then add(report, used, data) end end
    select(items, function(data) return data.occurrences <= 2 end, "equalPoolAggregate", true, 6, report, used)
    select(items, function(data) return data.occurrences >= 10 end, "equalPoolAggregate", false, 6, report, used)
    select(items, function(data)
        for _, occurrence in ipairs(data.occurrencesData) do if occurrence.relativeWeight >= 0.99 then return true end end
        return false
    end, "nominalRollAware", true, 5, report, used)
    select(items, function(data)
        for _, occurrence in ipairs(data.occurrencesData) do if occurrence.section == "junk" then return true end end
        return false
    end, "equalPoolAggregate", true, 5, report, used)
    select(items, function(data)
        for _, occurrence in ipairs(data.occurrencesData) do if (occurrence.nominalRolls or 0) >= 4 then return true end end
        return false
    end, "nominalRollAware", true, 5, report, used)
    select(items, function() return true end, "equalPoolAggregate", true, 50, report, used)

    logModdedSummary(counters)
    ItemRarityUtils.info(string.format("Pool exposure: %d mapped routes; %d pools without a known route.", counters.mappedRoutes or 0, counters.poolsWithoutKnownRoutes or 0))
    logRouteResolution(items, counters)
    local tierRegistry = buildTierRegistry(items)
    counters.tierRegistry = tierRegistry
    logTierDistribution(tierRegistry, counters.itemTypes or 0)
    logKnownItemsByCategory(items)
    logTierLists(tierRegistry)
    local dumpPath = writeTierDump(tierRegistry)
    if dumpPath then ItemRarityUtils.info("Full EXOTIC/EPIC tier dump written to Zomboid/Lua/" .. dumpPath) end
    logTierAnomalies(items)
    ItemRarityUtils.info("TableAvailability comparative report: " .. #report .. " items. Scores are table metrics, not world-find probabilities.")
    for _, data in ipairs(report) do logItem(data) end
    ItemRarityUtils.info("Detailed pool/route analyses for required comparisons follow.")
    for _, fullType in ipairs(ROUTE_ANALYSIS_ITEMS) do logRouteAnalysis(items[fullType]) end
end
