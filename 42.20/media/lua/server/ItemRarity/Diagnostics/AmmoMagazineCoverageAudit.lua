-- Explicit, read-only coverage report for ammunition, magazines and the
-- magazine-shaped WeaponPart scripts that B42/mod bridges expose.  The report
-- builds a temporary shadow table only; it never invokes the loot scanner,
-- RouteWeighted, registry publisher or UI transport.
ItemRarityAmmoMagazineCoverageAudit = ItemRarityAmmoMagazineCoverageAudit or {}

local function call(object, method)
    if not object then return nil end
    local ok, fn = pcall(function() return object[method] end)
    if not ok or type(fn) ~= "function" then return nil end
    local called, value = pcall(function() return fn(object) end)
    return called and value or nil
end

local function indexed(object, index)
    local ok, fn = pcall(function() return object and object.get end)
    if not ok or type(fn) ~= "function" then return nil end
    local called, value = pcall(function() return fn(object, index) end)
    return called and value or nil
end

local function field(object, name)
    local ok, value = pcall(function() return object and object[name] end)
    return ok and value or nil
end

local function get(script, runtime, getters, fields)
    for _, getter in ipairs(getters or {}) do
        local value = call(runtime, getter)
        if value ~= nil then return value end
        value = call(script, getter)
        if value ~= nil then return value end
    end
    for _, name in ipairs(fields or {}) do
        local value = field(runtime, name)
        if value ~= nil then return value end
        value = field(script, name)
        if value ~= nil then return value end
    end
    return nil
end

local function text(script, runtime, getters, fields)
    local value = get(script, runtime, getters, fields)
    return value == nil and "" or tostring(value)
end

local function number(script, runtime, getters, fields)
    return tonumber(get(script, runtime, getters, fields))
end

local function fullTypeOf(script)
    local fullType = call(script, "getFullName") or call(script, "getFullType")
    if fullType and tostring(fullType) ~= "" then return tostring(fullType) end
    local module = call(script, "getModuleName") or call(script, "getModule")
    local name = call(script, "getName")
    return module and name and tostring(module) .. "." .. tostring(name) or nil
end

local function runtimeFor(script)
    local ok, runtime = pcall(function() return script:InstanceItem(nil, false) end)
    return ok and runtime or nil
end

local function shallowCopy(source)
    local copy = {}
    for key, value in pairs(source or {}) do copy[key] = value end
    return copy
end

local function lower(value) return string.lower(tostring(value or "")) end
local function contains(value, token) return string.find(lower(value), token, 1, true) ~= nil end
local function moduleOf(fullType) return string.match(tostring(fullType), "^([^.]+)%.") or "UNKNOWN" end

local function safe(value)
    if value == nil or value == "" then return "-" end
    if type(value) == "number" then return string.format("%.3f", value) end
    if type(value) == "table" then
        local values = {}
        for _, entry in ipairs(value) do table.insert(values, tostring(entry)) end
        return #values > 0 and table.concat(values, ",") or "-"
    end
    return tostring(value):gsub("[\r\n|]", " ")
end

local function normalizedCallback(value)
    local callback = tostring(value or "")
    local lowered = lower(callback)
    return (lowered == "nil" or lowered == "null") and "" or callback
end

local function allScripts(manager)
    local collection = call(manager, "getAllItems") or call(manager, "getAllScriptItems") or call(manager, "getItems")
    local scripts, seen = {}, {}
    local function append(script)
        local fullType = fullTypeOf(script)
        if fullType and not seen[fullType] then
            seen[fullType] = true
            table.insert(scripts, script)
        end
    end
    if type(collection) == "table" then
        for _, script in pairs(collection) do append(script) end
    else
        local size = tonumber(call(collection, "size") or call(collection, "getSize")) or 0
        for index = 0, size - 1 do append(indexed(collection, index)) end
    end
    table.sort(scripts, function(a, b) return fullTypeOf(a) < fullTypeOf(b) end)
    return scripts
end

local function canonicalFirearm(value)
    return lower(tostring(value or ""):gsub("%[", ""):gsub("%]", ""):gsub("%s", ""))
end

local function magazineTargets(value)
    local targets, seen = {}, {}
    local source = tostring(value or ""):gsub("%[", ""):gsub("%]", "")
    for target in string.gmatch(source, "[^;,%s]+") do
        local canonical = canonicalFirearm(target)
        if canonical ~= "" and not seen[canonical] then
            seen[canonical] = true
            table.insert(targets, canonical)
        end
    end
    return targets
end

local function canonicalAmmoType(value)
    local key = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local sentinel = lower(key)
    if sentinel == "" or sentinel == "nil" or sentinel == "null" or sentinel == "[]" then return "" end
    return key
end

local function firearmInfo(shadow, scriptByType)
    local byFullType, byAmmoType = {}, {}
    for fullType, data in pairs(shadow) do
        if data.utilityKind == "FIREARM" and data.utilityEligible then
            byFullType[canonicalFirearm(fullType)] = data
            local info = scriptByType[fullType]
            -- FirearmUtility transports combat metrics but deliberately keeps
            -- AmmoType outside utilityMetrics. Read the same structural
            -- ScriptItem declaration that admitted the firearm instead.
            local ammoType = info and text(info.script, info.runtime, { "getAmmoType" }, { "ammoType" }) or nil
            local key = canonicalAmmoType(ammoType)
            if key ~= "" then
                byAmmoType[key] = byAmmoType[key] or {}
                table.insert(byAmmoType[key], data)
            end
        end
    end
    return byFullType, byAmmoType
end

local function tierIndex(tier)
    return ({ COMMON = 1, UNCOMMON = 2, RARE = 3, EPIC = 4, EXOTIC = 5 })[tier] or 0
end

local function bestTier(firearms)
    local best, names, bestValue = nil, {}, nil
    for _, firearm in ipairs(firearms or {}) do
        table.insert(names, firearm.fullType)
        local tier = firearm.finalRarityTier or firearm.firearmFinalTier
        if not best or tierIndex(tier) > tierIndex(best) then
            best, bestValue = tier, tonumber(firearm.firearmFinalScore) or tonumber(firearm.firearmCombinedScore)
        end
    end
    table.sort(names)
    return best, names, bestValue
end

local function firearmTier(score)
    local tiers = ((ItemRarityConfig or {}).utility or {}).firearm and ItemRarityConfig.utility.firearm.tiers or {}
    if score >= (tiers.exotic or 85) then return "EXOTIC" end
    if score >= (tiers.epic or 70) then return "EPIC" end
    if score >= (tiers.rare or 55) then return "RARE" end
    if score >= (tiers.uncommon or 40) then return "UNCOMMON" end
    return "COMMON"
end

local function cappedMagazineTier(score)
    local tier = firearmTier(score)
    local ceiling = (((ItemRarityConfig or {}).utility or {}).magazine or {}).maxTier or "EPIC"
    return tierIndex(tier) > tierIndex(ceiling) and ceiling or tier
end

-- Script GunType may be a complete fullType or a bare local item identifier.
-- The latter is structurally resolvable only within the declaring module; no
-- cross-module suffix search or item-name heuristic is permitted here.
local function resolveMagazineTargets(gunType, ownModule, firearmByType)
    local resolved, seen = {}, {}
    for _, target in ipairs(magazineTargets(gunType)) do
        local firearm = firearmByType[target]
        if not firearm and not string.find(target, ".", 1, true) and ownModule ~= "UNKNOWN" then
            firearm = firearmByType[canonicalFirearm(ownModule .. "." .. target)]
        end
        if firearm and not seen[firearm.fullType] then
            seen[firearm.fullType] = true
            table.insert(resolved, firearm)
        end
    end
    table.sort(resolved, function(a, b) return a.fullType < b.fullType end)
    return resolved
end

local function structuralClass(script, runtime, data)
    local tags = text(script, runtime, { "getTags" }, { "tags" })
    local scriptType = text(script, runtime, { "getType" }, { "type" })
    local itemType = text(script, runtime, { "getItemType" }, { "itemType" })
    local ammoType = text(script, runtime, { "getAmmoType" }, { "ammoType" })
    local maxAmmo = number(script, runtime, { "getMaxAmmo" }, { "maxAmmo" }) or 0
    local partType = text(script, runtime, { "getPartType" }, { "partType" })
    local gunType = text(script, runtime, { "getGunType" }, { "gunType" })
    local openBox = normalizedCallback(text(script, runtime, { "getDoubleClickRecipe" }, { "doubleClickRecipe" }))
    local replaceOnUse = normalizedCallback(text(script, runtime, { "getReplaceOnUse" }, { "replaceOnUse" }))
    local replaceOnDeplete = normalizedCallback(text(script, runtime, { "getReplaceOnDeplete" }, { "replaceOnDeplete" }))
    local capacity = number(script, runtime, { "getCapacity" }, { "capacity" }) or 0
    local magazineLike = maxAmmo > 0 and ammoType ~= "" and (gunType ~= "" or partType ~= "" or contains(tags, "magazine"))
    if magazineLike and (contains(scriptType, "weapon") or contains(itemType, "weaponpart") or partType ~= "") then
        return "WEAPON_PART_MAGAZINE"
    end
    if openBox ~= "" then return "AMMO_BOX" end
    if replaceOnUse ~= "" or replaceOnDeplete ~= "" then return "TRANSFORMABLE_AMMO" end
    if data.utilityKind == "MAGAZINE" or magazineLike then return "MAGAZINE" end
    if data.utilityKind == "AMMO" or contains(tags, "base:ammo") then return "DIRECT_AMMO" end
    return "UNKNOWN"
end

local function rejectionReason(data, class)
    if data.utilityKind == "AMMO" and data.utilityEligible ~= true then
        return "AmmoUtility V1: no structurally compatible FirearmUtility result"
    end
    if data.utilityKind == "MAGAZINE" and data.utilityEligible ~= true then
        return "MagazineUtility V1: no compatible published FirearmUtility value"
    end
    if class == "AMMO_BOX" then return "AmmoUtility V1 deliberately excludes OpenBox/DoubleClickRecipe transformations" end
    if class == "TRANSFORMABLE_AMMO" then return "AmmoUtility V1 deliberately excludes transformed/depleting item states" end
    if class == "WEAPON_PART_MAGAZINE" then return "MagazineUtility V1 excludes weapon scripts; precedence remains unresolved" end
    return data.utilitySupport or "No selected Ammo/Magazine candidate"
end

local function scriptFields(script, runtime)
    return {
        displayName = text(script, runtime, { "getDisplayName", "getName" }, { "displayName", "name" }),
        source = text(script, runtime, { "getModID", "getMod", "getModName", "getSourceMod" }, { "modID", "mod", "modName", "sourceMod" }),
        scriptType = text(script, runtime, { "getType" }, { "type" }),
        displayCategory = text(script, runtime, { "getDisplayCategory" }, { "displayCategory" }),
        tags = text(script, runtime, { "getTags" }, { "tags" }),
        ammoType = text(script, runtime, { "getAmmoType" }, { "ammoType" }),
        maxAmmo = number(script, runtime, { "getMaxAmmo" }, { "maxAmmo" }),
        partType = text(script, runtime, { "getPartType" }, { "partType" }),
        weaponPartType = text(script, runtime, { "getWeaponPartType" }, { "weaponPartType" }),
        gunType = text(script, runtime, { "getGunType" }, { "gunType" }),
        replaceOnUse = normalizedCallback(text(script, runtime, { "getReplaceOnUse" }, { "replaceOnUse" })),
        replaceOnDeplete = normalizedCallback(text(script, runtime, { "getReplaceOnDeplete" }, { "replaceOnDeplete" })),
        openBox = normalizedCallback(text(script, runtime, { "getDoubleClickRecipe" }, { "doubleClickRecipe" })),
        capacity = number(script, runtime, { "getCapacity" }, { "capacity" }) or 0,
    }
end

function ItemRarityAmmoMagazineCoverageAudit.write(activeResults)
    if type(activeResults) ~= "table" or not getScriptManager or not getFileWriter then return nil end
    if not ItemRarityItemClassifier or not ItemRarityUtilityCalculator then return nil end
    local scripts = allScripts(getScriptManager())
    if #scripts == 0 then return nil end

    local shadow, scriptByType = {}, {}
    for fullType, data in pairs(activeResults) do shadow[fullType] = shallowCopy(data) end
    for _, script in ipairs(scripts) do
        local fullType = fullTypeOf(script)
        local runtime = runtimeFor(script)
        scriptByType[fullType] = { script = script, runtime = runtime }
        if not shadow[fullType] then
            local category, metadata = ItemRarityItemClassifier.getFunctionalCategory(fullType)
            shadow[fullType] = {
                fullType = fullType, module = metadata.module or moduleOf(fullType), category = category,
                displayCategory = metadata.displayCategory, scriptType = metadata.scriptType,
                occurrences = 0, syntheticCoverageAudit = true, scarcityState = "UNKNOWN",
                baseScarcityTier = "COMMON", rarityTier = "COMMON",
            }
        end
        shadow[fullType]._scriptItem = script
    end

    local calculator = ItemRarityUtilityCalculator
    local savedBounds, savedGraphs = calculator.lastFirearmNormalizationBounds, calculator._scanBodyLocationGraphs
    local ok, err = pcall(function() calculator.calculate(shadow) end)
    calculator.lastFirearmNormalizationBounds, calculator._scanBodyLocationGraphs = savedBounds, savedGraphs
    if not ok then
        local failed = getFileWriter("ItemRarity_AmmoMagazineCoverageAudit.txt", true, false)
        if failed then failed:write("AMMO/MAGAZINE COVERAGE AUDIT FAILED WITHOUT ACTIVE MUTATION\n" .. tostring(err) .. "\n"); failed:close() end
        return nil
    end

    local firearmByType, firearmsByAmmoType = firearmInfo(shadow, scriptByType)
    local rows, extraStructural = {}, {}
    local counts = { DIRECT_AMMO_SAFE_UTILITY_ONLY = 0, MAGAZINE_SAFE_UTILITY_ONLY = 0, AMMO_BOX_SAFE = 0, WEAPON_PART_MAGAZINE_CASES = 0, UNSAFE_UNKNOWN = 0 }
    for fullType, info in pairs(scriptByType) do
        if not activeResults[fullType] then
            local data, fields = shadow[fullType], scriptFields(info.script, info.runtime)
            -- CandidateDiscovery already proved this representation readable.
            -- Prefer its captured GunType when the public getter is blank.
            if data.utilityMetrics and data.utilityMetrics.gunType and data.utilityMetrics.gunType ~= "" then
                fields.gunType = data.utilityMetrics.gunType
            end
            local class = structuralClass(info.script, info.runtime, data)
            local selected = data.utilityKind == "AMMO" or data.utilityKind == "MAGAZINE"
            local relevant = selected or class == "AMMO_BOX" or class == "TRANSFORMABLE_AMMO" or class == "WEAPON_PART_MAGAZINE"
            if relevant then
                local currentCompatible, futureCompatible, proposedTier, proposedScore = {}, {}, nil, nil
                if data.utilityKind == "AMMO" then
                    currentCompatible = data.ammoCompatibleFirearms or {}
                    futureCompatible = firearmsByAmmoType[canonicalAmmoType(fields.ammoType)] or {}
                    proposedTier = select(1, bestTier(futureCompatible))
                elseif data.utilityKind == "MAGAZINE" then
                    futureCompatible = resolveMagazineTargets(fields.gunType, moduleOf(fullType), firearmByType)
                    local _, _, bestValue = bestTier(futureCompatible)
                    if bestValue then
                        local magazine = (((ItemRarityConfig or {}).utility or {}).magazine or {})
                        local saturation = magazine.capacitySaturation or 20
                        local capacityValue = 100 * (fields.maxAmmo or 0) / ((fields.maxAmmo or 0) + saturation)
                        proposedScore = (magazine.compatibleWeaponWeight or 0.70) * bestValue + (magazine.capacityWeight or 0.30) * capacityValue
                        proposedTier = cappedMagazineTier(proposedScore)
                    end
                end
                local futureSafe = selected and proposedTier ~= nil
                local row = {
                    fullType = fullType, fields = fields, data = data, class = class, selected = selected,
                    accepted = data.utilityEligible == true, rejection = rejectionReason(data, class),
                    currentCompatible = currentCompatible, futureCompatible = futureCompatible,
                    proposedTier = proposedTier, proposedScore = proposedScore, futureSafe = futureSafe,
                }
                if selected then
                    table.insert(rows, row)
                    if class == "WEAPON_PART_MAGAZINE" then counts.WEAPON_PART_MAGAZINE_CASES = counts.WEAPON_PART_MAGAZINE_CASES + 1 end
                    if class == "DIRECT_AMMO" and futureSafe then
                        counts.DIRECT_AMMO_SAFE_UTILITY_ONLY = counts.DIRECT_AMMO_SAFE_UTILITY_ONLY + 1
                    elseif class == "MAGAZINE" and futureSafe then
                        counts.MAGAZINE_SAFE_UTILITY_ONLY = counts.MAGAZINE_SAFE_UTILITY_ONLY + 1
                    elseif not futureSafe then
                        counts.UNSAFE_UNKNOWN = counts.UNSAFE_UNKNOWN + 1
                    end
                else
                    table.insert(extraStructural, row)
                    counts.UNSAFE_UNKNOWN = counts.UNSAFE_UNKNOWN + 1
                end
            end
        end
    end
    table.sort(rows, function(a, b) return a.fullType < b.fullType end)
    table.sort(extraStructural, function(a, b) return a.fullType < b.fullType end)

    local ghostRows = {}
    for fullType, data in pairs(activeResults) do
        if not scriptByType[fullType] and (data.utilityKind == "AMMO" or data.utilityKind == "MAGAZINE") then
            table.insert(ghostRows, { fullType = fullType, data = data })
        end
    end
    table.sort(ghostRows, function(a, b) return a.fullType < b.fullType end)

    local writer = getFileWriter("ItemRarity_AmmoMagazineCoverageAudit.txt", true, false)
    if not writer then return nil end
    writer:write("Item Rarity Ammo/Magazine coverage audit (READ ONLY)\n")
    writer:write("Shadow CandidateDiscovery/Utility calculation only. No scan, RouteWeighted, scarcity, registry, tier or UI mutation occurred.\n\n")
    writer:write(string.format("NO_RESULT_SELECTED_AMMO_MAGAZINE=%d | DIRECT_AMMO_SAFE_UTILITY_ONLY=%d | MAGAZINE_SAFE_UTILITY_ONLY=%d | AMMO_BOX_SAFE=%d | WEAPON_PART_MAGAZINE_CASES=%d | UNSAFE_UNKNOWN=%d\n\n",
        #rows, counts.DIRECT_AMMO_SAFE_UTILITY_ONLY, counts.MAGAZINE_SAFE_UTILITY_ONLY, counts.AMMO_BOX_SAFE, counts.WEAPON_PART_MAGAZINE_CASES, counts.UNSAFE_UNKNOWN))
    writer:write("NO-RESULT AMMO/MAGAZINE CANDIDATES\n")
    writer:write("fullType | displayName | module/source | ScriptItem type | DisplayCategory | tags | AmmoType | MaxAmmo | PartType | WeaponPartType | GunType | ReplaceOnUse | ReplaceOnDeplete | OpenBox | structuralClass | candidateKind | accepted current | exact current rejection/skip reason | loot result row | registry entry | FinalRarityTier | current compatible firearms | structural compatible firearms | structural compatible count | proposed score/tier\n")
    for _, row in ipairs(rows) do
        local f, d = row.fields, row.data
        local futureNames = {}
        for _, firearm in ipairs(row.futureCompatible) do table.insert(futureNames, firearm.fullType) end
        local proposed = d.utilityKind == "MAGAZINE" and (safe(row.proposedScore) .. "/" .. safe(row.proposedTier)) or safe(row.proposedTier)
        writer:write(table.concat({ row.fullType, safe(f.displayName), moduleOf(row.fullType) .. "/" .. safe(f.source), safe(f.scriptType), safe(f.displayCategory), safe(f.tags), safe(f.ammoType), safe(f.maxAmmo), safe(f.partType), safe(f.weaponPartType), safe(f.gunType), safe(f.replaceOnUse), safe(f.replaceOnDeplete), safe(f.openBox), row.class, safe(d.utilityKind), tostring(row.accepted), safe(row.rejection), "false", "false", "-", safe(row.currentCompatible), safe(futureNames), tostring(#futureNames), proposed }, " | ") .. "\n")
    end
    writer:write("\nSTRUCTURAL AMMO BOX / TRANSFORM / WEAPONPART CASES (NO RESULT)\n")
    writer:write("fullType | displayName | module/source | structuralClass | tags | AmmoType | MaxAmmo | PartType | GunType | OpenBox | ReplaceOnUse | ReplaceOnDeplete | selected candidate | reason\n")
    for _, row in ipairs(extraStructural) do
        local f, d = row.fields, row.data
        writer:write(table.concat({ row.fullType, safe(f.displayName), moduleOf(row.fullType) .. "/" .. safe(f.source), row.class, safe(f.tags), safe(f.ammoType), safe(f.maxAmmo), safe(f.partType), safe(f.gunType), safe(f.openBox), safe(f.replaceOnUse), safe(f.replaceOnDeplete), safe(d.utilityKind), safe(row.rejection) }, " | ") .. "\n")
    end
    writer:write("\nGHOST RESULT ROWS WITH AMMO/MAGAZINE UTILITY\n")
    writer:write("fullType | utilityKind | utility metrics | final tier | migration decision\n")
    if #ghostRows == 0 then writer:write("(none)\n") end
    for _, row in ipairs(ghostRows) do
        writer:write(table.concat({ row.fullType, safe(row.data.utilityKind), safe(row.data.utilityMetrics), safe(row.data.finalRarityTier), "NO MIGRATION: no active ScriptItem structural proof" }, " | ") .. "\n")
    end
    writer:close()
    if ItemRarityUtils and ItemRarityUtils.info then
        ItemRarityUtils.info(string.format("Ammo/Magazine coverage audit written: %d no-result selected candidates | %d structural extras", #rows, #extraStructural))
    end
    return true
end
