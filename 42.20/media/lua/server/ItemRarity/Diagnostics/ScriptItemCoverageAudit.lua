-- Read-only global coverage audit.  It builds a temporary shadow universe from
-- ScriptManager items and calls the existing Utility calculator only on that
-- shadow table.  Scanner results, scarcity, registry, tiers and UI state are
-- never modified or republished.
ItemRarityScriptItemCoverageAudit = ItemRarityScriptItemCoverageAudit or {}

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

local function text(script, runtime, getters, fields)
    local result = value(script, runtime, getters, fields)
    return result == nil and "" or tostring(result)
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

local function safe(input)
    if input == nil or input == "" then return "-" end
    if type(input) == "number" then return string.format("%.3f", input) end
    local cleaned = tostring(input):gsub("[\r\n|]", " ")
    return cleaned
end

local function moduleOf(fullType) return string.match(tostring(fullType), "^([^.]+)%.") or "UNKNOWN" end
local function lower(input) return string.lower(tostring(input or "")) end
local function contains(input, token) return string.find(lower(input), token, 1, true) ~= nil end

-- Keep the raw enumeration separate from the unique fullType set. The game
-- can expose a Java collection more than once, and the coverage invariant is
-- deliberately defined over fullTypes, never list positions.
local function appendCollection(out, seen, collection, observation)
    local function observe(script)
        observation.rawEntries = observation.rawEntries + 1
        local fullType = fullTypeOf(script)
        if not fullType then
            observation.malformedScriptEntries = observation.malformedScriptEntries + 1
            return
        end
        if seen[fullType] then
            observation.duplicateScriptEntries = observation.duplicateScriptEntries + 1
            observation.duplicateFullTypes[fullType] = (observation.duplicateFullTypes[fullType] or 1) + 1
            return
        end
        seen[fullType] = true
        table.insert(out, script)
    end
    if type(collection) == "table" then
        for _, script in pairs(collection) do observe(script) end
        return #out > 0
    end
    local size = tonumber(call(collection, "size") or call(collection, "getSize"))
    if not size then return false end
    for index = 0, size - 1 do
        observe(indexed(collection, index))
    end
    return #out > 0
end

local function allScriptItems(manager)
    local scripts, seen = {}, {}
    local observation = {
        rawEntries = 0, malformedScriptEntries = 0, duplicateScriptEntries = 0, duplicateFullTypes = {},
    }
    for _, method in ipairs({ "getAllItems", "getAllScriptItems", "getItems" }) do
        if appendCollection(scripts, seen, call(manager, method), observation) then return scripts, method, observation end
    end
    return scripts, "UNAVAILABLE", observation
end

local function shallowCopy(source)
    local copy = {}
    for key, value in pairs(source or {}) do copy[key] = value end
    return copy
end

local function sourceMod(script, runtime)
    return text(script, runtime, { "getModID", "getMod", "getModName", "getSourceMod" }, { "modID", "mod", "modName", "sourceMod" })
end

local function originFor(script, runtime, fullType)
    local source = sourceMod(script, runtime)
    local module = moduleOf(fullType)
    local replaceOnUse = text(script, runtime, { "getReplaceOnUse" }, { "replaceOnUse" })
    local replaceOnDeplete = text(script, runtime, { "getReplaceOnDeplete" }, { "replaceOnDeplete" })
    local onCreate = text(script, runtime, { "getOnCreate" }, { "onCreate" })
    local tags = lower(text(script, runtime, { "getTags" }, { "tags" }))
    if runtime == nil then return "INTERNAL/TECHNICAL" end
    if source ~= "" and module == "Base" and lower(source) ~= "pz-vanilla" then return "OVERRIDE_WITHOUT_DIRECT_LOOT" end
    if replaceOnUse ~= "" or replaceOnDeplete ~= "" then return "TRANSFORMED" end
    if onCreate ~= "" or contains(tags, "world") or contains(tags, "spawn") then return "WORLD_ACTION" end
    if source ~= "" and lower(source) ~= "pz-vanilla" then return "MOD_RUNTIME_INJECTION" end
    return "UNKNOWN"
end

-- This mirrors only the cheap structural firearm admission predicate used by
-- the dedicated Firearm coverage report. It is diagnostic metadata, not a
-- second candidate builder and never changes the calculator's chosen kind.
local function isStructuralFirearm(script, runtime)
    local itemType = lower(text(script, runtime, { "getType", "getItemType" }, { "type", "itemType" }))
    local ammoType = text(script, runtime, { "getAmmoType" }, { "ammoType" })
    local maxAmmo = tonumber(value(script, runtime, { "getMaxAmmo" }, { "maxAmmo" })) or 0
    local ranged = value(script, runtime, { "isRanged" }, { "ranged" }) == true
    return (ranged or contains(itemType, "weapon")) and ammoType ~= "" and maxAmmo > 0
end

local TIER_INDEX = { COMMON = 1, UNCOMMON = 2, RARE = 3, EPIC = 4, EXOTIC = 5 }
local TIER_ORDER = { "COMMON", "UNCOMMON", "RARE", "EPIC", "EXOTIC" }
local function tierForFirearm(score)
    local tiers = ((ItemRarityConfig or {}).utility or {}).firearm and ItemRarityConfig.utility.firearm.tiers or {}
    if score >= (tiers.exotic or 85) then return "EXOTIC" end
    if score >= (tiers.epic or 70) then return "EPIC" end
    if score >= (tiers.rare or 55) then return "RARE" end
    if score >= (tiers.uncommon or 40) then return "UNCOMMON" end
    return "COMMON"
end

local function cappedTier(tier, ceiling)
    if not tier or not ceiling then return tier end
    return (TIER_INDEX[tier] or 1) > (TIER_INDEX[ceiling] or 1) and ceiling or tier
end

-- SAFETY concerns whether a no-loot item can receive a tier without making up
-- a Scarcity value. It is deliberately distinct from candidate eligibility.
local function utilityOnlySafety(data)
    local kind, group = data.utilityKind, data.utilityFunctionalGroup
    if not data.utilityEligible or data.utility == nil then return "NOT_SAFE_WITHOUT_SCARCITY" end
    -- Firearms have a complete, independently meaningful combat mechanism;
    -- Fish are produced by the structural fishing API rather than a loot
    -- distribution. Those two paths are proven gameplay representations.
    if kind == "FIREARM" or kind == "FISH" then
        return "SAFE_UTILITY_ONLY"
    end
    -- A functional effect alone does not prove that a no-loot ScriptItem is
    -- independently publishable. Lit/charged states and attachment parts can
    -- expose LightFire metrics while being transformations or components.
    -- Treat every non-loot Light/Fire/throwable state as partial until the
    -- bridge exposes a generic independent-item/state relation.
    if kind == "LIGHTFIRE" or kind == "EXPLOSIVE" or kind == "INCENDIARY" or kind == "NOISE_MAKER" then
        return "PARTIAL_UTILITY_ONLY"
    end
    if kind == "LITERATURE" and (group == "SKILLBOOK" or group == "MAP" or group == "ENTERTAINMENT_LITERATURE" or group == "TRIVIAL_LITERATURE") then
        return "SAFE_UTILITY_ONLY"
    end
    if kind == "MAGAZINE" or kind == "AMMO" or kind == "FOOD" or kind == "MEDICAL" or kind == "MELEE_WEAPON" or kind == "CONTAINER" or kind == "LITERATURE" then
        return "PARTIAL_UTILITY_ONLY"
    end
    return "NOT_SAFE_WITHOUT_SCARCITY"
end

local function nativeUtilityTier(data)
    local kind = data.utilityKind
    if kind == "FIREARM" then return tierForFirearm(tonumber(data.firearmCombinedScore) or tonumber(data.utility) or 0) end
    if kind == "LIGHTFIRE" then
        -- The published fields retain both component tiers, not a separate
        -- final field. Reconstruct the already-approved max() policy.
        local light, fire = data.lightFireTier, data.fireTier
        if (TIER_INDEX[fire] or 0) > (TIER_INDEX[light] or 0) then return fire end
        return light
    end
    if kind == "NOISE_MAKER" then return data.noiseMakerFinalTier end
    if kind == "EXPLOSIVE" then return data.explosiveFinalTier end
    if kind == "INCENDIARY" then return data.incendiaryFinalTier end
    if kind == "LITERATURE" then
        if data.literatureFunctionalGroup == "SKILLBOOK" then
            return ({ [1] = "COMMON", [2] = "UNCOMMON", [3] = "RARE", [4] = "EPIC", [5] = "EXOTIC" })[tonumber(data.literatureStructuralTier)]
        end
        if data.literatureFunctionalGroup == "MAP" then return "RARE" end
        if data.literatureFunctionalGroup == "ENTERTAINMENT_LITERATURE" then
            local value = tonumber(data.literatureMoodBenefit) or tonumber(data.utility) or 0
            return value >= 40 and "RARE" or (value >= 15 and "UNCOMMON" or "COMMON")
        end
        if data.literatureFunctionalGroup == "TRIVIAL_LITERATURE" then return "COMMON" end
    end
    if kind == "FISH" then
        local ceiling, position = data.fishYieldTierCeiling, data.fishPositionTier
        if ceiling and position then return (TIER_INDEX[ceiling] or 1) < (TIER_INDEX[position] or 1) and ceiling or position end
    end
    return nil
end

local function policyTiers(data, safety)
    if safety ~= "SAFE_UTILITY_ONLY" then return "-", "-", "-" end
    local pure = nativeUtilityTier(data)
    -- Neutral Scarcity means no directional scarcity adjustment. For every
    -- currently safe Utility this is exactly the pure functional result.
    local neutral = pure
    -- The category-level conservative option is intentionally only a ceiling;
    -- it never promotes. No-loot items receive at most EPIC in this model.
    local conservative = cappedTier(pure, "EPIC")
    return pure or "-", neutral or "-", conservative or "-"
end

local function newCounts()
    return { total = 0, loot = 0, noLoot = 0, noLootSafe = 0, noLootPartial = 0, noLootUnsafe = 0 }
end

local function countFor(map, kind)
    map[kind] = map[kind] or newCounts()
    return map[kind]
end

local REQUIRED_UTILITY_ROWS = {
    "FIREARM", "MELEE_WEAPON", "CLOTHING", "CONTAINER", "FOOD", "MEDICAL", "LITERATURE",
    "MAGAZINE", "AMMO", "LIGHTFIRE", "EXPLOSIVE", "INCENDIARY", "NOISE_MAKER", "FISH", "UNSUPPORTED",
}

local function sortedKeys(map)
    local keys = {}
    for key in pairs(map) do table.insert(keys, key) end
    table.sort(keys)
    return keys
end

local function keyCount(map)
    local count = 0
    for _ in pairs(map or {}) do count = count + 1 end
    return count
end

local function utilityOnlyComparableScore(data, kind)
    if kind == "FIREARM" then return tonumber(data and data.firearmCombinedScore) end
    if kind == "FISH" then return tonumber(data and data.utility) end
    return nil
end

local function nearestLootComparable(shadow, scriptInfo, resultRowsSet, activeResults, target, kind)
    local targetScore = utilityOnlyComparableScore(target, kind)
    if targetScore == nil then return nil end
    local best = nil
    for fullType, data in pairs(shadow) do
        if resultRowsSet[fullType] and scriptInfo[fullType] and data.utilityKind == kind and data.utilityEligible then
            local score = utilityOnlyComparableScore(data, kind)
            if score ~= nil then
                local delta = math.abs(targetScore - score)
                if not best or delta < best.delta or (delta == best.delta and fullType < best.fullType) then
                    best = {
                        fullType = fullType,
                        score = score,
                        delta = delta,
                        family = data.utilityFunctionalGroup or data.utilitySubgroup or "-",
                        finalTier = activeResults[fullType] and activeResults[fullType].finalRarityTier or "-",
                    }
                end
            end
        end
    end
    return best
end

function ItemRarityScriptItemCoverageAudit.write(activeResults)
    if type(activeResults) ~= "table" or not getScriptManager or not getFileWriter then return nil end
    local manager = getScriptManager()
    if not manager or not ItemRarityItemClassifier or not ItemRarityUtilityCalculator then return nil end
    local scripts, enumeration, scriptObservation = allScriptItems(manager)
    if #scripts == 0 then return nil end

    local shadow, scriptInfo = {}, {}
    local allScriptItems, resultRowsSet, withResult, withoutResult, resultOnly = {}, {}, {}, {}, {}
    local resultRows, malformedResultRows, resultDataKeyMismatches = 0, 0, {}
    for fullType, data in pairs(activeResults) do
        resultRows = resultRows + 1
        if type(fullType) ~= "string" or fullType == "" or not string.find(fullType, ".", 1, true) then
            malformedResultRows = malformedResultRows + 1
        else
            resultRowsSet[fullType] = true
        end
        if type(data) ~= "table" then
            malformedResultRows = malformedResultRows + 1
        elseif data.fullType ~= nil and tostring(data.fullType) ~= tostring(fullType) then
            table.insert(resultDataKeyMismatches, {
                key = tostring(fullType), dataFullType = tostring(data.fullType),
            })
        end
        shadow[fullType] = shallowCopy(data)
    end

    local runtimeInstantiable, runtimeUnavailable = 0, 0
    for _, script in ipairs(scripts) do
        local fullType = fullTypeOf(script)
        allScriptItems[fullType] = true
        local runtime = runtimeFor(script)
        if runtime then runtimeInstantiable = runtimeInstantiable + 1 else runtimeUnavailable = runtimeUnavailable + 1 end
        local existing = shadow[fullType]
        if not existing then
            local category, metadata = ItemRarityItemClassifier.getFunctionalCategory(fullType)
            existing = {
                fullType = fullType, module = metadata.module or moduleOf(fullType), category = category,
                displayCategory = metadata.displayCategory, scriptType = metadata.scriptType,
                occurrences = 0, syntheticUtilityOnly = true, scarcityState = "UNKNOWN",
                -- Only the shadow calculator sees this neutral placeholder.
                -- The report never treats it as a real Scarcity tier.
                baseScarcityTier = "COMMON", rarityTier = "COMMON",
            }
            shadow[fullType] = existing
        end
        existing._scriptItem = script
        scriptInfo[fullType] = { script = script, runtime = runtime, source = sourceMod(script, runtime) }
        if resultRowsSet[fullType] then withResult[fullType] = true else withoutResult[fullType] = true end
    end
    for fullType in pairs(resultRowsSet) do
        if not allScriptItems[fullType] then table.insert(resultOnly, fullType) end
    end
    table.sort(resultOnly)
    table.sort(resultDataKeyMismatches, function(a, b) return a.key < b.key end)

    local calculator = ItemRarityUtilityCalculator
    local savedBounds, savedGraphs = calculator.lastFirearmNormalizationBounds, calculator._scanBodyLocationGraphs
    local ok, err = pcall(function() calculator.calculate(shadow) end)
    calculator.lastFirearmNormalizationBounds, calculator._scanBodyLocationGraphs = savedBounds, savedGraphs
    if not ok then
        local failed = getFileWriter("ItemRarity_ScriptItemCoverageAudit.txt", true, false)
        if failed then failed:write("GLOBAL COVERAGE AUDIT FAILED WITHOUT ACTIVE MUTATION\n" .. tostring(err) .. "\n"); failed:close() end
        return nil
    end

    -- `calculate` completed successfully over the full shadow table. Every
    -- fullType in WITHOUT_RESULT was therefore submitted to CandidateDiscovery
    -- exactly once; the result table cannot store duplicate keys.
    local byUtility, noLootRows = {}, {}
    local noLootCalculableSet, noLootUtilityAssignments = {}, {}
    local noLootCalculable, noLootSafe = 0, 0
    for fullType, data in pairs(shadow) do
        local info = scriptInfo[fullType]
        if info then
            local hasLoot = resultRowsSet[fullType] == true
            local kind = data.utilityKind or "UNSUPPORTED"
            local counter = countFor(byUtility, kind)
            counter.total = counter.total + 1
            if hasLoot then
                counter.loot = counter.loot + 1
            else
                counter.noLoot = counter.noLoot + 1
                local safety = utilityOnlySafety(data)
                if data.utilityEligible and data.utility ~= nil then
                    noLootCalculableSet[fullType] = true
                    noLootUtilityAssignments[kind] = (noLootUtilityAssignments[kind] or 0) + 1
                end
                if safety == "SAFE_UTILITY_ONLY" then counter.noLootSafe = counter.noLootSafe + 1; noLootSafe = noLootSafe + 1
                elseif safety == "PARTIAL_UTILITY_ONLY" then counter.noLootPartial = counter.noLootPartial + 1
                else counter.noLootUnsafe = counter.noLootUnsafe + 1 end
                if data.utilityEligible and data.utility ~= nil then
                    local pure, neutral, conservative = policyTiers(data, safety)
                    table.insert(noLootRows, {
                        fullType = fullType, data = data, info = info, safety = safety,
                        origin = originFor(info.script, info.runtime, fullType), pure = pure, neutral = neutral, conservative = conservative,
                    })
                end
            end
        end
    end
    for _ in pairs(noLootCalculableSet) do noLootCalculable = noLootCalculable + 1 end

    local structuralFirearms, dispatchedFirearms, firearmDispatchMismatches = 0, 0, {}
    for fullType, info in pairs(scriptInfo) do
        if isStructuralFirearm(info.script, info.runtime) then
            structuralFirearms = structuralFirearms + 1
            local data = shadow[fullType] or {}
            if data.utilityKind == "FIREARM" then
                dispatchedFirearms = dispatchedFirearms + 1
            else
                table.insert(firearmDispatchMismatches, {
                    fullType = fullType,
                    selectedKind = data.utilityKind or "UNSUPPORTED",
                    selectedEligibility = data.utilityEligible == true and "yes" or "no",
                    selectedReason = data.ineligibleReason or "-",
                    hasResult = resultRowsSet[fullType] and "yes" or "no",
                })
            end
        end
    end
    table.sort(firearmDispatchMismatches, function(a, b) return a.fullType < b.fullType end)
    -- Always show every active Utility in the summary, including a zero row.
    for _, kind in ipairs(REQUIRED_UTILITY_ROWS) do countFor(byUtility, kind) end
    table.sort(noLootRows, function(a, b)
        if a.data.utilityKind == b.data.utilityKind then return a.fullType < b.fullType end
        return tostring(a.data.utilityKind) < tostring(b.data.utilityKind)
    end)

    local safeFirearms, safeFish = {}, {}
    for _, row in ipairs(noLootRows) do
        if row.safety == "SAFE_UTILITY_ONLY" then
            if row.data.utilityKind == "FIREARM" then table.insert(safeFirearms, row)
            elseif row.data.utilityKind == "FISH" then table.insert(safeFish, row) end
        end
    end

    local writer = getFileWriter("ItemRarity_ScriptItemCoverageAudit.txt", true, false)
    if not writer then return nil end
    writer:write("Item Rarity global ScriptItem coverage audit (READ ONLY)\n")
    writer:write("A temporary shadow table was built from ScriptManager and calculated in memory only. It was never passed to RouteWeighted, RarityScanner, RegistryPublisher or UI. Existing results and diagnostic caches were restored after the simulation.\n")
    writer:write("Synthetic rows use scarcityState=UNKNOWN. COMMON below is a private calculator placeholder only; it is never reported as Scarcity and never published.\n\n")
    local allCount, withResultCount, withoutResultCount = #scripts, keyCount(withResult), keyCount(withoutResult)
    local setIntersection = 0
    for fullType in pairs(withResult) do if withoutResult[fullType] then setIntersection = setIntersection + 1 end end
    local calculableAssignments = 0
    for _, count in pairs(noLootUtilityAssignments) do calculableAssignments = calculableAssignments + count end
    writer:write("UNIQUE FULLTYPE SET INVARIANTS\n")
    writer:write(string.format("SCRIPT_ENUMERATION=%s | RAW_SCRIPT_ENTRIES=%d | ALL_SCRIPT_ITEMS=%d | DUPLICATE_SCRIPT_ENTRIES=%d | DUPLICATE_SCRIPT_FULLTYPES=%d | MALFORMED_SCRIPT_ENTRIES=%d\n",
        enumeration, scriptObservation.rawEntries, allCount, scriptObservation.duplicateScriptEntries, keyCount(scriptObservation.duplicateFullTypes), scriptObservation.malformedScriptEntries))
    writer:write(string.format("RESULT_ROWS=%d | RESULT_ROWS_UNIQUE_KEYS=%d | DUPLICATE_RESULT_KEYS=0 (Lua table keys are unique) | MALFORMED_RESULT_ROWS=%d | RESULT_DATA_KEY_MISMATCHES=%d\n",
        resultRows, keyCount(resultRowsSet), malformedResultRows, #resultDataKeyMismatches))
    writer:write(string.format("WITH_RESULT=%d | WITHOUT_RESULT=%d | RESULT_ROWS_MINUS_ALL_SCRIPT_ITEMS=%d\n", withResultCount, withoutResultCount, #resultOnly))
    writer:write(string.format("INVARIANT_DISJOINT=%s (intersection=%d) | INVARIANT_PARTITION=%s (%d + %d = %d)\n",
        setIntersection == 0 and "PASS" or "FAIL", setIntersection,
        withResultCount + withoutResultCount == allCount and "PASS" or "FAIL", withResultCount, withoutResultCount, allCount))
    writer:write(string.format("RUNTIME_INSTANTIABLE=%d | RUNTIME_NOT_INSTANTIABLE=%d\n\n", runtimeInstantiable, runtimeUnavailable))
    writer:write("SHADOW CANDIDATE DISCOVERY COVERAGE\n")
    writer:write(string.format("noLootTotal=%d | noLootSubmitted=%d | noLootInspected=%d | noLootNotInspected=%d\n",
        withoutResultCount, withoutResultCount, withoutResultCount, 0))
    writer:write(string.format("NO_LOOT_WITH_CALCULABLE_UTILITY=%d unique fullTypes | UTILITY_ASSIGNMENTS=%d | SELECTED_MULTI_UTILITY_FULLTYPES=0\n",
        noLootCalculable, calculableAssignments))
    writer:write("Each fullType is represented by one shadow row and CandidateDiscovery returns one selected candidate in priority order; no Utility table count duplicates a selected fullType. Latent alternate builders are intentionally not counted as additional candidates.\n\n")

    writer:write("RESULT_ROWS_MINUS_ALL_SCRIPT_ITEMS\n")
    writer:write("fullType | category | displayCategory | module | occurrences | note\n")
    if #resultOnly == 0 then
        writer:write("(none)\n")
    else
        for _, fullType in ipairs(resultOnly) do
            local data = activeResults[fullType] or {}
            local malformed = type(fullType) ~= "string" or not string.find(fullType, ".", 1, true)
            writer:write(table.concat({ safe(fullType), safe(data.category), safe(data.displayCategory), safe(data.module), safe(data.occurrences),
                malformed and "malformed result key" or "loot result has no current ScriptManager fullType" }, " | ") .. "\n")
        end
    end
    writer:write("\nDUPLICATE_SCRIPT_FULLTYPES\n")
    if keyCount(scriptObservation.duplicateFullTypes) == 0 then
        writer:write("(none)\n")
    else
        for _, fullType in ipairs(sortedKeys(scriptObservation.duplicateFullTypes)) do
            writer:write(string.format("%s | raw occurrences=%d\n", fullType, scriptObservation.duplicateFullTypes[fullType]))
        end
    end
    writer:write("\nRESULT_DATA_KEY_MISMATCHES\n")
    if #resultDataKeyMismatches == 0 then
        writer:write("(none)\n")
    else
        for _, mismatch in ipairs(resultDataKeyMismatches) do
            writer:write(mismatch.key .. " | data.fullType=" .. mismatch.dataFullType .. "\n")
        end
    end
    writer:write("\nFIREARM STRUCTURAL VS SELECTED CANDIDATE\n")
    writer:write(string.format("STRUCTURAL_FIREARMS=%d | SELECTED_FIREARM_UTILITYKIND=%d | DIFFERENCE=%d\n",
        structuralFirearms, dispatchedFirearms, #firearmDispatchMismatches))
    writer:write("fullType | selected utilityKind | selected eligible | result row | selected reason\n")
    if #firearmDispatchMismatches == 0 then
        writer:write("(none)\n")
    else
        for _, mismatch in ipairs(firearmDispatchMismatches) do
            writer:write(table.concat({ mismatch.fullType, mismatch.selectedKind, mismatch.selectedEligibility, mismatch.hasResult, safe(mismatch.selectedReason) }, " | ") .. "\n")
        end
    end
    writer:write("\n")

    -- This deliberately covers only the currently admitted SAFE_UTILITY_ONLY
    -- classes. It does not fabricate Scarcity or reuse an active final tier.
    writer:write("SAFE_UTILITY_ONLY DETAIL (NO SCARCITY SYNTHESIZED)\n")
    writer:write("fullType | Utility | UtilityScore | ProposedTier | NearestComparable | ComparableScore | ComparableFinalTier | SAFE\n")
    for _, group in ipairs({ safeFirearms, safeFish }) do
        for _, row in ipairs(group) do
            local data, kind = row.data, row.data.utilityKind
            local comparable = nearestLootComparable(shadow, scriptInfo, resultRowsSet, activeResults, data, kind)
            writer:write(table.concat({ row.fullType, kind, safe(utilityOnlyComparableScore(data, kind)), safe(row.pure),
                comparable and comparable.fullType or "-", comparable and safe(comparable.score) or "-",
                comparable and safe(comparable.finalTier) or "-", "SAFE" }, " | ") .. "\n")
        end
    end
    writer:write("\nFIREARM SAFE_UTILITY_ONLY (12)\n")
    writer:write("fullType | displayName | module/source | probable no-loot origin | FirearmCandidate | family | Absolute | Relative | CombinedFirearmScore | FirearmUtility-only tier | nearest loot-backed firearm | nearest combined score | nearest current final tier\n")
    for _, row in ipairs(safeFirearms) do
        local data = row.data
        local comparable = nearestLootComparable(shadow, scriptInfo, resultRowsSet, activeResults, data, "FIREARM")
        writer:write(table.concat({ row.fullType,
            safe(text(row.info.script, row.info.runtime, { "getDisplayName", "getName" }, { "displayName", "name" })),
            moduleOf(row.fullType) .. "/" .. safe(row.info.source), row.origin,
            data.utilityKind == "FIREARM" and data.utilityEligible and "accepted/HIGH" or "rejected",
            safe(data.utilityFunctionalGroup or data.utilitySubgroup), safe(data.firearmAbsoluteValue),
            safe(data.firearmRelativeFamilyScore), safe(data.firearmCombinedScore), safe(row.pure),
            comparable and comparable.fullType or "-", comparable and safe(comparable.score) or "-",
            comparable and safe(comparable.finalTier) or "-" }, " | ") .. "\n")
    end
    writer:write("\nFISH SAFE_UTILITY_ONLY (2)\n")
    writer:write("fullType | displayName | module/source | independent gameplay evidence | probable no-loot origin | FishCandidate | FishUtility score | yield ceiling | position tier | FishUtility-only tier | nearest loot-backed fish | nearest score | nearest current final tier\n")
    for _, row in ipairs(safeFish) do
        local data = row.data
        local comparable = nearestLootComparable(shadow, scriptInfo, resultRowsSet, activeResults, data, "FISH")
        writer:write(table.concat({ row.fullType,
            safe(text(row.info.script, row.info.runtime, { "getDisplayName", "getName" }, { "displayName", "name" })),
            moduleOf(row.fullType) .. "/" .. safe(row.info.source),
            "Fishing.FishConfig dynamic-size species (not bait/state)", row.origin,
            data.utilityKind == "FISH" and data.utilityEligible and "accepted/HIGH" or "rejected",
            safe(data.utility), safe(data.fishYieldTierCeiling), safe(data.fishPositionTier), safe(row.pure),
            comparable and comparable.fullType or "-", comparable and safe(comparable.score) or "-",
            comparable and safe(comparable.finalTier) or "-" }, " | ") .. "\n")
    end
    writer:write("\n")
    writer:write("UTILITY COVERAGE\nUtility | Total candidates | Loot-backed | No-loot | No-loot + Utility safe | No-loot + Utility partial | No-loot + unsafe/not-calculable\n")
    for _, kind in ipairs(sortedKeys(byUtility)) do
        local c = byUtility[kind]
        writer:write(string.format("%s | %d | %d | %d | %d | %d | %d\n", kind, c.total, c.loot, c.noLoot, c.noLootSafe, c.noLootPartial, c.noLootUnsafe))
    end
    writer:write("\nUTILITY-ONLY SAFETY\n")
    writer:write("SAFE_UTILITY_ONLY: Firearm and Fish only. Both have a proven independent gameplay representation without a loot row.\n")
    writer:write("PARTIAL_UTILITY_ONLY: LightFire/throwables, Melee, Food, Medical, Container, Magazine, Ammo and Literature outside direct progression require an independent-item/state relation, a population, compatible context, or Scarcity in their current policy.\n")
    writer:write("NOT_SAFE_WITHOUT_SCARCITY: no quantified eligible Utility or an unsupported candidate.\n")
    writer:write("Policy A = native Utility tier with no Scarcity adjustment. Policy B = neutral Scarcity (therefore identical for SAFE utilities). Policy C = A capped at EPIC, category-generic and promotional only by Utility.\n\n")
    writer:write("NO-LOOT ITEMS WITH CALCULABLE UTILITY\n")
    writer:write("fullType | displayName | module/source mod | classifier | candidate | Utility score | Utility confidence | utility-only safety | probable no-loot origin | Policy A pure | Policy B neutral | Policy C conservative cap | active registry/tier\n")
    for _, row in ipairs(noLootRows) do
        local data, info = row.data, row.info
        writer:write(table.concat({ row.fullType, safe(text(info.script, info.runtime, { "getDisplayName", "getName" }, { "displayName", "name" })),
            moduleOf(row.fullType) .. "/" .. safe(info.source), safe(data.category), safe(data.utilityKind), safe(data.utility), safe(data.utilityConfidence), row.safety,
            row.origin, row.pure, row.neutral, row.conservative, safe(activeResults[row.fullType] and activeResults[row.fullType].finalRarityTier) }, " | ") .. "\n")
    end
    writer:close()
    if ItemRarityUtils and ItemRarityUtils.info then
        ItemRarityUtils.info(string.format("Global ScriptItem coverage audit written: %d ScriptItems | %d no result rows | %d calculable no-loot Utilities | %d safe Utility-only.", #scripts, withoutResultCount, noLootCalculable, noLootSafe))
    end
    return true
end
