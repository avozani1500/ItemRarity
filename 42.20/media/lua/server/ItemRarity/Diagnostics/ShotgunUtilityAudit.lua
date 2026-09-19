require "ItemRarity/RarityUtils"
require "ItemRarity/RarityConfig"

-- Read-only forensic report for the active FirearmUtility V1 SHOTGUN family.
-- It never calls UtilityCalculator, never rescans and never writes to the
-- registry. All scores below are values already published on current rows.
ItemRarityShotgunUtilityAudit = ItemRarityShotgunUtilityAudit or {}

local TIER_INDEX = { COMMON=1, UNCOMMON=2, RARE=3, EPIC=4, EXOTIC=5 }

local function call(object, method)
    if not object then return nil end
    local ok, fn = pcall(function() return object[method] end)
    if not ok or type(fn) ~= "function" then return nil end
    local called, value = pcall(function() return fn(object) end)
    return called and value or nil
end

local function field(object, name)
    local ok, value = pcall(function() return object and object[name] end)
    return ok and value or nil
end

local function value(script, runtime, getters, fields)
    for _, getter in ipairs(getters or {}) do
        local got = call(runtime, getter)
        if got ~= nil then return got end
        got = call(script, getter)
        if got ~= nil then return got end
    end
    for _, name in ipairs(fields or {}) do
        local got = field(runtime, name)
        if got ~= nil then return got end
        got = field(script, name)
        if got ~= nil then return got end
    end
    return nil
end

local function number(script, runtime, getters, fields)
    return tonumber(value(script, runtime, getters, fields))
end

local function text(script, runtime, getters, fields)
    local got = value(script, runtime, getters, fields)
    return got == nil and "" or tostring(got)
end

local function boolean(script, runtime, getters, fields)
    return value(script, runtime, getters, fields) == true
end

local function lower(v) return string.lower(tostring(v or "")) end
local function round(v) return v == nil and nil or math.floor(v * 1000 + .5) / 1000 end
local function safe(v)
    if v == nil or v == "" then return "-" end
    if type(v) == "number" then return string.format("%.3f", v) end
    return tostring(v):gsub("[\r\n|]", " ")
end

local function runtimeFor(script)
    if not script then return nil end
    local ok, item = pcall(function() return script:InstanceItem(nil, false) end)
    return ok and item or nil
end

local function scarcityPercentile(data)
    return tonumber(data.scarcityPercentile)
        or tonumber(data.tableAvailability and data.tableAvailability.routeWeightedPercentile)
end

local function component(data, name)
    return tonumber(data.utilityComponents and data.utilityComponents[name])
end

local function recordFor(data, manager)
    if data.utilityKind ~= "FIREARM" or data.utilitySubgroup ~= "SHOTGUN" then return nil end
    local script = manager and manager:FindItem(data.fullType) or nil
    if not script then return nil end
    local runtime = runtimeFor(script)
    local minDamage = number(script, runtime, { "getMinDamage" }, { "minDamage" })
    local maxDamage = number(script, runtime, { "getMaxDamage" }, { "maxDamage" })
    local percentile = scarcityPercentile(data)
    local strength = tonumber(data.firearmScarcityStrength) or (percentile and (100 - percentile) or 50)
    return {
        data=data,
        fullType=data.fullType,
        displayName=text(runtime, script, { "getDisplayName", "getName" }, { "displayName", "name" }),
        source=tostring(data.fullType):match("^Base%.") and "VANILLA" or "MODDED",
        family=data.utilitySubgroup,
        ammoType=text(script, runtime, { "getAmmoType" }, { "ammoType" }),
        fireMode=text(script, runtime, { "getFireMode" }, { "fireMode" }),
        minDamage=minDamage, maxDamage=maxDamage,
        averageDamage=minDamage and maxDamage and (minDamage + maxDamage) / 2 or nil,
        minRange=number(script, runtime, { "getMinRange" }, { "minRange" }),
        maxRange=number(script, runtime, { "getMaxRange" }, { "maxRange" }),
        maxAmmo=number(script, runtime, { "getMaxAmmo" }, { "maxAmmo" }),
        maxHitCount=number(script, runtime, { "getMaxHitCount" }, { "maxHitCount", "maxHitcount" }),
        criticalChance=number(script, runtime, { "getCriticalChance" }, { "criticalChance" }),
        criticalMultiplier=number(script, runtime, { "getCriticalDamageMultiplier", "getCritDmgMultiplier" }, { "criticalDamageMultiplier", "critDmgMultiplier" }),
        aimingTime=number(script, runtime, { "getAimingTime" }, { "aimingTime", "aimingtime" }),
        reloadTime=number(script, runtime, { "getReloadTime" }, { "reloadTime", "reloadtime" }),
        recoilDelay=number(script, runtime, { "getRecoilDelay" }, { "recoilDelay" }),
        hitChance=number(script, runtime, { "getHitChance" }, { "hitChance" }),
        swingTime=number(script, runtime, { "getSwingTime" }, { "swingTime" }),
        conditionMax=number(script, runtime, { "getConditionMax" }, { "conditionMax" }),
        conditionLowerChance=number(script, runtime, { "getConditionLowerChance" }, { "conditionLowerChance" }),
        weight=number(script, runtime, { "getActualWeight", "getWeight" }, { "actualWeight", "weight" }),
        soundRadius=number(script, runtime, { "getSoundRadius" }, { "soundRadius" }),
        piercing=boolean(script, runtime, { "isPiercingBullets" }, { "piercingBullets" }),
        projectileCount=number(script, runtime, { "getProjectileCount", "getProjectileNumber" }, { "projectileCount", "projectileNumber" }),
        projectileSpread=number(script, runtime, { "getProjectileSpread", "getProjectileSpreadModifier" }, { "projectileSpread", "projectileSpreadModifier" }),
        absoluteOffense=component(data, "offense"), absoluteCapacity=component(data, "capacity"),
        absoluteHandling=component(data, "handling"), absoluteRange=component(data, "range"),
        relativeOffense=component(data, "relativeOffense"), relativeCapacity=component(data, "relativeCapacity"),
        relativeHandling=component(data, "relativeHandling"), relativeRange=component(data, "relativeRange"),
        absoluteValue=tonumber(data.firearmAbsoluteValue), relativeValue=tonumber(data.firearmRelativeFamilyScore),
        combined=tonumber(data.firearmCombinedScore), confidence=data.firearmRankingConfidence,
        relativeWeight=(ItemRarityConfig.utility and ItemRarityConfig.utility.firearm and ItemRarityConfig.utility.firearm.relativeWeight or {})[data.firearmRankingConfidence] or 0,
        scarcityPercentile=percentile, scarcityStrength=strength,
        scarcityContribution=.05 * strength,
        finalScore=tonumber(data.firearmFinalScore), finalTier=data.finalRarityTier,
        occurrences=data.occurrences or 0,
    }
end

local function delta(left, right, key)
    local a, b = left[key], right[key]
    if a == nil or b == nil then return "-" end
    return string.format("%+.3f", b - a)
end

local function tierDelta(left, right)
    local a, b = TIER_INDEX[left.finalTier] or 0, TIER_INDEX[right.finalTier] or 0
    return string.format("%+d", b - a)
end

-- A report-only near-variant pairing. It uses only common ammo mechanism and
-- capacity; no display name/fullType pattern decides a pair. For the vanilla
-- shotguns this finds the two normal/sawed-off comparisons naturally.
local function structuralPairs(rows)
    local buckets, pairRows = {}, {}
    for _, row in ipairs(rows) do
        local key = lower(row.ammoType) .. "|" .. tostring(row.maxAmmo or "-")
        buckets[key] = buckets[key] or {}
        table.insert(buckets[key], row)
    end
    for key, members in pairs(buckets) do
        table.sort(members, function(a,b) return a.fullType < b.fullType end)
        for leftIndex=1,#members-1 do
            for rightIndex=leftIndex+1,#members do
                table.insert(pairRows, { key=key, left=members[leftIndex], right=members[rightIndex] })
            end
        end
    end
    table.sort(pairRows, function(a,b) return a.left.fullType .. a.right.fullType < b.left.fullType .. b.right.fullType end)
    return pairRows
end

local function writeRows(writer, rows)
    writer:write("\nALL ACTIVE SHOTGUNS\n")
    writer:write("fullType | displayName | source | family | ammo / fireMode | damage min/max/avg | range min/max | cap / maxHit | crit chance/mult | swing/aim/reload/recoil/hitChance | condition/lowerChance | weight/sound | piercing | pelletCount/spread | abs Off/Cap/Handle/Range | rel Off/Cap/Handle/Range | Absolute | Relative | relativeWeight/confidence | Combined | Scarcity pct/strength/contribution | FinalScore | FinalTier | occurrences\n")
    for _, row in ipairs(rows) do
        writer:write(table.concat({
            safe(row.fullType), safe(row.displayName), safe(row.source), safe(row.family), safe(row.ammoType) .. "/" .. safe(row.fireMode),
            safe(row.minDamage) .. "/" .. safe(row.maxDamage) .. "/" .. safe(row.averageDamage), safe(row.minRange) .. "/" .. safe(row.maxRange),
            safe(row.maxAmmo) .. "/" .. safe(row.maxHitCount), safe(row.criticalChance) .. "/" .. safe(row.criticalMultiplier),
            safe(row.swingTime) .. "/" .. safe(row.aimingTime) .. "/" .. safe(row.reloadTime) .. "/" .. safe(row.recoilDelay) .. "/" .. safe(row.hitChance),
            safe(row.conditionMax) .. "/" .. safe(row.conditionLowerChance), safe(row.weight) .. "/" .. safe(row.soundRadius), safe(row.piercing),
            safe(row.projectileCount) .. "/" .. safe(row.projectileSpread),
            safe(row.absoluteOffense) .. "/" .. safe(row.absoluteCapacity) .. "/" .. safe(row.absoluteHandling) .. "/" .. safe(row.absoluteRange),
            safe(row.relativeOffense) .. "/" .. safe(row.relativeCapacity) .. "/" .. safe(row.relativeHandling) .. "/" .. safe(row.relativeRange),
            safe(row.absoluteValue), safe(row.relativeValue), safe(row.relativeWeight) .. "/" .. safe(row.confidence), safe(row.combined),
            safe(row.scarcityPercentile) .. "/" .. safe(row.scarcityStrength) .. "/" .. safe(row.scarcityContribution),
            safe(row.finalScore), safe(row.finalTier), safe(row.occurrences),
        }, " | ") .. "\n")
    end
end

local function writePairs(writer, rows)
    local pairs = structuralPairs(rows)
    writer:write("\nSTRUCTURAL NEAR-VARIANT PAIRS (same ammo mechanism + capacity)\n")
    writer:write("This is a pairing aid only. It is not used by FirearmUtility and does not infer a sawed-off rule. Delta direction is right minus left.\n")
    writer:write("pair key | left fullType/display | right fullType/display | raw dDamage/dRange/dWeight/dAim/dReload/dRecoil | abs dOff/dCap/dHandle/dRange | dAbsolute/dRelative/dCombined/dFinal | tier delta\n")
    for _, pair in ipairs(pairs) do
        local l, r = pair.left, pair.right
        local raw = table.concat({ "damage=" .. delta(l,r,"averageDamage"), "range=" .. delta(l,r,"maxRange"), "weight=" .. delta(l,r,"weight"), "aim=" .. delta(l,r,"aimingTime"), "reload=" .. delta(l,r,"reloadTime"), "recoil=" .. delta(l,r,"recoilDelay") }, ";")
        local components = table.concat({ "off=" .. delta(l,r,"absoluteOffense"), "cap=" .. delta(l,r,"absoluteCapacity"), "handling=" .. delta(l,r,"absoluteHandling"), "range=" .. delta(l,r,"absoluteRange") }, ";")
        local scores = table.concat({ "absolute=" .. delta(l,r,"absoluteValue"), "relative=" .. delta(l,r,"relativeValue"), "combined=" .. delta(l,r,"combined"), "final=" .. delta(l,r,"finalScore") }, ";")
        writer:write(table.concat({ safe(pair.key), safe(l.fullType) .. "/" .. safe(l.displayName), safe(r.fullType) .. "/" .. safe(r.displayName), raw, components, scores, tierDelta(l,r) }, " | ") .. "\n")
    end
end

function ItemRarityShotgunUtilityAudit.write(results)
    if type(results) ~= "table" or not getFileWriter then return nil end
    local manager = getScriptManager and getScriptManager() or nil
    if not manager then return nil end
    local rows = {}
    for _, data in pairs(results) do
        local row = recordFor(data, manager)
        if row then table.insert(rows, row) end
    end
    table.sort(rows, function(a,b) return (a.finalScore or 0) == (b.finalScore or 0) and a.fullType < b.fullType or (a.finalScore or 0) > (b.finalScore or 0) end)
    local writer = getFileWriter("ItemRarity_ShotgunUtilityAudit.txt", true, false)
    if not writer then return nil end
    local tiers = { COMMON=0, UNCOMMON=0, RARE=0, EPIC=0, EXOTIC=0 }
    for _, row in ipairs(rows) do tiers[row.finalTier] = (tiers[row.finalTier] or 0) + 1 end
    local second = rows[2]
    writer:write("Item Rarity FirearmUtility SHOTGUN audit (READ ONLY)\n")
    writer:write("Reads active published values only. It does not recalculate FirearmUtility, normalize a family, change a tier, rescan or publish registry data.\n")
    writer:write("Firearm V1 Model B uses absolute vanilla p05/p95 reference, then family refinement controlled by RankingConfidence, then 95% Combined + 5% ScarcityStrength.\n")
    writer:write(string.format("SHOTGUN_FULLTYPES=%d | RankingConfidence=%s | relativeWeight=%s\n", #rows, safe(rows[1] and rows[1].confidence), safe(rows[1] and rows[1].relativeWeight)))
    writer:write(string.format("TIER_DISTRIBUTION | COMMON=%d | UNCOMMON=%d | RARE=%d | EPIC=%d | EXOTIC=%d\n", tiers.COMMON, tiers.UNCOMMON, tiers.RARE, tiers.EPIC, tiers.EXOTIC))
    if rows[1] and second then writer:write(string.format("TOP_SCORE_GAP | %s %.3f minus %s %.3f = %.3f\n", rows[1].fullType, rows[1].finalScore or 0, second.fullType, second.finalScore or 0, (rows[1].finalScore or 0) - (second.finalScore or 0))) end
    writer:write("No dedicated pellet/spread getter returned a value if '-' is shown; maxHitCount remains the exposed multi-hit signal used by the active formula.\n")
    writeRows(writer, rows)
    writePairs(writer, rows)
    writer:write("\nTOP 10 BY ACTIVE FINAL SCORE\nrank | fullType | displayName | FinalScore | Absolute | Relative | Combined | ScarcityContribution | FinalTier\n")
    for index, row in ipairs(rows) do
        if index > 10 then break end
        writer:write(string.format("%d | %s | %s | %.3f | %.3f | %.3f | %.3f | %.3f | %s\n", index, row.fullType, safe(row.displayName), row.finalScore or 0, row.absoluteValue or 0, row.relativeValue or 0, row.combined or 0, row.scarcityContribution or 0, safe(row.finalTier)))
    end
    writer:close()
    ItemRarityUtils.info(string.format("SHOTGUN audit written: %d active firearms.", #rows))
    return true
end
