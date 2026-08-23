require "ItemRarity/RarityUtils"

-- Read-only source audit for FoodUtility V1. It compares the declared
-- ScriptItem bridge against two fresh temporary instances; no candidate,
-- tier, registry entry or scan result is changed.
ItemRarityFoodStaticSourceAudit = ItemRarityFoodStaticSourceAudit or {}

local FIELDS = {
    { key="hungerChange", getter="getHungerChange", field="hungerChange" },
    { key="thirstChange", getter="getThirstChange", field="thirstChange" },
    { key="calories", getter="getCalories", field="calories" },
    { key="unhappyChange", getter="getUnhappyChange", field="unhappyChange" },
    { key="boredomChange", getter="getBoredomChange", field="boredomChange" },
    { key="stressChange", getter="getStressChange", field="stressChange" },
    { key="daysFresh", getter="getDaysFresh", field="daysFresh" },
    { key="daysTotallyRotten", getter="getDaysTotallyRotten", field="daysTotallyRotten" },
    { key="minutesToCook", getter="getMinutesToCook", field="minutesToCook" },
    { key="minutesToBurn", getter="getMinutesToBurn", field="minutesToBurn" },
    { key="useDelta", getter="getUseDelta", field="useDelta" },
    { key="foodSicknessChange", getter="getFoodSicknessChange", field="foodSicknessChange" },
    { key="dangerousUncooked", getter="isDangerousUncooked", field="dangerousUncooked" },
    { key="cookable", getter="isCookable", field="isCookable" },
}

local function value(object, descriptor)
    if not object then return nil, "MISSING" end
    local ok, method = pcall(function() return object[descriptor.getter] end)
    if ok and type(method) == "function" then
        local called, result = pcall(function() return method(object) end)
        if called and result ~= nil then return result, "GETTER" end
    end
    local fieldOk, result = pcall(function() return object[descriptor.field] end)
    if fieldOk and result ~= nil then return result, "FIELD" end
    return nil, "MISSING"
end

local function same(a, b)
    if type(a) == "number" and type(b) == "number" then return math.abs(a - b) < 0.000001 end
    return a == b
end

local function printable(v)
    if v == nil then return "N/A" end
    if type(v) == "number" then return string.format("%.6f", v) end
    return tostring(v)
end

function ItemRarityFoodStaticSourceAudit.write(results)
    if type(results) ~= "table" or not getScriptManager or not getFileWriter then return nil end
    local rows = {}
    for _, data in pairs(results) do
        if data.utilityKind == "FOOD" and data.utilityEligible and data.foodValueStatus == "MECHANICAL_VALUE_KNOWN" then
            table.insert(rows, data)
        end
    end
    table.sort(rows, function(a,b) return a.fullType < b.fullType end)
    local writer = getFileWriter("ItemRarity_FoodStaticSourceAudit.txt", true, false)
    if not writer then return nil end
    local compared, mismatched, unstable = 0, 0, 0
    local fieldMismatch, fieldMissing = {}, {}
    writer:write("Item Rarity FoodUtility V1 static-source audit (READ ONLY)\n")
    writer:write("Eligible FOOD/DRINK only. ScriptItem is the intended source; runtime rows are fresh temporary instances used only to identify bridge/default/OnCreate divergence.\n")
    writer:write("A mismatch or instance instability is diagnostic evidence only: no utility/tier/registry value is changed.\n\n")
    writer:write("fullType | group | field | scriptValue | scriptSource | runtimeA | runtimeB | matchScriptRuntime | runtimeStable\n")
    for _, data in ipairs(rows) do
        local script = getScriptManager():FindItem(data.fullType)
        local first, second
        if script then
            local okA, itemA = pcall(function() return script:InstanceItem(nil, false) end)
            local okB, itemB = pcall(function() return script:InstanceItem(nil, false) end)
            first = okA and itemA or nil
            second = okB and itemB or nil
        end
        local rowMismatch, rowUnstable = false, false
        for _, descriptor in ipairs(FIELDS) do
            local declared, declaredSource = value(script, descriptor)
            local runtimeA = value(first, descriptor)
            local runtimeB = value(second, descriptor)
            local matches = same(declared, runtimeA)
            local stable = same(runtimeA, runtimeB)
            if not matches then
                rowMismatch = true
                fieldMismatch[descriptor.key] = (fieldMismatch[descriptor.key] or 0) + 1
            end
            if not stable then rowUnstable = true end
            if declared == nil then fieldMissing[descriptor.key] = (fieldMissing[descriptor.key] or 0) + 1 end
            writer:write(string.format("%s | %s | %s | %s | %s | %s | %s | %s | %s\n",
                data.fullType, tostring(data.utilitySubgroup), descriptor.key,
                printable(declared), declaredSource, printable(runtimeA), printable(runtimeB),
                tostring(matches), tostring(stable)))
        end
        compared = compared + 1
        if rowMismatch then mismatched = mismatched + 1 end
        if rowUnstable then unstable = unstable + 1 end
    end
    local function summary(map)
        local keys = {}; for key in pairs(map) do table.insert(keys, key) end; table.sort(keys)
        local out = {}; for _, key in ipairs(keys) do table.insert(out, key .. "=" .. tostring(map[key])) end
        return #out > 0 and table.concat(out, ", ") or "none"
    end
    writer:write(string.format("\nSUMMARY | eligible=%d | rows-with-script-runtime-difference=%d | rows-with-runtime-instability=%d\n", compared, mismatched, unstable))
    writer:write("SCRIPT/RUNTIME DIFFERENCES BY FIELD | " .. summary(fieldMismatch) .. "\n")
    writer:write("SCRIPT BRIDGE MISSING BY FIELD | " .. summary(fieldMissing) .. "\n")
    writer:close()
    ItemRarityUtils.info(string.format("Food static-source audit written: %d eligible FOOD/DRINK | script/runtime differences=%d | runtime-unstable=%d.", compared, mismatched, unstable))
    return true
end
