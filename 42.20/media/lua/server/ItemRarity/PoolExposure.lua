require "ItemRarity/RarityConfig"

ItemRarityPoolExposure = ItemRarityPoolExposure or {}
ItemRarityPoolExposure.registry = {}

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function addUnique(list, set, value)
    if value and value ~= "" and not set[value] then
        set[value] = true
        table.insert(list, value)
    end
end

local function hasCondition(route)
    return route.forceForItems ~= nil or route.forceForZones ~= nil
        or route.forceForTiles ~= nil or route.forceForRooms ~= nil
end

local function selectorGroupKey(route)
    return (route.source or "unknown") .. ":" .. (route.path or "unknown")
end

local function buildRouteSummary(route, selectorTotals)
    local groupTotal = selectorTotals[selectorGroupKey(route)] or 1
    local selectorWeight = tonumber(route.weightChance) or 1
    local conditional = hasCondition(route)
    return {
        room = route.room,
        container = route.container,
        path = route.path,
        routeKind = route.routeKind or "direct",
        selectorWeight = selectorWeight,
        selectorShare = selectorWeight / groupTotal,
        min = route.min,
        max = route.max,
        forceForItems = route.forceForItems,
        forceForZones = route.forceForZones,
        forceForTiles = route.forceForTiles,
        forceForRooms = route.forceForRooms,
        conditional = conditional,
    }
end

local function collectSelectorTotals(pools)
    local totals = {}
    local seen = {}
    for _, pool in pairs(pools) do
        if pool.distributionType == "procedural" then
            for _, route in ipairs(pool.routes or {}) do
                local key = selectorGroupKey(route)
                -- items and junk are separate scanner pools but share one
                -- procedural selector. Count its candidate only once.
                local candidateKey = key .. ":" .. pool.name
                -- The Java selector defaults missing/non-positive values to 1.
                if not seen[candidateKey] then
                    totals[key] = (totals[key] or 0) + math.max(1, tonumber(route.weightChance) or 1)
                    seen[candidateKey] = true
                end
            end
        end
    end
    return totals
end

function ItemRarityPoolExposure.buildRegistry(pools)
    local selectorTotals = collectSelectorTotals(pools)
    local registry = {}
    local maxRooms, maxContainers = 1, 1

    for poolId, pool in pairs(pools) do
        local entry = {
            id = poolId,
            name = pool.name,
            section = pool.section,
            procedural = pool.distributionType == "procedural",
            referencedByRooms = {}, roomSet = {},
            referencedByContainers = {}, containerSet = {},
            selectors = {},
            conditions = {},
            routes = {},
            routeCount = 0,
            conditionalRouteCount = 0,
        }
        for _, route in ipairs(pool.routes or {}) do
            local summary = buildRouteSummary(route, selectorTotals)
            table.insert(entry.routes, summary)
            table.insert(entry.selectors, {
                path = summary.path, weightChance = summary.selectorWeight,
                selectorShare = summary.selectorShare, min = summary.min, max = summary.max,
            })
            addUnique(entry.referencedByRooms, entry.roomSet, summary.room)
            addUnique(entry.referencedByContainers, entry.containerSet, summary.container)
            entry.routeCount = entry.routeCount + 1
            if summary.conditional then
                entry.conditionalRouteCount = entry.conditionalRouteCount + 1
                table.insert(entry.conditions, summary)
            end
        end
        entry.uniqueRoomCount = #entry.referencedByRooms
        entry.uniqueContainerCount = #entry.referencedByContainers
        entry.singleRoute = entry.routeCount == 1
        entry.singleRoom = entry.uniqueRoomCount == 1
        entry.singleContainer = entry.uniqueContainerCount == 1
        entry.hasConditions = entry.conditionalRouteCount > 0
        maxRooms = math.max(maxRooms, entry.uniqueRoomCount)
        maxContainers = math.max(maxContainers, entry.uniqueContainerCount)
        registry[poolId] = entry
    end

    local config = ItemRarityConfig.poolExposure
    for _, entry in pairs(registry) do
        local routeNotReached = 1
        for _, route in ipairs(entry.routes) do
            local routeWeight = route.selectorShare
            if route.conditional then routeWeight = routeWeight * config.conditionalRouteFactor end
            routeNotReached = routeNotReached * (1 - clamp(routeWeight, 0, 1))
        end
        -- Saturating union avoids a linear 200x reward for 200 routes.
        entry.routeReachability = 1 - routeNotReached
        entry.roomCoverage = math.log(1 + entry.uniqueRoomCount) / math.log(1 + maxRooms)
        entry.containerCoverage = math.log(1 + entry.uniqueContainerCount) / math.log(1 + maxContainers)
        entry.coverage = entry.roomCoverage * config.roomCoverageWeight
            + entry.containerCoverage * config.containerCoverageWeight
        entry.poolExposure = entry.routeReachability * entry.coverage
        entry.poolExposurePercent = entry.poolExposure * 100
        pools[entry.id].exposure = entry
    end

    ItemRarityPoolExposure.registry = registry
    return registry
end
