require "ItemRarity/RarityUtils"

-- Read-only discovery report for a future Firearm / Ammo / Magazine / Weapon
-- Part utility. It never changes candidates, FinalRarityTier, registry fields
-- or the scanner signature. Classification is structural: ranged state, item
-- fields and tags; it never relies on a name, display name or fullType list.
ItemRarityFirearmAudit = ItemRarityFirearmAudit or {}

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

local function num(script, runtime, getters, fields)
    return tonumber(value(script, runtime, getters, fields))
end

local function text(script, runtime, getters, fields)
    local result = value(script, runtime, getters, fields)
    return result == nil and "" or tostring(result)
end

local function bool(script, runtime, getters, fields)
    return value(script, runtime, getters, fields) == true
end

local function lower(value) return string.lower(tostring(value or "")) end
local function has(textValue, token) return string.find(lower(textValue), token, 1, true) ~= nil end
local function moduleOf(fullType) return string.match(tostring(fullType), "^([^.]+)%.") or "UNKNOWN" end
local function normalized(value) return string.lower(tostring(value or "")):gsub("[^%w]", "") end
local function ammoKey(value)
    local key = normalized(value)
    key = key:gsub("base", ""):gsub("bullets", ""):gsub("ammo", "")
    return key
end
local function safe(value)
    if value == nil or value == "" then return "-" end
    if type(value) == "number" then return string.format("%.3f", value) end
    return tostring(value):gsub("[\r\n|]", " ")
end

local function slash(...)
    local parts = {}
    for _, value in ipairs({ ... }) do table.insert(parts, safe(value)) end
    return table.concat(parts, "/")
end

local function join(values)
    if not values or #values == 0 then return "-" end
    table.sort(values)
    return table.concat(values, ";")
end

local function splitTargets(textValue)
    textValue = tostring(textValue or ""):gsub("[%[%]]", "")
    local values, seen = {}, {}
    for target in string.gmatch(tostring(textValue or ""), "[^;,%s]+") do
        if target ~= "" and not seen[target] then
            seen[target] = true
            table.insert(values, target)
        end
    end
    return values
end

local function structuralFullType(script)
    local fullType = call(script, "getFullName") or call(script, "getFullType")
    if fullType and tostring(fullType) ~= "" then return tostring(fullType) end
    local module = call(script, "getModuleName") or call(script, "getModule")
    local name = call(script, "getName")
    if module and name then return tostring(module) .. "." .. tostring(name) end
    return nil
end

local function findScriptItem(manager, fullType)
    if not manager or not fullType or fullType == "" then return nil end
    local ok, item = pcall(function() return manager:FindItem(fullType) end)
    return ok and item or nil
end

local function structuralMagazineRows(results)
    local manager = getScriptManager and getScriptManager() or nil
    local published, rows = {}, {}
    local seen = {}
    for fullType in pairs(results or {}) do published[fullType] = true end
    -- A script-manager global list is not exposed consistently by the B42 Lua
    -- bridge.  Resolve magazines from the structural firearm -> MagazineType
    -- relationship instead.  This remains dynamic: no magazine fullType list.
    for firearmType, data in pairs(results or {}) do
        if data.utilityKind == "FIREARM" then
            local firearm = findScriptItem(manager, firearmType)
            -- MagazineType is exposed reliably on the temporary runtime item,
            -- whereas some B42 ScriptItem bridges omit its direct getter.
            local firearmRuntime = nil
            if firearm then
                local ok, item = pcall(function() return firearm:InstanceItem(nil, false) end)
                firearmRuntime = ok and item or nil
            end
            local magazineType = text(firearm, firearmRuntime, { "getMagazineType" }, { "magazineType" })
            local script = findScriptItem(manager, magazineType)
            local fullType = structuralFullType(script) or magazineType
            if fullType and not published[fullType] and not seen[fullType] then
                local runtime = nil
                if script then
                    local ok, item = pcall(function() return script:InstanceItem(nil, false) end)
                    runtime = ok and item or nil
                end
                local ammoType = text(script, runtime, { "getAmmoType" }, { "ammoType" })
                local gunType = text(script, runtime, { "getGunType" }, { "gunType" })
                local maxAmmo = num(script, runtime, { "getMaxAmmo" }, { "maxAmmo" }) or 0
                if ammoType ~= "" and gunType ~= "" and maxAmmo > 0 then
                    seen[fullType] = true
                    table.insert(rows, {
                        fullType = fullType, module = moduleOf(fullType), ammoType = ammoType, gunType = gunType,
                        maxAmmo = maxAmmo, weight = num(script, nil, { "getActualWeight", "getWeight" }, { "actualWeight", "weight" }),
                    })
                end
            end
        end
    end
    table.sort(rows, function(a, b) return a.fullType < b.fullType end)
    return rows
end

local function runtimeFor(script)
    if not script then return nil end
    local ok, item = pcall(function() return script:InstanceItem(nil, false) end)
    return ok and item or nil
end

local function rowFor(data)
    local manager = getScriptManager and getScriptManager() or nil
    local script = manager and manager:FindItem(data.fullType) or nil
    if not script then return nil end
    local runtime = runtimeFor(script)
    local tags = lower(text(script, runtime, { "getTags" }, { "tags" }))
    local display = text(script, runtime, { "getDisplayCategory" }, { "displayCategory" })
    local itemType = text(script, runtime, { "getType", "getItemType" }, { "type", "itemType" })
    local ammoType = text(script, runtime, { "getAmmoType" }, { "ammoType" })
    local doubleClickRecipe = text(script, runtime, { "getDoubleClickRecipe" }, { "doubleClickRecipe" })
    local gunType = text(script, runtime, { "getGunType" }, { "gunType" })
    local magazineType = text(script, runtime, { "getMagazineType" }, { "magazineType" })
    local partType = text(script, runtime, { "getPartType" }, { "partType" })
    local mountOn = text(script, runtime, { "getMountOn" }, { "mountOn" })
    local attachmentType = text(script, runtime, { "getAttachmentType" }, { "attachmentType" })
    local ranged = bool(script, runtime, { "isRanged" }, { "ranged" })
    local maxAmmo = num(script, runtime, { "getMaxAmmo" }, { "maxAmmo" }) or 0
    local containerCapacity = num(script, runtime, { "getCapacity" }, { "capacity" }) or 0
    local magazine = gunType ~= "" and ammoType ~= "" and maxAmmo > 0
    local weaponPart = lower(display) == "weaponpart" or lower(itemType) == "base:weaponpart" or partType ~= "" or mountOn ~= ""
    -- Weapon cases can inherit Ranged from their underlying script class, but
    -- expose neither ammunition nor a usable firing mechanism.  Ranged alone
    -- is therefore insufficient structural evidence for a firearm.
    local firearm = ranged and ammoType ~= "" and maxAmmo > 0
    -- The broad technical AMMO category also contains traps, weapon cases and
    -- ammo containers.  Only the runtime ammo tag is enough evidence for
    -- direct ammunition; the remainder is intentionally deferred.
    -- `base:ammo` is also used by ammo straps and bags. Direct ammunition is
    -- non-container ammunition with no opening/transformation recipe.
    local ammo = not magazine and has(tags, "base:ammo") and containerCapacity <= 0 and doubleClickRecipe == ""
    local special = not firearm and not magazine and not weaponPart and not ammo
        and (data.category == "AMMO" or lower(display) == "ammo" or ranged or has(tags, "base:ammocase"))
    local kind = firearm and "FIREARM" or magazine and "MAGAZINE" or weaponPart and "WEAPON_PART" or ammo and "AMMO" or special and "SPECIAL_PARTIAL" or nil
    if not kind then return nil end

    local minDamage = num(script, runtime, { "getMinDamage" }, { "minDamage" })
    local maxDamage = num(script, runtime, { "getMaxDamage" }, { "maxDamage" })
    local maxRange = num(script, runtime, { "getMaxRange" }, { "maxRange" })
    local maxHitCount = num(script, runtime, { "getMaxHitCount" }, { "maxHitCount", "maxHitcount" }) or 1
    local fireMode = lower(text(script, runtime, { "getFireMode" }, { "fireMode" }))
    local attachmentLower = lower(attachmentType)
    local family = ""
    if firearm then
        if fireMode == "auto" then family = "AUTOMATIC_RIFLE"
        elseif string.find(lower(ammoType), "shotgun", 1, true) then family = "SHOTGUN"
        elseif string.find(attachmentLower, "holster", 1, true) then family = "HANDGUN"
        elseif (maxRange or 0) >= 25 then family = "RIFLE"
        else family = "LONG_GUN" end
    end
    local record = {
        data = data, script = script, runtime = runtime, kind = kind,
        fullType = data.fullType, module = moduleOf(data.fullType), displayCategory = display, itemType = itemType, tags = tags,
        ammoType = ammoType, gunType = gunType, magazineType = magazineType, doubleClickRecipe = doubleClickRecipe, partType = partType, mountOn = mountOn,
        family = family,
        minDamage = minDamage, maxDamage = maxDamage, averageDamage = minDamage and maxDamage and (minDamage + maxDamage) / 2 or nil,
        minRange = num(script, runtime, { "getMinRange" }, { "minRange" }), maxRange = maxRange,
        criticalChance = num(script, runtime, { "getCriticalChance" }, { "criticalChance" }),
        criticalMultiplier = num(script, runtime, { "getCriticalDamageMultiplier", "getCritDmgMultiplier" }, { "criticalDamageMultiplier", "critDmgMultiplier" }),
        aimingTime = num(script, runtime, { "getAimingTime" }, { "aimingTime", "aimingtime" }),
        reloadTime = num(script, runtime, { "getReloadTime" }, { "reloadTime", "reloadtime" }),
        recoilDelay = num(script, runtime, { "getRecoilDelay" }, { "recoilDelay" }),
        hitChance = num(script, runtime, { "getHitChance" }, { "hitChance" }),
        soundRadius = num(script, runtime, { "getSoundRadius" }, { "soundRadius" }),
        conditionMax = num(script, runtime, { "getConditionMax" }, { "conditionMax" }),
        weight = num(script, runtime, { "getActualWeight", "getWeight" }, { "actualWeight", "weight" }),
        maxAmmo = maxAmmo, containerCapacity = containerCapacity,
        stackCount = num(script, runtime, { "getCount" }, { "count" }),
        piercing = bool(script, runtime, { "isPiercingBullets" }, { "piercingBullets" }),
        maxHitCount = maxHitCount,
        attachmentType = attachmentType,
        aimingTimeModifier = num(script, runtime, { "getAimingTimeModifier" }, { "aimingTimeModifier" }),
        reloadTimeModifier = num(script, runtime, { "getReloadTimeModifier" }, { "reloadTimeModifier" }),
        recoilDelayModifier = num(script, runtime, { "getRecoilDelayModifier" }, { "recoilDelayModifier" }),
        hitChanceModifier = num(script, runtime, { "getHitChanceModifier" }, { "hitChanceModifier" }),
        maxRangeModifier = num(script, runtime, { "getMaxRangeModifier" }, { "maxRangeModifier" }),
        minSightRange = num(script, runtime, { "getMinSightRange" }, { "minSightRange" }),
        maxSightRange = num(script, runtime, { "getMaxSightRange" }, { "maxSightRange" }),
        projectileSpreadModifier = num(script, runtime, { "getProjectileSpreadModifier" }, { "projectileSpreadModifier" }),
        scarcityTier = data.baseScarcityTier or data.rarityTier,
        scarcityPercentile = data.scarcityPercentile or (data.tableAvailability and data.tableAvailability.routeWeightedPercentile),
        finalTier = data.finalRarityTier,
        occurrences = data.occurrences or 0,
    }
    record.profile = table.concat({ kind, record.family, tostring(record.ammoType), tostring(record.magazineType), tostring(record.gunType),
        tostring(record.minDamage), tostring(record.maxDamage), tostring(record.maxRange), tostring(record.maxAmmo), tostring(record.partType),
        tostring(record.mountOn), tostring(record.aimingTimeModifier), tostring(record.reloadTimeModifier), tostring(record.recoilDelayModifier),
        tostring(record.hitChanceModifier), tostring(record.maxRangeModifier) }, ":")
    return record
end

local function countProfiles(rows)
    local profiles = {}
    for _, row in ipairs(rows) do profiles[row.profile] = true end
    local total = 0; for _ in pairs(profiles) do total = total + 1 end
    return total
end

local function sorted(rows, less)
    table.sort(rows, less or function(a, b) return a.fullType < b.fullType end)
    return rows
end

local function writeRows(writer, title, rows, headers, mapper, less)
    writer:write("\n" .. title .. "\n" .. headers .. "\n")
    sorted(rows, less)
    for _, row in ipairs(rows) do
        local values = mapper(row)
        for index, value in ipairs(values) do values[index] = safe(value) end
        writer:write(table.concat(values, " | ") .. "\n")
    end
end

local function clamp(value, low, high)
    return math.max(low, math.min(high, value or 0))
end

local function uniqueProfiles(rows)
    -- The active calculator establishes a fullType order before it keeps one
    -- representative per structural profile.  Do the same here: `rows` was
    -- originally fed from pairs(results), whose traversal order must never
    -- choose a different vanilla reference or silently move score anchors.
    local ordered = {}
    for _, row in ipairs(rows) do table.insert(ordered, row) end
    table.sort(ordered, function(a, b) return tostring(a.fullType or "") < tostring(b.fullType or "") end)
    local profiles, seen = {}, {}
    for _, row in ipairs(ordered) do
        if not seen[row.profile] then
            seen[row.profile] = true
            table.insert(profiles, row)
        end
    end
    return profiles
end

local function rangeScale(rows, selector, invert)
    local low, high = nil, nil
    for _, row in ipairs(rows) do
        local value = selector(row)
        if value ~= nil then
            low = low == nil and value or math.min(low, value)
            high = high == nil and value or math.max(high, value)
        end
    end
    return function(value)
        if value == nil then return nil end
        if low == nil or high == nil or high <= low then return 50 end
        local score = (value - low) * 100 / (high - low)
        return invert and 100 - score or score
    end
end

local function confidence(count)
    if count >= 8 then return "HIGH" end
    if count >= 4 then return "MEDIUM" end
    return "LOW"
end

local function tierRank(tier)
    return ({ COMMON = 1, UNCOMMON = 2, RARE = 3, EPIC = 4, EXOTIC = 5 })[tier] or 1
end

local function tierForScore(score)
    if score >= 80 then return "EXOTIC" end
    if score >= 60 then return "EPIC" end
    if score >= 40 then return "RARE" end
    if score >= 20 then return "UNCOMMON" end
    return "COMMON"
end

-- Diagnostic-only reuse of the existing Scarcity × Utility semantics. This is
-- deliberately not called by the active FinalRarityTier pipeline.
local function hypotheticalTier(scarcity, utilityScore)
    local utilityTier = tierForScore(utilityScore)
    local s, u = tierRank(scarcity), tierRank(utilityTier)
    if s == 1 then return u >= 4 and "UNCOMMON" or "COMMON" end
    if s == 2 then return u >= 4 and "RARE" or "UNCOMMON" end
    if s == 3 then return u >= 4 and "EPIC" or "RARE" end
    if s == 4 then return u >= 5 and "EXOTIC" or (u >= 3 and "EPIC" or "RARE") end
    return u >= 4 and "EXOTIC" or (u >= 2 and "EPIC" or "RARE")
end

-- Firearms deliberately use their own diagnostic tier policy.  Unlike the
-- generic Scarcity x Utility matrix, combat quality is primary here and
-- scarcity is examined only as a deliberately tiny optional refinement.
local function firearmTierForScore(score)
    if score >= 85 then return "EXOTIC" end
    if score >= 70 then return "EPIC" end
    if score >= 55 then return "RARE" end
    if score >= 40 then return "UNCOMMON" end
    return "COMMON"
end

local function firearmScarcityStrength(row)
    local percentile = tonumber(row.scarcityPercentile)
    -- Lower availability percentile means scarcer.  Missing data is neutral
    -- in this diagnostic rather than silently manufacturing rarity.
    return percentile and clamp(100 - percentile, 0, 100) or 50
end

local function writeUtilitySimulation(writer, firearms)
    local families = {}
    local absoluteBounds = { damage = 0, range = 0, capacity = 0, weight = 0, recoil = 0, aim = 0, reload = 0, sound = 0 }
    for _, row in ipairs(firearms) do
        families[row.family] = families[row.family] or {}
        table.insert(families[row.family], row)
        absoluteBounds.damage = math.max(absoluteBounds.damage, row.averageDamage or 0)
        absoluteBounds.range = math.max(absoluteBounds.range, row.maxRange or 0)
        absoluteBounds.capacity = math.max(absoluteBounds.capacity, row.maxAmmo or 0)
        absoluteBounds.weight = math.max(absoluteBounds.weight, row.weight or 0)
        absoluteBounds.recoil = math.max(absoluteBounds.recoil, row.recoilDelay or 0)
        absoluteBounds.aim = math.max(absoluteBounds.aim, row.aimingTime or 0)
        absoluteBounds.reload = math.max(absoluteBounds.reload, row.reloadTime or 0)
        absoluteBounds.sound = math.max(absoluteBounds.sound, row.soundRadius or 0)
    end
    writer:write("\nFIREARMUTILITY DIAGNOSTIC SIMULATION (READ ONLY)\n")
    writer:write("Offense=45% (average damage 75%, sqrt-saturated multi-hit 25%); Range=20%; Capacity=20%; Handling=15%.\n")
    writer:write("Handling is inverted weight/recoil/aim/reload/sound where the field is available. Range normalizes within family. No ammo availability is used.\n")
    writer:write(string.format("Absolute bounds from loaded structural firearms: avgDamage=%.3f | range=%.3f | capacity=%.3f | weight=%.3f | recoil=%.3f | aim=%.3f | reload=%.3f | sound=%.3f.\n", absoluteBounds.damage, absoluteBounds.range, absoluteBounds.capacity, absoluteBounds.weight, absoluteBounds.recoil, absoluteBounds.aim, absoluteBounds.reload, absoluteBounds.sound))
    local names = {}; for family in pairs(families) do table.insert(names, family) end; table.sort(names)
    for _, family in ipairs(names) do
        local rows = families[family]
        local profiles = uniqueProfiles(rows)
        local profileCount = #profiles
        local damageScale = rangeScale(profiles, function(r) return r.averageDamage end, false)
        local multiScale = rangeScale(profiles, function(r) return math.sqrt(clamp(r.maxHitCount or 1, 1, 9)) end, false)
        local rangeScore = rangeScale(profiles, function(r) return r.maxRange end, false)
        local capacityScale = rangeScale(profiles, function(r) return r.maxAmmo end, false)
        local weightScale = rangeScale(profiles, function(r) return r.weight end, true)
        local recoilScale = rangeScale(profiles, function(r) return r.recoilDelay end, true)
        local aimScale = rangeScale(profiles, function(r) return r.aimingTime end, true)
        local reloadScale = rangeScale(profiles, function(r) return r.reloadTime end, true)
        local soundScale = rangeScale(profiles, function(r) return r.soundRadius end, true)
        for _, row in ipairs(rows) do
            local damage = damageScale(row.averageDamage) or 50
            local multi = multiScale(math.sqrt(clamp(row.maxHitCount or 1, 1, 9))) or 50
            -- Saturation keeps a 9-target shotgun useful without granting a
            -- linear ninefold advantage over a single-target firearm.
            local offense = .75 * damage + .25 * multi
            local handlingParts = { weightScale(row.weight), recoilScale(row.recoilDelay), aimScale(row.aimingTime), reloadScale(row.reloadTime), soundScale(row.soundRadius) }
            local total, count = 0, 0
            for _, part in ipairs(handlingParts) do if part ~= nil then total = total + part; count = count + 1 end end
            local handling = count > 0 and total / count or 50
            row.firearmOffense = offense
            row.firearmRange = rangeScore(row.maxRange) or 50
            row.firearmCapacity = capacityScale(row.maxAmmo) or 50
            row.firearmHandling = handling
            row.firearmUtility = .45 * offense + .20 * row.firearmRange + .20 * row.firearmCapacity + .15 * handling
            local absoluteDamage = absoluteBounds.damage > 0 and 100 * (row.averageDamage or 0) / absoluteBounds.damage or 0
            local absoluteMulti = 100 * (math.sqrt(clamp(row.maxHitCount or 1, 1, 9)) - 1) / (math.sqrt(9) - 1)
            local absoluteOffense = .75 * absoluteDamage + .25 * absoluteMulti
            local absoluteRange = absoluteBounds.range > 0 and 100 * (row.maxRange or 0) / absoluteBounds.range or 0
            local absoluteCapacity = absoluteBounds.capacity > 0 and 100 * (row.maxAmmo or 0) / absoluteBounds.capacity or 0
            local costs = {
                absoluteBounds.weight > 0 and 100 * (1 - (row.weight or 0) / absoluteBounds.weight) or nil,
                absoluteBounds.recoil > 0 and 100 * (1 - (row.recoilDelay or 0) / absoluteBounds.recoil) or nil,
                absoluteBounds.aim > 0 and 100 * (1 - (row.aimingTime or 0) / absoluteBounds.aim) or nil,
                absoluteBounds.reload > 0 and 100 * (1 - (row.reloadTime or 0) / absoluteBounds.reload) or nil,
                absoluteBounds.sound > 0 and 100 * (1 - (row.soundRadius or 0) / absoluteBounds.sound) or nil,
            }
            local costTotal, costCount = 0, 0
            for _, cost in ipairs(costs) do if cost ~= nil then costTotal = costTotal + clamp(cost, 0, 100); costCount = costCount + 1 end end
            row.absoluteHandling = costCount > 0 and costTotal / costCount or 50
            row.absoluteFirearmValue = .45 * absoluteOffense + .20 * absoluteRange + .20 * absoluteCapacity + .15 * row.absoluteHandling
        end
        local ordered = {}
        for _, row in ipairs(rows) do table.insert(ordered, row) end
        table.sort(ordered, function(a, b) return a.firearmUtility == b.firearmUtility and a.fullType < b.fullType or a.firearmUtility > b.firearmUtility end)
        local rankByProfile, uniqueRank = {}, 0
        for _, row in ipairs(ordered) do if not rankByProfile[row.profile] then uniqueRank = uniqueRank + 1; rankByProfile[row.profile] = uniqueRank end end
        writer:write(string.format("\n[%s] fullTypes=%d | uniqueProfiles=%d | RankingConfidence=%s\n", family, #rows, profileCount, confidence(profileCount)))
        writer:write("fullType | damage avg | range | multiHit | capacity | AbsoluteFirearmValue | RelativeFamilyScore | combinedScore | profileRank | profilePct | Scarcity | currentTier | hypotheticalTier | RankingConfidence\n")
        for _, row in ipairs(ordered) do
            local rank = rankByProfile[row.profile]
            local pct = profileCount <= 1 and 50 or (profileCount - rank) * 100 / (profileCount - 1)
            local rankingConfidence = confidence(profileCount)
            local relativeWeight = rankingConfidence == "HIGH" and .40 or (rankingConfidence == "MEDIUM" and .25 or .10)
            row.combinedFirearmScore = (1 - relativeWeight) * row.absoluteFirearmValue + relativeWeight * row.firearmUtility
            writer:write(string.format("%s | %.3f | %.3f | %s | %s | %.2f | %.2f | %.2f | %d/%d | %.2f | %s | %s | %s | %s\n",
                row.fullType, row.averageDamage or 0, row.maxRange or 0, safe(row.maxHitCount), safe(row.maxAmmo), row.absoluteFirearmValue, row.firearmUtility, row.combinedFirearmScore, rank, profileCount, pct, safe(row.scarcityTier), safe(row.finalTier), hypotheticalTier(row.scarcityTier, row.combinedFirearmScore), rankingConfidence))
        end
    end
end

local function percentile(values, fraction)
    if #values == 0 then return 0 end
    table.sort(values)
    local index = 1 + (#values - 1) * fraction
    local low, high = math.floor(index), math.ceil(index)
    if low == high then return values[low] end
    return values[low] + (values[high] - values[low]) * (index - low)
end

local function robustScale(values)
    local copy = {}; for _, value in ipairs(values) do table.insert(copy, value) end
    local low, high = percentile(copy, .05), percentile(copy, .95)
    return function(value)
        if high <= low then return 50 end
        return clamp((value - low) * 100 / (high - low), 0, 100)
    end, low, high
end

local function criticalRaw(row)
    return (row.criticalChance or 0) * (row.criticalMultiplier or 0)
end

local function buildCombatScores(rows, referenceRows)
    local profiles = uniqueProfiles(referenceRows or rows)
    local function values(selector)
        local out = {}; for _, row in ipairs(profiles) do table.insert(out, selector(row) or 0) end; return out
    end
    local damage, damageP05, damageP95 = robustScale(values(function(r) return r.averageDamage end))
    local multi, multiP05, multiP95 = robustScale(values(function(r) return math.sqrt(clamp(r.maxHitCount or 1, 1, 9)) end))
    local critical, criticalP05, criticalP95 = robustScale(values(criticalRaw))
    local range, rangeP05, rangeP95 = robustScale(values(function(r) return r.maxRange end))
    local capacity, capacityP05, capacityP95 = robustScale(values(function(r) return r.maxAmmo end))
    local weight, weightP05, weightP95 = robustScale(values(function(r) return r.weight end))
    local recoil, recoilP05, recoilP95 = robustScale(values(function(r) return r.recoilDelay end))
    local aim, aimP05, aimP95 = robustScale(values(function(r) return r.aimingTime end))
    local reload, reloadP05, reloadP95 = robustScale(values(function(r) return r.reloadTime end))
    local sound, soundP05, soundP95 = robustScale(values(function(r) return r.soundRadius end))
    local scoreByProfile = {}
    for _, row in ipairs(rows) do
        local offense = .70 * damage(row.averageDamage or 0) + .20 * multi(math.sqrt(clamp(row.maxHitCount or 1, 1, 9))) + .10 * critical(criticalRaw(row))
        local handling = .30 * (100 - recoil(row.recoilDelay or 0)) + .25 * (100 - aim(row.aimingTime or 0))
            + .25 * (100 - reload(row.reloadTime or 0)) + .15 * (100 - weight(row.weight or 0)) + .05 * (100 - sound(row.soundRadius or 0))
        local rangeScore, capacityScore = range(row.maxRange or 0), capacity(row.maxAmmo or 0)
        row.combatOffense, row.combatHandling, row.combatRange, row.combatCapacity = offense, handling, rangeScore, capacityScore
        row.combatRawA = .55 * offense + .20 * capacityScore + .20 * handling + .05 * rangeScore
        row.combatRawB = .50 * offense + .20 * capacityScore + .20 * handling + .10 * rangeScore
        scoreByProfile[row.profile] = row
    end
    return profiles, {
        damage = { p05 = damageP05, p95 = damageP95 }, multiHit = { p05 = multiP05, p95 = multiP95 }, critical = { p05 = criticalP05, p95 = criticalP95 },
        range = { p05 = rangeP05, p95 = rangeP95 }, capacity = { p05 = capacityP05, p95 = capacityP95 }, weight = { p05 = weightP05, p95 = weightP95 },
        recoil = { p05 = recoilP05, p95 = recoilP95 }, aiming = { p05 = aimP05, p95 = aimP95 }, reload = { p05 = reloadP05, p95 = reloadP95 }, sound = { p05 = soundP05, p95 = soundP95 },
    }
end

local function writeCombatRecalibration(writer, firearms)
    local vanilla = {}
    for _, row in ipairs(firearms) do if row.module == "Base" then table.insert(vanilla, row) end end
    -- The reference population is vanilla only. Modded firearms can be scored
    -- against the same frozen transforms later, but never redefine the scale.
    local vanillaProfiles, simulationBounds = buildCombatScores(firearms, vanilla)
    -- Keep the vanilla-referenced component pass before each family pass
    -- overwrites `combat*` with its relative values. This is diagnostic data
    -- used to verify runtime integration, never an active score input.
    for _, row in ipairs(firearms) do
        row.globalOffense = row.combatOffense
        row.globalCapacity = row.combatCapacity
        row.globalHandling = row.combatHandling
        row.globalRange = row.combatRange
        row.globalRawB = row.combatRawB
    end
    local rawA, rawB = {}, {}
    for _, row in ipairs(firearms) do row.vanillaRawA, row.vanillaRawB = row.combatRawA, row.combatRawB end
    for _, row in ipairs(vanillaProfiles) do table.insert(rawA, row.combatRawA); table.insert(rawB, row.combatRawB) end
    local absoluteA, lowA, highA = robustScale(rawA)
    local absoluteB, lowB, highB = robustScale(rawB)
    local families = {}; for _, row in ipairs(firearms) do families[row.family] = families[row.family] or {}; table.insert(families[row.family], row) end
    writer:write("\nFIREARMUTILITY RECALIBRATION A/B (READ ONLY)\n")
    writer:write("A=Offense55/Capacity20/Handling20/Range5. B=Offense50/Capacity20/Handling20/Range10. Offense=Damage70/MultiHit20/Critical10. Handling=Recoil30/Aim25/Reload25/Weight15/Sound5.\n")
    writer:write(string.format("Vanilla-only robust absolute reference: A raw p05=%.2f p95=%.2f | B raw p05=%.2f p95=%.2f. Mods never participate in these anchors.\n", lowA, highA, lowB, highB))
    local activeBounds = ItemRarityUtilityCalculator and ItemRarityUtilityCalculator.lastFirearmNormalizationBounds or nil
    writer:write("SIMULATION vs ACTIVE NORMALIZATION BOUNDS (p05/p95; vanilla profiles only)\n")
    writer:write("axis | simulation p05/p95 | active p05/p95\n")
    for _, axis in ipairs({ "damage", "multiHit", "critical", "range", "capacity", "weight", "recoil", "aiming", "reload", "sound" }) do
        local sim = simulationBounds[axis] or {}
        local active = activeBounds and activeBounds.components and activeBounds.components[axis] or {}
        writer:write(string.format("%s | %.6f/%.6f | %.6f/%.6f\n", axis, sim.p05 or 0, sim.p95 or 0, active.p05 or 0, active.p95 or 0))
    end
    writer:write(string.format("reference profiles | %d | %d\n", #vanillaProfiles, activeBounds and activeBounds.referenceProfiles or 0))
    local names = {}; for family in pairs(families) do table.insert(names, family) end; table.sort(names)
    for _, family in ipairs(names) do
        local rows = families[family]
        -- Family scores retain the same component model but use only direct
        -- alternatives. They refine, never replace, absolute value.
        buildCombatScores(rows)
        local profileCount = #uniqueProfiles(rows)
        local rankConfidence = confidence(profileCount)
        local relativeWeight = rankConfidence == "HIGH" and .40 or (rankConfidence == "MEDIUM" and .25 or .10)
        for _, row in ipairs(rows) do
            row.absoluteA, row.absoluteB = absoluteA(row.vanillaRawA or row.combatRawA), absoluteB(row.vanillaRawB or row.combatRawB)
            -- buildCombatScores(rows) has just made its components relative to
            -- this family; calculate the family refinements from that pass.
            row.relativeA = .55 * row.combatOffense + .20 * row.combatCapacity + .20 * row.combatHandling + .05 * row.combatRange
            row.relativeB = .50 * row.combatOffense + .20 * row.combatCapacity + .20 * row.combatHandling + .10 * row.combatRange
            row.combinedA = (1 - relativeWeight) * row.absoluteA + relativeWeight * row.relativeA
            row.combinedB = (1 - relativeWeight) * row.absoluteB + relativeWeight * row.relativeB
            row.rankingConfidence = rankConfidence
            row.firearmScarcityStrength = firearmScarcityStrength(row)
            row.firearmScoreWithScarcityA = .95 * row.combinedA + .05 * row.firearmScarcityStrength
            row.firearmScoreWithScarcityB = .95 * row.combinedB + .05 * row.firearmScarcityStrength
        end
        table.sort(rows, function(a, b) return a.combinedA == b.combinedA and a.fullType < b.fullType or a.combinedA > b.combinedA end)
        writer:write(string.format("\n[%s] fullTypes=%d | uniqueProfiles=%d | RankingConfidence=%s | relativeWeight=%.0f%%\n", family, #rows, profileCount, rankConfidence, relativeWeight * 100))
        writer:write("fullType | Offense | Capacity | Handling | Range | Absolute A | Relative A | Combined A | Hypo A | Absolute B | Relative B | Combined B | Hypo B | Scarcity | RankingConfidence\n")
        for _, row in ipairs(rows) do
            writer:write(string.format("%s | %.2f | %.2f | %.2f | %.2f | %.2f | %.2f | %.2f | %s | %.2f | %.2f | %.2f | %s | %s | %s\n", row.fullType, row.combatOffense, row.combatCapacity, row.combatHandling, row.combatRange, row.absoluteA, row.relativeA, row.combinedA, hypotheticalTier(row.scarcityTier, row.combinedA), row.absoluteB, row.relativeB, row.combinedB, hypotheticalTier(row.scarcityTier, row.combinedB), safe(row.scarcityTier), rankConfidence))
        end
    end

    -- This is the requested firearm-only tier-policy comparison.  It is
    -- written after every family has been scored so the 22 records can be
    -- inspected in one mechanically ordered list.  It is report-only.
    local ordered = {}
    for _, row in ipairs(firearms) do table.insert(ordered, row) end
    table.sort(ordered, function(a, b)
        if a.combinedA == b.combinedA then return a.fullType < b.fullType end
        return a.combinedA > b.combinedA
    end)
    writer:write("\nFIREARM TIER POLICY SIMULATION (READ ONLY; NO ACTIVE INTEGRATION)\n")
    writer:write("Utility-pure: <40 COMMON | 40-54.99 UNCOMMON | 55-69.99 RARE | 70-84.99 EPIC | >=85 EXOTIC.\n")
    writer:write("Scarcity-adjusted comparison: 95% CombinedFirearmScore + 5% ScarcityStrength, where ScarcityStrength = 100 - ScarcityPercentile.\n")
    writer:write("fullType | family | simB Off/Cap/Handling/Range | active Off/Cap/Handling/Range | simB Absolute/Relative/Combined/Final | active Absolute/Relative/Combined/Final | activeTier | Utility tier B | Adjusted tier B\n")
    local distributionA, distributionAdjustedA, distributionB, distributionAdjustedB = {}, {}, {}, {}
    for _, tier in ipairs({ "COMMON", "UNCOMMON", "RARE", "EPIC", "EXOTIC" }) do
        distributionA[tier], distributionAdjustedA[tier], distributionB[tier], distributionAdjustedB[tier] = 0, 0, 0, 0
    end
    for _, row in ipairs(ordered) do
        local pureA, adjustedA = firearmTierForScore(row.combinedA), firearmTierForScore(row.firearmScoreWithScarcityA)
        local pureB, adjustedB = firearmTierForScore(row.combinedB), firearmTierForScore(row.firearmScoreWithScarcityB)
        distributionA[pureA] = distributionA[pureA] + 1
        distributionAdjustedA[adjustedA] = distributionAdjustedA[adjustedA] + 1
        distributionB[pureB] = distributionB[pureB] + 1
        distributionAdjustedB[adjustedB] = distributionAdjustedB[adjustedB] + 1
        local active = row.data.utilityComponents or {}
        writer:write(string.format("%s | %s | %.3f/%.3f/%.3f/%.3f | %.3f/%.3f/%.3f/%.3f | %.3f/%.3f/%.3f/%.3f | %.3f/%.3f/%.3f/%.3f | %s | %s | %s\n",
            row.fullType, row.family,
            row.globalOffense, row.globalCapacity, row.globalHandling, row.globalRange,
            active.offense or 0, active.capacity or 0, active.handling or 0, active.range or 0,
            row.absoluteB, row.relativeB, row.combinedB, row.firearmScoreWithScarcityB,
            row.data.firearmAbsoluteValue or 0, row.data.firearmRelativeFamilyScore or 0, row.data.firearmCombinedScore or 0, row.data.firearmFinalScore or 0,
            safe(row.data.finalRarityTier), pureB, adjustedB))
    end
    writer:write(string.format("DISTRIBUTION A pure C/U/R/E/X = %d/%d/%d/%d/%d | A adjusted = %d/%d/%d/%d/%d\n",
        distributionA.COMMON, distributionA.UNCOMMON, distributionA.RARE, distributionA.EPIC, distributionA.EXOTIC,
        distributionAdjustedA.COMMON, distributionAdjustedA.UNCOMMON, distributionAdjustedA.RARE, distributionAdjustedA.EPIC, distributionAdjustedA.EXOTIC))
    writer:write(string.format("DISTRIBUTION B pure C/U/R/E/X = %d/%d/%d/%d/%d | B adjusted = %d/%d/%d/%d/%d\n",
        distributionB.COMMON, distributionB.UNCOMMON, distributionB.RARE, distributionB.EPIC, distributionB.EXOTIC,
        distributionAdjustedB.COMMON, distributionAdjustedB.UNCOMMON, distributionAdjustedB.RARE, distributionAdjustedB.EPIC, distributionAdjustedB.EXOTIC))
end

-- MagazineUtility is deliberately contextual: capacity is meaningful only
-- together with the firearm that accepts the magazine.  This report remains
-- read-only and uses the already-published FirearmUtility V1 score.
local function writeMagazineUtilitySimulation(writer, magazines, results)
    local firearms = {}
    for fullType, data in pairs(results or {}) do
        if data.utilityKind == "FIREARM" and data.firearmFinalScore ~= nil then
            firearms[fullType] = tonumber(data.firearmFinalScore)
        end
    end
    writer:write("\nMAGAZINEUTILITY CONTEXTUAL SIMULATION (READ ONLY)\n")
    writer:write("MagazineUtility = 70% best compatible FirearmUtility V1 + 30% CapacityValue. CapacityValue = 100 * MaxAmmo / (MaxAmmo + 10). No Scarcity. Tier is capped at EPIC.\n")
    writer:write("fullType | published | ammoType | compatible firearms | best firearm value | average firearm value | MaxAmmo | CapacityValue | MagazineUtility | hypothetical tier\n")
    local function writeOne(row, published)
        local compatible, values = splitTargets(row.gunType), {}
        for _, fullType in ipairs(compatible) do if firearms[fullType] ~= nil then table.insert(values, firearms[fullType]) end end
        table.sort(values)
        local best = values[#values]
        local total = 0; for _, value in ipairs(values) do total = total + value end
        local average = #values > 0 and total / #values or nil
        local capacityValue = 100 * (row.maxAmmo or 0) / ((row.maxAmmo or 0) + 10)
        local score = best and (.70 * best + .30 * capacityValue) or nil
        local tier = score and firearmTierForScore(score) or "PARTIAL"
        if tier == "EXOTIC" then tier = "EPIC" end
        writer:write(string.format("%s | %s | %s | %s | %s | %s | %.3f | %.3f | %s | %s\n",
            row.fullType, published and "YES" or "NO", row.ammoType, join(compatible),
            best and string.format("%.3f", best) or "-", average and string.format("%.3f", average) or "-",
            row.maxAmmo or 0, capacityValue, score and string.format("%.3f", score) or "-", tier))
    end
    for _, row in ipairs(magazines) do writeOne(row, true) end
    local structuralOnly = structuralMagazineRows(results)
    if #structuralOnly > 0 then
        writer:write("STRUCTURAL MAGAZINES OUTSIDE THE PUBLISHED LOOT REGISTRY\n")
        for _, row in ipairs(structuralOnly) do writeOne(row, false) end
    end
end

local TIER_INDEX = { COMMON = 1, UNCOMMON = 2, RARE = 3, EPIC = 4, EXOTIC = 5 }
local function higherTier(left, right)
    if not left or (TIER_INDEX[right] or 0) > (TIER_INDEX[left] or 0) then return right end
    return left
end

-- Direct ammunition is matched to firearm-declared AmmoType using the same
-- normalized script identifier bridge used in the earlier structural audit.
-- Boxes are reported separately: a DoubleClickRecipe identifies an opening
-- transformation, but B42's public Item bridge does not expose that recipe's
-- mapped output item reliably enough to inherit a tier yet.
local function writeAmmoTierSimulation(writer, ammoRows, specialRows, firearmsByAmmo, results)
    writer:write("\nAMMO TIER INHERITANCE SIMULATION (READ ONLY)\n")
    writer:write("Direct ammo tier = highest FinalFirearmTier among structurally compatible firearms. No scarcity, quantity or separate AmmoUtility.\n")
    writer:write("fullType | compatible firearms | inherited firearm tier | current FinalTier | status\n")
    for _, row in ipairs(ammoRows) do
        local compatible = firearmsByAmmo[ammoKey(row.fullType)] or firearmsByAmmo[ammoKey(row.ammoType)] or {}
        local tier = nil
        for _, firearm in ipairs(compatible) do
            local data = results[firearm]
            tier = higherTier(tier, data and data.finalRarityTier or nil)
        end
        writer:write(string.format("%s | %s | %s | %s | %s\n", row.fullType, join(compatible), safe(tier), safe(row.finalTier), tier and "DIRECT_AMMO" or "SPECIAL_PARTIAL: no reliable firearm link"))
    end
    writer:write("\nAMMO BOX / CARTON STRUCTURAL CANDIDATES\n")
    writer:write("fullType | opening recipe | tags | current FinalTier | proposed status\n")
    for _, row in ipairs(specialRows) do
        if row.doubleClickRecipe ~= "" or has(row.tags, "base:ammocase") then
            local status = row.doubleClickRecipe ~= "" and "PARTIAL: opening recipe declared; output link unavailable via public bridge" or "SPECIAL_PARTIAL: ammo container without declared output link"
            writer:write(string.format("%s | %s | %s | %s | %s\n", row.fullType, safe(row.doubleClickRecipe), safe(row.tags), safe(row.finalTier), status))
        end
    end
end

function ItemRarityFirearmAudit.write(results)
    if type(results) ~= "table" or not getFileWriter then return nil end
    local groups = { FIREARM = {}, AMMO = {}, MAGAZINE = {}, WEAPON_PART = {}, SPECIAL_PARTIAL = {} }
    for _, data in pairs(results) do
        local row = rowFor(data)
        if row then table.insert(groups[row.kind], row) end
    end
    for _, rows in pairs(groups) do sorted(rows) end

    local firearmsByAmmo, firearmsByMagazine = {}, {}
    for _, row in ipairs(groups.FIREARM) do
        local ammoToken, magKey = ammoKey(row.ammoType), normalized(row.magazineType)
        if ammoToken ~= "" then firearmsByAmmo[ammoToken] = firearmsByAmmo[ammoToken] or {}; table.insert(firearmsByAmmo[ammoToken], row.fullType) end
        if magKey ~= "" then firearmsByMagazine[magKey] = firearmsByMagazine[magKey] or {}; table.insert(firearmsByMagazine[magKey], row.fullType) end
    end

    local vanilla, modded = 0, 0
    for _, rows in pairs(groups) do for _, row in ipairs(rows) do if row.module == "Base" then vanilla = vanilla + 1 else modded = modded + 1 end end end
    local writer = getFileWriter("ItemRarity_FirearmAmmoAudit.txt", true, false)
    if not writer then return nil end
    writer:write("Item Rarity FIREARM / AMMO / MAGAZINE / WEAPON_PART structural audit (READ ONLY)\n")
    writer:write("No Utility, FinalRarityTier, registry, UI, scanner classification or signature is changed. Families are derived from ranged state + declared weapon fields, not names.\n")
    writer:write(string.format("CANDIDATES=%d | VANILLA=%d | MODDED=%d\n", vanilla + modded, vanilla, modded))
    for _, kind in ipairs({ "FIREARM", "AMMO", "MAGAZINE", "WEAPON_PART", "SPECIAL_PARTIAL" }) do
        writer:write(string.format("%s | fullTypes=%d | mechanicalProfiles=%d\n", kind, #groups[kind], countProfiles(groups[kind])))
    end

    writeRows(writer, "FIREARMS", groups.FIREARM,
        "fullType | module | family | ammoType | magazineType | clip/maxAmmo | min/max/avgDamage | min/maxRange | crit/chance | aiming/reload/recoil | hitChance | soundRadius | conditionMax | weight | piercing | multihit | attachmentType | occurrences | ScarcityTier | ScarcityPct | AuditProfile | ActiveProfile | ActiveKind | ActiveProfiles | ActiveAvg/Range/Cap/Multi/CritChance/CritMult/Recoil/Aim/Reload/Weight/Sound | ActiveAbsOffense/Capacity/Handling/Range | ActiveAbsolute | ActiveRelative | ActiveRankConfidence | ActiveCombined | ActiveScarcityStrength | ActiveFinalScore | FinalTier",
        function(r)
            local c = r.data.utilityComponents or {}
            local m = r.data.utilityMetrics or {}
            return { r.fullType, r.module, r.family, r.ammoType, r.magazineType, r.maxAmmo, slash(r.minDamage, r.maxDamage, r.averageDamage), slash(r.minRange, r.maxRange), slash(r.criticalChance, r.criticalMultiplier), slash(r.aimingTime, r.reloadTime, r.recoilDelay), r.hitChance, r.soundRadius, r.conditionMax, r.weight, r.piercing, r.maxHitCount, r.attachmentType, r.occurrences, r.scarcityTier, r.scarcityPercentile, r.profile, r.data.utilityProfile, r.data.utilityKind, r.data.utilityProfileCount, slash(m.averageDamage, m.maxRange, m.maxAmmo, m.maxHitCount, m.criticalChance, m.criticalMultiplier, m.recoilDelay, m.aimingTime, m.reloadTime, m.weight, m.soundRadius), slash(c.offense, c.capacity, c.handling, c.range), r.data.firearmAbsoluteValue, r.data.firearmRelativeFamilyScore, r.data.firearmRankingConfidence, r.data.firearmCombinedScore, r.data.firearmScarcityStrength, r.data.firearmFinalScore, r.finalTier }
        end,
        function(a,b) return (a.averageDamage or 0) == (b.averageDamage or 0) and a.fullType < b.fullType or (a.averageDamage or 0) > (b.averageDamage or 0) end)

    writeRows(writer, "AMMO", groups.AMMO,
        "fullType | module | ammoKey | stackCount | weight | compatibleFirearms | occurrences | ScarcityTier | ScarcityPct | ActiveKind | ActiveInheritedTier | ActiveCompatibleFirearms | FinalTier | tags",
        function(r)
            local compatible = firearmsByAmmo[ammoKey(r.fullType)] or firearmsByAmmo[ammoKey(r.ammoType)] or {}
            return { r.fullType, r.module, r.ammoType ~= "" and r.ammoType or ammoKey(r.fullType), r.stackCount, r.weight, join(compatible), r.occurrences, r.scarcityTier, r.scarcityPercentile, safe(r.data.utilityKind), safe(r.data.ammoInheritedFirearmTier), safe(join(r.data.ammoCompatibleFirearms or {})), r.finalTier, r.tags }
        end)

    writeRows(writer, "MAGAZINES", groups.MAGAZINE,
        "fullType | module | ammoType | capacity | GunType declared | compatibleFirearms | weight | occurrences | ScarcityTier | ScarcityPct | ActiveKind | ActiveMetricGunType | ActiveUtility | ActiveMagazineScore | ActiveReason | FinalTier | tags",
        function(r)
            local compatible, seen = splitTargets(r.gunType), {}
            for _, value in ipairs(compatible) do seen[value] = true end
            for _, value in ipairs(firearmsByMagazine[normalized(r.fullType)] or {}) do if not seen[value] then seen[value] = true; table.insert(compatible, value) end end
            return { r.fullType, r.module, r.ammoType, r.maxAmmo, r.gunType, join(compatible), r.weight, r.occurrences, r.scarcityTier, r.scarcityPercentile,
                safe(r.data.utilityKind), safe(r.data.utilityMetrics and r.data.utilityMetrics.gunType), safe(r.data.utility), safe(r.data.magazineFinalScore), safe(r.data.utilityAdjustmentReason), r.finalTier, r.tags }
        end)

    writeMagazineUtilitySimulation(writer, groups.MAGAZINE, results)
    writeAmmoTierSimulation(writer, groups.AMMO, groups.SPECIAL_PARTIAL, firearmsByAmmo, results)

    writeRows(writer, "WEAPON PARTS", groups.WEAPON_PART,
        "fullType | module | PartType | MountOn compatible firearms | aimingMod | reloadMod | recoilMod | hitChanceMod | rangeMod | sightMin/Max | spreadMod | weight | occurrences | ScarcityTier | ScarcityPct | FinalTier | tags",
        function(r) return { safe(r.fullType), safe(r.module), safe(r.partType), safe(join(splitTargets(r.mountOn))), safe(r.aimingTimeModifier), safe(r.reloadTimeModifier), safe(r.recoilDelayModifier), safe(r.hitChanceModifier), safe(r.maxRangeModifier), safe(slash(r.minSightRange, r.maxSightRange)), safe(r.projectileSpreadModifier), safe(r.weight), safe(r.occurrences), safe(r.scarcityTier), safe(r.scarcityPercentile), safe(r.finalTier), safe(r.tags) } end)

    writeRows(writer, "SPECIAL / PARTIAL", groups.SPECIAL_PARTIAL,
        "fullType | module | displayCategory | itemType | tags | occurrences | ScarcityTier | ScarcityPct | FinalTier",
        function(r) return { r.fullType, r.module, r.displayCategory, r.itemType, r.tags, r.occurrences, r.scarcityTier, r.scarcityPercentile, r.finalTier } end)

    writeUtilitySimulation(writer, groups.FIREARM)
    writeCombatRecalibration(writer, groups.FIREARM)

    writer:write("\nFAMILY COUNTS\nfamily | fullTypes\n")
    local families = {}
    for _, row in ipairs(groups.FIREARM) do families[row.family] = (families[row.family] or 0) + 1 end
    local familyNames = {}
    for family in pairs(families) do table.insert(familyNames, family) end
    table.sort(familyNames)
    for _, family in ipairs(familyNames) do writer:write(family .. " | " .. tostring(families[family]) .. "\n") end
    writer:close()
    ItemRarityUtils.info(string.format("FIREARM audit written: firearms=%d (%d profiles) | ammo=%d (%d profiles) | magazines=%d (%d profiles) | parts=%d (%d profiles).",
        #groups.FIREARM, countProfiles(groups.FIREARM), #groups.AMMO, countProfiles(groups.AMMO), #groups.MAGAZINE, countProfiles(groups.MAGAZINE), #groups.WEAPON_PART, countProfiles(groups.WEAPON_PART)))
    return true
end
