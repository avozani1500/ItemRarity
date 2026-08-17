require "ItemRarity/RarityConfig"
require "ItemRarity/RarityUtils"
require "ItemRarity/UtilityCalculator"

ItemRarityWeaponLaboratory = ItemRarityWeaponLaboratory or {}

-- This module is loaded only by development reports. Runtime calculations stay
-- in UtilityCalculator; shared readers are exposed through the diagnostic API.
local API = ItemRarityUtilityCalculator.getWeaponDiagnosticApi()
local UTILITY = ItemRarityConfig.utility
local NORMALIZATION = UTILITY.normalization
local sortedCopy = API.sortedCopy
local quantile = API.quantile
local uniqueSorted = API.uniqueSorted
local clamp = API.clamp
local percentileRank = API.percentileRank
local readNumber = API.readNumber
local readBoolean = API.readBoolean
local weaponFamily = API.weaponFamily
-- WeaponUtility laboratory. This report is observational: it uses the
-- already-calculated current metrics and never feeds an experimental score
-- back into FinalRarityTier, the registry, or any UI path.
local WEAPON_METRIC_ORDER = {
    "averageDamage", "attackSpeed", "range", "critical", "durability",
    "multiHit", "weight", "endurance", "knockdown",
}

-- Frozen V1 weights are retained only so the archived A/B/C laboratory can
-- describe historical comparisons. They are not runtime configuration and
-- never participate in WeaponUtility V2.
local LEGACY_WEAPON_V1_WEIGHTS = {
    averageDamage = 0.25, attackSpeed = 0.15, range = 0.10, critical = 0.10,
    durability = 0.15, multiHit = 0.10, weight = 0.05, endurance = 0.05,
    knockdown = 0.05,
}

local function diagnosticRank(records, fieldName, inverted)
    local profileValues = {}
    for _, record in ipairs(records) do
        local value = record[fieldName]
        if value ~= nil and profileValues[record.profile] == nil then profileValues[record.profile] = value end
    end
    local values = {}
    for _, value in pairs(profileValues) do table.insert(values, value) end
    if #values == 0 then return end
    local sorted = sortedCopy(values)
    local low = quantile(sorted, NORMALIZATION.winsorLowPercentile)
    local high = quantile(sorted, NORMALIZATION.winsorHighPercentile)
    local ranks = uniqueSorted((function()
        local output = {}
        for _, value in ipairs(values) do table.insert(output, clamp(value, low, high)) end
        return output
    end)())
    for _, record in ipairs(records) do
        local value = record[fieldName]
        if value ~= nil then record[fieldName .. "Percentile"] = percentileRank(ranks, clamp(value, low, high), inverted) end
    end
end

local function diagnosticProfilePosition(records, scoreField)
    local profiles = {}
    for _, record in ipairs(records) do
        if record[scoreField] ~= nil and profiles[record.profile] == nil then profiles[record.profile] = record[scoreField] end
    end
    local values = {}
    for profile, value in pairs(profiles) do table.insert(values, { profile = profile, value = value }) end
    table.sort(values, function(a, b)
        if a.value == b.value then return a.profile < b.profile end
        return a.value < b.value
    end)
    local positions, count, index = {}, #values, 1
    while index <= count do
        local last = index
        while last < count and values[last + 1].value == values[index].value do last = last + 1 end
        local percentile = count == 1 and 50 or ((index + last - 2) / (2 * (count - 1))) * 100
        local rank = count - last + 1
        for slot = index, last do positions[values[slot].profile] = { percentile = percentile, rank = rank } end
        index = last + 1
    end
    for _, record in ipairs(records) do
        local position = positions[record.profile]
        if position then
            record[scoreField .. "Percentile"] = position.percentile
            record[scoreField .. "Rank"] = position.rank
            record[scoreField .. "Profiles"] = count
        end
    end
end

local function diagnosticUniqueProfiles(records)
    local byProfile = {}
    for _, record in ipairs(records) do
        local current = byProfile[record.profile]
        if not current or record.data.fullType < current.data.fullType then byProfile[record.profile] = record end
    end
    local output = {}
    for _, record in pairs(byProfile) do table.insert(output, record) end
    table.sort(output, function(a, b) return a.data.fullType < b.data.fullType end)
    return output
end

local function diagnosticCorrelation(records, firstField, secondField)
    -- Correlations are calculated once per mechanical profile.  Aliases of the
    -- same weapon must not make a shared profile look more statistically common.
    local profiles = {}
    for _, record in ipairs(records) do
        local first, second = record[firstField], record[secondField]
        if first ~= nil and second ~= nil and profiles[record.profile] == nil then
            profiles[record.profile] = { first = first, second = second }
        end
    end
    local count, firstTotal, secondTotal = 0, 0, 0
    for _, pair in pairs(profiles) do
        count = count + 1
        firstTotal = firstTotal + pair.first
        secondTotal = secondTotal + pair.second
    end
    if count < 3 then return nil, count end
    local firstMean, secondMean = firstTotal / count, secondTotal / count
    local covariance, firstVariance, secondVariance = 0, 0, 0
    for _, pair in pairs(profiles) do
        local firstDelta, secondDelta = pair.first - firstMean, pair.second - secondMean
        covariance = covariance + firstDelta * secondDelta
        firstVariance = firstVariance + firstDelta * firstDelta
        secondVariance = secondVariance + secondDelta * secondDelta
    end
    if firstVariance == 0 or secondVariance == 0 then return nil, count end
    return covariance / math.sqrt(firstVariance * secondVariance), count
end

local function diagnosticWeaponRecord(data)
    local metrics = data.utilityMetrics or {}
    local manager = getScriptManager and getScriptManager() or nil
    local scriptItem = manager and manager:FindItem(data.fullType) or nil
    local ok, runtimeItem = pcall(function() return scriptItem and scriptItem:InstanceItem(nil, false) end)
    if not ok then runtimeItem = nil end
    local minDamage = readNumber(scriptItem, "getMinDamage", "minDamage", nil)
    local maxDamage = readNumber(scriptItem, "getMaxDamage", "maxDamage", nil)
    local swingTime = readNumber(scriptItem, "getSwingTime", "swingTime", nil)
    local averageDamage = metrics.averageDamage or (minDamage and maxDamage and (minDamage + maxDamage) / 2 or nil)
    local endurance = metrics.endurance
    local weight = metrics.weight
    return {
        data = data,
        profile = data.utilityProfile,
        family = weaponFamily(scriptItem) or "UNKNOWN",
        minDamage = minDamage,
        maxDamage = maxDamage,
        averageDamage = averageDamage,
        swingTime = swingTime,
        -- `attackSpeed` is the historical Utility field name, but its raw
        -- value is Swingtime and is ranked inverted (lower is better).
        attackSpeed = swingTime,
        minimumSwingTime = readNumber(scriptItem, "getMinimumSwingTime", "minimumSwingTime", nil),
        -- B42 exposes this reliably on the runtime HandWeapon, not on the
        -- ScriptItem bridge.  `calculateCombatSpeed()` starts at .8 and then
        -- multiplies this value before player-state modifiers are applied.
        baseSpeed = readNumber(runtimeItem, "getBaseSpeed", "baseSpeed", 1),
        range = metrics.range,
        -- These values are not publicly bridged on ScriptItem in B42, while
        -- HandWeapon's runtime methods expose them. Keep both values so the
        -- report can show exactly what the current Utility saw versus reality.
        criticalChance = readNumber(runtimeItem, "getCriticalChance", "criticalChance", nil),
        criticalMultiplier = readNumber(runtimeItem, "getCriticalDamageMultiplier", "criticalDamageMultiplier", nil),
        combatCritical = (function()
            local chance = readNumber(runtimeItem, "getCriticalChance", "criticalChance", nil)
            local multiplier = readNumber(runtimeItem, "getCriticalDamageMultiplier", "criticalDamageMultiplier", nil)
            return chance and multiplier and math.max(0, chance) * math.max(0, multiplier) or nil
        end)(),
        currentCritical = metrics.critical,
        -- Kept under the active metric name for the current-score breakdown.
        critical = metrics.critical,
        conditionMax = readNumber(scriptItem, "getConditionMax", "conditionMax", nil),
        conditionLowerChance = readNumber(scriptItem, "getConditionLowerChance", "conditionLowerChance", nil),
        durability = metrics.durability,
        multiHit = metrics.multiHit,
        weight = weight,
        endurance = endurance,
        knockdown = metrics.knockdown,
        useEndurance = readBoolean(runtimeItem, "isUseEndurance", "useEndurance"),
        twoHanded = readBoolean(runtimeItem, "isTwoHandWeapon", "twoHandWeapon"),
        cantAttackAtLowEndurance = readBoolean(runtimeItem, "isCantAttackWithLowestEndurance", "cantAttackWithLowestEndurance"),
        -- Animation emits SetMeleeDelay with an animation-owned value, so the
        -- exact attack interval cannot be reconstructed from an item alone.
        -- These are deliberately named *indices*, never real seconds or DPS.
        baselineCombatSpeed = readNumber(runtimeItem, "getBaseSpeed", "baseSpeed", 1) * 0.8,
        attackTempoIndex = (function()
            local baseSpeed = readNumber(runtimeItem, "getBaseSpeed", "baseSpeed", 1)
            return swingTime and swingTime > 0 and (0.8 * baseSpeed) / swingTime or nil
        end)(),
        nominalDamageIndex = averageDamage and swingTime and swingTime > 0 and averageDamage / swingTime or nil,
        tempoAdjustedDamageIndex = (function()
            local baseSpeed = readNumber(runtimeItem, "getBaseSpeed", "baseSpeed", 1)
            return averageDamage and swingTime and swingTime > 0 and averageDamage * (0.8 * baseSpeed) / swingTime or nil
        end)(),
        enduranceLoad = weight and endurance and weight * endurance or nil,
    }
end

local function scoreWeaponModel(record, name, offense)
    local p = function(metric) return record[metric .. "Percentile"] or 0 end
    record.efficiency = p("enduranceLoad") * 0.70 + p("weight") * 0.30
    record.control = p("range") * 0.60 + p("knockdown") * 0.40
    record.reliability = p("durability")
    record[name .. "Offense"] = offense
    record[name .. "ScoreBeforePenalty"] = offense * 0.45 + record.efficiency * 0.25
        + record.control * 0.15 + record.reliability * 0.15
    local weakest = math.min(record.efficiency, record.reliability)
    record.softImbalancePenalty = math.max(0, 35 - weakest) * 0.125 -- maximum 4.375
    record[name .. "Score"] = record[name .. "ScoreBeforePenalty"] - record.softImbalancePenalty
end

local function scoreWeaponModels(record)
    -- All three models retain the same 45/25/15/15 architecture. Only the
    -- philosophy inside Offense changes. Indices are winsorized percentiles.
    local p = function(metric) return record[metric .. "Percentile"] or 0 end
    -- A: deliberately production-over-time oriented, but still not DPS.
    scoreWeaponModel(record, "modelA", p("tempoAdjustedDamageIndex") * .55 + p("combatCritical") * .25 + p("multiHit") * .20)
    -- B: impact-oriented; cadence is a supporting 20% of Offense.
    scoreWeaponModel(record, "modelB", p("averageDamage") * .45 + p("combatCritical") * .20 + p("multiHit") * .15 + p("attackTempoIndex") * .20)
    -- C: balanced default; tempo is 15%, with damage still the leading signal.
    scoreWeaponModel(record, "modelC", p("averageDamage") * .40 + p("combatCritical") * .25 + p("multiHit") * .20 + p("attackTempoIndex") * .15)
    -- Sensitivity sweep for Model C: only damage/tempo trade places.
    scoreWeaponModel(record, "modelC10", p("averageDamage") * .45 + p("combatCritical") * .25 + p("multiHit") * .20 + p("attackTempoIndex") * .10)
    scoreWeaponModel(record, "modelC20", p("averageDamage") * .35 + p("combatCritical") * .25 + p("multiHit") * .20 + p("attackTempoIndex") * .20)
end

local function simulatedUtilityCandidate(percentile)
    if percentile == nil then return "-" end
    if percentile >= 95 then return "EXOTIC candidate" end
    if percentile >= 90 then return "EPIC candidate" end
    if percentile >= 80 then return "RARE candidate" end
    return "below RARE"
end

local function writeModelRanking(writer, label, records, scoreField, limit, descending)
    local unique = diagnosticUniqueProfiles(records)
    table.sort(unique, function(a, b)
        if a[scoreField] == b[scoreField] then return a.data.fullType < b.data.fullType end
        if descending then return a[scoreField] > b[scoreField] end
        return a[scoreField] < b[scoreField]
    end)
    writer:write(string.format("\n%s (%d mechanical profiles)\n", label, #unique))
    for index = 1, math.min(limit, #unique) do
        local record = unique[index]
        writer:write(string.format("%2d. %s | family=%s | score=%.2f | p%.2f | offense=%.2f | eff=%.2f | control=%.2f | reliability=%.2f | penalty=%.2f | base=%s\n",
            index, record.data.fullType, record.family, record[scoreField], record[scoreField .. "Percentile"] or -1,
            record[string.gsub(scoreField, "Score$", "Offense")] or -1, record.efficiency, record.control, record.reliability,
            record.softImbalancePenalty, record.data.baseScarcityTier or "-"))
    end
end

local function writeWeaponLine(writer, record)
    local data = record.data
    writer:write(string.format("\n%s | base=%s | activeEligible=%s | currentUtility=%s | currentParentP=%s\n",
        data.fullType, data.baseScarcityTier, tostring(data.utilityEligible), data.utility and string.format("%.2f", data.utility) or "-",
        data.utilityParentPercentile and string.format("%.2f", data.utilityParentPercentile) or "-"))
    if not data.utilityEligible then writer:write("active exclusion: " .. tostring(data.utilityAdjustmentReason) .. " (included in this report only)\n") end
    writer:write(string.format("raw: minDamage=%s | maxDamage=%s | averageDamage=%s | Swingtime=%s | MinimumSwingtime=%s | BaseSpeed(runtime)=%s | neutralCombatSpeed(.8*BaseSpeed)=%s\n",
        record.minDamage and string.format("%.3f", record.minDamage) or "-", record.maxDamage and string.format("%.3f", record.maxDamage) or "-",
        record.averageDamage and string.format("%.3f", record.averageDamage) or "-", record.swingTime and string.format("%.3f", record.swingTime) or "-",
        record.minimumSwingTime and string.format("%.3f", record.minimumSwingTime) or "-", record.baseSpeed and string.format("%.3f", record.baseSpeed) or "-",
        record.baselineCombatSpeed and string.format("%.3f", record.baselineCombatSpeed) or "-"))
    writer:write(string.format("cadence: EffectiveAttackTime=unavailable (animation SetMeleeDelay is authoritative) | attackTempoIndex(.8*BaseSpeed/Swingtime)=%s | nominalDamageIndex(avg/Swingtime)=%s | damageRateIndex(avg*.8*BaseSpeed/Swingtime)=%s\n",
        record.attackTempoIndex and string.format("%.3f", record.attackTempoIndex) or "-",
        record.nominalDamageIndex and string.format("%.3f", record.nominalDamageIndex) or "-",
        record.tempoAdjustedDamageIndex and string.format("%.3f", record.tempoAdjustedDamageIndex) or "-"))
    writer:write(string.format("combat fields: range=%s | criticalChance(runtime)=%s | critMultiplier(runtime)=%s | realCriticalProduct=%s | currentUtilityCriticalProduct=%s | conditionMax=%s | conditionLowerChance=%s | derivedDurability=%s | multiHit=%s | weight=%s | EnduranceMod=%s | weight*EnduranceMod=%s | knockdown=%s\n",
        record.range and string.format("%.3f", record.range) or "-", record.criticalChance and string.format("%.3f", record.criticalChance) or "-",
        record.criticalMultiplier and string.format("%.3f", record.criticalMultiplier) or "-", record.combatCritical and string.format("%.3f", record.combatCritical) or "-",
        record.currentCritical and string.format("%.3f", record.currentCritical) or "-",
        record.conditionMax and string.format("%.3f", record.conditionMax) or "-", record.conditionLowerChance and string.format("%.3f", record.conditionLowerChance) or "-",
        record.durability and string.format("%.3f", record.durability) or "-", record.multiHit and string.format("%.3f", record.multiHit) or "-",
        record.weight and string.format("%.3f", record.weight) or "-", record.endurance and string.format("%.3f", record.endurance) or "-",
        record.enduranceLoad and string.format("%.3f", record.enduranceLoad) or "-", record.knockdown and string.format("%.3f", record.knockdown) or "-"))
    writer:write(string.format("B42 flags: isUseEndurance=%s | twoHanded=%s | cantAttackAtLowEndurance=%s\n",
        tostring(record.useEndurance), tostring(record.twoHanded), tostring(record.cantAttackAtLowEndurance)))
    writer:write("current components (percentile x active weight = contribution):\n")
    for _, name in ipairs(WEAPON_METRIC_ORDER) do
        local percentile = data.utilityMetricPercentiles and data.utilityMetricPercentiles[name] or nil
        local weight = LEGACY_WEAPON_V1_WEIGHTS[name] or 0
        writer:write(string.format("  %s | raw=%s | p=%s | weight=%.2f | contribution=%s\n", name,
            record[name] and string.format("%.3f", record[name]) or "-", percentile and string.format("%.2f", percentile) or "-", weight,
            percentile and string.format("%.2f", percentile * weight) or "-"))
    end
    writer:write(string.format("simulation percentiles: avgDamage=%.2f | attackTempo=%.2f | damageRateIndex=%.2f | critical(runtime)=%.2f | multiHit=%.2f | strainProxy(inverted)=%.2f | weight(inverted)=%.2f | range=%.2f | knockdown=%.2f | durability=%.2f\n",
        record.averageDamagePercentile or -1, record.attackTempoIndexPercentile or -1, record.tempoAdjustedDamageIndexPercentile or -1,
        record.combatCriticalPercentile or -1, record.multiHitPercentile or -1,
        record.enduranceLoadPercentile or -1, record.weightPercentile or -1, record.rangePercentile or -1,
        record.knockdownPercentile or -1, record.durabilityPercentile or -1))
    writer:write(string.format("common subscores: efficiency=%.2f | control=%.2f | reliability=%.2f | softBalancePenalty=%.2f\n",
        record.efficiency, record.control, record.reliability, record.softImbalancePenalty))
    for _, model in ipairs({ "modelA", "modelB", "modelC", "modelC10", "modelC20" }) do
        writer:write(string.format("  %s | offense=%.2f | utility=%.2f | rank %d/%d p%.2f | %s\n", model,
            record[model .. "Offense"], record[model .. "Score"], record[model .. "ScoreRank"] or 0,
            record[model .. "ScoreProfiles"] or 0, record[model .. "ScorePercentile"] or -1,
            simulatedUtilityCandidate(record[model .. "ScorePercentile"])))
    end
end

function ItemRarityWeaponLaboratory.writeAnalysis(results)
    if not UTILITY.diagnosticsEnabled or not getFileWriter then return end
    local records = {}
    for _, data in pairs(results) do
        if data.utilityEligible and data.utilityKind == "MELEE_WEAPON" and data.utilityMetrics and data.utilityProfile then
            table.insert(records, diagnosticWeaponRecord(data))
        end
    end
    diagnosticRank(records, "averageDamage", false)
    diagnosticRank(records, "attackTempoIndex", false)
    diagnosticRank(records, "tempoAdjustedDamageIndex", false)
    diagnosticRank(records, "enduranceLoad", true)
    diagnosticRank(records, "range", false)
    diagnosticRank(records, "combatCritical", false)
    diagnosticRank(records, "multiHit", false)
    diagnosticRank(records, "weight", true)
    diagnosticRank(records, "knockdown", false)
    diagnosticRank(records, "durability", false)
    for _, record in ipairs(records) do scoreWeaponModels(record) end
    for _, model in ipairs({ "modelA", "modelB", "modelC", "modelC10", "modelC20" }) do
        diagnosticProfilePosition(records, model .. "Score")
    end

    local writer = getFileWriter("ItemRarity_WeaponUtilityAnalysis.txt", true, false)
    if not writer then return end
    writer:write("Item Rarity WeaponUtility A/B/C laboratory (diagnostic only; active WeaponUtility, tiers and UI unchanged)\n")
    writer:write("CURRENT utility uses nine independent, group-normalized metric percentiles: damage 25%, Swingtime 15%, range 10%, criticalChance*criticalMultiplier 10%, durability 15%, multi-hit 10%, weight 5%, EnduranceMod 5%, knockdown 5%.\n")
    local combatSkillTools = 0
    for _, data in pairs(results) do
        if data.category == "TOOL" and data.utilityEligible and data.utilityKind == "MELEE_WEAPON" then combatSkillTools = combatSkillTools + 1 end
    end
    writer:write(string.format("Combat eligibility: HandWeapons with B42 combat-skill categories (Axe/Spear/SmallBlade/LongBlade/Blunt, including SmallBlunt) are eligible regardless of functional WEAPON/TOOL category. Eligible TOOL combat items=%d.\n", combatSkillTools))
    writer:write("Current Utility does not use MinimumSwingtime, BaseSpeed, isUseEndurance, cantAttackAtLowEndurance, DamageRate, or the B42 weight*EnduranceMod interaction.\n")
    writer:write("CADENCE FINDING (B42.20.2): SwipeStatePlayer receives animation event SetMeleeDelay and forwards its float directly to IsoGameCharacter.setMeleeDelay. Therefore the animation owns the real attack delay; no item-only EffectiveAttackTime can be defensibly reconstructed. MinimumSwingtime is retained as evidence but is not used as cadence here.\n")
    writer:write("Player-neutral mechanical signals: IsoGameCharacter.calculateCombatSpeed begins at .8 and multiplies runtime HandWeapon.BaseSpeed before moodle, skill, fitness, injury, random and equipment modifiers. AttackTempoIndex=(.8*BaseSpeed)/Swingtime and DamageRateIndex=AverageDamage*AttackTempoIndex are comparative indices only, explicitly not seconds, attacks/sec, DamageRate, or DPS.\n")
    writer:write("B42 local combat code uses weight * EnduranceMod in muscle-strain calculation, with additional strength, two-handed, weapon/player and sandbox modifiers. weight*EnduranceMod below is a player-independent proxy, not exact stamina spent per swing. twoHanded and low-endurance restriction are reported but not separately penalized: correctly held two-handed weapons do not take calculateCombatSpeed's missing-secondary-hand .77 penalty, and there is no proof that an extra static penalty would avoid double counting.\n")
    writer:write("COMMON architecture: Efficiency=.70 inverse(weight*EnduranceMod)+.30 inverse(weight); Control=.60 range+.40 knockdown; Reliability=log-derived durability; final=.45 Offense+.25 Efficiency+.15 Control+.15 Reliability minus softPenalty=.125*max(0,35-min(Efficiency,Reliability)).\n")
    writer:write("MODEL A (DPS-oriented reference): Offense=.55 DamageRateIndex+.25 runtime critical+.20 multiHit. MODEL B (Impact): Offense=.45 AverageDamage+.20 runtime critical+.15 multiHit+.20 AttackTempoIndex. MODEL C (Balanced): Offense=.40 AverageDamage+.25 runtime critical+.20 multiHit+.15 AttackTempoIndex. All components are robust percentiles.\n")
    local currentCriticalNonZero, runtimeCriticalAvailable = 0, 0
    for _, record in ipairs(records) do
        if (record.currentCritical or 0) > 0 then currentCriticalNonZero = currentCriticalNonZero + 1 end
        if record.combatCritical ~= nil then runtimeCriticalAvailable = runtimeCriticalAvailable + 1 end
    end
    writer:write(string.format("Critical bridge audit: current Utility saw a non-zero critical product on %d/%d melee profiles; runtime HandWeapon exposed critical data on %d/%d.\n",
        currentCriticalNonZero, #records, runtimeCriticalAvailable, #records))
    local correlations = {
        { "averageDamage", "attackTempoIndex", "average damage vs attack tempo" },
        { "tempoAdjustedDamageIndex", "combatCritical", "damage-rate index vs runtime critical" },
        { "tempoAdjustedDamageIndex", "multiHit", "damage-rate index vs multi-hit" },
        { "combatCritical", "multiHit", "runtime critical vs multi-hit" },
        { "tempoAdjustedDamageIndex", "knockdown", "damage-rate index vs knockdown" },
        { "enduranceLoad", "knockdown", "strain proxy vs knockdown" },
        { "weight", "knockdown", "weight vs knockdown" },
    }
    writer:write("Raw component correlations (Pearson r, one value per mechanical profile; descriptive only):\n")
    for _, entry in ipairs(correlations) do
        local correlation, profiles = diagnosticCorrelation(records, entry[1], entry[2])
        writer:write(string.format("  %s = %s (n=%d)\n", entry[3], correlation and string.format("%.3f", correlation) or "unavailable", profiles or 0))
    end
    for _, model in ipairs({ "modelA", "modelB", "modelC" }) do
        writer:write(string.format("%s final-score correlations (Pearson r):\n", model))
        for _, field in ipairs({ "averageDamage", "attackTempoIndex", "combatCritical", "multiHit", "range", "weight", "enduranceLoad", "knockdown", "durability" }) do
            local correlation, profiles = diagnosticCorrelation(records, field, model .. "Score")
            writer:write(string.format("  %s = %s (n=%d)\n", field, correlation and string.format("%.3f", correlation) or "unavailable", profiles or 0))
        end
    end
    writer:write("\nTARGET DECOMPOSITIONS\n")
    local wanted = {
        "Base.Katana", "Base.Machete", "Base.GardenFork", "Base.HuntingKnife", "Base.HuntingKnifeForged", "Base.KitchenKnife",
        "Base.BaseballBat", "Base.Crowbar", "Base.Cudgel_ScrapSheet", "Base.BlockMaul", "Base.Cudgel_GardenForkHead",
        "Base.Axe", "Base.Spear", "Base.Broom",
        -- Report-only review targets for the A/B EXOTIC simulation. These do
        -- not participate in Utility, tiers, registry publishing or UI.
        "Base.WoodAxeForged", "Base.MacheteForged", "Base.ShortSword",
    }
    local byFullType = {}
    for _, record in ipairs(records) do byFullType[record.data.fullType] = record end
    for _, fullType in ipairs(wanted) do if byFullType[fullType] then writeWeaponLine(writer, byFullType[fullType]) end end
    writer:write("\nSELECTED RANKING: V1 versus Model A/B/C\n")
    local selected = {}
    for _, fullType in ipairs(wanted) do if byFullType[fullType] then table.insert(selected, byFullType[fullType]) end end
    table.sort(selected, function(a, b) return (a.data.utility or -1) > (b.data.utility or -1) end)
    for _, record in ipairs(selected) do writer:write(string.format("%s | V1=%s parentP=%s | A=%.2f p%.2f | B=%.2f p%.2f | C=%.2f p%.2f\n",
        record.data.fullType, record.data.utility and string.format("%.2f", record.data.utility) or "-", record.data.utilityParentPercentile and string.format("%.2f", record.data.utilityParentPercentile) or "-",
        record.modelAScore, record.modelAScorePercentile or -1, record.modelBScore, record.modelBScorePercentile or -1,
        record.modelCScore, record.modelCScorePercentile or -1)) end
    writer:write("\nMODEL C CADENCE SENSITIVITY (only tempo/damage allocation changes inside Offense)\n")
    for _, fullType in ipairs({ "Base.Katana", "Base.Machete", "Base.HuntingKnifeForged", "Base.KitchenKnife", "Base.BlockMaul", "Base.GardenFork" }) do
        local record = byFullType[fullType]
        if record then writer:write(string.format("%s | C10=%.2f p%.2f | C15=%.2f p%.2f | C20=%.2f p%.2f | delta10to20=%.2f points / %.2f percentile\n",
            fullType, record.modelC10Score, record.modelC10ScorePercentile or -1, record.modelCScore, record.modelCScorePercentile or -1,
            record.modelC20Score, record.modelC20ScorePercentile or -1, record.modelC20Score - record.modelC10Score,
            (record.modelC20ScorePercentile or 0) - (record.modelC10ScorePercentile or 0))) end
    end
    for _, model in ipairs({ "modelA", "modelB", "modelC" }) do
        writeModelRanking(writer, "TOP 20 " .. model, records, model .. "Score", 20, true)
        writeModelRanking(writer, "BOTTOM 20 " .. model, records, model .. "Score", 20, false)
        writer:write(string.format("\n%s UTILITY-ONLY POTENTIAL TIERS (deduplicated; p>=95 EXOTIC, p>=90 EPIC; scarcity gates intentionally not applied)\n", model))
        local unique = diagnosticUniqueProfiles(records)
        table.sort(unique, function(a, b) return a[model .. "Score"] > b[model .. "Score"] end)
        for _, tier in ipairs({ "EXOTIC", "EPIC" }) do
            writer:write(tier .. " candidates:\n")
            for _, record in ipairs(unique) do
                local percentile = record[model .. "ScorePercentile"] or -1
                local matches = false
                if tier == "EXOTIC" then matches = percentile >= 95
                elseif tier == "EPIC" then matches = percentile >= 90 and percentile < 95 end
                if matches then writer:write(string.format("  %s | score=%.2f p%.2f | baseScarcity=%s\n", record.data.fullType,
                    record[model .. "Score"], percentile, record.data.baseScarcityTier or "-")) end
            end
        end
    end
    writer:close()
    ItemRarityUtils.info("WeaponUtility analysis report written to Zomboid/Lua/ItemRarity_WeaponUtilityAnalysis.txt.")
end
