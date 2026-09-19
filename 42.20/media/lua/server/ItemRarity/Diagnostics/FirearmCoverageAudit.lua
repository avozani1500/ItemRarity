-- Read-only coverage audit for the full Firearm pipeline.  Unlike the
-- published-firearm reports, this enumerates ScriptManager items as well as
-- current loot-scan rows, so valid firearms with no direct loot route can be
-- identified without changing candidates, Utility, the registry or tiers.
ItemRarityFirearmCoverageAudit = ItemRarityFirearmCoverageAudit or {}

local function call(object, method)
    if not object then return nil end
    local ok, fn = pcall(function() return object[method] end)
    if not ok or type(fn) ~= "function" then return nil end
    local called, value = pcall(function() return fn(object) end)
    return called and value or nil
end

local function indexed(object, index)
    if not object then return nil end
    local ok, fn = pcall(function() return object.get end)
    if not ok or type(fn) ~= "function" then return nil end
    local called, value = pcall(function() return fn(object, index) end)
    return called and value or nil
end

local function field(object, name)
    local ok, value = pcall(function() return object and object[name] end)
    return ok and value or nil
end

local function value(script, runtime, getters, fields)
    for _, getter in ipairs(getters or {}) do
        local result = call(runtime, getter)
        if result ~= nil then return result end
        result = call(script, getter)
        if result ~= nil then return result end
    end
    for _, name in ipairs(fields or {}) do
        local result = field(runtime, name)
        if result ~= nil then return result end
        result = field(script, name)
        if result ~= nil then return result end
    end
    return nil
end

local function number(script, runtime, getters, fields)
    return tonumber(value(script, runtime, getters, fields))
end

local function text(script, runtime, getters, fields)
    local result = value(script, runtime, getters, fields)
    return result == nil and "" or tostring(result)
end

local function boolean(script, runtime, getters, fields)
    return value(script, runtime, getters, fields) == true
end

local function lower(input) return string.lower(tostring(input or "")) end
local function contains(input, token) return string.find(lower(input), token, 1, true) ~= nil end
local function moduleOf(fullType) return string.match(tostring(fullType), "^([^.]+)%.") or "UNKNOWN" end
local function safe(input)
    if input == nil or input == "" then return "-" end
    if type(input) == "number" then return string.format("%.3f", input) end
    local cleaned = tostring(input):gsub("[\r\n|]", " ")
    return cleaned
end

local function fullTypeOf(script)
    local fullType = call(script, "getFullName") or call(script, "getFullType")
    if fullType and tostring(fullType) ~= "" then return tostring(fullType) end
    local module, name = call(script, "getModuleName") or call(script, "getModule"), call(script, "getName")
    return module and name and tostring(module) .. "." .. tostring(name) or nil
end

local function runtimeFor(script)
    if not script then return nil end
    local ok, item = pcall(function() return script:InstanceItem(nil, false) end)
    return ok and item or nil
end

local function appendCollection(out, seen, collection)
    if type(collection) == "table" then
        for _, script in pairs(collection) do
            local fullType = fullTypeOf(script)
            if fullType and not seen[fullType] then seen[fullType] = true; table.insert(out, script) end
        end
        return #out > 0
    end
    local size = tonumber(call(collection, "size") or call(collection, "getSize"))
    if not size then return false end
    for index = 0, size - 1 do
        local script = indexed(collection, index)
        local fullType = fullTypeOf(script)
        if fullType and not seen[fullType] then seen[fullType] = true; table.insert(out, script) end
    end
    -- A Java Map also has size()/get(), but integer lookup is not a portable
    -- way to enumerate it. Only claim success when this representation
    -- actually yielded ScriptItems; otherwise try the next bridge getter.
    return #out > 0
end

local function allScriptItems(manager)
    local items, seen = {}, {}
    -- Build 42 has exposed one of these collection getters across revisions.
    -- The first non-empty collection is sufficient and avoids combining a
    -- list with a map representation of the same ScriptItems.
    for _, method in ipairs({ "getAllItems", "getAllScriptItems", "getItems" }) do
        local collection = call(manager, method)
        if appendCollection(items, seen, collection) then
            return items, method
        end
    end
    return items, "UNAVAILABLE"
end

local function familyFor(fireMode, ammoType, attachmentType, maxRange)
    if lower(fireMode) == "auto" then return "AUTOMATIC_RIFLE" end
    if contains(ammoType, "shotgun") then return "SHOTGUN" end
    if contains(attachmentType, "holster") then return "HANDGUN" end
    if (maxRange or 0) >= 25 then return "RIFLE" end
    return "LONG_GUN"
end

local function firearmFacts(script)
    local runtime = runtimeFor(script)
    local scriptType = text(script, runtime, { "getType", "getItemType" }, { "type", "itemType" })
    local ammoType = text(script, runtime, { "getAmmoType" }, { "ammoType" })
    local maxAmmo = number(script, runtime, { "getMaxAmmo" }, { "maxAmmo" }) or 0
    local ranged = boolean(script, runtime, { "isRanged" }, { "ranged" })
    local weaponScript = contains(scriptType, "weapon")
    local structurallyFirearm = (ranged or weaponScript) and ammoType ~= "" and maxAmmo > 0
    local minDamage = number(script, runtime, { "getMinDamage" }, { "minDamage" })
    local maxDamage = number(script, runtime, { "getMaxDamage" }, { "maxDamage" })
    local essentials = {
        minDamage and maxDamage and (minDamage + maxDamage) / 2 or nil,
        number(script, runtime, { "getMaxRange" }, { "maxRange" }), maxAmmo,
        number(script, runtime, { "getRecoilDelay" }, { "recoilDelay" }),
        number(script, runtime, { "getAimingTime" }, { "aimingTime", "aimingtime" }),
        number(script, runtime, { "getReloadTime" }, { "reloadTime", "reloadtime" }),
        number(script, runtime, { "getActualWeight", "getWeight" }, { "actualWeight", "weight" }),
        number(script, runtime, { "getSoundRadius" }, { "soundRadius" }),
    }
    local missing = {}
    for index, label in ipairs({ "averageDamage", "maxRange", "maxAmmo", "recoilDelay", "aimingTime", "reloadTime", "weight", "soundRadius" }) do
        if essentials[index] == nil then table.insert(missing, label) end
    end
    local family = familyFor(text(script, runtime, { "getFireMode" }, { "fireMode" }), ammoType,
        text(script, runtime, { "getAttachmentType" }, { "attachmentType" }), essentials[2])
    return {
        runtime = runtime, runtimeWorks = runtime ~= nil, scriptType = scriptType, ammoType = ammoType,
        maxAmmo = maxAmmo, family = family, structurallyFirearm = structurallyFirearm,
        candidateConstructed = structurallyFirearm,
        utilityEligible = structurallyFirearm and #missing == 0,
        missing = table.concat(missing, ";"),
    }
end

local function sourceMod(script, runtime)
    return text(script, runtime, { "getModID", "getMod", "getModName", "getSourceMod" }, { "modID", "mod", "modName", "sourceMod" })
end

local function rowFor(script, results, registry)
    local fullType = fullTypeOf(script)
    local facts = firearmFacts(script)
    if not facts.structurallyFirearm then return nil end
    local data = results[fullType]
    local entry = registry[fullType]
    local category = "-"
    if ItemRarityItemClassifier and ItemRarityItemClassifier.getFunctionalCategory then
        category = select(1, ItemRarityItemClassifier.getFunctionalCategory(fullType)) or "UNKNOWN"
    end
    local hasLoot = data and (tonumber(data.occurrences) or 0) > 0
    local hasScarcity = data and data.tableAvailability and data.tableAvailability.routeWeighted ~= nil
    local hasUtility = data and data.utilityKind == "FIREARM" and data.utility ~= nil
    local hasTier = data and data.finalRarityTier ~= nil
    local reason
    if not data then
        reason = "no loot-distribution occurrence: scanner never creates a result row; candidate/Utility/registry are not invoked"
    elseif not facts.candidateConstructed then
        reason = "FirearmCandidate rejected: no ranged ammunition mechanism"
    elseif not facts.utilityEligible then
        reason = "FirearmCandidate constructed but Utility ineligible: missing " .. facts.missing
    elseif not hasScarcity then
        reason = "scan row exists but RouteWeighted scarcity is absent"
    elseif not hasUtility then
        reason = "scarcity exists but FirearmUtility did not produce a value"
    elseif not entry then
        reason = "Utility exists but RegistryPublisher has no entry"
    elseif not hasTier then
        reason = "registry/result has no FinalRarityTier"
    else
        reason = "published normally"
    end
    return {
        fullType = fullType, displayName = text(script, facts.runtime, { "getDisplayName", "getName" }, { "displayName", "name" }),
        module = moduleOf(fullType), sourceMod = sourceMod(script, facts.runtime), category = category,
        scriptType = facts.scriptType, ammoType = facts.ammoType, family = facts.family,
        scriptExists = true, runtimeWorks = facts.runtimeWorks, presentInLoot = hasLoot,
        scarcity = hasScarcity, candidate = facts.candidateConstructed, utilityEligible = facts.utilityEligible,
        utility = hasUtility, registry = entry ~= nil, finalTier = hasTier and data.finalRarityTier or nil,
        reason = reason, data = data, missing = facts.missing,
    }
end

function ItemRarityFirearmCoverageAudit.write(results)
    if type(results) ~= "table" or not getFileWriter or not getScriptManager then return nil end
    local manager = getScriptManager()
    if not manager then return nil end
    local registry = ItemRarity and type(ItemRarity.registry) == "table" and ItemRarity.registry or {}
    local scripts, enumeration = allScriptItems(manager)
    local rows, counts = {}, {
        totalScripts = #scripts, firearms = 0, candidatesAccepted = 0, candidatesRejected = 0,
        utilityEligible = 0, withLoot = 0, withoutLoot = 0, withScarcity = 0, withoutScarcity = 0,
        withUtility = 0, withoutUtility = 0, withRegistry = 0, withoutRegistry = 0,
        withTier = 0, withoutTier = 0, classified = 0,
    }
    for _, script in ipairs(scripts) do
        local row = rowFor(script, results, registry)
        if row then
            table.insert(rows, row)
            counts.firearms = counts.firearms + 1
            if row.category ~= "UNKNOWN" then counts.classified = counts.classified + 1 end
            if row.candidate then counts.candidatesAccepted = counts.candidatesAccepted + 1 else counts.candidatesRejected = counts.candidatesRejected + 1 end
            if row.utilityEligible then counts.utilityEligible = counts.utilityEligible + 1 end
            if row.presentInLoot then counts.withLoot = counts.withLoot + 1 else counts.withoutLoot = counts.withoutLoot + 1 end
            if row.scarcity then counts.withScarcity = counts.withScarcity + 1 else counts.withoutScarcity = counts.withoutScarcity + 1 end
            if row.utility then counts.withUtility = counts.withUtility + 1 else counts.withoutUtility = counts.withoutUtility + 1 end
            if row.registry then counts.withRegistry = counts.withRegistry + 1 else counts.withoutRegistry = counts.withoutRegistry + 1 end
            if row.finalTier then counts.withTier = counts.withTier + 1 else counts.withoutTier = counts.withoutTier + 1 end
        end
    end
    table.sort(rows, function(a, b) return a.fullType < b.fullType end)
    local writer = getFileWriter("ItemRarity_FirearmCoverageAudit.txt", true, false)
    if not writer then return nil end
    writer:write("Item Rarity Firearm coverage audit (READ ONLY)\n")
    writer:write("Enumerates ScriptManager firearm mechanisms and compares them with the current loot-scan, FirearmUtility and registry pipeline. It does not rescan, create a candidate, score Utility, publish a registry entry or change a tier.\n")
    writer:write("A non-loot firearm is intentionally absent from active results today: LootAnalyzer is built only from final merged loot-distribution occurrences.\n\n")
    writer:write("SCRIPT_ENUMERATION=" .. enumeration .. " | total ScriptItems=" .. counts.totalScripts .. "\n")
    writer:write(string.format("TOTAL_FIREARM_SCRIPTITEMS=%d | CLASSIFIED=%d | CANDIDATES_ACCEPTED=%d | CANDIDATES_REJECTED=%d | UTILITY_ELIGIBLE_IF_SCANNED=%d\n", counts.firearms, counts.classified, counts.candidatesAccepted, counts.candidatesRejected, counts.utilityEligible))
    writer:write(string.format("WITH_LOOT=%d | WITHOUT_LOOT=%d | WITH_SCARCITY=%d | WITHOUT_SCARCITY=%d | WITH_UTILITY=%d | WITHOUT_UTILITY=%d | WITH_REGISTRY=%d | WITHOUT_REGISTRY=%d | WITH_FINAL_TIER=%d | WITHOUT_FINAL_TIER=%d\n", counts.withLoot, counts.withoutLoot, counts.withScarcity, counts.withoutScarcity, counts.withUtility, counts.withoutUtility, counts.withRegistry, counts.withoutRegistry, counts.withTier, counts.withoutTier))
    writer:write("CANDIDATES_ACCEPTED means the same structural ranged+ammo+MaxAmmo gate as makeFirearmCandidate. UTILITY_ELIGIBLE_IF_SCANNED additionally requires all Firearm V1 confirmed fields.\n\n")
    writer:write("FIREARMS WITHOUT FINAL TIER\n")
    writer:write("fullType | displayName | module | source mod/override source | ItemType | ammo type | family | ScriptItem | runtime instance | loot distributions | scarcity entry | FirearmCandidate | FirearmUtility eligible if scanned | FirearmUtility active | registry entry | FinalRarityTier | exact skip reason\n")
    local missing = 0
    for _, row in ipairs(rows) do
        if not row.finalTier then
            missing = missing + 1
            writer:write(table.concat({ row.fullType, safe(row.displayName), row.module, safe(row.sourceMod), safe(row.scriptType), safe(row.ammoType), safe(row.family),
                "yes", row.runtimeWorks and "yes" or "no", row.presentInLoot and "yes" or "no", row.scarcity and "yes" or "no",
                row.candidate and "yes" or "no", row.utilityEligible and "yes" or ("no: " .. safe(row.missing)), row.utility and "yes" or "no",
                row.registry and "yes" or "no", safe(row.finalTier), safe(row.reason) }, " | ") .. "\n")
        end
    end
    if missing == 0 then writer:write("(none)\n") end
    writer:write("\nALL STRUCTURALLY DETECTABLE FIREARMS\n")
    writer:write("fullType | module | source mod/override source | category | family | ammo | loot | scarcity | candidate | eligible | utility | registry | tier | occurrences | reason\n")
    for _, row in ipairs(rows) do
        writer:write(table.concat({ row.fullType, row.module, safe(row.sourceMod), safe(row.category), safe(row.family), safe(row.ammoType),
            row.presentInLoot and "yes" or "no", row.scarcity and "yes" or "no", row.candidate and "yes" or "no", row.utilityEligible and "yes" or "no",
            row.utility and "yes" or "no", row.registry and "yes" or "no", safe(row.finalTier), safe(row.data and row.data.occurrences), safe(row.reason) }, " | ") .. "\n")
    end
    writer:close()
    if ItemRarityUtils and ItemRarityUtils.info then
        ItemRarityUtils.info(string.format("Firearm coverage audit written: %d ScriptManager firearms | %d without active tier.", counts.firearms, counts.withoutTier))
    end
    return true
end
