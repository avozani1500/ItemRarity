require "ItemRarity/RarityUtils"
require "ItemRarity/LootAnalyzer"
require "ItemRarity/PoolExposure"
require "ItemRarity/PoolRouteResolver"
require "ItemRarity/TableAvailabilityCalculator"
require "ItemRarity/UtilityCalculator"
require "ItemRarity/RarityRegistryPublisher"
require "ItemRarity/Diagnostics/RegistrySnapshot"

-- Observes final Lua loot tables. It never writes to loot tables or items.
ItemRarityScanner = ItemRarityScanner or {}
-- Preserve completed merge/scan state when reloadLuaFile reloads this module
-- during a live-world validation. runFullScan(force=true) still clears all
-- derived caches explicitly before rebuilding them.
ItemRarityScanner.hasScanned = ItemRarityScanner.hasScanned == true
ItemRarityScanner.rawOccurrences = ItemRarityScanner.rawOccurrences or {}
ItemRarityScanner.pools = ItemRarityScanner.pools or {}
ItemRarityScanner.proceduralRoutes = ItemRarityScanner.proceduralRoutes or {}
ItemRarityScanner.poolRegistry = ItemRarityScanner.poolRegistry or {}
ItemRarityScanner.results = ItemRarityScanner.results or {}
ItemRarityScanner.summary = ItemRarityScanner.summary or {}
ItemRarityScanner.isScanning = ItemRarityScanner.isScanning == true
ItemRarityScanner.distributionMergeReady = ItemRarityScanner.distributionMergeReady == true

local function resolveFullType(itemName)
    if type(itemName) ~= "string" or itemName == "" then return nil end
    local manager = getScriptManager and getScriptManager() or nil
    local scriptItem = manager and manager:FindItem(itemName) or nil
    if scriptItem and scriptItem.getFullName then return scriptItem:getFullName() end
    if string.find(itemName, ".", 1, true) then return itemName end
    return "Base." .. itemName
end

local function countItemPairs(items)
    local metadata = { itemCount = 0, totalWeight = 0, duplicateCount = 0, itemCounts = {} }
    if type(items) ~= "table" then return metadata end
    for index = 1, #items, 2 do
        local itemName, weight = items[index], items[index + 1]
        if type(itemName) == "string" and type(weight) == "number" then
            metadata.itemCount = metadata.itemCount + 1
            metadata.totalWeight = metadata.totalWeight + weight
            metadata.itemCounts[itemName] = (metadata.itemCounts[itemName] or 0) + 1
            if metadata.itemCounts[itemName] > 1 then metadata.duplicateCount = metadata.duplicateCount + 1 end
        end
    end
    return metadata
end

local function makeRoute(rootName, path, entry, room, container)
    local routeKind = "direct"
    if room == "all" then routeKind = "global_all_room"
    elseif container == "other" then routeKind = "room_other_fallback"
    elseif container == "all" then routeKind = "room_all_fallback" end
    return {
        source = rootName,
        path = path,
        room = room,
        container = container,
        routeKind = routeKind,
        min = entry.min,
        max = entry.max,
        weightChance = entry.weightChance,
        forceForZones = entry.forceForZones,
        forceForTiles = entry.forceForTiles,
        forceForRooms = entry.forceForRooms,
        forceForItems = entry.forceForItems,
    }
end

local function appendPath(path, key)
    if type(key) == "number" then return path .. "[" .. tostring(key) .. "]" end
    return path .. "." .. tostring(key)
end

local function collectProceduralRoutes(root, rootName, routes)
    if type(root) ~= "table" then return end
    local visited = {}
    local function visit(node, path, room, container, depth)
        if type(node) ~= "table" or visited[node] then return end
        visited[node] = true
        if node.procedural and type(node.procList) == "table" then
            for _, entry in ipairs(node.procList) do
                if type(entry) == "table" and type(entry.name) == "string" then
                    routes[entry.name] = routes[entry.name] or {}
                    table.insert(routes[entry.name], makeRoute(rootName, path, entry, room, container))
                end
            end
        end
        for key, value in pairs(node) do
            if type(value) == "table" and key ~= "items" and key ~= "junk" and key ~= "procList" then
                local nextRoom, nextContainer = room, container
                if depth == 0 and type(key) == "string" then
                    nextRoom, nextContainer = key, nil
                elseif depth == 1 and type(key) == "string" then
                    nextContainer = key
                end
                visit(value, appendPath(path, key), nextRoom, nextContainer, depth + 1)
            end
        end
    end
    visit(root, rootName, nil, nil, 0)
end

local function addPool(pools, poolId, name, distributionType, section, distribution, routes)
    local metadata = countItemPairs(distribution.items)
    local pool = {
        id = poolId,
        name = name,
        distributionType = distributionType,
        section = section,
        rolls = distribution.rolls,
        itemCount = metadata.itemCount,
        totalWeight = metadata.totalWeight,
        duplicateCount = metadata.duplicateCount,
        hasJunk = distribution.junk ~= nil,
        routes = routes or {},
    }
    pools[poolId] = pool
    return pool, metadata
end

local function addPoolOccurrences(rawOccurrences, counters, pool, metadata, distribution)
    if type(distribution.items) ~= "table" then return end
    for index = 1, #distribution.items, 2 do
        local itemName, weight = distribution.items[index], distribution.items[index + 1]
        local fullType = type(weight) == "number" and resolveFullType(itemName) or nil
        if not fullType then
            counters.malformedEntries = counters.malformedEntries + 1
        else
            local module = string.match(fullType, "^([^.]+)%.") or "UNKNOWN"
            table.insert(rawOccurrences, {
                fullType = fullType,
                module = module,
                itemName = itemName,
                distribution = pool.name,
                distributionType = pool.distributionType,
                source = pool.id,
                section = pool.section,
                weight = weight,
                poolItemCount = metadata.itemCount,
                poolTotalWeight = metadata.totalWeight,
                relativeWeight = metadata.totalWeight > 0 and weight / metadata.totalWeight or 0,
                duplicateCount = metadata.itemCounts[itemName] or 0,
                rolls = pool.rolls,
                hasJunk = pool.hasJunk,
                routeCount = #pool.routes,
                routes = pool.routes,
                poolExposure = pool.exposure and pool.exposure.poolExposure or 0,
                poolExposureData = pool.exposure,
            })
            counters.entries = counters.entries + 1
        end
    end
end

local function scanProcedural(rawOccurrences, pools, routes, counters)
    if type(ProceduralDistributions) ~= "table" or type(ProceduralDistributions.list) ~= "table" then
        ItemRarityUtils.warn("ProceduralDistributions.list is unavailable; procedural pools were skipped.")
        return
    end
    for name, distribution in pairs(ProceduralDistributions.list) do
        if type(name) == "string" and type(distribution) == "table" then
            counters.proceduralDistributions = counters.proceduralDistributions + 1
            local pool, metadata = addPool(pools, "procedural:" .. name .. ":items", name, "procedural", "items", distribution, routes[name])
            addPoolOccurrences(rawOccurrences, counters, pool, metadata, distribution)
            if type(distribution.junk) == "table" then
                local junkPool, junkMetadata = addPool(pools, "procedural:" .. name .. ":junk", name, "procedural", "junk", distribution.junk, routes[name])
                addPoolOccurrences(rawOccurrences, counters, junkPool, junkMetadata, distribution.junk)
            end
        end
    end
end

local function scanStatic(root, rootName, rawOccurrences, pools, counters)
    if type(root) ~= "table" then return end
    local visited = {}
    local function visit(node, path, room, container, depth)
        if type(node) ~= "table" or visited[node] then return end
        visited[node] = true
        if type(node.items) == "table" then
            counters.staticDistributions = counters.staticDistributions + 1
            local pool, metadata = addPool(pools, "static:" .. path .. ":items", path, "static", "items", node, { makeRoute(rootName, path, {}, room, container) })
            addPoolOccurrences(rawOccurrences, counters, pool, metadata, node)
            if type(node.junk) == "table" then
                local junkPool, junkMetadata = addPool(pools, "static:" .. path .. ":junk", path, "static", "junk", node.junk, { makeRoute(rootName, path, {}, room, container) })
                addPoolOccurrences(rawOccurrences, counters, junkPool, junkMetadata, node.junk)
            end
        end
        for key, value in pairs(node) do
            if type(value) == "table" and key ~= "items" and key ~= "junk" and key ~= "procList" then
                local nextRoom, nextContainer = room, container
                if depth == 0 and type(key) == "string" then
                    nextRoom, nextContainer = key, nil
                elseif depth == 1 and type(key) == "string" then
                    nextContainer = key
                end
                visit(value, appendPath(path, key), nextRoom, nextContainer, depth + 1)
            end
        end
    end
    visit(root, rootName, nil, nil, 0)
end

local function nowMs()
    return getTimestampMs and getTimestampMs() or 0
end

local function stableValue(value)
    if type(value) == "number" then return string.format("%.8f", value) end
    if value == nil then return "-" end
    return tostring(value)
end

-- The signature is intentionally derived only from the published scan result,
-- ordered by fullType. It is a diagnostic equivalence check; it never feeds
-- scarcity, Utility, tiering or the registry itself.
local function buildResultSignature(results)
    local fullTypes = {}
    for fullType in pairs(results) do table.insert(fullTypes, fullType) end
    table.sort(fullTypes)

    local rows = {}
    for _, fullType in ipairs(fullTypes) do
        local data = results[fullType]
        local availability = data.tableAvailability or {}
        table.insert(rows, table.concat({
            fullType,
            stableValue(data.baseScarcityTier),
            stableValue(data.rarityTier),
            stableValue(data.finalRarityTier),
            stableValue(availability.routeWeighted),
            stableValue(availability.routeWeightedPercentile),
            stableValue(data.utility),
            stableValue(data.utilityPercentile),
            stableValue(data.utilityConfidence),
            stableValue(data.utilityEligible),
            stableValue(data.utilityKind),
            stableValue(data.utilitySubgroup),
            stableValue(data.utilitySubgroupRank),
            stableValue(data.utilityParentPercentile),
        }, "\t"))
    end

    return table.concat(rows, "\n"), #fullTypes
end

local function fingerprint(signature)
    local checksumA, checksumB = 0, 0
    for index = 1, #signature do
        local byte = string.byte(signature, index)
        checksumA = (checksumA * 31 + byte) % 2147483647
        checksumB = (checksumB * 131 + byte + index) % 2147483647
    end
    return string.format("%d:%d:%d", #signature, checksumA, checksumB)
end

local function clearDerivedState()
    ItemRarityScanner.hasScanned = false
    ItemRarityScanner.rawOccurrences = {}
    ItemRarityScanner.pools = {}
    ItemRarityScanner.proceduralRoutes = {}
    ItemRarityScanner.poolRegistry = {}
    ItemRarityScanner.results = {}
    ItemRarityScanner.summary = {}
    if ItemRarityPoolExposure then ItemRarityPoolExposure.registry = {} end
end

function ItemRarityScanner.setDistributionMergeReady(source)
    ItemRarityScanner.distributionMergeReady = true
    ItemRarityScanner.distributionMergeSource = source or "OnPostDistributionMerge"
end

function ItemRarityScanner.canScanCurrentTables()
    return type(ProceduralDistributions) == "table"
        and type(ProceduralDistributions.list) == "table"
        and type(SuburbsDistributions) == "table"
end

-- Keep the live validation compact and automatic.  This intentionally reads
-- only already-published runtime values; it never contributes to the result
-- signature or changes the scoring pipeline.
local function logMechanicalValueValidation(results)
    local tierCounts = { COMMON = 0, UNCOMMON = 0, RARE = 0, EPIC = 0, EXOTIC = 0 }
    local trivialCount, changedCount = 0, 0
    local transitions = { uncommon = 0, rare = 0, epic = 0, exotic = 0 }
    local accessory = { trivial = 0, changed = 0, uncommon = 0, rare = 0, epic = 0, exotic = 0, partial = {} }

    for _, data in pairs(results) do
        local tier = data.finalRarityTier
        if tierCounts[tier] then tierCounts[tier] = tierCounts[tier] + 1 end
        if data.clothingMechanicalValueStatus == "MECHANICALLY_TRIVIAL" then
            trivialCount = trivialCount + 1
            local beforeCap = data.clothingMechanicalTierBeforeCap
            if beforeCap and beforeCap ~= tier then
                changedCount = changedCount + 1
                if beforeCap == "UNCOMMON" and tier == "COMMON" then transitions.uncommon = transitions.uncommon + 1 end
                if beforeCap == "RARE" and tier == "UNCOMMON" then transitions.rare = transitions.rare + 1 end
                if beforeCap == "EPIC" and tier == "UNCOMMON" then transitions.epic = transitions.epic + 1 end
                if beforeCap == "EXOTIC" and tier == "UNCOMMON" then transitions.exotic = transitions.exotic + 1 end
            end
        end
        if data.accessoryMechanicalValueStatus == "MECHANICALLY_TRIVIAL" then
            accessory.trivial = accessory.trivial + 1
            local beforeCap = data.accessoryMechanicalTierBeforeCap
            if beforeCap and beforeCap ~= tier then
                accessory.changed = accessory.changed + 1
                if beforeCap == "UNCOMMON" and tier == "COMMON" then accessory.uncommon = accessory.uncommon + 1 end
                if beforeCap == "RARE" and tier == "UNCOMMON" then accessory.rare = accessory.rare + 1 end
                if beforeCap == "EPIC" and tier == "UNCOMMON" then accessory.epic = accessory.epic + 1 end
                if beforeCap == "EXOTIC" and tier == "UNCOMMON" then accessory.exotic = accessory.exotic + 1 end
            end
        elseif data.accessoryMechanicalValueStatus == "MECHANICAL_VALUE_PARTIAL" then
            table.insert(accessory.partial, data.fullType)
        end
    end

    ItemRarityUtils.info(string.format(
        "Clothing MechanicalValue Policy 3 | trivial=%d | tier-changed=%d | UNCOMMON->COMMON=%d | RARE->UNCOMMON=%d | EPIC->UNCOMMON=%d | EXOTIC->UNCOMMON=%d | tiers C/U/R/E/X=%d/%d/%d/%d/%d",
        trivialCount, changedCount, transitions.uncommon, transitions.rare, transitions.epic, transitions.exotic,
        tierCounts.COMMON, tierCounts.UNCOMMON, tierCounts.RARE, tierCounts.EPIC, tierCounts.EXOTIC
    ))
    table.sort(accessory.partial)
    ItemRarityUtils.info(string.format(
        "Accessory MechanicalValue Policy 3 | trivial=%d | tier-changed=%d | UNCOMMON->COMMON=%d | RARE->UNCOMMON=%d | EPIC->UNCOMMON=%d | EXOTIC->UNCOMMON=%d | PARTIAL=%s",
        accessory.trivial, accessory.changed, accessory.uncommon, accessory.rare, accessory.epic, accessory.exotic,
        #accessory.partial > 0 and table.concat(accessory.partial, ",") or "none"
    ))

    local targets = {
        "Base.Briefs_SmallTrunks_Black", "Base.Boxers_Hearts", "Base.Jacket_NavyBlue", "Base.Jacket_Leather",
        "Base.Jacket_Fireman", "Base.Shoes_WorkBoots", "Base.Cuirass_Metal",
        "Base.Vambrace_Left", "Base.Shoulderpad_Articulated_L_Metal", "Base.HazmatSuit",
        "Base.Katana", "Base.HollowBook_Handgun",
    }
    for _, fullType in ipairs(targets) do
        local data = results[fullType]
        if data then
            ItemRarityUtils.info(string.format(
                "Validation %s | tier=%s | beforeCap=%s | MechanicalValue=%s | MechanicalStatus=%s",
                fullType, tostring(data.finalRarityTier), tostring(data.clothingMechanicalTierBeforeCap),
                tostring(data.clothingMechanicalValue), tostring(data.clothingMechanicalValueStatus)
            ))
        else
            ItemRarityUtils.warn("Validation target missing: " .. fullType)
        end
    end
    for _, fullType in ipairs({ "Base.Glasses_Normal_HornRimmed", "Base.Glasses", "Base.Tie_BowTieFull", "Base.Hat_FastFood", "Base.Hat_BaseballCap_3N", "Base.Gloves_MetalArmour", "Base.GasmaskFilter", "Base.HolsterShoulder", "Base.Oxygen_Tank", "Base.RespiratorFilters" }) do
        local data = results[fullType]
        if data then
            ItemRarityUtils.info(string.format(
                "Accessory validation %s | tier=%s | beforeCap=%s | MechanicalValue=%s | MechanicalStatus=%s",
                fullType, tostring(data.finalRarityTier), tostring(data.accessoryMechanicalTierBeforeCap),
                tostring(data.accessoryMechanicalValue), tostring(data.accessoryMechanicalValueStatus)
            ))
        end
    end
end

local function runFullScan(source, force)
    if ItemRarityScanner.isScanning then
        ItemRarityUtils.warn("Scan request ignored: a scan is already running.")
        return ItemRarityScanner.results
    end
    if not force and ItemRarityScanner.hasScanned then return ItemRarityScanner.results end
    if not ItemRarityScanner.canScanCurrentTables() then
        ItemRarityUtils.warn("Scan deferred (" .. tostring(source) .. "): final distribution tables are not ready.")
        return nil, "final distribution tables are not ready"
    end

    -- A manual scan is valid only after the first merged-table scan (or after
    -- the real merge event). This refuses a console call made too early rather
    -- than silently analyzing pre-merge vanilla data.
    if force and not ItemRarityScanner.hasScanned and not ItemRarityScanner.distributionMergeReady then
        ItemRarityUtils.warn("Manual rescan rejected: OnPostDistributionMerge has not completed yet.")
        return nil, "OnPostDistributionMerge has not completed yet"
    end

    local previousSignature = ItemRarityScanner.lastScanSignature
    local manualStarted = nowMs()
    if force then
        ItemRarityUtils.info("manual rescan started")
        clearDerivedState()
        ItemRarityUtils.info("caches cleared")
    end

    ItemRarityScanner.isScanning = true
    local scanStarted = nowMs()
    local rawOccurrences, pools, routes = {}, {}, {}
    local counters = { entries = 0, malformedEntries = 0, proceduralDistributions = 0, staticDistributions = 0 }
    collectProceduralRoutes(SuburbsDistributions, "SuburbsDistributions", routes)
    collectProceduralRoutes(VehicleDistributions, "VehicleDistributions", routes)
    local routesCollectedAt = getTimestampMs and getTimestampMs() or scanStarted
    scanProcedural(rawOccurrences, pools, routes, counters)
    scanStatic(SuburbsDistributions, "SuburbsDistributions", rawOccurrences, pools, counters)
    scanStatic(VehicleDistributions, "VehicleDistributions", rawOccurrences, pools, counters)
    local tablesScannedAt = getTimestampMs and getTimestampMs() or routesCollectedAt
    local registry = ItemRarityPoolExposure.buildRegistry(pools)
    local routeResolution = ItemRarityPoolRouteResolver.analyze(pools)
    for _, occurrence in ipairs(rawOccurrences) do
        local pool = pools[occurrence.source]
        occurrence.poolExposure = pool and pool.exposure and pool.exposure.poolExposure or 0
        occurrence.poolExposureData = pool and pool.exposure or nil
    end
    local exposureBuiltAt = getTimestampMs and getTimestampMs() or tablesScannedAt

    ItemRarityScanner.rawOccurrences = rawOccurrences
    ItemRarityScanner.pools = pools
    ItemRarityScanner.proceduralRoutes = routes
    ItemRarityScanner.poolRegistry = registry
    ItemRarityScanner.results = ItemRarityLootAnalyzer.analyze(rawOccurrences)
    ItemRarityTableAvailabilityCalculator.calculate(ItemRarityScanner.results)
    ItemRarityUtilityCalculator.calculate(ItemRarityScanner.results)
    local availabilityCalculatedAt = getTimestampMs and getTimestampMs() or exposureBuiltAt
    ItemRarityScanner.summary = counters
    ItemRarityScanner.hasScanned = true

    local vanilla, modded = 0, 0
    local modules = {}
    for _, data in pairs(ItemRarityScanner.results) do
        if data.module == "Base" then vanilla = vanilla + 1 else modded = modded + 1 end
        if data.module ~= "Base" then
            local module = modules[data.module] or { name = data.module, itemTypes = 0, occurrences = 0, proceduralOccurrences = 0, staticOccurrences = 0, distributions = {}, distributionSet = {}, examples = {} }
            module.itemTypes = module.itemTypes + 1
            module.occurrences = module.occurrences + data.occurrences
            module.proceduralOccurrences = module.proceduralOccurrences + data.proceduralOccurrences
            module.staticOccurrences = module.staticOccurrences + data.staticOccurrences
            for _, distribution in ipairs(data.distributions) do
                if not module.distributionSet[distribution] then module.distributionSet[distribution] = true; table.insert(module.distributions, distribution) end
            end
            if #module.examples < 5 then table.insert(module.examples, data.fullType) end
            modules[data.module] = module
        end
    end
    counters.itemTypes = vanilla + modded
    counters.vanillaItemTypes = vanilla
    counters.moddedItemTypes = modded
    counters.moddedModules = modules
    counters.performance = {
        routeCollectionMs = routesCollectedAt - scanStarted,
        tableScanMs = tablesScannedAt - routesCollectedAt,
        exposureAnalysisMs = exposureBuiltAt - tablesScannedAt,
        availabilityCalculationMs = availabilityCalculatedAt - exposureBuiltAt,
        totalMs = availabilityCalculatedAt - scanStarted,
    }
    counters.poolRegistry = registry
    counters.routeResolution = routeResolution
    counters.unresolvedPoolOccurrences = 0
    counters.unresolvedPoolNames = {}
    counters.unresolvedPoolNameSet = {}
    for _, occurrence in ipairs(rawOccurrences) do
        local pool = pools[occurrence.source]
        local status = pool and pool.routeResolution and pool.routeResolution.classification
        if status == "UNRESOLVED_AFTER_FINAL_MERGE" then
            counters.unresolvedPoolOccurrences = counters.unresolvedPoolOccurrences + 1
            if not counters.unresolvedPoolNameSet[pool.name] then
                counters.unresolvedPoolNameSet[pool.name] = true
                table.insert(counters.unresolvedPoolNames, pool.name)
            end
        end
    end
    counters.poolsWithoutKnownRoutes = 0
    counters.mappedRoutes = 0
    for _, poolData in pairs(registry) do
        counters.mappedRoutes = counters.mappedRoutes + poolData.routeCount
        if poolData.routeCount == 0 then counters.poolsWithoutKnownRoutes = counters.poolsWithoutKnownRoutes + 1 end
    end
    local signature, signatureItemCount = buildResultSignature(ItemRarityScanner.results)
    counters.resultSignature = fingerprint(signature)
    counters.resultSignatureItemCount = signatureItemCount
    ItemRarityScanner.lastScanSignature = signature
    ItemRarityScanner.lastScanSignatureFingerprint = counters.resultSignature
    ItemRarityUtils.info(string.format("Scan completed: %d item types (%d Base, %d modded), %d entries, %d procedural distributions, %d static distributions.", counters.itemTypes, vanilla, modded, counters.entries, counters.proceduralDistributions, counters.staticDistributions))
    ItemRarityUtils.info(string.format("Pool exposure registry: %d pools, %d mapped routes, %d pools without a known route.", (function() local n=0 for _ in pairs(registry) do n=n+1 end return n end)(), counters.mappedRoutes, counters.poolsWithoutKnownRoutes))
    ItemRarityUtils.info(string.format("Performance: route collection=%dms | table scan=%dms | exposure=%dms | availability=%dms | total=%dms.",
        counters.performance.routeCollectionMs, counters.performance.tableScanMs, counters.performance.exposureAnalysisMs,
        counters.performance.availabilityCalculationMs, counters.performance.totalMs))
    if counters.malformedEntries > 0 then ItemRarityUtils.warn("Skipped " .. counters.malformedEntries .. " malformed item/weight pairs.") end
    ItemRarityRegistryPublisher.publish(ItemRarityScanner.results)
    ItemRarityUtils.info("registry republished")
    if force then logMechanicalValueValidation(ItemRarityScanner.results) end
    if ItemRarityConfig.devReportsEnabled then
        require "ItemRarity/Diagnostics/RuntimeDiagnosticReport"
        ItemRarityUtilityCalculator.writeReports(ItemRarityScanner.results)
        ItemRarityDiagnosticReport.log(ItemRarityScanner.results, counters)
    else
        ItemRarityUtils.info("Development reports disabled; set ItemRarityConfig.devReportsEnabled=true to generate diagnostics.")
    end
    ItemRarityScanner.isScanning = false
    if force then
        local sameAsPrevious = previousSignature ~= nil and previousSignature == signature
        ItemRarityUtils.info(string.format("manual rescan scan completed - %d items", counters.itemTypes))
        ItemRarityUtils.info("manual rescan deterministic comparison: " .. (sameAsPrevious and "MATCH" or "CHANGED")
            .. " | signature=" .. counters.resultSignature)
        ItemRarityUtils.info(string.format("manual rescan completed in %d ms", nowMs() - manualStarted))
    end
    return ItemRarityScanner.results
end

-- Both automatic startup scanning and console-triggered rescans use the exact
-- same full pipeline above. `force` is the only difference: it invalidates the
-- previous derived scanner state before reading the already-merged runtime data.
function ItemRarityScanner.scan(source)
    return runFullScan(source or "automatic", false)
end

function ItemRarityScanner.rescan(source)
    local results = runFullScan(source or "manual", true)
    -- Temporary forensic capture for baseline-regression investigation. The
    -- writer is read-only and runs after the completed pipeline/signature.
    if ItemRarityRegistrySnapshot and ItemRarityRegistrySnapshot.write then
        ItemRarityRegistrySnapshot.write("CURRENT")
    end
    return results
end
