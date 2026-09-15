require "ItemRarity/RarityUtils"

-- Read-only feasibility audit for a possible ToolUtility V1.  This module is
-- deliberately loaded only by an explicit dev command.  It reads the current
-- scan and ScriptItem/runtime bridge, but never rescans, republishes or
-- changes candidates, utility values or FinalRarityTier.
ItemRarityToolUtilityAudit = ItemRarityToolUtilityAudit or {}

local TIER_INDEX = { COMMON = 1, UNCOMMON = 2, RARE = 3, EPIC = 4, EXOTIC = 5 }
local TIERS = { "COMMON", "UNCOMMON", "RARE", "EPIC", "EXOTIC" }

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

local function lower(v) return string.lower(tostring(v or "")) end
local function clamp(v, minimum, maximum) return math.max(minimum, math.min(maximum, v)) end

local function safe(value)
    if value == nil or value == "" then return "-" end
    if type(value) == "number" then return string.format("%.3f", value) end
    local cleaned = tostring(value):gsub("[\r\n|]", " ")
    return cleaned
end

local function runtimeFor(script)
    if not script then return nil end
    local ok, item = pcall(function() return script:InstanceItem(nil, false) end)
    return ok and item or nil
end

local function parseTags(raw)
    local tags, seen = {}, {}
    for tag in string.gmatch(lower(raw), "[a-z0-9_]+:[a-z0-9_]+") do
        if not seen[tag] then seen[tag] = true; table.insert(tags, tag) end
    end
    table.sort(tags)
    return tags
end

local function containsTag(tags, suffix)
    for _, tag in ipairs(tags) do
        if tag == "base:" .. suffix then return true end
    end
    return false
end

-- These are B42 script *tag semantics*, never item names/fullTypes.  Each
-- domain represents an independently explicit reusable-tool capability.  A
-- generic material/cosmetic tag (for example hasmetal) deliberately does not
-- qualify: it says nothing about a usable world action.
local FUNCTION_DOMAINS = {
    { id="CONSTRUCTION", tags={ "hammer", "hastoolhead", "removebarricade", "sledgehammer", "crowbar", "prytool" } },
    { id="CUTTING", tags={ "saw", "metalsaw", "smallsaw", "axe", "pickaxe", "cutplant", "choptree", "boltcutters", "scissors" } },
    { id="FASTENING", tags={ "screwdriver", "wrench", "pliers", "metalworkingpliers", "visegrips", "removeglass", "removebullet" } },
    { id="GROUND_WORK", tags={ "digplow", "removestump", "drillwood", "drillmetal", "drillwoodpoor" } },
    { id="ANIMAL_WORK", tags={ "shear", "fleshingtool", "killanimal", "butcheranimal" } },
}

-- These tags are clear tools in the script vocabulary, but the bridge does
-- not expose enough world/recipe semantics to establish their comparative
-- value.  They remain PARTIAL rather than becoming false HIGH detections.
local PARTIAL_TOOL_TAGS = {
    "awl", "carpentrychisel", "crudechisel", "claytool", "headingtool",
    "knappingtool", "knittingneedles", "sewingneedle", "whetstone", "tongs",
    "crudetongs", "fishingnet", "fishinghook", "fishingline", "purifywater",
    "siphongas", "plastertrowel", "farmingloot", "compost", "fertilizer",
}

local function explicitDomains(tags)
    local domains = {}
    for _, domain in ipairs(FUNCTION_DOMAINS) do
        for _, tag in ipairs(domain.tags) do
            if containsTag(tags, tag) then
                table.insert(domains, domain.id)
                break
            end
        end
    end
    return domains
end

local function partialSignal(tags)
    for _, tag in ipairs(PARTIAL_TOOL_TAGS) do
        if containsTag(tags, tag) then return tag end
    end
    return nil
end

local function hasAny(tags, tokens)
    for _, token in ipairs(tokens) do if containsTag(tags, token) then return true end end
    return false
end

local function isReusable(row)
    -- Condition is the only bridge-proven reusable lifecycle signal used here.
    -- Items with a declared replacement, drainable state or an unusually high
    -- use delta are intentionally withheld from HIGH even when a tool tag is
    -- present.  This avoids treating consumables/charges as durable tools.
    if not row.conditionMax or row.conditionMax <= 1 then return false, "conditionMax <= 1" end
    if row.drainable then return false, "drainable" end
    if row.replaceOnUse ~= "" or row.replaceOnDeplete ~= "" then return false, "replacement declared" end
    if row.useDelta and row.useDelta >= 0.10 then return false, "depletable useDelta" end
    return true, "condition-backed reusable"
end

local function toolConfidence(row)
    local domains = explicitDomains(row.tags)
    local reusable, reusableReason = isReusable(row)
    local special = hasAny(row.tags, {
        "usesbattery", "isfirefuel", "isfiretinder", "startfire", "lightwhenattached",
        "tentbed", "megaphone", "compass", "whistle", "harmonica", "aerosol",
    })
    if #domains > 0 and reusable and not special then
        return "REUSABLE_TOOL_HIGH", domains, reusableReason
    end
    local partial = partialSignal(row.tags)
    if #domains > 0 then return "REUSABLE_TOOL_PARTIAL", domains, special and "other specialized runtime function" or reusableReason end
    if partial then return "REUSABLE_TOOL_PARTIAL", domains, "explicit tool tag needs recipe/world-action bridge: " .. partial end
    return "NOT_MEASURABLE", domains, "no explicit reusable-tool action signal"
end

local function toolScore(row)
    local confidence, domains = toolConfidence(row)
    if confidence ~= "REUSABLE_TOOL_HIGH" then return nil, nil end
    -- Candidate V1 only.  The score intentionally values explicit independent
    -- functions more than generic durability/carry data.  Reuse is a modest
    -- confirmation, never a scarcity proxy.  Fixed absolute anchors:
    -- 1 domain=50, 2=65, 3+=80; condition 20=100; carry starts at 60 and
    -- decreases five points per weight above 1.
    local functionValue = 35 + 15 * math.min(#domains, 3)
    local durabilityValue = clamp((row.conditionMax or 0) * 5, 0, 100)
    local carryValue = clamp(60 - 5 * math.max(0, (row.weight or 1) - 1), 20, 60)
    local reuseValue = 100
    local score = .55 * functionValue + .20 * durabilityValue + .15 * carryValue + .10 * reuseValue
    return score, {
        functions = functionValue, durability = durabilityValue, carry = carryValue,
        reuse = reuseValue, domains = domains,
    }
end

local function toolTier(score)
    if not score then return nil end
    -- Conservative fixed bands.  A tool without explicit high-confidence
    -- world/tool signals receives no tier from this diagnostic.
    if score >= 85 then return "EPIC" end
    if score >= 70 then return "RARE" end
    if score >= 55 then return "UNCOMMON" end
    return "COMMON"
end

local function tierForPercentile(percentile)
    if percentile == nil then return nil end
    if percentile >= 85 then return "EXOTIC" end
    if percentile >= 70 then return "EPIC" end
    if percentile >= 55 then return "RARE" end
    if percentile >= 40 then return "UNCOMMON" end
    return "COMMON"
end

local function maxTier(left, right)
    if not left or (TIER_INDEX[right] or 0) > (TIER_INDEX[left] or 0) then return right end
    return left
end

local function tierPlusOne(tier)
    local index = TIER_INDEX[tier]
    return index and TIERS[math.min(#TIERS, index + 1)] or tier
end

local function comboA(row)
    return maxTier(row.weaponTierProxy, row.toolTier)
end

local function comboB(row)
    if not row.toolScore then return row.weaponTierProxy end
    if not row.weaponTierProxy then return row.toolTier end
    -- The second role can contribute only up to 15 normalized points.  Tool
    -- score has no weapon damage/range data, limiting overlap with Weapon V2.
    local weapon = row.weaponPercentile or 0
    local bonus = clamp(((row.toolScore or 0) - 45) * .50, 0, 15)
    return tierForPercentile(clamp(weapon + bonus, 0, 100))
end

local function comboC(row)
    local best = maxTier(row.weaponTierProxy, row.toolTier)
    if row.weaponTierProxy and row.toolTier and (row.toolScore or 0) >= 55 then
        return tierPlusOne(best)
    end
    return best
end

local function rowFor(data, manager)
    local script = manager and manager:FindItem(data.fullType) or nil
    if not script then return nil end
    local runtime = runtimeFor(script)
    local rawTags = text(script, runtime, { "getTags" }, { "tags" })
    local row = {
        data = data,
        fullType = data.fullType,
        displayCategory = text(script, runtime, { "getDisplayCategory" }, { "displayCategory" }),
        itemType = text(script, runtime, { "getType", "getItemType" }, { "type", "itemType" }),
        tags = parseTags(rawTags),
        rawTags = rawTags,
        weight = number(script, runtime, { "getActualWeight", "getWeight" }, { "actualWeight", "weight" }),
        conditionMax = number(script, runtime, { "getConditionMax" }, { "conditionMax" }),
        useDelta = number(script, runtime, { "getUseDelta" }, { "useDelta" }),
        replaceOnUse = text(script, runtime, { "getReplaceOnUse" }, { "replaceOnUse" }),
        replaceOnDeplete = text(script, runtime, { "getReplaceOnDeplete" }, { "replaceOnDeplete" }),
        drainable = boolean(script, runtime, { "isDrainable" }, { "drainable" }),
        canBeActivated = boolean(script, runtime, { "canBeActivated", "isCanBeActivated" }, { "canBeActivated", "activated" }),
        canBeEquipped = boolean(script, runtime, { "isCanBeEquipped", "canBeEquipped" }, { "canBeEquipped", "equipped" }),
        bodyLocation = text(script, runtime, { "getBodyLocation" }, { "bodyLocation" }),
        handType = text(script, runtime, { "getHandType" }, { "handType" }),
        minDamage = number(script, runtime, { "getMinDamage" }, { "minDamage" }),
        maxDamage = number(script, runtime, { "getMaxDamage" }, { "maxDamage" }),
        maxRange = number(script, runtime, { "getMaxRange" }, { "maxRange" }),
        swingTime = number(script, runtime, { "getSwingTime" }, { "swingTime" }),
        conditionLowerChance = number(script, runtime, { "getConditionLowerChance" }, { "conditionLowerChance" }),
        activeUtility = data.utility,
        activeUtilityKind = data.utilityKind,
        activeTier = data.finalRarityTier,
        weaponPercentile = tonumber(data.utilityPercentile),
    }
    row.domains = explicitDomains(row.tags)
    row.confidence, row.domains, row.confidenceReason = toolConfidence(row)
    row.toolScore, row.components = toolScore(row)
    row.toolTier = toolTier(row.toolScore)
    row.weaponTierProxy = data.utilityKind == "MELEE_WEAPON" and tierForPercentile(row.weaponPercentile) or nil
    row.comboA, row.comboB, row.comboC = comboA(row), comboB(row), comboC(row)
    return row
end

local function join(values)
    if not values or #values == 0 then return "-" end
    return table.concat(values, ";")
end

local function countTiers(rows, field)
    local counts = { COMMON=0, UNCOMMON=0, RARE=0, EPIC=0, EXOTIC=0, NONE=0 }
    for _, row in ipairs(rows) do
        local tier = row[field]
        counts[tier or "NONE"] = (counts[tier or "NONE"] or 0) + 1
    end
    return counts
end

local function formatTierCounts(counts)
    return string.format("COMMON=%d | UNCOMMON=%d | RARE=%d | EPIC=%d | EXOTIC=%d | no tool result=%d",
        counts.COMMON or 0, counts.UNCOMMON or 0, counts.RARE or 0,
        counts.EPIC or 0, counts.EXOTIC or 0, counts.NONE or 0)
end

local function writeRows(writer, heading, rows)
    writer:write("\n" .. heading .. "\n")
    writer:write("fullType | displayCategory | itemType | confidence | reason | explicit domains | tags | conditionMax | useDelta | drainable | replaceOnUse/deplete | activated/equippable | weight | min/maxDamage | range/swing | active utility kind/value/percentile | active tier | ToolScore [functions/durability/carry/reuse] | ToolTier | A max | B capped bonus | C max+1\n")
    for _, row in ipairs(rows) do
        local c = row.components or {}
        writer:write(table.concat({
            safe(row.fullType), safe(row.displayCategory), safe(row.itemType), safe(row.confidence), safe(row.confidenceReason), join(row.domains),
            safe(row.rawTags), safe(row.conditionMax), safe(row.useDelta), safe(row.drainable), safe(row.replaceOnUse) .. "/" .. safe(row.replaceOnDeplete),
            safe(row.canBeActivated) .. "/" .. safe(row.canBeEquipped), safe(row.weight), safe(row.minDamage) .. "/" .. safe(row.maxDamage),
            safe(row.maxRange) .. "/" .. safe(row.swingTime), safe(row.activeUtilityKind) .. "/" .. safe(row.activeUtility) .. "/" .. safe(row.weaponPercentile),
            safe(row.activeTier), safe(row.toolScore) .. " [" .. safe(c.functions) .. "/" .. safe(c.durability) .. "/" .. safe(c.carry) .. "/" .. safe(c.reuse) .. "]",
            safe(row.toolTier), safe(row.comboA), safe(row.comboB), safe(row.comboC),
        }, " | ") .. "\n")
    end
end

local function writeTagInventory(writer, rows)
    local counts = {}
    for _, row in ipairs(rows) do
        for _, tag in ipairs(row.tags) do counts[tag] = (counts[tag] or 0) + 1 end
    end
    local tags = {}
    for tag in pairs(counts) do table.insert(tags, tag) end
    table.sort(tags, function(a, b) return counts[a] == counts[b] and a < b or counts[a] > counts[b] end)
    writer:write("\nSTRUCTURAL TAG INVENTORY\n")
    writer:write("tag | Tool fullTypes | interpretation in this audit\n")
    for _, tag in ipairs(tags) do
        local suffix = tag:gsub("^base:", "")
        local interpretation = "observed only"
        for _, domain in ipairs(FUNCTION_DOMAINS) do
            for _, token in ipairs(domain.tags) do if suffix == token then interpretation = "HIGH candidate domain: " .. domain.id end end
        end
        for _, token in ipairs(PARTIAL_TOOL_TAGS) do if suffix == token then interpretation = "PARTIAL: explicit tool but missing comparable action semantics" end end
        writer:write(string.format("%s | %d | %s\n", tag, counts[tag], interpretation))
    end
end

local function writeLargePromotions(writer, rows)
    writer:write("\nPOTENTIAL 2+ TIER PROMOTIONS (READ ONLY)\n")
    writer:write("Only compares active FinalTier with the proposed diagnostic combiners; a row is not a recommendation to integrate.\n")
    writer:write("fullType | active tier | A | B | C | confidence | ToolScore | reason\n")
    local count = 0
    for _, row in ipairs(rows) do
        local active = TIER_INDEX[row.activeTier] or 0
        local highest = math.max(TIER_INDEX[row.comboA] or 0, TIER_INDEX[row.comboB] or 0, TIER_INDEX[row.comboC] or 0)
        if highest - active >= 2 then
            count = count + 1
            writer:write(table.concat({ safe(row.fullType), safe(row.activeTier), safe(row.comboA), safe(row.comboB), safe(row.comboC), safe(row.confidence), safe(row.toolScore), safe(row.confidenceReason) }, " | ") .. "\n")
        end
    end
    writer:write("TOTAL_2PLUS=" .. tostring(count) .. "\n")
end

function ItemRarityToolUtilityAudit.write(results)
    if type(results) ~= "table" or not getFileWriter then return nil end
    local manager = getScriptManager and getScriptManager() or nil
    if not manager then
        ItemRarityUtils.warn("ToolUtility audit skipped: ScriptManager is unavailable")
        return nil
    end

    local rows = {}
    for _, data in pairs(results) do
        if data.category == "TOOL" then
            local row = rowFor(data, manager)
            if row then table.insert(rows, row) end
        end
    end
    table.sort(rows, function(a, b) return a.fullType < b.fullType end)

    local writer = getFileWriter("ItemRarity_ToolUtilityAudit.txt", true, false)
    if not writer then return nil end
    local counts = { REUSABLE_TOOL_HIGH=0, REUSABLE_TOOL_PARTIAL=0, NOT_MEASURABLE=0 }
    for _, row in ipairs(rows) do counts[row.confidence] = (counts[row.confidence] or 0) + 1 end

    writer:write("Item Rarity ToolUtility V1 feasibility audit (READ ONLY)\n")
    writer:write("No CraftRecipe graph/parser is used. No candidate, Utility, FinalRarityTier, registry, scan result or signature is changed.\n")
    writer:write("Tool rows are the current structural category TOOL. Item names/fullTypes appear only as report identifiers, never as detection rules.\n\n")
    writer:write("TOOL_FULLTYPES=" .. tostring(#rows) .. "\n")
    writer:write("REUSABLE_TOOL_HIGH=" .. tostring(counts.REUSABLE_TOOL_HIGH) .. "\n")
    writer:write("REUSABLE_TOOL_PARTIAL=" .. tostring(counts.REUSABLE_TOOL_PARTIAL) .. "\n")
    writer:write("NOT_MEASURABLE=" .. tostring(counts.NOT_MEASURABLE) .. "\n\n")
    writer:write("HIGH requires: >=1 explicit B42 action/tool tag domain + condition-backed non-drainable/no-replacement lifecycle + no specialized light/fire/electronic/camping signal.\n")
    writer:write("PARTIAL is deliberately retained for recipe-dependent tools, consumables, specialty equipment and explicit tool tags whose relative gameplay effect is not exposed.\n")
    writer:write("ToolScore candidate (HIGH only): 55% explicit function domains, 20% condition durability, 15% carry cost, 10% reuse. Fixed bands: <55 C, 55-69 U, 70-84 R, >=85 E. No Scarcity; EXOTIC is impossible.\n")
    writer:write("A=max(WeaponUtility percentile-tier proxy, ToolTier); B=Weapon percentile + capped Tool bonus (max 15), non-weapon uses ToolTier; C=best function tier, then at most +1 when both functions are independently present.\n")
    writer:write("Weapon proxy is diagnostic only: utilityPercentile bands C<40,U<55,R<70,E<85,X>=85. It is not the active WeaponUtility tier policy.\n")

    writeTagInventory(writer, rows)
    local high, partial, notMeasurable = {}, {}, {}
    for _, row in ipairs(rows) do
        if row.confidence == "REUSABLE_TOOL_HIGH" then table.insert(high, row)
        elseif row.confidence == "REUSABLE_TOOL_PARTIAL" then table.insert(partial, row)
        else table.insert(notMeasurable, row) end
    end
    writer:write("\nCOMBINATION DISTRIBUTIONS (HIGH rows only)\n")
    writer:write("A | " .. formatTierCounts(countTiers(high, "comboA")) .. "\n")
    writer:write("B | " .. formatTierCounts(countTiers(high, "comboB")) .. "\n")
    writer:write("C | " .. formatTierCounts(countTiers(high, "comboC")) .. "\n")
    writeRows(writer, "REUSABLE_TOOL_HIGH", high)
    writeRows(writer, "REUSABLE_TOOL_PARTIAL", partial)
    writeRows(writer, "NOT_MEASURABLE", notMeasurable)
    writeLargePromotions(writer, high)
    writer:write("\nSAFETY VERDICT\n")
    writer:write("Do not integrate based on this report alone. TOOL_V1 is safe only if every changed item is HIGH, the chosen combiner has no unjustified 2+ movement, and manual review finds no tag semantic false positives.\n")
    writer:close()
    ItemRarityUtils.info(string.format("ToolUtility feasibility audit written: %d TOOL fullTypes | HIGH=%d | PARTIAL=%d | NOT_MEASURABLE=%d.", #rows, counts.REUSABLE_TOOL_HIGH, counts.REUSABLE_TOOL_PARTIAL, counts.NOT_MEASURABLE))
    return true
end
