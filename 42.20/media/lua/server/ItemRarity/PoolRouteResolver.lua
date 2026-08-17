-- Classifies how a procedural pool is reached after the final B42 loot merge.
-- This is structural only: it identifies Java-supported mechanisms, but never
-- estimates how often their parent item appears in the map.
ItemRarityPoolRouteResolver = ItemRarityPoolRouteResolver or {}

local function addUnique(list, set, value)
    if value and value ~= "" and not set[value] then
        set[value] = true
        table.insert(list, value)
    end
end

-- In B42's Kahlua bridge the Java THashMap returned by
-- getItemPickerContainers() cannot be indexed or called from Lua.  The same
-- registration is observable safely in the merged root: ParseSuburbsDistributions
-- registers every top-level table with `rolls` under that item's type.
local function isRegisteredContainerType(name)
    local distribution = type(SuburbsDistributions) == "table" and SuburbsDistributions[name] or nil
    return type(distribution) == "table" and distribution.rolls ~= nil
end

local function collectNestedBagTargets(root, namedTables, targets, visited)
    if type(root) ~= "table" or visited[root] then return end
    visited[root] = true
    if type(root.bags) == "table" then
        local names = namedTables[root.bags]
        if names then
            for _, name in ipairs(names) do targets[name] = true end
        end
    end
    for key, value in pairs(root) do
        if key ~= "items" and key ~= "junk" and key ~= "procList" then
            collectNestedBagTargets(value, namedTables, targets, visited)
        end
    end
end

local function routeKindSummary(routes)
    local kinds, seen = {}, {}
    for _, route in ipairs(routes or {}) do
        addUnique(kinds, seen, route.routeKind or "direct")
    end
    return kinds
end

local function hasDirectRoute(kinds)
    for _, kind in ipairs(kinds) do
        if kind == "direct" then return true end
    end
    return false
end

function ItemRarityPoolRouteResolver.analyze(pools)
    local namedTables, nestedBagTargets = {}, {}
    if type(ProceduralDistributions) == "table" and type(ProceduralDistributions.list) == "table" then
        for name, distribution in pairs(ProceduralDistributions.list) do
            if type(name) == "string" and type(distribution) == "table" then
                namedTables[distribution] = namedTables[distribution] or {}
                table.insert(namedTables[distribution], name)
            end
        end
        local visited = {}
        collectNestedBagTargets(ProceduralDistributions.list, namedTables, nestedBagTargets, visited)
        collectNestedBagTargets(SuburbsDistributions, namedTables, nestedBagTargets, visited)
        collectNestedBagTargets(VehicleDistributions, namedTables, nestedBagTargets, visited)
    end

    local summary = {
        poolCount = 0,
        noDirectRouteCount = 0,
        classifications = {},
        unresolvedPoolIds = {},
        nestedBagTargets = nestedBagTargets,
    }

    for poolId, pool in pairs(pools) do
        local routeKinds = routeKindSummary(pool.routes)
        local classification, detail
        if #routeKinds > 0 then
            if hasDirectRoute(routeKinds) then
                classification = "DIRECT_SELECTOR"
            else
                classification = "GENERIC_FALLBACK"
            end
            detail = table.concat(routeKinds, ",")
        elseif pool.distributionType ~= "procedural" then
            classification = "STATIC_OR_NESTED_TABLE"
            detail = "static table has no procedural selector"
        elseif isRegisteredContainerType(pool.name) then
            classification = "SPECIAL_CONTAINER_TYPE"
            detail = "registered in ItemPickerJava containers by item type"
        elseif nestedBagTargets[pool.name] then
            classification = "NESTED_BAG_REFERENCE"
            detail = "referenced through a bags table"
        else
            classification = "UNRESOLVED_AFTER_FINAL_MERGE"
            detail = "no procList route, container-type registration, or bags reference found"
            table.insert(summary.unresolvedPoolIds, poolId)
        end

        pool.routeResolution = {
            classification = classification,
            detail = detail,
            routeKinds = routeKinds,
            directRouteCount = #pool.routes,
        }
        summary.poolCount = summary.poolCount + 1
        summary.classifications[classification] = (summary.classifications[classification] or 0) + 1
        if #routeKinds == 0 then summary.noDirectRouteCount = summary.noDirectRouteCount + 1 end
    end
    return summary
end
