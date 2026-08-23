require "ItemRarity/RarityUtils"

-- Read-only ContainerUtility sanity report. It consumes the already-published
-- scanner results and never calls the calculator, publisher or tier logic.
ItemRarityContainerSanityReport = ItemRarityContainerSanityReport or {}

local TARGETS = {
    "Base.Bag_Military",
    "Base.Bag_ALICEpack",
    "Base.Bag_BigHikingBag",
    "Base.Bag_NormalHikingBag",
}

local function lower(value)
    return string.lower(tostring(value or ""))
end

local function scriptString(scriptItem, getter, field)
    if not scriptItem then return nil end
    local ok, method = pcall(function() return scriptItem[getter] end)
    if ok and type(method) == "function" then
        local called, value = pcall(function() return method(scriptItem) end)
        if called and value ~= nil then return tostring(value) end
    end
    local fieldOk, value = pcall(function() return scriptItem[field] end)
    return fieldOk and value ~= nil and tostring(value) or nil
end

local function scriptItemFor(fullType)
    local manager = getScriptManager and getScriptManager() or nil
    return manager and manager:FindItem(fullType) or nil
end

local function runtimeItemFor(scriptItem)
    if not scriptItem then return nil end
    local ok, item = pcall(function() return scriptItem:InstanceItem(nil, false) end)
    return ok and item or nil
end

local function numberFrom(object, getter, field)
    if not object then return nil end
    local ok, method = pcall(function() return object[getter] end)
    if ok and type(method) == "function" then
        local called, value = pcall(function() return method(object) end)
        if called and tonumber(value) ~= nil then return tonumber(value) end
    end
    local fieldOk, value = pcall(function() return object[field] end)
    return fieldOk and tonumber(value) or nil
end

local function declaredRunSpeed(scriptItem)
    local value = numberFrom(scriptItem, "getRunSpeedModifier", "runSpeedModifier")
    if value ~= nil then return value end
    return numberFrom(runtimeItemFor(scriptItem), "getRunSpeedModifier", "runSpeedModifier")
end

local function isMilitaryAliceMatch(data)
    local script = scriptItemFor(data.fullType)
    local displayName = lower(scriptString(script, "getDisplayName", "displayName"))
    local fullType = lower(data.fullType)
    return fullType:find("military", 1, true) or fullType:find("alice", 1, true)
        or displayName:find("military", 1, true) or displayName:find("alice", 1, true)
end

local function countProfiles(results, predicate)
    local profiles = {}
    for _, data in pairs(results or {}) do
        if predicate(data) and data.utilityProfile then profiles[data.utilityProfile] = true end
    end
    local total = 0
    for _ in pairs(profiles) do total = total + 1 end
    return total
end

local function number(value)
    return value == nil and "N/A" or string.format("%.2f", tonumber(value) or 0)
end

local function percentile(data, metric)
    local values = data.utilityMetricPercentiles or {}
    return number(values[metric])
end

function ItemRarityContainerSanityReport.write(results)
    if type(results) ~= "table" or not getFileWriter then return nil end
    local backpackProfiles = countProfiles(results, function(data)
        return data.utilityKind == "CONTAINER" and data.utilitySubgroup == "BACKPACK" and data.utilityEligible
    end)
    local parentProfiles = countProfiles(results, function(data)
        return data.utilityKind == "CONTAINER" and data.utilityEligible
    end)
    local writer = getFileWriter("ItemRarity_ContainerSanity.txt", true, false)
    if not writer then return nil end

    writer:write("Item Rarity ContainerUtility sanity check (READ ONLY)\n")
    writer:write("No calculator, FinalRarityTier, registry or UI data is modified.\n")
    writer:write(string.format("BACKPACK unique mechanical profiles=%d | wearable-container parent profiles=%d\n\n", backpackProfiles, parentProfiles))
    writer:write("fullType | subgroup | normalizationGroup | subgroupProfiles | fallbackToParent | capacity raw/pctl | weightReduction raw/pctl | emptyWeight raw/pctl | runSpeedModifier raw/pctl | attachments raw/pctl | Utility | ScarcityTier | ScarcityPercentile | FinalRarityTier | reason\n")
    for _, fullType in ipairs(TARGETS) do
        local data = results[fullType]
        if not data then
            writer:write(fullType .. " | unavailable in current scanner universe\n")
        else
            local metrics = data.utilityMetrics or {}
            local script = scriptItemFor(fullType)
            local normalized = data.utilityNormalizationGroup or "N/A"
            local fallback = normalized == "CONTAINER:WEARABLE_CONTAINER" and "YES" or "NO"
            writer:write(string.format(
                "%s | %s | %s | %d | %s | %s/%s | %s/%s | %s/%s | %s/%s | %s/%s | %s | %s | %s | %s | %s\n",
                fullType, tostring(data.utilitySubgroup), normalized, backpackProfiles, fallback,
                number(metrics.capacity), percentile(data, "capacity"),
                number(metrics.weightReduction), percentile(data, "weightReduction"),
                number(metrics.emptyWeight), percentile(data, "emptyWeight"),
                number(declaredRunSpeed(script)), percentile(data, "runSpeedModifier"),
                number(metrics.attachments), percentile(data, "attachments"),
                number(data.utility), tostring(data.baseScarcityTier), number(data.scarcityPercentile),
                tostring(data.finalRarityTier), tostring(data.utilityAdjustmentReason)
            ))
        end
    end
    writer:write("\nMILITARY / ALICE FULLTYPE AUDIT\n")
    writer:write("module | fullType | DisplayName | icon | subgroup | capacity | weightReduction | emptyWeight | runSpeedModifier | attachments | occurrences | Utility | FinalRarityTier\n")
    local matches = {}
    for _, data in pairs(results) do
        if data.utilityKind == "CONTAINER" and isMilitaryAliceMatch(data) then table.insert(matches, data) end
    end
    table.sort(matches, function(a, b) return a.fullType < b.fullType end)
    for _, data in ipairs(matches) do
        local script = scriptItemFor(data.fullType)
        local metrics = data.utilityMetrics or {}
        local module = string.match(data.fullType, "^([^.]+)%.") or "UNKNOWN"
        writer:write(string.format("%s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s\n",
            module, data.fullType, tostring(scriptString(script, "getDisplayName", "displayName") or "N/A"),
            tostring(scriptString(script, "getIcon", "icon") or "N/A"), tostring(data.utilitySubgroup),
            number(metrics.capacity), number(metrics.weightReduction), number(metrics.emptyWeight),
            number(declaredRunSpeed(script)), number(metrics.attachments), tostring(data.occurrences or 0),
            number(data.utility), tostring(data.finalRarityTier)))
    end
    writer:write("\nIDENTITY CHECK FOR THE 18/65/1 PROFILE\n")
    for _, data in pairs(results) do
        local metrics = data.utilityMetrics or {}
        if data.utilityKind == "CONTAINER" and metrics.capacity == 18 and metrics.weightReduction == 65 and metrics.emptyWeight == 1 then
            local script = scriptItemFor(data.fullType)
            writer:write(string.format("%s | DisplayName=%s | icon=%s | subgroup=%s | occurrences=%s | Utility=%s | Final=%s\n",
                data.fullType, tostring(scriptString(script, "getDisplayName", "displayName") or "N/A"),
                tostring(scriptString(script, "getIcon", "icon") or "N/A"), tostring(data.utilitySubgroup),
                tostring(data.occurrences or 0), number(data.utility), tostring(data.finalRarityTier)))
        end
    end
    writer:close()
    ItemRarityUtils.info("ContainerUtility sanity report written to Zomboid/Lua/ItemRarity_ContainerSanity.txt (read-only).")
    return true
end
