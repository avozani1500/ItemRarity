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
    -- string.gsub returns both the rewritten string and its replacement
    -- count. Keep only the string: forwarding both into table.insert() made
    -- the targeted Clothing report pass an accidental third argument.
    local cleaned = tostring(value):gsub("[\r\n|]", " ")
    return cleaned
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

-- This report is deliberately derived from the already-published registry.
-- It is a coverage inventory only: no candidate, tier, scanner state or
-- signature field is mutated here.
local function coverageOwner(data)
    local reason = tostring(data.utilityAdjustmentReason or "")
    local prefixes = {
        { "WeaponUtility", "WeaponUtility V2" },
        { "ClothingUtility", "ClothingUtility V1" },
        { "Accessory MechanicalValue", "Accessory mechanical policy" },
        { "Clothing MechanicalValue", "Clothing mechanical policy" },
        { "MedicalUtility", "MedicalUtility V1" },
        { "FoodUtility", "FoodUtility V1" },
        { "FishUtility", "FishUtility V1" },
        { "ContainerUtility", "ContainerUtility V2" },
        { "LiteratureUtility", "LiteratureUtility V1" },
        { "RecipeLiterature", "RecipeLiterature V1" },
        { "MapUtility", "MapUtility V1" },
        { "LightFireUtility", "LightFireUtility V1" },
        { "FirearmUtility", "FirearmUtility V1" },
        { "MagazineUtility", "MagazineUtility V1" },
        { "AmmoUtility", "AmmoUtility V1" },
    }
    for _, entry in ipairs(prefixes) do
        if string.find(reason, entry[1], 1, true) then return entry[2] end
    end
    -- Melee and the already-safe Container V2 groups may finish with a generic
    -- matrix/threshold reason.  Their calculated Utility is the authoritative
    -- signal here; they are not fallback items merely because the final reason
    -- does not repeat the utility's name.
    if data.utilityKind == "MELEE_WEAPON" and data.utility ~= nil then return "WeaponUtility V2" end
    if data.utilityKind == "CONTAINER" and data.utility ~= nil and not string.find(reason, "deferred", 1, true) then return "ContainerUtility V2" end
    return nil
end

local function coverageStatus(data)
    local mechanical = data.clothingMechanicalValueStatus or data.accessoryMechanicalValueStatus
    if mechanical == "MECHANICALLY_TRIVIAL" then return "TRIVIAL" end
    if mechanical and string.find(mechanical, "PARTIAL", 1, true) then return "PARTIAL" end
    local explicit = data.medicalValueStatus or data.foodValueStatus or data.utilitySupport or ""
    explicit = tostring(explicit)
    if string.find(explicit, "TRIVIAL", 1, true) then return "TRIVIAL" end
    if string.find(explicit, "PARTIAL", 1, true) or string.find(explicit, "UNSUPPORTED", 1, true) then return "PARTIAL" end
    if data.utilityFunctionalGroup == "TRIVIAL_LITERATURE" then return "TRIVIAL" end
    if not data.utilityEligible then return "PARTIAL" end
    return "KNOWN"
end

local function coverageFamily(data)
    local category = tostring(data.category or data.itemType or "UNCLASSIFIED")
    local display = tostring(data.displayCategory or "")
    local kind = tostring(data.utilityKind or "")
    return category .. " | " .. (display ~= "" and display or "-") .. " | " .. (kind ~= "" and kind or "NO_KIND")
end

local function coverageReadiness(rows)
    local partial, metrics, valid = 0, 0, 0
    for _, data in ipairs(rows) do
        if coverageStatus(data) == "PARTIAL" then partial = partial + 1 end
        if type(data.utilityMetrics) == "table" then metrics = metrics + 1 end
        if (tonumber(data.utilityValidAttributeCount) or 0) >= 3 then valid = valid + 1 end
    end
    if partial == #rows then return "PARTIAL / bridge or model evidence incomplete" end
    if valid > 0 or metrics > 0 then return "structural attributes present; targeted audit possible" end
    return "no reliable active structural metric exposed"
end

local function writeSystemCoverageReport(results)
    if type(results) ~= "table" or not getFileWriter then return nil end
    local categories, fallbackFamilies = {}, {}
    local total = 0
    for _, data in pairs(results) do
        total = total + 1
        local category = tostring(data.category or data.itemType or "UNCLASSIFIED")
        local bucket = categories[category] or { total = 0, active = 0, fallback = 0, partial = 0, trivial = 0, owners = {} }
        categories[category] = bucket
        bucket.total = bucket.total + 1
        local owner, status = coverageOwner(data), coverageStatus(data)
        if owner then bucket.active = bucket.active + 1; bucket.owners[owner] = (bucket.owners[owner] or 0) + 1 else
            bucket.fallback = bucket.fallback + 1
            local family = coverageFamily(data)
            fallbackFamilies[family] = fallbackFamilies[family] or {}
            table.insert(fallbackFamilies[family], data)
        end
        if status == "PARTIAL" then bucket.partial = bucket.partial + 1 end
        if status == "TRIVIAL" then bucket.trivial = bucket.trivial + 1 end
    end
    local writer = getFileWriter("ItemRarity_SystemCoverage.txt", true, false)
    if not writer then return nil end
    writer:write("Item Rarity system coverage audit (READ ONLY)\n")
    writer:write("Published registry only. This report does not alter tiers, registry, scanner state or signature.\n")
    writer:write(string.format("PUBLISHED_ITEMS=%d\n\n", total))
    writer:write("CATEGORY COVERAGE\ncategory | total | active Utility | fallback/Scarcity | PARTIAL | TRIVIAL | Utility coverage | active owners\n")
    local names = {}
    for name in pairs(categories) do table.insert(names, name) end
    table.sort(names)
    for _, name in ipairs(names) do
        local b, owners = categories[name], {}
        for owner, count in pairs(b.owners) do table.insert(owners, owner .. "=" .. tostring(count)) end
        table.sort(owners)
        writer:write(string.format("%s | %d | %d | %d | %d | %d | %.1f%% | %s\n", name, b.total, b.active, b.fallback, b.partial, b.trivial, b.total > 0 and (100 * b.active / b.total) or 0, #owners > 0 and table.concat(owners, "; ") or "-"))
    end
    writer:write("\nLARGEST FALLBACK / SCARCITY FAMILIES\nfamily (category | displayCategory | utilityKind) | fullTypes | readiness | examples | reasons\n")
    local families = {}
    for family, rows in pairs(fallbackFamilies) do table.insert(families, { family = family, rows = rows }) end
    table.sort(families, function(a, b) return #a.rows == #b.rows and a.family < b.family or #a.rows > #b.rows end)
    for _, entry in ipairs(families) do
        local examples, reasons = {}, {}
        for index, data in ipairs(entry.rows) do
            if index <= 8 then table.insert(examples, tostring(data.fullType)) end
            local reason = tostring(data.utilityAdjustmentReason or "no eligible Utility data")
            reasons[reason] = true
        end
        local reasonList = {}
        for reason in pairs(reasons) do table.insert(reasonList, reason) end
        table.sort(reasonList)
        writer:write(string.format("%s | %d | %s | %s | %s\n", entry.family, #entry.rows, coverageReadiness(entry.rows), table.concat(examples, ";"), table.concat(reasonList, " || ")))
    end
    writer:close()
    ItemRarityUtils.info(string.format("System coverage audit written: %d published items, %d fallback families.", total, #families))
    return true
end

-- Tool is intentionally split into structural subfamilies instead of being
-- treated as one mechanical population.  This audit does not score anything.
local function toolSubfamily(data, script, runtime, tags, display, itemType)
    if data.utilityKind == "MELEE_WEAPON" and data.utility ~= nil then return "MELEE_ALREADY_COVERED" end
    local signal = lower(display .. " " .. itemType .. " " .. tags)
    if string.find(signal, "seed", 1, true) then return "SEED_OR_AGRICULTURE_INPUT" end
    if string.find(signal, "vehicle", 1, true) or string.find(signal, "mechanic", 1, true) then return "MECHANICS" end
    if string.find(signal, "fishing", 1, true) or string.find(signal, "fish", 1, true) then return "FISHING" end
    if string.find(signal, "camp", 1, true) then return "CAMPING" end
    if string.find(signal, "garden", 1, true) or string.find(signal, "farm", 1, true) then return "GARDENING" end
    if string.find(signal, "paint", 1, true) or string.find(signal, "clean", 1, true) then return "PAINT_OR_CLEANING" end
    return "GENERAL_CRAFTING_OR_TOOL"
end

local function toolReadiness(group, rows)
    if group == "MELEE_ALREADY_COVERED" then return "already covered by WeaponUtility V2" end
    if group == "SEED_OR_AGRICULTURE_INPUT" then return "no: value depends on growth/planting context" end
    if group == "FISHING" then return "no: bait, lure and fishing-state logic not exposed as stable simple stats" end
    if group == "CAMPING" then return "no: use depends on survival actions/recipes or world state" end
    if group == "GARDENING" then return "no: value depends on farming actions and growth state" end
    if group == "PAINT_OR_CLEANING" then return "no: mostly cosmetic/maintenance actions, no common absolute value" end
    if group == "MECHANICS" then return "audit candidate: condition/uses exposed, but repair value needs vehicle-action semantics" end
    return "no: general tools require recipe/crafting semantics to compare safely"
end

local function writeToolAudit(results)
    if type(results) ~= "table" or not getFileWriter then return nil end
    local manager = getScriptManager and getScriptManager() or nil
    local groups, total = {}, 0
    for _, data in pairs(results) do
        if data.category == "TOOL" then
            local script = manager and manager:FindItem(data.fullType) or nil
            if script then
                local runtime = runtimeFor(script)
                local tags = lower(text(script, runtime, { "getTags" }, { "tags" }))
                local display = text(script, runtime, { "getDisplayCategory" }, { "displayCategory" })
                local itemType = text(script, runtime, { "getType", "getItemType" }, { "type", "itemType" })
                local group = toolSubfamily(data, script, runtime, tags, display, itemType)
                local row = {
                    data = data, fullType = data.fullType, module = moduleOf(data.fullType), group = group,
                    display = display, itemType = itemType, tags = tags,
                    weight = num(script, runtime, { "getActualWeight", "getWeight" }, { "actualWeight", "weight" }),
                    conditionMax = num(script, runtime, { "getConditionMax" }, { "conditionMax" }),
                    useDelta = num(script, runtime, { "getUseDelta" }, { "useDelta" }),
                    capacity = num(script, runtime, { "getCapacity" }, { "capacity" }),
                    maxItemWeight = num(script, runtime, { "getMaxItemSize", "getMaxItemWeight" }, { "maxItemSize", "maxItemWeight" }),
                    utilityKind = data.utilityKind, utility = data.utility,
                }
                row.profile = table.concat({ group, tostring(row.display), tostring(row.itemType), tostring(row.tags), tostring(row.weight), tostring(row.conditionMax), tostring(row.useDelta), tostring(row.capacity), tostring(row.maxItemWeight) }, ":")
                groups[group] = groups[group] or {}
                table.insert(groups[group], row)
                total = total + 1
            end
        end
    end
    local writer = getFileWriter("ItemRarity_ToolAudit.txt", true, false)
    if not writer then return nil end
    writer:write("Item Rarity TOOL structural audit (READ ONLY)\n")
    writer:write("Subfamilies use category, script display/type and tags; never item names or fullType rules. No Utility or tier is changed.\n")
    writer:write(string.format("TOOL_FULLTYPES=%d\n\n", total))
    writer:write("SUBFAMILY SUMMARY\nsubfamily | fullTypes | unique profiles | active coverage | reliable runtime fields | measurable without recipes | conclusion\n")
    local names = {}
    for name in pairs(groups) do table.insert(names, name) end
    table.sort(names)
    for _, name in ipairs(names) do
        local rows, profiles, active = groups[name], {}, 0
        for _, row in ipairs(rows) do profiles[row.profile] = true; if row.utilityKind and row.utility ~= nil then active = active + 1 end end
        local direct = name == "MELEE_ALREADY_COVERED"
        writer:write(string.format("%s | %d | %d | %d | weight;conditionMax;useDelta;capacity/maxItemWeight when declared | %s | %s\n", name, #rows, (function() local n=0 for _ in pairs(profiles) do n=n+1 end return n end)(), active, direct and "yes (already WeaponUtility)" or "no", toolReadiness(name, rows)))
    end
    for _, name in ipairs(names) do
        local rows = groups[name]
        table.sort(rows, function(a, b) return a.fullType < b.fullType end)
        writer:write("\n" .. name .. "\n")
        writer:write("fullType | module | displayCategory | itemType | tags | weight | conditionMax | useDelta | capacity | maxItemWeight | activeUtilityKind | activeUtility\n")
        for _, row in ipairs(rows) do
            writer:write(table.concat({ safe(row.fullType), safe(row.module), safe(row.display), safe(row.itemType), safe(row.tags), safe(row.weight), safe(row.conditionMax), safe(row.useDelta), safe(row.capacity), safe(row.maxItemWeight), safe(row.utilityKind), safe(row.utility) }, " | ") .. "\n")
        end
    end
    writer:close()
    ItemRarityUtils.info(string.format("TOOL audit written: %d fullTypes across %d structural subfamilies.", total, #names))
    return true
end

-- Capability probe for a future RecipeValue/CraftingValue infrastructure.
-- It deliberately asks only the public runtime bridge.  Falling back to a
-- filesystem parser would make mod coverage load-order dependent, so it is
-- explicitly not attempted here.
local function probe(object, method)
    local ok, fn = pcall(function() return object and object[method] end)
    if not ok or type(fn) ~= "function" then return false, nil end
    local called, value = pcall(function() return fn(object) end)
    return called, value
end

local function collectionSize(collection)
    if not collection then return nil end
    local value = call(collection, "size") or call(collection, "length")
    return tonumber(value)
end

local function collectionGet(collection, index)
    if not collection then return nil end
    return indexed(collection, index)
end

local function writeRecipeInfrastructureAudit()
    if not getFileWriter then return nil end
    local writer = getFileWriter("ItemRarity_RecipeInfrastructureAudit.txt", true, false)
    if not writer then return nil end
    local manager = getScriptManager and getScriptManager() or (ScriptManager and ScriptManager.instance) or nil
    writer:write("Item Rarity RecipeValue / CraftingValue infrastructure capability audit (READ ONLY)\n")
    writer:write("Public runtime bridge only; no script parser, tier, Utility, registry or scanner mutation.\n\n")
    writer:write("SCRIPT MANAGER\n")
    writer:write("available=" .. tostring(manager ~= nil) .. "\n")
    local list, listMethod = nil, nil
    for _, method in ipairs({ "getAllCraftRecipes", "getCraftRecipes", "getAllRecipes", "getRecipes" }) do
        local ok, value = probe(manager, method)
        writer:write(method .. " | callable=" .. tostring(ok) .. " | collectionSize=" .. safe(collectionSize(value)) .. "\n")
        if not list and ok and collectionSize(value) and collectionSize(value) > 0 then list, listMethod = value, method end
    end
    writer:write("\nDIRECT LOOKUP\n")
    for _, method in ipairs({ "getCraftRecipe", "getRecipe" }) do
        local ok = pcall(function() return manager and manager[method] end)
        writer:write(method .. " | memberAccessible=" .. tostring(ok) .. " | requires caller-known recipe id\n")
    end
    if not list then
        writer:write("\nRESULT: public bridge does not enumerate CraftRecipes on this runtime. Outputs, inputs, quantities, tools, skills, stations, duration, alternatives and dependency graph cannot be built generically. A script parser would be required and is intentionally out of scope.\n")
        writer:close()
        ItemRarityUtils.info("Recipe infrastructure audit written: CraftRecipe enumeration unavailable through public runtime bridge.")
        return true
    end

    local count = collectionSize(list) or 0
    writer:write(string.format("\nENUMERATION\nmethod=%s | recipes=%d\n", listMethod, count))
    local methodNames = { "getName", "getId", "getInputs", "getOutputs", "getRequiredSkills", "getRequiredTools", "getRequiredStations", "getCraftBench", "getTime", "getOnCreate", "getOnTest", "getCanBeDoneFromFloor" }
    local availability, samples = {}, math.min(count, 10)
    for index = 0, samples - 1 do
        local recipe = collectionGet(list, index)
        writer:write("\nRECIPE_SAMPLE_" .. tostring(index + 1) .. "\n")
        for _, method in ipairs(methodNames) do
            local ok, value = probe(recipe, method)
            availability[method] = availability[method] or ok
            local rendered = collectionSize(value) or value
            writer:write(method .. " | callable=" .. tostring(ok) .. " | value=" .. safe(rendered) .. "\n")
        end
    end
    writer:write("\nNESTED INPUT / OUTPUT / SKILL OBJECT PROBE\n")
    local firstRecipe = collectionGet(list, 0)
    local nested = {
        { "INPUT", call(firstRecipe, "getInputs"), { "getItem", "getItems", "getItemType", "getCount", "getAmount", "getUse", "getUses", "isTool", "isKeep", "isDestroy", "getFlags" } },
        { "OUTPUT", call(firstRecipe, "getOutputs"), { "getItem", "getItems", "getItemType", "getCount", "getAmount", "getQuantity", "getUses", "getFlags" } },
        { "SKILL", call(firstRecipe, "getRequiredSkills"), { "getPerk", "getPerkType", "getLevel", "getSkill", "getRequiredLevel" } },
    }
    for _, probeData in ipairs(nested) do
        local label, collection, methods = probeData[1], probeData[2], probeData[3]
        local size = collectionSize(collection)
        local object = size and size > 0 and collectionGet(collection, 0) or nil
        writer:write(label .. " | collectionSize=" .. safe(size) .. " | firstObject=" .. safe(object) .. "\n")
        for _, method in ipairs(methods) do
            -- Some Java getters require an index/argument and Kahlua logs an
            -- error even when pcall catches it.  Probe member visibility only
            -- until signatures are known; never call an unknown overload.
            local ok, member = pcall(function() return object and object[method] end)
            writer:write("  " .. method .. " | memberAccessible=" .. tostring(ok and type(member) == "function") .. " | signature not invoked\n")
        end
    end
    writer:write("\nCAPABILITY SUMMARY\nfield | public bridge seen\n")
    for _, method in ipairs(methodNames) do writer:write(method .. " | " .. tostring(availability[method] == true) .. "\n") end
    writer:write("\nINTERPRETATION\n")
    writer:write("If outputs and inputs are enumerable, quantities still require inspecting every Input/Output object and alternatives/dependency graphs need a second pass. Skill/tools/stations/time are only safe when their respective getters are exposed. Runtime enumeration is mod-generic; a parser is not needed only if this bridge remains complete.\n")
    writer:close()
    ItemRarityUtils.info(string.format("Recipe infrastructure audit written: %d CraftRecipes enumerated via %s.", count, listMethod))
    return true
end

-- Explosive and trap effects are often applied by callbacks/world objects.
-- This audit reports only values directly exposed on the ScriptItem/runtime
-- item, never guesses an effect from a display name or fullType.
local function writeExplosiveTrapAudit(results)
    if type(results) ~= "table" or not getFileWriter then return nil end
    local manager = getScriptManager and getScriptManager() or nil
    local groups = { THROWABLE_EXPLOSIVE = {}, PLACED_OR_TRIGGER_DEVICE = {}, INCENDIARY = {}, NOISE_MAKER = {}, TRAP = {}, SPECIAL_PARTIAL = {} }
    local effectFields = {
        explosionPower = { "getExplosionPower", "explosionPower" }, explosionRange = { "getExplosionRange", "explosionRange" },
        firePower = { "getFirePower", "firePower" }, fireRange = { "getFireRange", "fireRange" },
        smokeRange = { "getSmokeRange", "smokeRange" }, noiseRange = { "getNoiseRange", "noiseRange" },
        timer = { "getTriggerExplosionTimer", "getTimer", "triggerExplosionTimer", "timer" },
        sensorRange = { "getSensorRange", "sensorRange" }, remoteRange = { "getRemoteRange", "remoteRange" },
    }
    local total = 0
    for _, data in pairs(results) do
        local script = manager and manager:FindItem(data.fullType) or nil
        if script then
            local runtime = runtimeFor(script)
            local display = text(script, runtime, { "getDisplayCategory" }, { "displayCategory" })
            local tags = lower(text(script, runtime, { "getTags" }, { "tags" }))
            local candidate = (data.category == "AMMO" and lower(display) == "explosives") or (data.category == "TOOL" and lower(display) == "trapping")
            if candidate then
                local metrics = {}
                for key, names in pairs(effectFields) do
                    metrics[key] = num(script, runtime, { names[1], names[2] }, { names[2] })
                end
                local remote = bool(script, runtime, { "isCanBeRemote", "getCanBeRemote" }, { "canBeRemote" })
                local ranged = bool(script, runtime, { "isRanged" }, { "ranged" })
                local group = "SPECIAL_PARTIAL"
                if lower(display) == "trapping" or has(tags, "trap") then group = "TRAP"
                elseif (metrics.noiseRange or 0) > 0 and (metrics.explosionPower or 0) <= 0 and (metrics.firePower or 0) <= 0 then group = "NOISE_MAKER"
                elseif (metrics.firePower or 0) > 0 or (metrics.fireRange or 0) > 0 then group = "INCENDIARY"
                elseif remote or (metrics.timer or 0) > 0 or (metrics.sensorRange or 0) > 0 then group = "PLACED_OR_TRIGGER_DEVICE"
                elseif (metrics.explosionPower or 0) > 0 or (metrics.explosionRange or 0) > 0 then group = ranged and "THROWABLE_EXPLOSIVE" or "PLACED_OR_TRIGGER_DEVICE" end
                local row = {
                    fullType = data.fullType, module = moduleOf(data.fullType), group = group, display = display, tags = tags,
                    weight = num(script, runtime, { "getActualWeight", "getWeight" }, { "actualWeight", "weight" }),
                    conditionMax = num(script, runtime, { "getConditionMax" }, { "conditionMax" }),
                    useDelta = num(script, runtime, { "getUseDelta" }, { "useDelta" }),
                    ranged = ranged, remote = remote, metrics = metrics, finalTier = data.finalRarityTier,
                    scarcityTier = data.baseScarcityTier or data.rarityTier,
                    activeKind = data.utilityKind, activeNoiseTier = data.noiseMakerFinalTier,
                    reason = data.utilityAdjustmentReason,
                }
                row.profile = table.concat({ group, tostring(row.ranged), tostring(row.remote), tostring(row.weight), tostring(row.conditionMax), tostring(row.useDelta), tostring(metrics.explosionPower), tostring(metrics.explosionRange), tostring(metrics.firePower), tostring(metrics.fireRange), tostring(metrics.noiseRange), tostring(metrics.timer), tostring(metrics.sensorRange), tostring(metrics.remoteRange) }, ":")
                table.insert(groups[group], row)
                total = total + 1
            end
        end
    end
    local writer = getFileWriter("ItemRarity_ExplosiveTrapAudit.txt", true, false)
    if not writer then return nil end
    writer:write("Item Rarity explosive / trap structural audit (READ ONLY)\n")
    writer:write("Only directly exposed item/runtime attributes are reported. Missing effect values mean callback/world-object dependence and remain PARTIAL.\n")
    writer:write(string.format("CANDIDATES=%d\n\n", total))
    writer:write("GROUP SUMMARY\ngroup | fullTypes | unique profiles | directly measurable effect evidence | status\n")
    for _, group in ipairs({ "THROWABLE_EXPLOSIVE", "PLACED_OR_TRIGGER_DEVICE", "INCENDIARY", "NOISE_MAKER", "TRAP", "SPECIAL_PARTIAL" }) do
        local profiles, measurable = {}, 0
        for _, row in ipairs(groups[group]) do
            profiles[row.profile] = true
            local m = row.metrics
            if (m.explosionPower or 0) > 0 or (m.explosionRange or 0) > 0 or (m.firePower or 0) > 0 or (m.fireRange or 0) > 0 or (m.noiseRange or 0) > 0 then measurable = measurable + 1 end
        end
        local profileCount = 0; for _ in pairs(profiles) do profileCount = profileCount + 1 end
        writer:write(string.format("%s | %d | %d | %d | %s\n", group, #groups[group], profileCount, measurable, measurable == #groups[group] and "potentially measurable; compare only within group" or "PARTIAL: essential effects absent or incomplete"))
    end
    for _, group in ipairs({ "THROWABLE_EXPLOSIVE", "PLACED_OR_TRIGGER_DEVICE", "INCENDIARY", "NOISE_MAKER", "TRAP", "SPECIAL_PARTIAL" }) do
        table.sort(groups[group], function(a, b) return a.fullType < b.fullType end)
        writer:write("\n" .. group .. "\n")
        writer:write("fullType | module | displayCategory | ranged | remote | explosionPower | explosionRange | firePower | fireRange | smokeRange | noiseRange | timer | sensorRange | remoteRange | weight | conditionMax | useDelta | active tier | current reason | tags\n")
        for _, row in ipairs(groups[group]) do
            local m = row.metrics
            writer:write(table.concat({ safe(row.fullType), safe(row.module), safe(row.display), safe(row.ranged), safe(row.remote), safe(m.explosionPower), safe(m.explosionRange), safe(m.firePower), safe(m.fireRange), safe(m.smokeRange), safe(m.noiseRange), safe(m.timer), safe(m.sensorRange), safe(m.remoteRange), safe(row.weight), safe(row.conditionMax), safe(row.useDelta), safe(row.finalTier), safe(row.reason), safe(row.tags) }, " | ") .. "\n")
        end
    end
    local function tierForScore(score)
        if score < 20 then return "COMMON" end
        if score < 40 then return "UNCOMMON" end
        if score < 60 then return "RARE" end
        if score < 80 then return "EPIC" end
        return "EXOTIC"
    end
    local function anchored(value, anchors)
        value = tonumber(value) or 0
        if value <= anchors[1][1] then return anchors[1][2] end
        for index = 2, #anchors do
            local left, right = anchors[index - 1], anchors[index]
            if value <= right[1] then
                return left[2] + (right[2] - left[2]) * (value - left[1]) / (right[1] - left[1])
            end
        end
        return anchors[#anchors][2]
    end
    local powerAnchors = { { 0, 0 }, { 50, 40 }, { 70, 60 }, { 90, 80 }, { 110, 100 } }
    local rangeAnchors = { { 0, 0 }, { 3, 40 }, { 5, 60 }, { 7, 80 }, { 9, 100 } }
    local function fireTier(range)
        range = tonumber(range) or 0
        if range < 3 then return "COMMON" end
        if range < 4 then return "UNCOMMON" end
        if range < 5 then return "RARE" end
        if range < 7 then return "EPIC" end
        return "EXOTIC"
    end
    local function noiseTier(range)
        range = tonumber(range) or 0
        if range < 15 then return "COMMON" end
        if range < 30 then return "UNCOMMON" end
        if range < 50 then return "RARE" end
        return "EPIC"
    end
    writer:write("\nV1 SIMULATION (READ ONLY)\n")
    writer:write("Absolute-scale calibration only. Trigger/timer/sensor and smoke radius are recorded but excluded; no population percentile is used.\n")
    writer:write("\nEXPLOSIVE\nfullType | ExplosionPower/PowerValue | ExplosionRange/RangeValue | 70/30 score | simulated tier | active tier | ScarcityTier | trigger/timer/sensor diagnostics\n")
    for _, row in ipairs(groups.PLACED_OR_TRIGGER_DEVICE) do
        local m, power = row.metrics, anchored(row.metrics.explosionPower, powerAnchors)
        local range = anchored(row.metrics.explosionRange, rangeAnchors)
        local score = .70 * power + .30 * range
        writer:write(table.concat({ safe(row.fullType), safe(m.explosionPower) .. "/" .. safe(power), safe(m.explosionRange) .. "/" .. safe(range), safe(score), tierForScore(score), safe(row.finalTier), safe(row.scarcityTier), "timer=" .. safe(m.timer) .. ";sensor=" .. safe(m.sensorRange) .. ";remote=" .. safe(m.remoteRange) }, " | ") .. "\n")
    end
    writer:write("\nINCENDIARY\nfullType | FireRange | simulated tier | active tier | ScarcityTier | trigger/timer/sensor diagnostics\n")
    for _, row in ipairs(groups.INCENDIARY) do
        local m = row.metrics
        writer:write(table.concat({ safe(row.fullType), safe(m.fireRange), fireTier(m.fireRange), safe(row.finalTier), safe(row.scarcityTier), "timer=" .. safe(m.timer) .. ";sensor=" .. safe(m.sensorRange) .. ";remote=" .. safe(m.remoteRange) }, " | ") .. "\n")
    end
    writer:write("\nNOISE_MAKER\nNoiseMakerUtility V1: <15 COMMON; 15-29 UNCOMMON; 30-49 RARE; >=50 EPIC (EPIC ceiling). Scarcity, timer, sensor, remote and SmokeRange are excluded.\n")
    writer:write("fullType | NoiseRange | SmokeRange diagnostic | active kind | active tier | active NoiseMaker tier | proposed Utility tier | ScarcityTier | trigger/timer/sensor diagnostics\n")
    for _, row in ipairs(groups.NOISE_MAKER) do
        local m = row.metrics
        writer:write(table.concat({ safe(row.fullType), safe(m.noiseRange), safe(m.smokeRange), safe(row.activeKind), safe(row.finalTier), safe(row.activeNoiseTier), noiseTier(m.noiseRange), safe(row.scarcityTier), "timer=" .. safe(m.timer) .. ";sensor=" .. safe(m.sensorRange) .. ";remote=" .. safe(m.remoteRange) }, " | ") .. "\n")
    end
    writer:close()
    ItemRarityUtils.info(string.format("Explosive/trap audit written: %d candidates.", total))
    return true
end

-- Focused Clothing diagnostic. It reads only fields already published by the
-- active calculator, then selects comparable lower-body records from their
-- structural subgroup/body slot. It never creates Clothing instances, edits
-- results, or invokes the historical all-clothing MechanicalValue report.
local function writeClothingTargetedAudit(results)
    if type(results) ~= "table" or not getFileWriter then return end
    local manager = getScriptManager and getScriptManager() or nil
    local rows = {}
    for _, data in pairs(results) do
        if data.category == "CLOTHING" and data.utilityKind == "CLOTHING" then
            local discovery = data.clothingDiscovery or {}
            local body = lower(discovery.bodyLocation)
            local subgroup = tostring(data.utilitySubgroup or "")
            -- `LEGS` is calculator-derived from BodyLocation/coverage; the
            -- underwear exception is also its declared BodyLocation, never a
            -- display name or fullType rule.
            if subgroup == "LEGS" or has(body, "underwear") then
                local script = findScriptItem(manager, data.fullType)
                local display = text(script, nil, { "getDisplayName" }, { "displayName" })
                local metrics, components = data.utilityMetrics or {}, data.utilityComponents or {}
                local direct = components.directSlot or {}
                table.insert(rows, {
                    data = data, display = display, body = discovery.bodyLocation or "", covered = discovery.coveredParts or "",
                    slot = data.clothingEquipmentGraph and data.clothingEquipmentGraph.slotId or "",
                    metrics = metrics, direct = direct,
                })
            end
        end
    end
    table.sort(rows, function(a, b)
        if a.slot == b.slot then return a.data.fullType < b.data.fullType end
        return tostring(a.slot) < tostring(b.slot)
    end)
    local writer = getFileWriter("ItemRarity_ClothingTargetedAudit.txt", true, false)
    if not writer then return end
    writer:write("Item Rarity targeted lower-body Clothing audit (READ ONLY)\n")
    writer:write("Selection uses active structural LEG subgroup or declared underwear BodyLocation. No clothing instance is created; FinalRarityTier, UI, registry and signature are unchanged. Dirty is an instance state, so the report identifies the stable fullType rather than guessing it from a localized item label.\n\n")
    writer:write("fullType | displayName | BodyLocation | coveredParts | comparable slot | Scarcity | FinalTier | tier origin | MechanicalValue/Status | Bite/Scratch/Bullet | insulation/wind/water | weight | run/combat/discomfort/vision/hearing | conditionMax | ClothingScore | slot pct/rank/confidence/profiles | normalized direct components P/Cov/Dur/Mob/Wt/Disc/Sense/Weather | relative/absolute protection\n")
    for _, row in ipairs(rows) do
        local d, m, c = row.data, row.metrics, row.direct
        writer:write(table.concat({
            safe(d.fullType), safe(row.display), safe(row.body), safe(row.covered), safe(row.slot),
            safe(d.baseScarcityTier), safe(d.finalRarityTier), safe(d.utilityAdjustmentReason),
            safe(slash(d.clothingMechanicalValue, d.clothingMechanicalValueStatus)),
            safe(slash(m.biteDefense, m.scratchDefense, m.bulletDefense)),
            safe(slash(m.insulation, m.windResistance, m.waterResistance)), safe(m.weight),
            safe(slash(m.runSpeedModifier, m.combatSpeedModifier, m.discomfortModifier, m.visionModifier, m.hearingModifier)),
            safe(m.conditionMax), safe(d.utility),
            safe(slash(d.slotQualityPercentile, d.slotQualityRank, d.slotRankingConfidence, d.utilityProfileCount)),
            safe(slash(c.protection, c.coverage, c.durability, c.mobility, c.weight, c.discomfort, c.senses, c.weather)),
            safe(slash(c.relativeProtection, c.absoluteProtection)),
        }, " | ") .. "\n")
    end
    writer:close()
    ItemRarityUtils.info(string.format("Targeted Clothing audit written: %d lower-body/underwear records.", #rows))
end

-- Outerwear comparison is selected solely from the declared BodyLocation.
-- The report exposes the already-published DIRECT_SLOT components so a
-- diagnostic can distinguish a Scarcity result from a score-driven result.
local function writeOuterwearAudit(results)
    if type(results) ~= "table" or not getFileWriter then return end
    local manager = getScriptManager and getScriptManager() or nil
    local rows = {}
    for _, data in pairs(results) do
        if data.category == "CLOTHING" and data.utilityKind == "CLOTHING" then
            local discovery = data.clothingDiscovery or {}
            local body = lower(discovery.bodyLocation)
            if has(body, "jacket") then
                local script = findScriptItem(manager, data.fullType)
                table.insert(rows, {
                    data = data, display = text(script, nil, { "getDisplayName" }, { "displayName" }),
                    body = discovery.bodyLocation or "", covered = discovery.coveredParts or "",
                })
            end
        end
    end
    table.sort(rows, function(a, b) return a.data.fullType < b.data.fullType end)
    local writer = getFileWriter("ItemRarity_ClothingOuterwearAudit.txt", true, false)
    if not writer then return end
    writer:write("Item Rarity structural outerwear comparison (READ ONLY)\n")
    writer:write("Selection: declared BodyLocation containing 'jacket'; no item name/fullType is used as a classification rule. Scores and components are those published by the active ClothingUtility V1 pipeline.\n\n")
    writer:write("fullType | displayName | BodyLocation | coveredParts | Scarcity | FinalTier | tier origin | MechanicalValue/Status | Bite/Scratch/Bullet | insulation/wind/water | weight | run/combat/discomfort/vision/hearing | conditionMax | ClothingScore | slot pct/rank/confidence/profiles | normalized P/Cov/Dur/Mob/Wt/Disc/Sense/Weather | relative/absolute protection\n")
    for _, row in ipairs(rows) do
        local d, m, c = row.data, row.data.utilityMetrics or {}, (row.data.utilityComponents or {}).directSlot or {}
        writer:write(table.concat({ safe(d.fullType), safe(row.display), safe(row.body), safe(row.covered), safe(d.baseScarcityTier), safe(d.finalRarityTier), safe(d.utilityAdjustmentReason), safe(slash(d.clothingMechanicalValue, d.clothingMechanicalValueStatus)), safe(slash(m.biteDefense, m.scratchDefense, m.bulletDefense)), safe(slash(m.insulation, m.windResistance, m.waterResistance)), safe(m.weight), safe(slash(m.runSpeedModifier, m.combatSpeedModifier, m.discomfortModifier, m.visionModifier, m.hearingModifier)), safe(m.conditionMax), safe(d.utility), safe(slash(d.slotQualityPercentile, d.slotQualityRank, d.slotRankingConfidence, d.utilityProfileCount)), safe(slash(c.protection, c.coverage, c.durability, c.mobility, c.weight, c.discomfort, c.senses, c.weather)), safe(slash(c.relativeProtection, c.absoluteProtection)) }, " | ") .. "\n")
    end
    writer:close()
    ItemRarityUtils.info(string.format("Outerwear Clothing audit written: %d jacket-slot records.", #rows))
end

-- Container V2 deliberately defers non-wearable/special cases. This report
-- surfaces only structurally small personal containers and their profiles so
-- a future trivial policy can be evidenced before it is proposed. It does
-- not manufacture a KNOWN/TRIVIAL state for a deferred group.
local function writeSmallContainerAudit(results)
    if type(results) ~= "table" or not getFileWriter then return end
    local manager = getScriptManager and getScriptManager() or nil
    local rows = {}
    for _, data in pairs(results) do
        if data.category == "CONTAINER" and data.utilityKind == "CONTAINER" then
            local m = data.utilityMetrics or {}
            local group, capacity = tostring(data.containerV2Group or data.utilitySubgroup or ""), tonumber(m.capacity)
            if group == "KEY_CONTAINER" or ((group == "NON_WEARABLE_CONTAINER" or group == "CASE") and capacity ~= nil and capacity <= 5) then
                local script = findScriptItem(manager, data.fullType)
                local runtime = nil
                if script then local ok, item = pcall(function() return script:InstanceItem(nil, false) end); runtime = ok and item or nil end
                local body = text(script, runtime, { "getBodyLocation", "canBeEquipped" }, { "bodyLocation" })
                local restrictions = text(script, runtime, { "getAcceptItemFunction" }, { "acceptItemFunction" })
                local maxItemSize = num(script, runtime, { "getMaxItemSize" }, { "maxItemSize" })
                local status = group == "KEY_CONTAINER" and "MECHANICALLY_TRIVIAL_POLICY" or "DEFERRED_UNASSESSED"
                table.insert(rows, { data=data, display=text(script, nil, { "getDisplayName" }, { "displayName" }), group=group, body=body, restrictions=restrictions, maxItemSize=maxItemSize, status=status })
            end
        end
    end
    table.sort(rows, function(a, b) return a.data.fullType < b.data.fullType end)
    local writer = getFileWriter("ItemRarity_SmallContainerAudit.txt", true, false)
    if not writer then return end
    writer:write("Item Rarity small personal container audit (READ ONLY)\n")
    writer:write("Selection: KEY_CONTAINER or deferred CASE/NON_WEARABLE_CONTAINER with declared capacity <= 5. No display-name/fullType classifier exists here; all fields are structural/runtime. Deferred does not mean trivial.\n\n")
    writer:write("fullType | displayName | Container subgroup | capacity | weightReduction | emptyWeight | RunSpeedModifier | attachments | equip/body slot | accept/restrictions | maxItemSize | mechanical status | Scarcity | FinalTier | rule/origin | profile | utility/confidence\n")
    for _, row in ipairs(rows) do
        local d, m = row.data, row.data.utilityMetrics or {}
        writer:write(table.concat({ safe(d.fullType), safe(row.display), safe(row.group), safe(m.capacity), safe(m.weightReduction), safe(m.emptyWeight), safe(m.runSpeedModifier), safe(m.attachments), safe(row.body), safe(row.restrictions), safe(row.maxItemSize), safe(row.status), safe(d.baseScarcityTier), safe(d.finalRarityTier), safe(d.utilityAdjustmentReason), safe(d.utilityProfile), safe(slash(d.utility, d.utilityConfidence)) }, " | ") .. "\n")
    end
    writer:close()
    ItemRarityUtils.info(string.format("Small-container audit written: %d structurally small records.", #rows))
end

local COMBINER_TIERS = { "COMMON", "UNCOMMON", "RARE", "EPIC", "EXOTIC" }
local COMBINER_INDEX = { COMMON=1, UNCOMMON=2, RARE=3, EPIC=4, EXOTIC=5 }
local function combinerTierAt(index)
    return COMBINER_TIERS[math.max(1, math.min(#COMBINER_TIERS, index or 1))]
end

-- These candidate Utility bands preserve the active P2 good/excellent cuts
-- and add only the outer C/U and E/X bounds needed to turn a continuous
-- DIRECT_SLOT score into an anchor tier for this report. They are simulation
-- inputs, not a modification of ClothingUtility's internal score.
local function directSlotUtilityTier(score)
    score = tonumber(score) or 0
    if score < 40 then return "COMMON" end
    if score < 53.64 then return "UNCOMMON" end
    if score < 61.28 then return "RARE" end
    if score < 70 then return "EPIC" end
    return "EXOTIC"
end

local function bumpDistribution(distribution, tier)
    distribution[tier] = (distribution[tier] or 0) + 1
end

local function formatDistribution(distribution)
    local parts = {}
    for _, tier in ipairs(COMBINER_TIERS) do table.insert(parts, tier .. "=" .. tostring(distribution[tier] or 0)) end
    return table.concat(parts, " ")
end

-- A deliberately small, review-oriented sample for the continuous-score C1
-- candidate. It consumes the already calculated score/components and never
-- participates in the published tier pipeline.
local function writeClothingC1SampleAudit(rows)
    if type(rows) ~= "table" or not getFileWriter then return end
    local candidates = {}
    for _, row in ipairs(rows) do
        local activeIndex = COMBINER_INDEX[row.data.finalRarityTier] or 1
        local c1Index = COMBINER_INDEX[row.modelC1] or 1
        local flags = {}
        if activeIndex == 1 and c1Index >= 3 then table.insert(flags, "COMMON_TO_RARE_PLUS") end
        if activeIndex == 2 and c1Index >= 3 then table.insert(flags, "UNCOMMON_TO_RARE_PLUS") end
        if activeIndex >= 3 and c1Index == 1 then table.insert(flags, "RARE_EPIC_TO_COMMON") end
        if activeIndex - c1Index >= 2 then table.insert(flags, "DROP_2PLUS") end
        if c1Index - activeIndex >= 2 then table.insert(flags, "RISE_2PLUS") end
        if #flags > 0 then
            row.c1SampleFlags = table.concat(flags, ",")
            table.insert(candidates, row)
        end
    end
    table.sort(candidates, function(a, b)
        local ad = math.abs((COMBINER_INDEX[a.modelC1] or 1) - (COMBINER_INDEX[a.data.finalRarityTier] or 1))
        local bd = math.abs((COMBINER_INDEX[b.modelC1] or 1) - (COMBINER_INDEX[b.data.finalRarityTier] or 1))
        if ad == bd then
            -- Within an equal-size movement, review the most extreme adjusted
            -- score first, because it is closest to a meaningful tier claim.
            if a.adjustedC1 == b.adjustedC1 then return a.data.fullType < b.data.fullType end
            return a.adjustedC1 > b.adjustedC1
        end
        return ad > bd
    end)
    local writer = getFileWriter("ItemRarity_ClothingC1SampleAudit.txt", true, false)
    if not writer then return end
    writer:write("Clothing DIRECT_SLOT C1 review sample (READ ONLY; MECHANICALLY_TRIVIAL excluded)\n")
    writer:write("C1: ScarcityAdjustment=(ScarcityStrength-50)/10; AdjustedScore=clamp(ClothingScore+adjustment,0,100); FinalTier=tier(AdjustedScore).\n")
    writer:write("Only the requested high-impact transitions are selected, maximum 30. Protection/weather/mobility are the existing normalized ClothingUtility components, not recomputed values.\n\n")
    writer:write("category | fullType | displayName | bodyLocation/group | ClothingScore | ScarcityStrength | adjustment | AdjustedScore | active | C1 | protection | weather | mobility | probable reason\n")
    local manager = getScriptManager and getScriptManager() or nil
    for index, row in ipairs(candidates) do
        if index > 30 then break end
        local d, c = row.data, row.direct
        local script = findScriptItem(manager, d.fullType)
        local display = text(script, nil, { "getDisplayName" }, { "displayName" })
        local slot = d.clothingEquipmentGraph and d.clothingEquipmentGraph.slotId or "-"
        local direction = row.adjustmentC1 >= 0 and "positive" or "negative"
        local reason = string.format("%s Scarcity adjustment %.3f shifts continuous score %.3f to %.3f across the C1 tier boundary", direction, row.adjustmentC1, d.utility or 0, row.adjustedC1)
        writer:write(table.concat({ safe(row.c1SampleFlags), safe(d.fullType), safe(display), safe(slot), safe(d.utility), safe(row.scarcityStrength), safe(row.adjustmentC1), safe(row.adjustedC1), safe(d.finalRarityTier), safe(row.modelC1), safe(c.protection), safe(c.weather), safe(c.mobility), safe(reason) }, " | ") .. "\n")
    end
    writer:write("\nWORK BOOTS SANITY CHECK\n")
    for _, row in ipairs(rows) do
        if row.data.fullType == "Base.Shoes_WorkBoots" then
            local d, c = row.data, row.direct
            writer:write("fullType=" .. safe(d.fullType) .. "\n")
            writer:write("score=" .. safe(d.utility) .. " scarcityStrength=" .. safe(row.scarcityStrength) .. " adjustment=" .. safe(row.adjustmentC1) .. " adjustedScore=" .. safe(row.adjustedC1) .. " active=" .. safe(d.finalRarityTier) .. " C1=" .. safe(row.modelC1) .. "\n")
            writer:write("components protection=" .. safe(c.protection) .. " coverage=" .. safe(c.coverage) .. " durability=" .. safe(c.durability) .. " mobility=" .. safe(c.mobility) .. " weight=" .. safe(c.weight) .. " discomfort=" .. safe(c.discomfort) .. " senses=" .. safe(c.senses) .. " weather=" .. safe(c.weather) .. "\n")
            writer:write("interpretation=the 60.090 score comes principally from protection 68.837, durability 95, weather 100, with neutral 50 handling costs; C1 does not make it RARE by scarcity, it remains RARE after its small negative scarcity adjustment.\n")
            break
        end
    end
    writer:close()
    ItemRarityUtils.info(string.format("Clothing C1 review sample written: %d qualifying changes, capped at 30 rows.", #candidates))
end

-- Candidate successor to Clothing Policy 3: an item whose known mechanics
-- are structurally trivial is always COMMON. This is report-only and does
-- not touch the active C1 combiner or published tier.
local function writeClothingTrivialPolicySimulation(results)
    if type(results) ~= "table" or not getFileWriter then return end
    local manager = getScriptManager and getScriptManager() or nil
    local rows, uncommonToCommon = {}, 0
    for _, data in pairs(results) do
        if data.category == "CLOTHING" and data.clothingMechanicalValueStatus == "MECHANICALLY_TRIVIAL" then
            if data.finalRarityTier == "UNCOMMON" then uncommonToCommon = uncommonToCommon + 1 end
            table.insert(rows, data)
        end
    end
    table.sort(rows, function(a, b) return a.fullType < b.fullType end)
    local writer = getFileWriter("ItemRarity_ClothingTrivialPolicySimulation.txt", true, false)
    if not writer then return end
    writer:write("Clothing trivial-policy simulation (READ ONLY)\n")
    writer:write("Predicate: clothingMechanicalValueStatus=MECHANICALLY_TRIVIAL. Proposed FinalTier=COMMON, with no Scarcity influence. Clothing DIRECT_SLOT C1 is not recomputed or changed.\n")
    writer:write(string.format("TRIVIAL=%d | UNCOMMON_TO_COMMON=%d | PROPOSED_COMMON=%d\n\n", #rows, uncommonToCommon, #rows))
    writer:write("fullType | displayName | ScarcityTier | current FinalTier | proposed FinalTier\n")
    for _, data in ipairs(rows) do
        local script = findScriptItem(manager, data.fullType)
        local display = text(script, nil, { "getDisplayName" }, { "displayName" })
        writer:write(table.concat({ safe(data.fullType), safe(display), safe(data.baseScarcityTier), safe(data.finalRarityTier), "COMMON" }, " | ") .. "\n")
    end
    writer:close()
    ItemRarityUtils.info(string.format("Clothing trivial-policy simulation written: %d trivial items; %d UNCOMMON -> COMMON.", #rows, uncommonToCommon))
end

-- Simulates only the final Clothing DIRECT_SLOT combiner. Internal score,
-- component weights, MechanicalValue, structural grouping and trivial policy
-- are untouched. Trivial records are intentionally omitted so this report
-- cannot confuse the separate Policy 3 question with scarcity anchoring.
local function writeClothingCombinerSimulation(results)
    if type(results) ~= "table" or not getFileWriter then return end
    local rows, distributions = {}, { active={}, a={}, b={}, c1={}, c2={} }
    for _, data in pairs(results) do
        local direct = (data.utilityComponents or {}).directSlot
        if data.category == "CLOTHING" and data.utilityKind == "CLOTHING" and direct and data.utility ~= nil
            and data.clothingMechanicalValueStatus ~= "MECHANICALLY_TRIVIAL" then
            local utilityTier = directSlotUtilityTier(data.utility)
            local utilityIndex = COMBINER_INDEX[utilityTier]
            local scarcityIndex = COMBINER_INDEX[data.baseScarcityTier] or 1
            local activeIndex = COMBINER_INDEX[data.finalRarityTier] or 1
            -- A: Utility anchor; Scarcity itself is clamped to one step around
            -- the anchor. This is the literal ±1 interpretation.
            local modelA = combinerTierAt(math.max(utilityIndex - 1, math.min(utilityIndex + 1, scarcityIndex)))
            -- B: preserve the current V1 output only where it is inside the
            -- same Utility floor/ceiling; otherwise snap it to that boundary.
            local modelB = combinerTierAt(math.max(utilityIndex - 1, math.min(utilityIndex + 1, activeIndex)))
            -- C uses the continuous ClothingScore as the anchor. Scarcity is
            -- only a bounded numeric adjustment, never a tier movement.
            local scarcityPercentile = tonumber(data.scarcityPercentile)
                or tonumber(((data.tableAvailability or {}).routeWeightedPercentile)) or 50
            local scarcityStrength = clamp(100 - scarcityPercentile, 0, 100)
            local adjustmentC1 = (scarcityStrength - 50) / 10
            local adjustmentC2 = .15 * (scarcityStrength - 50)
            local adjustedC1 = clamp((tonumber(data.utility) or 0) + adjustmentC1, 0, 100)
            local adjustedC2 = clamp((tonumber(data.utility) or 0) + adjustmentC2, 0, 100)
            local modelC1 = directSlotUtilityTier(adjustedC1)
            local modelC2 = directSlotUtilityTier(adjustedC2)
            local row = {
                data=data, utilityTier=utilityTier, modelA=modelA, modelB=modelB,
                scarcityStrength=scarcityStrength, adjustmentC1=adjustmentC1,
                adjustmentC2=adjustmentC2, adjustedC1=adjustedC1,
                adjustedC2=adjustedC2, modelC1=modelC1, modelC2=modelC2,
                direct=direct,
            }
            table.insert(rows, row)
            bumpDistribution(distributions.active, data.finalRarityTier)
            bumpDistribution(distributions.a, modelA)
            bumpDistribution(distributions.b, modelB)
            bumpDistribution(distributions.c1, modelC1)
            bumpDistribution(distributions.c2, modelC2)
        end
    end
    table.sort(rows, function(a, b) return a.data.fullType < b.data.fullType end)
    local writer = getFileWriter("ItemRarity_ClothingCombinerSimulation.txt", true, false)
    if not writer then return end
    writer:write("Clothing DIRECT_SLOT final-combiner simulation (READ ONLY)\n")
    writer:write("Excluded: MECHANICALLY_TRIVIAL, which remains a separate Policy 3 concern. No score/component/group/MechanicalValue field is recomputed.\n")
    writer:write("Diagnostic UtilityTier bands: <40 COMMON; 40-53.63 UNCOMMON; 53.64-61.27 RARE; 61.28-69.99 EPIC; >=70 EXOTIC. Existing P2 good/excellent cuts are retained; outer bounds are simulation-only.\n")
    writer:write("Model A: clamp ScarcityTier to UtilityTier +/-1. Model B: clamp current active V1 tier to UtilityTier +/-1.\n")
    writer:write("Model C1: ScarcityStrength=100-ScarcityPercentile; adjustment=(strength-50)/10 (-5..+5); tier(ClothingScore+adjustment).\n")
    writer:write("Model C2: ScarcityStrength=100-ScarcityPercentile; adjustment=.15*(strength-50) (-7.5..+7.5); tier(ClothingScore+adjustment).\n")
    writer:write("ACTIVE " .. formatDistribution(distributions.active) .. "\n")
    writer:write("MODEL_A " .. formatDistribution(distributions.a) .. "\n")
    writer:write("MODEL_B " .. formatDistribution(distributions.b) .. "\n\n")
    writer:write("MODEL_C1 " .. formatDistribution(distributions.c1) .. "\n")
    writer:write("MODEL_C2 " .. formatDistribution(distributions.c2) .. "\n\n")
    writer:write("ALL DIRECT_SLOT NONTRIVIAL\nfullType | displayName | slot | UtilityScore | ScarcityStrength | C1 adjustment | C1 adjusted score | C2 adjustment | C2 adjusted score | UtilityTier | Scarcity | active | ModelA | ModelB | ModelC1 | ModelC2 | score pct/rank/confidence/profiles | normalized P/Cov/Dur/Mob/Wt/Disc/Sense/Weather | tier origin\n")
    local manager = getScriptManager and getScriptManager() or nil
    for _, row in ipairs(rows) do
        local d, c = row.data, row.direct
        local script = findScriptItem(manager, d.fullType)
        local display = text(script, nil, { "getDisplayName" }, { "displayName" })
        local slot = d.clothingEquipmentGraph and d.clothingEquipmentGraph.slotId or ""
        writer:write(table.concat({ safe(d.fullType), safe(display), safe(slot), safe(d.utility), safe(row.scarcityStrength), safe(row.adjustmentC1), safe(row.adjustedC1), safe(row.adjustmentC2), safe(row.adjustedC2), safe(row.utilityTier), safe(d.baseScarcityTier), safe(d.finalRarityTier), safe(row.modelA), safe(row.modelB), safe(row.modelC1), safe(row.modelC2), safe(slash(d.slotQualityPercentile, d.slotQualityRank, d.slotRankingConfidence, d.utilityProfileCount)), safe(slash(c.protection, c.coverage, c.durability, c.mobility, c.weight, c.discomfort, c.senses, c.weather)), safe(d.utilityAdjustmentReason) }, " | ") .. "\n")
    end
    writer:write("\nTOP CHANGES (active -> Model C1 or Model C2)\n")
    local changed = {}
    for _, row in ipairs(rows) do
        if row.data.finalRarityTier ~= row.modelC1 or row.data.finalRarityTier ~= row.modelC2 then table.insert(changed, row) end
    end
    table.sort(changed, function(a, b)
        local da = math.max(math.abs((COMBINER_INDEX[a.data.finalRarityTier] or 1) - (COMBINER_INDEX[a.modelC1] or 1)), math.abs((COMBINER_INDEX[a.data.finalRarityTier] or 1) - (COMBINER_INDEX[a.modelC2] or 1)))
        local db = math.max(math.abs((COMBINER_INDEX[b.data.finalRarityTier] or 1) - (COMBINER_INDEX[b.modelC1] or 1)), math.abs((COMBINER_INDEX[b.data.finalRarityTier] or 1) - (COMBINER_INDEX[b.modelC2] or 1)))
        if da == db then return a.data.fullType < b.data.fullType end
        return da > db
    end)
    for index, row in ipairs(changed) do
        if index > 80 then break end
        writer:write(table.concat({ safe(row.data.fullType), safe(row.data.utility), safe(row.scarcityStrength), safe(row.adjustmentC1), safe(row.adjustedC1), safe(row.adjustmentC2), safe(row.adjustedC2), safe(row.utilityTier), safe(row.data.finalRarityTier), safe(row.modelC1), safe(row.modelC2) }, " | ") .. "\n")
    end
    writer:close()
    writeClothingC1SampleAudit(rows)
    ItemRarityUtils.info(string.format("Clothing combiner simulation written: %d nontrivial DIRECT_SLOT records; %d changed rows.", #rows, #changed))
end

-- Wallet simulation is intentionally much narrower than CASE. A candidate
-- needs the directly exposed Wallet acceptance callback, capacity <=1, zero
-- reduction, zero attachments, and no functional equip slot. The result is
-- REPORT ONLY; specialized cases remain outside this predicate.
local function writeWalletTrivialSimulation(results)
    if type(results) ~= "table" or not getFileWriter then return end
    local manager = getScriptManager and getScriptManager() or nil
    local rows = {}
    for _, data in pairs(results) do
        if data.category == "CONTAINER" and data.utilityKind == "CONTAINER" then
            local m = data.utilityMetrics or {}
            if tonumber(m.capacity) and tonumber(m.capacity) <= 1 and tonumber(m.weightReduction) == 0 and tonumber(m.attachments) == 0 then
                local script = findScriptItem(manager, data.fullType)
                local runtime = nil
                if script then local ok, item = pcall(function() return script:InstanceItem(nil, false) end); runtime = ok and item or nil end
                local accept = text(script, runtime, { "getAcceptItemFunction" }, { "acceptItemFunction" })
                local body = lower(text(script, runtime, { "getBodyLocation", "canBeEquipped" }, { "bodyLocation" }))
                local noFunctionalSlot = body == "" or body == "-" or has(body, "none") or has(body, "null")
                if has(accept, "wallet") and noFunctionalSlot then
                    table.insert(rows, { data=data, accept=accept, body=body })
                end
            end
        end
    end
    table.sort(rows, function(a, b) return a.data.fullType < b.data.fullType end)
    local writer = getFileWriter("ItemRarity_WalletTrivialSimulation.txt", true, false)
    if not writer then return end
    writer:write("Wallet trivial-container simulation (READ ONLY)\nFinalTier=COMMON only for the structural predicate AcceptItemFunction.Wallet + capacity<=1 + WeightReduction=0 + attachments=0 + no functional equip slot. No general CASE policy is proposed.\n\n")
    writer:write("fullType | displayName | capacity | weightReduction | emptyWeight | attachments | accept function | body/equip | active accept | active equip | active wallet predicate | current Scarcity | current FinalTier | proposed FinalTier\n")
    for _, row in ipairs(rows) do
        local d, m = row.data, row.data.utilityMetrics or {}
        local script = findScriptItem(manager, d.fullType)
        writer:write(table.concat({ safe(d.fullType), safe(text(script, nil, { "getDisplayName" }, { "displayName" })), safe(m.capacity), safe(m.weightReduction), safe(m.emptyWeight), safe(m.attachments), safe(row.accept), safe(row.body), safe(d.containerAcceptItemFunction), safe(d.containerEquipSlot), safe(d.containerWalletTrivial), safe(d.baseScarcityTier), safe(d.finalRarityTier), "COMMON" }, " | ") .. "\n")
    end
    writer:close()
    ItemRarityUtils.info(string.format("Wallet trivial simulation written: %d structurally matching containers.", #rows))
end

-- Global registry review. This does not treat an uncommon design choice as a
-- bug automatically: it separates rule candidates from bounded/partial
-- architecture and from cases that are explainable by the current design.
local function writeGlobalRarityAnomalyAudit(results)
    if type(results) ~= "table" or not getFileWriter then return end
    local tierIndex = { COMMON=1, UNCOMMON=2, RARE=3, EPIC=4, EXOTIC=5 }
    local classRank = { ACCEPTABLE_BY_DESIGN=1, FUTURE_BRIDGE_OR_ARCHITECTURE=2, PROBABLE_RULE_ISSUE=3 }
    local manager = getScriptManager and getScriptManager() or nil
    local suspects, profiles = {}, {}
    local function mechanicalStatus(data)
        return data.clothingMechanicalValueStatus or data.accessoryMechanicalValueStatus
            or data.foodValueStatus or data.medicalValueStatus or data.utilitySupport or "UNSPECIFIED"
    end
    local function add(data, classification, reason, severity)
        local key = data.fullType
        local record = suspects[key]
        if not record then
            record = { data=data, classification=classification, reasons={}, severity=severity or 0 }
            suspects[key] = record
        end
        if classRank[classification] > classRank[record.classification] then record.classification = classification end
        record.severity = math.max(record.severity, severity or 0)
        table.insert(record.reasons, reason)
    end
    for _, data in pairs(results) do
        local finalIndex = tierIndex[data.finalRarityTier] or 1
        local status = mechanicalStatus(data)
        local utility = tonumber(data.utility)
        local reason = tostring(data.utilityAdjustmentReason or "")
        local fallback = data.utilityEligible ~= true or has(lower(reason), "no eligible")
            or has(lower(reason), "deferred") or has(lower(reason), "thresholds unavailable")
        if status == "MECHANICALLY_TRIVIAL" and finalIndex > 1 then
            add(data, "PROBABLE_RULE_ISSUE", "TRIVIAL above COMMON", 100 + finalIndex)
        end
        if (status == "MECHANICAL_VALUE_PARTIAL" or status == "UTILITY_PARTIAL") and finalIndex >= 4 then
            add(data, "FUTURE_BRIDGE_OR_ARCHITECTURE", "PARTIAL in EPIC/EXOTIC; effect not quantified by current architecture", 70 + finalIndex)
        end
        if fallback and finalIndex >= 4 then
            add(data, "FUTURE_BRIDGE_OR_ARCHITECTURE", "fallback/Scarcity in EPIC/EXOTIC", 65 + finalIndex)
        end
        if utility and utility <= 35 and finalIndex >= 4 and status ~= "MECHANICALLY_TRIVIAL" then
            add(data, "PROBABLE_RULE_ISSUE", "low normalized Utility (<=35) in EPIC/EXOTIC", 60 + finalIndex)
        end
        if utility and utility >= 70 and finalIndex <= 2 and status ~= "MECHANICALLY_TRIVIAL" then
            add(data, "ACCEPTABLE_BY_DESIGN", "high normalized Utility (>=70) held at COMMON/UNCOMMON", 45 + (3 - finalIndex))
        end
        local profile = tostring(data.utilityProfile or "")
        local kind = tostring(data.utilityKind or "")
        if profile ~= "" and profile ~= "nil" and kind ~= "" and kind ~= "nil" then
            local profileKey = kind .. "|" .. profile
            profiles[profileKey] = profiles[profileKey] or {}
            table.insert(profiles[profileKey], data)
        end
    end
    -- Identical profiles are the strongest safe signal for a Scarcity-driven
    -- visual gap, because the mechanics used by the active Utility match.
    for _, members in pairs(profiles) do
        if #members >= 2 then
            local low, high = members[1], members[1]
            for _, data in ipairs(members) do
                if (tierIndex[data.finalRarityTier] or 1) < (tierIndex[low.finalRarityTier] or 1) then low = data end
                if (tierIndex[data.finalRarityTier] or 1) > (tierIndex[high.finalRarityTier] or 1) then high = data end
            end
            local gap = (tierIndex[high.finalRarityTier] or 1) - (tierIndex[low.finalRarityTier] or 1)
            if gap >= 2 then
                local note = string.format("identical active Utility profile has %d-tier gap with %s", gap, high.fullType)
                add(low, "ACCEPTABLE_BY_DESIGN", note, 40 + gap)
                add(high, "ACCEPTABLE_BY_DESIGN", string.format("identical active Utility profile has %d-tier gap with %s", gap, low.fullType), 40 + gap)
            end
        end
    end
    local rows = {}
    for _, record in pairs(suspects) do table.insert(rows, record) end
    table.sort(rows, function(a, b)
        local ca, cb = classRank[a.classification], classRank[b.classification]
        if ca ~= cb then return ca > cb end
        if a.severity ~= b.severity then return a.severity > b.severity end
        return a.data.fullType < b.data.fullType
    end)
    local byCategory = {}
    for _, record in ipairs(rows) do
        local category = tostring(record.data.category or record.data.utilityKind or "UNCLASSIFIED")
        byCategory[category] = byCategory[category] or { total=0, bug=0, future=0, acceptable=0 }
        local count = byCategory[category]
        count.total = count.total + 1
        if record.classification == "PROBABLE_RULE_ISSUE" then count.bug = count.bug + 1
        elseif record.classification == "FUTURE_BRIDGE_OR_ARCHITECTURE" then count.future = count.future + 1
        else count.acceptable = count.acceptable + 1 end
    end
    local categories = {}
    for category in pairs(byCategory) do table.insert(categories, category) end
    table.sort(categories)
    local writer = getFileWriter("ItemRarity_GlobalRarityAnomalyAudit.txt", true, false)
    if not writer then return end
    writer:write("Global rarity anomaly audit (READ ONLY)\n")
    writer:write("Heuristics flag review candidates only; no category, score, tier or signature is changed. Identical-profile gaps are marked ACCEPTABLE_BY_DESIGN until a category-specific policy says otherwise.\n")
    writer:write(string.format("PUBLISHED=%d | DISTINCT_SUSPECTS=%d | TOP_LIMIT=50\n\n", (function() local n=0; for _ in pairs(results) do n=n+1 end; return n end)(), #rows))
    writer:write("COUNTS BY CATEGORY\ncategory | suspects | probable rule issue | future bridge/architecture | acceptable by design\n")
    for _, category in ipairs(categories) do
        local c = byCategory[category]
        writer:write(table.concat({ safe(category), safe(c.total), safe(c.bug), safe(c.future), safe(c.acceptable) }, " | ") .. "\n")
    end
    writer:write("\nTOP 50 REVIEW CANDIDATES\nclassification | fullType | displayName | category | FinalTier | ScarcityTier | Utility/fallback | status | reason\n")
    for index, record in ipairs(rows) do
        if index > 50 then break end
        local data = record.data
        local script = findScriptItem(manager, data.fullType)
        local display = text(script, nil, { "getDisplayName" }, { "displayName" })
        local owner = data.utilityKind or "fallback"
        if data.utilityEligible ~= true then owner = "fallback/Scarcity" end
        writer:write(table.concat({ safe(record.classification), safe(data.fullType), safe(display), safe(data.category or data.utilityKind), safe(data.finalRarityTier), safe(data.baseScarcityTier), safe(owner), safe(mechanicalStatus(data)), safe(table.concat(record.reasons, "; ")) }, " | ") .. "\n")
    end
    writer:close()
    ItemRarityUtils.info(string.format("Global rarity anomaly audit written: %d distinct review candidates; top 50 emitted.", #rows))
end

-- Semantic family labels below are diagnostic presentation only. The candidate
-- predicate itself is strictly Category=MISC plus the existing structural
-- MECHANICALLY_TRIVIAL state; no name-based runtime rule is created.
local function miscTrivialDiagnosticFamily(fullType)
    local key = lower(tostring(fullType or ""))
    if has(key, "bellybutton") or has(key, "earring") or has(key, "nosestud") then return "piercing" end
    if has(key, "bracelet") or has(key, "necklace") then return "jewelry" end
    if has(key, "glasses") then return "eyewear_cosmetic" end
    if has(key, "tie_") or has(key, "bowtie") then return "tie" end
    if has(key, "sheath") then return "sheath" end
    return "other"
end

local function writeMiscTrivialPolicySimulation(results)
    if type(results) ~= "table" or not getFileWriter then return end
    local manager = getScriptManager and getScriptManager() or nil
    local rows, families = {}, {}
    for _, data in pairs(results) do
        local status = data.clothingMechanicalValueStatus or data.accessoryMechanicalValueStatus
        if data.category == "MISC" and status == "MECHANICALLY_TRIVIAL" and data.finalRarityTier ~= "COMMON" then
            local family = miscTrivialDiagnosticFamily(data.fullType)
            families[family] = (families[family] or 0) + 1
            table.insert(rows, { data=data, family=family, status=status })
        end
    end
    table.sort(rows, function(a, b) return a.data.fullType < b.data.fullType end)
    local order = { "jewelry", "piercing", "eyewear_cosmetic", "tie", "sheath", "other" }
    local writer = getFileWriter("ItemRarity_MiscTrivialPolicySimulation.txt", true, false)
    if not writer then return end
    writer:write("MISC trivial-policy simulation (READ ONLY)\n")
    writer:write("Predicate: category=MISC AND existing MechanicalState=MECHANICALLY_TRIVIAL. Proposed FinalTier=COMMON, Scarcity excluded. Semantic family labels are report-only and do not participate in the predicate.\n")
    writer:write("CANDIDATES_ABOVE_COMMON=" .. tostring(#rows) .. "\n")
    writer:write("FAMILY COUNTS\n")
    for _, family in ipairs(order) do writer:write(family .. "=" .. tostring(families[family] or 0) .. "\n") end
    writer:write("\nfamily | fullType | displayName | ScarcityTier | current FinalTier | proposed FinalTier | structural trivial reason\n")
    for _, row in ipairs(rows) do
        local d = row.data
        local script = findScriptItem(manager, d.fullType)
        local display = text(script, nil, { "getDisplayName" }, { "displayName" })
        local structural = d.accessoryMechanicalSpecialReason or d.clothingMechanicalSpecialReason or "known runtime attributes report no measured mechanical benefit"
        writer:write(table.concat({ safe(row.family), safe(d.fullType), safe(display), safe(d.baseScarcityTier), safe(d.finalRarityTier), "COMMON", safe(structural) }, " | ") .. "\n")
    end
    writer:close()
    ItemRarityUtils.info(string.format("MISC trivial-policy simulation written: %d structurally trivial MISC items above COMMON.", #rows))
end

-- Final V1 closure audit. Unlike the broad exploration report, this applies
-- the approved category-specific semantics before classifying a candidate.
-- In particular, absolute explosive/fire/noise bands and the firearm/fish/
-- literature policies are never evaluated as a generic 0..100 Utility score.
local function writeFinalUtilityClosureAudit(results)
    if type(results) ~= "table" or not getFileWriter then return end
    local tierIndex = { COMMON=1, UNCOMMON=2, RARE=3, EPIC=4, EXOTIC=5 }
    local classRank = { ACEITAVEL_DESIGN=1, ARQUITETURA_FUTURA=2, REGRA_PROVAVEL=3 }
    local manager = getScriptManager and getScriptManager() or nil
    local suspects, profiles = {}, {}
    local function stateOf(data)
        return data.clothingMechanicalValueStatus or data.accessoryMechanicalValueStatus
            or data.foodValueStatus or data.medicalValueStatus or data.utilitySupport or "UNSPECIFIED"
    end
    local function add(data, classification, reason, correction, severity)
        local record = suspects[data.fullType]
        if not record then
            record = { data=data, classification=classification, reasons={}, correction=correction or "-", severity=severity or 0 }
            suspects[data.fullType] = record
        end
        if classRank[classification] > classRank[record.classification] then
            record.classification, record.correction = classification, correction or record.correction
        end
        record.severity = math.max(record.severity, severity or 0)
        table.insert(record.reasons, reason)
    end
    local function clothingC1Tier(score)
        if score < 40 then return "COMMON" end
        if score < 53.64 then return "UNCOMMON" end
        if score < 61.28 then return "RARE" end
        if score < 70 then return "EPIC" end
        return "EXOTIC"
    end
    for _, data in pairs(results) do
        local finalIndex = tierIndex[data.finalRarityTier] or 1
        local state = stateOf(data)
        -- A trivial state is the one generic structural guarantee across the
        -- completed wearable/MISC policies. Anything above COMMON is a real
        -- rule candidate, independent of its original Scarcity.
        if state == "MECHANICALLY_TRIVIAL" and finalIndex > 1 then
            add(data, "REGRA_PROVAVEL", "MECHANICALLY_TRIVIAL published above COMMON", "route the existing structural trivial state to COMMON", 100 + finalIndex)
        end
        -- C1 must match its already-published adjusted continuous score for
        -- every nontrivial DIRECT_SLOT record.
        local direct = (data.utilityComponents or {}).directSlot
        if data.category == "CLOTHING" and direct and state ~= "MECHANICALLY_TRIVIAL"
            and tonumber(data.clothingAdjustedScore) ~= nil then
            local expected = clothingC1Tier(tonumber(data.clothingAdjustedScore))
            if data.finalRarityTier ~= expected then
                add(data, "REGRA_PROVAVEL", "DIRECT_SLOT C1 final tier differs from published adjusted score", "use C1 tier(ClothingAdjustedScore) consistently", 95)
            end
        end
        if data.category == "CONTAINER" and data.containerWalletTrivial == true and data.finalRarityTier ~= "COMMON" then
            add(data, "REGRA_PROVAVEL", "structural Wallet predicate published above COMMON", "apply the existing Wallet trivial policy before fallback", 94)
        end
        -- These are explicitly deferred by V1 architecture. A high tier is
        -- notable but not a rule bug: there is no quantified replacement yet.
        local fallbackReason = lower(tostring(data.utilityAdjustmentReason or ""))
        local fallback = data.utilityEligible ~= true or has(fallbackReason, "fallback")
            or has(fallbackReason, "deferred") or has(fallbackReason, "no eligible")
        if finalIndex >= 4 and (state == "MECHANICAL_VALUE_PARTIAL" or state == "UTILITY_PARTIAL" or fallback) then
            add(data, "ARQUITETURA_FUTURA", "PARTIAL/fallback published in EPIC/EXOTIC under an intentionally unquantified role", "requires future bridge/runtime or category-specific Utility", 60 + finalIndex)
        end
        -- Mechanical profile gaps are reviewable, but Scarcity is deliberately
        -- still meaningful for several completed categories. Keep them as
        -- design observations, never generic bugs.
        local profile, kind = tostring(data.utilityProfile or ""), tostring(data.utilityKind or "")
        if profile ~= "" and profile ~= "nil" and kind ~= "" and kind ~= "nil" then
            local key = kind .. "|" .. profile
            profiles[key] = profiles[key] or {}
            table.insert(profiles[key], data)
        end
    end
    for _, members in pairs(profiles) do
        if #members >= 2 then
            local low, high = members[1], members[1]
            for _, data in ipairs(members) do
                if (tierIndex[data.finalRarityTier] or 1) < (tierIndex[low.finalRarityTier] or 1) then low = data end
                if (tierIndex[data.finalRarityTier] or 1) > (tierIndex[high.finalRarityTier] or 1) then high = data end
            end
            local gap = (tierIndex[high.finalRarityTier] or 1) - (tierIndex[low.finalRarityTier] or 1)
            if gap >= 2 then
                add(low, "ACEITAVEL_DESIGN", string.format("identical active mechanical profile has %d-tier visual gap with %s", gap, high.fullType), "Scarcity remains an intentional differentiator for this completed policy", 25 + gap)
                add(high, "ACEITAVEL_DESIGN", string.format("identical active mechanical profile has %d-tier visual gap with %s", gap, low.fullType), "Scarcity remains an intentional differentiator for this completed policy", 25 + gap)
            end
        end
    end
    local rows = {}
    for _, record in pairs(suspects) do table.insert(rows, record) end
    table.sort(rows, function(a, b)
        local ca, cb = classRank[a.classification], classRank[b.classification]
        if ca ~= cb then return ca > cb end
        if a.severity ~= b.severity then return a.severity > b.severity end
        return a.data.fullType < b.data.fullType
    end)
    local totals = { REGRA_PROVAVEL=0, ARQUITETURA_FUTURA=0, ACEITAVEL_DESIGN=0 }
    local futureFamilies = {}
    for _, record in ipairs(rows) do
        totals[record.classification] = totals[record.classification] + 1
        if record.classification == "ARQUITETURA_FUTURA" then
            local category = tostring(record.data.category or record.data.utilityKind or "UNCLASSIFIED")
            futureFamilies[category] = (futureFamilies[category] or 0) + 1
        end
    end
    local futureOrder = {}
    for category in pairs(futureFamilies) do table.insert(futureOrder, category) end
    table.sort(futureOrder)
    local writer = getFileWriter("ItemRarity_FinalUtilityClosureAudit.txt", true, false)
    if not writer then return end
    writer:write("Final Utility/Rarity V1 closure audit (READ ONLY)\n")
    writer:write("Completed category semantics are applied before anomaly classification. No registry field or tier is changed.\n")
    writer:write("TOTAL_ITEMS=" .. tostring((function() local n=0; for _ in pairs(results) do n=n+1 end; return n end)()) .. "\n")
    writer:write("TOTAL_SUSPECTS=" .. tostring(#rows) .. "\n")
    writer:write("REGRA_PROVAVEL=" .. tostring(totals.REGRA_PROVAVEL) .. "\n")
    writer:write("ARQUITETURA_FUTURA=" .. tostring(totals.ARQUITETURA_FUTURA) .. "\n")
    writer:write("ACEITAVEL_DESIGN=" .. tostring(totals.ACEITAVEL_DESIGN) .. "\n\n")
    writer:write("ARQUITETURA_FUTURA BY CATEGORY\n")
    for _, category in ipairs(futureOrder) do writer:write(category .. "=" .. tostring(futureFamilies[category]) .. "\n") end
    writer:write("\nREGRA_PROVAVEL (only)\nfullType | displayName | category | FinalTier | ScarcityTier | Utility/fallback | mechanical state | exact reason | generic correction\n")
    for _, record in ipairs(rows) do
        if record.classification == "REGRA_PROVAVEL" then
            local data = record.data
            local script = findScriptItem(manager, data.fullType)
            local display = text(script, nil, { "getDisplayName" }, { "displayName" })
            local owner = data.utilityEligible == true and (data.utilityKind or "Utility") or "fallback/Scarcity"
            writer:write(table.concat({ safe(data.fullType), safe(display), safe(data.category), safe(data.finalRarityTier), safe(data.baseScarcityTier), safe(owner), safe(stateOf(data)), safe(table.concat(record.reasons, "; ")), safe(record.correction) }, " | ") .. "\n")
        end
    end
    writer:close()
    ItemRarityUtils.info(string.format("Final Utility/Rarity closure audit written: total=%d rule=%d future=%d acceptable=%d.", #rows, totals.REGRA_PROVAVEL, totals.ARQUITETURA_FUTURA, totals.ACEITAVEL_DESIGN))
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
    writeSystemCoverageReport(results)
    writeToolAudit(results)
    writeRecipeInfrastructureAudit()
    writeExplosiveTrapAudit(results)
    writeClothingTargetedAudit(results)
    writeOuterwearAudit(results)
    writeSmallContainerAudit(results)
    writeClothingCombinerSimulation(results)
    writeClothingTrivialPolicySimulation(results)
    writeWalletTrivialSimulation(results)
    writeGlobalRarityAnomalyAudit(results)
    writeMiscTrivialPolicySimulation(results)
    writeFinalUtilityClosureAudit(results)
    ItemRarityUtils.info(string.format("FIREARM audit written: firearms=%d (%d profiles) | ammo=%d (%d profiles) | magazines=%d (%d profiles) | parts=%d (%d profiles).",
        #groups.FIREARM, countProfiles(groups.FIREARM), #groups.AMMO, countProfiles(groups.AMMO), #groups.MAGAZINE, countProfiles(groups.MAGAZINE), #groups.WEAPON_PART, countProfiles(groups.WEAPON_PART)))
    return true
end
