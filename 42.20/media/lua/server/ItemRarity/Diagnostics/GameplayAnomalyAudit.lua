require "ItemRarity/RarityUtils"

-- Explicit, read-only forensic report for gameplay observations.  The target
-- labels below are lookup aids only: they never participate in classification,
-- scoring, or tier selection.
ItemRarityGameplayAnomalyAudit = ItemRarityGameplayAnomalyAudit or {}

local function call(object, getter, field)
    if not object then return nil end
    local ok, method = pcall(function() return object[getter] end)
    if ok and type(method) == "function" then
        local worked, value = pcall(function() return method(object) end)
        if worked and value ~= nil then return value end
    end
    local fieldOk, value = pcall(function() return object[field] end)
    return fieldOk and value or nil
end

local function safe(value)
    if value == nil then return "N/A" end
    if type(value) == "table" then
        local parts = {}
        for key, entry in pairs(value) do table.insert(parts, tostring(key) .. "=" .. tostring(entry)) end
        table.sort(parts)
        return table.concat(parts, ",")
    end
    return tostring(value):gsub("[\r\n|]", " ")
end

local function number(value)
    return type(value) == "number" and string.format("%.3f", value) or safe(value)
end

local function scriptFor(fullType)
    local manager = ScriptManager and ScriptManager.instance
    if not manager then return nil end
    local ok, script = pcall(function() return manager:FindItem(fullType) end)
    return ok and script or nil
end

local function displayName(data, script)
    return safe(call(script, "getDisplayName", "displayName") or data.displayName or data.fullType)
end

local function structuralState(data)
    if data.clothingMechanicalValueStatus then return data.clothingMechanicalValueStatus end
    if data.accessoryMechanicalValueStatus then return data.accessoryMechanicalValueStatus end
    if data.medicalValueStatus then return data.medicalValueStatus end
    if data.foodValueStatus then return data.foodValueStatus end
    if data.utilitySupport then return data.utilitySupport end
    return data.utilityEligible and "KNOWN" or "UNSUPPORTED"
end

local function candidateState(data)
    if data.utilityKind and data.utilityKind ~= "UNSUPPORTED" then return data.utilityKind end
    return "UNSUPPORTED"
end

local function scarcityStrength(data)
    local percentile = tonumber(data.scarcityPercentile)
        or (data.tableAvailability and tonumber(data.tableAvailability.routeWeightedPercentile))
    return percentile and (100 - percentile) or nil
end

local function routeWeighted(data)
    return data.routeWeighted or (data.tableAvailability and data.tableAvailability.routeWeighted)
end

local function baseCause(data)
    local kind, status = candidateState(data), structuralState(data)
    if status == "MECHANICALLY_TRIVIAL" and data.finalRarityTier ~= "COMMON" then return "A", "trivial structural state escaped its COMMON policy" end
    if kind == "UNSUPPORTED" or data.utilityEligible ~= true then return "B", "no active Utility; final tier is Scarcity fallback" end
    if kind == "CONTAINER" and not data.utilityEligible then return "F", "specialized/deferred container restrictions are not measurable" end
    if kind == "NOISE_MAKER" then return "G", "absolute tactical NoiseRange policy owns tier (Scarcity excluded)" end
    if kind == "FOOD" then return "C", "FoodUtility score plus its approved Scarcity refinement owns tier" end
    return "G", "active structural Utility/policy owns tier"
end

local targetTokens = {
    "tissue", "tissuebox", "lenç", "umbrella", "guarda", "photo album", "photoalbum", "álbum", "toy rat", "cattoy", "rato", "pizza cutter", "pizzacutter", "cortador", "corkscrew", "saca", "claw hammer", "hammer", "martelo", "wallpaper", "papel de parede", "bottle opener", "bottleopener", "abridor", "sponge holder", "potscrubber", "porta-esponja", "front mirror", "headmirror", "espelho", "game pieces", "gamepiece", "peças de jogo", "garden pitchfork", "gardenfork", "forcado", "socks", "meias", "garden fork", "firecracker", "bombinha", "maple syrup", "maplesyrup", "xarope", "earbuds", "fones", "mortar", "almofariz", "id card", "idcard", "identidade", "cortman", "plastic bag", "plasticbag", "plastic", "saco plástico", "quarter iron", "ironbarquarter", "barra de ferro", "chess", "xadrez", "toilet brush", "toiletbrush", "escova", "smokingpipe", "pipe", "cachimbo", "photo", "carteira",
}

local function targetMatch(data, script)
    local haystack = (safe(data.fullType) .. " " .. displayName(data, script)):lower()
    for _, token in ipairs(targetTokens) do if haystack:find(token, 1, true) then return true end end
    return false
end

local function writeTrace(writer, data)
    local script, class, reason = scriptFor(data.fullType), nil, nil
    class, reason = baseCause(data)
    local metrics, components = data.utilityMetrics or {}, data.utilityComponents or {}
    writer:write("\n[TRACE] " .. safe(data.fullType) .. "\n")
    writer:write("displayName=" .. displayName(data, script) .. "\n")
    writer:write("category=" .. safe(data.category) .. " | displayCategory=" .. safe(data.displayCategory) .. " | utilityKind=" .. candidateState(data) .. " | subgroup=" .. safe(data.utilitySubgroup) .. " | functionalGroup=" .. safe(data.utilityFunctionalGroup) .. "\n")
    writer:write("candidateConfidence=" .. safe(data.utilityConfidence) .. " | candidateState=" .. structuralState(data) .. " | eligible=" .. safe(data.utilityEligible) .. " | support=" .. safe(data.utilitySupport) .. "\n")
    writer:write("ScarcityStrength=" .. number(data.foodScarcityStrength or data.clothingScarcityStrength or scarcityStrength(data)) .. " | ScarcityTier=" .. safe(data.baseScarcityTier or data.rarityTier) .. " | RouteWeighted=" .. number(routeWeighted(data)) .. "\n")
    writer:write("Utility=" .. number(data.utility) .. " | UtilityTier=" .. safe(data.utilityTier or data.noiseMakerFinalTier or data.lightFireTier or data.firearmFinalScore) .. " | Metrics=" .. safe(metrics) .. " | Components=" .. safe(components) .. "\n")
    writer:write("C1Adjustment=" .. number(data.clothingScarcityAdjustment) .. " | AdjustedScore=" .. number(data.clothingAdjustedScore) .. " | FinalTier=" .. safe(data.finalRarityTier) .. "\n")
    writer:write("TRIVIAL=" .. tostring(structuralState(data) == "MECHANICALLY_TRIVIAL") .. " | SPECIAL_PARTIAL=" .. tostring((data.utilityFunctionalGroup or ""):find("PARTIAL", 1, true) ~= nil) .. " | UNSUPPORTED=" .. tostring(candidateState(data) == "UNSUPPORTED") .. "\n")
    writer:write("script: ItemType=" .. safe(call(script, "getType", "type")) .. " | BodyLocation=" .. safe(call(script, "getBodyLocation", "bodyLocation")) .. " | BloodClothingType=" .. safe(call(script, "getBloodClothingType", "bloodClothingType")) .. " | Capacity=" .. number(call(script, "getCapacity", "capacity")) .. " | WeightReduction=" .. number(call(script, "getWeightReduction", "weightReduction")) .. " | Weight=" .. number(call(script, "getActualWeight", "actualWeight") or call(script, "getWeight", "weight")) .. " | AcceptItemFunction=" .. safe(call(script, "getAcceptItemFunction", "acceptItemFunction")) .. "\n")
    writer:write("class=" .. class .. " | reason=" .. reason .. " | finalReason=" .. safe(data.utilityAdjustmentReason) .. "\n")
end

local function structurallyEmpty(data)
    local kind = candidateState(data)
    return kind == "UNSUPPORTED" and data.utilityEligible ~= true
        and not data.clothingMechanicalValueStatus and not data.accessoryMechanicalValueStatus
        and not data.medicalValueStatus and not data.foodValueStatus
end

local function lower(value) return tostring(value or ""):lower() end

local function callbackSignal(script)
    for _, getter in ipairs({ "getOnCreate", "getOnEat", "getOnCooked", "getOnEquip", "getOnUnequip", "getDoubleClickRecipe", "getReplaceOnUse", "getReplaceOnDeplete" }) do
        local value = call(script, getter, nil)
        if value ~= nil and tostring(value) ~= "" and lower(value) ~= "nil" and lower(value) ~= "null" then return true, getter end
    end
    return false, nil
end

-- High-confidence means intentionally narrow: a row must be an unmodelled
-- MISC memento/junk/appearance item with no tags, callbacks, container,
-- equip or consumable signal.  It deliberately leaves uncertain objects out.
local function trivialFallbackPredicate(data, script)
    if candidateState(data) ~= "UNSUPPORTED" or data.utilityEligible == true then return false, "has active or partial Utility route" end
    if data.category ~= "MISC" then return false, "category is not conservative MISC" end
    local display = lower(data.displayCategory)
    if display ~= "memento" and display ~= "junk" and display ~= "appearance" then return false, "display category may have world/mechanical role" end
    local tags = lower(call(script, "getTags", "tags"))
    if tags ~= "" and tags ~= "[]" then return false, "declared tags require future interpretation" end
    local special, source = callbackSignal(script)
    if special then return false, "declared special callback: " .. tostring(source) end
    local capacity = tonumber(call(script, "getCapacity", "capacity")) or 0
    local accept = call(script, "getAcceptItemFunction", "acceptItemFunction")
    if capacity > 0 or (accept and tostring(accept) ~= "") then return false, "container signal" end
    local body = call(script, "getBodyLocation", "bodyLocation")
    local equip = call(script, "getEquipSlot", "equipSlot")
    local attachment = call(script, "getAttachmentType", "attachmentType")
    if (body and tostring(body) ~= "") or (equip and tostring(equip) ~= "") or (attachment and tostring(attachment) ~= "") then return false, "equip/attachment signal" end
    local useDelta = tonumber(call(script, "getUseDelta", "useDelta"))
    local itemType = lower(call(script, "getType", "type") or call(script, "getItemType", "itemType"))
    if itemType:find("drainable", 1, true) or (useDelta and useDelta > 0 and useDelta < .031) then return false, "drainable/useful-consumable signal" end
    return true, "MISC " .. display .. " with no tags, callback, container, equip or consumable evidence"
end

local function tierIndex(tier)
    return ({ COMMON=1, UNCOMMON=2, RARE=3, EPIC=4, EXOTIC=5 })[tier] or 0
end

local function constrainedContainer(data, script)
    if data.utilityKind ~= "CONTAINER" or data.utilityEligible == true then return false end
    local metrics = data.utilityMetrics or {}
    local capacity = tonumber(metrics.capacity) or tonumber(call(script, "getCapacity", "capacity")) or 0
    local reduction = tonumber(metrics.weightReduction) or tonumber(call(script, "getWeightReduction", "weightReduction")) or 0
    local attachments = tonumber(metrics.attachments) or 0
    local accept = data.containerAcceptItemFunction or call(script, "getAcceptItemFunction", "acceptItemFunction")
    local body = data.containerEquipSlot or call(script, "getBodyLocation", "bodyLocation") or call(script, "getEquipSlot", "equipSlot")
    local bodyText = lower(body)
    -- The registry's diagnostic placeholder is not an equip location.  Treat
    -- it like the absent script getter, otherwise it hides the two albums
    -- this audit is intended to evaluate.
    local hasFunctionalSlot = bodyText ~= "" and bodyText ~= "n/a" and bodyText ~= "nil" and bodyText ~= "none" and bodyText ~= "unknown"
    local restricted = accept and tostring(accept) ~= ""
    local micro = capacity > 0 and capacity <= 5 and reduction <= 0 and attachments <= 0 and not hasFunctionalSlot
    return restricted and micro, { capacity=capacity, reduction=reduction, attachments=attachments, accept=accept, body=body }
end

local function noiseTier(range, model)
    if model == "B" then return range < 15 and "COMMON" or (range < 30 and "UNCOMMON" or "RARE") end
    if model == "C" then return range < 15 and "COMMON" or (range < 30 and "UNCOMMON" or (range < 70 and "RARE" or "EPIC")) end
    if model == "D" then return range < 20 and "COMMON" or (range < 50 and "UNCOMMON" or (range < 90 and "RARE" or "EPIC")) end
    return range < 15 and "COMMON" or (range < 30 and "UNCOMMON" or (range < 50 and "RARE" or "EPIC"))
end

local function writePolicyReview(results)
    if type(results) ~= "table" or not getFileWriter then return nil end
    local writer = getFileWriter("ItemRarity_PreReleasePolicyAudit.txt", true, false)
    if not writer then return nil end
    local trivial, excluded, restricted, noises, foods = {}, {}, {}, {}, {}
    for _, data in pairs(results) do
        local script = scriptFor(data.fullType)
        local allowed, reason = trivialFallbackPredicate(data, script)
        if allowed then table.insert(trivial, { data=data, script=script, reason=reason })
        elseif structurallyEmpty(data) and data.category == "MISC" then table.insert(excluded, { data=data, reason=reason }) end
        local container, shape = constrainedContainer(data, script)
        if container then table.insert(restricted, { data=data, script=script, shape=shape }) end
        if data.utilityKind == "NOISE_MAKER" then table.insert(noises, data) end
        if data.utilityKind == "FOOD" and data.utilityEligible then table.insert(foods, data) end
    end
    table.sort(trivial, function(a,b) return a.data.fullType < b.data.fullType end)
    table.sort(excluded, function(a,b) return a.data.fullType < b.data.fullType end)
    table.sort(restricted, function(a,b) return a.data.fullType < b.data.fullType end)
    table.sort(noises, function(a,b) return (a.noiseMakerNoiseRange or 0) > (b.noiseMakerNoiseRange or 0) end)
    table.sort(foods, function(a,b) return (a.foodQuality or 0) > (b.foodQuality or 0) end)
    local trivialRare = 0
    for _, row in ipairs(trivial) do if tierIndex(row.data.finalRarityTier) >= 3 then trivialRare = trivialRare + 1 end end
    writer:write("Item Rarity pre-release structural policy audit (READ ONLY)\n")
    writer:write("No candidate below changes classification, Utility, final tier, registry, signature or runtime behavior.\n\n")
    writer:write("1. HIGH-CONFIDENCE MECHANICALLY_TRIVIAL_FALLBACK SIMULATION\n")
    writer:write("Predicate: UNSUPPORTED MISC + displayCategory Memento/Junk/Appearance + no tags + no callback + no container/equip/attachment + no drainable signal. Everything ambiguous is excluded.\n")
    writer:write(string.format("CANDIDATES=%d | RARE_PLUS=%d | PROPOSED=COMMON | MISC_UNSUPPORTED_EXCLUDED=%d\n", #trivial, trivialRare, #excluded))
    writer:write("fullType | displayName | currentTier | ScarcityTier | ScarcityStrength | displayCategory | proposedTier | confidence | structural reason\n")
    for _, row in ipairs(trivial) do
        local d = row.data
        writer:write(table.concat({ safe(d.fullType), displayName(d, row.script), safe(d.finalRarityTier), safe(d.baseScarcityTier or d.rarityTier), number(scarcityStrength(d)), safe(d.displayCategory), "COMMON", "HIGH", row.reason }, " | ") .. "\n")
    end
    writer:write("\nEXCLUDED MISC UNSUPPORTED SAMPLE (not safe to cap)\nfullType | displayName | currentTier | displayCategory | exclusion reason\n")
    for index, row in ipairs(excluded) do
        if index > 40 then break end
        local d = row.data
        writer:write(table.concat({ safe(d.fullType), displayName(d, scriptFor(d.fullType)), safe(d.finalRarityTier), safe(d.displayCategory), safe(row.reason) }, " | ") .. "\n")
    end
    writer:write("\n2. RESTRICTED MICRO-CONTAINER SIMULATION\n")
    writer:write("Predicate: deferred CONTAINER + nonempty AcceptItemFunction + Capacity<=5 + WeightReduction<=0 + no attachments + no functional equip/body signal. Proposed COMMON; diagnostic only.\n")
    writer:write("fullType | displayName | Capacity | WeightReduction | attachments | AcceptItemFunction | currentTier | proposedTier | confidence\n")
    for _, row in ipairs(restricted) do
        local d, s = row.data, row.shape
        writer:write(table.concat({ safe(d.fullType), displayName(d, row.script), number(s.capacity), number(s.reduction), number(s.attachments), safe(s.accept), safe(d.finalRarityTier), "COMMON", "HIGH restriction / LOW semantic capacity" }, " | ") .. "\n")
    end
    writer:write("\n3. NOISE MAKER POLICY MODELS\n")
    writer:write("A=active (<15 C,15-29 U,30-49 R,>=50 E); B=RARE ceiling; C=<15 C,15-29 U,30-69 R,>=70 E; D=<20 C,20-49 U,50-89 R,>=90 E. D is an intentionally conservative outlier test, not a proposed active rule.\n")
    writer:write("fullType | displayName | NoiseRange | ExplosionPower/Range | FireRange | SmokeRange | Scarcity | A active | B | C | D\n")
    for _, d in ipairs(noises) do
        local m, script = d.utilityMetrics or {}, scriptFor(d.fullType)
        local range = tonumber(d.noiseMakerNoiseRange) or tonumber(m.noiseRange) or 0
        writer:write(table.concat({ safe(d.fullType), displayName(d, script), number(range), number(m.explosionPower).."/"..number(m.explosionRange), number(m.fireRange), number(call(script, "getSmokeRange", "smokeRange")), safe(d.baseScarcityTier or d.rarityTier), safe(d.finalRarityTier), noiseTier(range,"B"), noiseTier(range,"C"), noiseTier(range,"D") }, " | ") .. "\n")
    end
    local foodTiers = { COMMON=0, UNCOMMON=0, RARE=0, EPIC=0, EXOTIC=0 }
    for _, d in ipairs(foods) do foodTiers[d.finalRarityTier] = (foodTiers[d.finalRarityTier] or 0) + 1 end
    writer:write("\n4. FOOD OUTLIERS / TOP 20\n")
    writer:write(string.format("ELIGIBLE FOOD COUNTS | COMMON=%d | UNCOMMON=%d | RARE=%d | EPIC=%d | EXOTIC=%d\n", foodTiers.COMMON, foodTiers.UNCOMMON, foodTiers.RARE, foodTiers.EPIC, foodTiers.EXOTIC))
    writer:write("fullType | displayName | hungerComp(weighted) | moodComp(weighted) | energyComp(weighted) | preservationComp(weighted) | convenienceComp(weighted) | FoodQuality | ScarcityAdjustment(5%) | FinalScore | FinalTier\n")
    for index, d in ipairs(foods) do
        if index > 20 then break end
        local c = d.utilityComponents or {}
        local quality = tonumber(d.foodQuality or d.utility) or 0
        local scarcityPart = (tonumber(d.foodFinalScore) or quality) - quality * .95
        writer:write(table.concat({ safe(d.fullType), displayName(d, scriptFor(d.fullType)), number((c.sustenance or 0)*.60), number((c.mood or 0)*.20), number((c.energy or 0)*.12), number((c.preservation or 0)*.05), number((c.convenience or 0)*.03), number(quality), number(scarcityPart), number(d.foodFinalScore), safe(d.finalRarityTier) }, " | ") .. "\n")
    end
    writer:close()
    ItemRarityUtils.info(string.format("Pre-release policy audit written: trivialFallback=%d (%d RARE+) | restrictedMicroContainers=%d | noises=%d | eligibleFood=%d.", #trivial, trivialRare, #restricted, #noises, #foods))
    return true
end

function ItemRarityGameplayAnomalyAudit.write(results)
    if type(results) ~= "table" or not getFileWriter then return nil end
    local writer = getFileWriter("ItemRarity_GameplayAnomalyAudit.txt", true, false)
    if not writer then return nil end
    local targets, empty, fallbackHigh, causes, noises, foods, photoContainers = {}, {}, {}, {}, {}, {}, {}
    for _, data in pairs(results) do
        local script = scriptFor(data.fullType)
        if targetMatch(data, script) then table.insert(targets, data) end
        if structurallyEmpty(data) then table.insert(empty, data) end
        if candidateState(data) == "UNSUPPORTED" and (data.finalRarityTier == "RARE" or data.finalRarityTier == "EPIC" or data.finalRarityTier == "EXOTIC") then table.insert(fallbackHigh, data) end
        if data.utilityKind == "NOISE_MAKER" then table.insert(noises, data) end
        if data.utilityKind == "FOOD" and data.utilityEligible then table.insert(foods, data) end
        if data.utilityKind == "CONTAINER" and (data.utilitySubgroup == "CASE" or data.containerAcceptItemFunction == "AcceptItemFunction.Wallet") then table.insert(photoContainers, data) end
        local class = baseCause(data)
        causes[class] = (causes[class] or 0) + 1
    end
    table.sort(targets, function(a, b) return a.fullType < b.fullType end)
    table.sort(empty, function(a, b) return a.fullType < b.fullType end)
    table.sort(fallbackHigh, function(a, b) return a.fullType < b.fullType end)
    table.sort(noises, function(a, b) return (a.noiseMakerNoiseRange or 0) > (b.noiseMakerNoiseRange or 0) end)
    table.sort(foods, function(a, b) return (a.foodQuality or a.utility or 0) > (b.foodQuality or b.utility or 0) end)
    table.sort(photoContainers, function(a, b) return a.fullType < b.fullType end)
    writer:write("Item Rarity gameplay anomaly audit (READ ONLY)\n")
    writer:write("Target labels are report lookup aids only; no classification, Utility, tier, registry or signature is changed.\n")
    writer:write("Target matching is localization-tolerant and may return related rows; fullType is authoritative.\n\n")
    writer:write("ROOT CAUSE COUNTS | A=" .. tostring(causes.A or 0) .. " | B=" .. tostring(causes.B or 0) .. " | C=" .. tostring(causes.C or 0) .. " | D=" .. tostring(causes.D or 0) .. " | E=" .. tostring(causes.E or 0) .. " | F=" .. tostring(causes.F or 0) .. " | G=" .. tostring(causes.G or 0) .. "\n")
    writer:write("STRUCTURALLY EMPTY UNSUPPORTED=" .. tostring(#empty) .. " | UNSUPPORTED RARE+ FALLBACK=" .. tostring(#fallbackHigh) .. " | TARGET MATCHES=" .. tostring(#targets) .. "\n")
    writer:write("\nTARGET TRACES\n")
    for _, data in ipairs(targets) do writeTrace(writer, data) end
    writer:write("\nSTRUCTURALLY EMPTY UNSUPPORTED POPULATION\nfullType | displayName | final | scarcity | category | displayCategory | routeWeighted\n")
    for _, data in ipairs(empty) do
        local script = scriptFor(data.fullType)
        writer:write(table.concat({ safe(data.fullType), displayName(data, script), safe(data.finalRarityTier), safe(data.baseScarcityTier or data.rarityTier), safe(data.category), safe(data.displayCategory), number(routeWeighted(data)) }, " | ") .. "\n")
    end
    writer:write("\nUNSUPPORTED RARE+ FALLBACK\nfullType | displayName | final | scarcity | category | displayCategory | routeWeighted\n")
    for _, data in ipairs(fallbackHigh) do
        local script = scriptFor(data.fullType)
        writer:write(table.concat({ safe(data.fullType), displayName(data, script), safe(data.finalRarityTier), safe(data.baseScarcityTier or data.rarityTier), safe(data.category), safe(data.displayCategory), number(routeWeighted(data)) }, " | ") .. "\n")
    end
    writer:write("\nNOISE MAKER POLICY COMPARISON (diagnostic; active policy unchanged)\nfullType | displayName | NoiseRange | active tier | RARE-cap alternative | conservative >=70 EPIC alternative | scarcity\n")
    for _, data in ipairs(noises) do
        local range, script = tonumber(data.noiseMakerNoiseRange) or 0, scriptFor(data.fullType)
        local rareCap = range < 15 and "COMMON" or (range < 30 and "UNCOMMON" or "RARE")
        local conservative = range < 15 and "COMMON" or (range < 30 and "UNCOMMON" or (range < 70 and "RARE" or "EPIC"))
        writer:write(table.concat({ safe(data.fullType), displayName(data, script), number(range), safe(data.finalRarityTier), rareCap, conservative, safe(data.baseScarcityTier or data.rarityTier) }, " | ") .. "\n")
    end
    writer:write("\nFOOD COMPARABLES (top 20 FoodQuality; diagnostic only)\nfullType | displayName | FoodQuality | FoodFinalScore | ScarcityStrength | FinalTier | hunger | calories | preservation | mood | convenience\n")
    for index, data in ipairs(foods) do
        if index > 20 then break end
        local m, c, script = data.utilityMetrics or {}, data.utilityComponents or {}, scriptFor(data.fullType)
        writer:write(table.concat({ safe(data.fullType), displayName(data, script), number(data.foodQuality or data.utility), number(data.foodFinalScore), number(data.foodScarcityStrength or scarcityStrength(data)), safe(data.finalRarityTier), number(m.hungerBenefit), number(m.calories), number(c.preservation), number(c.mood), number(c.convenience) }, " | ") .. "\n")
    end
    writer:write("\nSPECIALIZED / WALLET-ACCEPTING CONTAINERS\nfullType | displayName | subgroup | Capacity | WeightReduction | Weight | AcceptItemFunction | utility | Scarcity | FinalTier | active reason\n")
    for _, data in ipairs(photoContainers) do
        local m, script = data.utilityMetrics or {}, scriptFor(data.fullType)
        writer:write(table.concat({ safe(data.fullType), displayName(data, script), safe(data.utilitySubgroup), number(m.capacity), number(m.weightReduction), number(m.emptyWeight), safe(data.containerAcceptItemFunction), number(data.utility), safe(data.baseScarcityTier or data.rarityTier), safe(data.finalRarityTier), safe(data.utilityAdjustmentReason) }, " | ") .. "\n")
    end
    writer:close()
    writePolicyReview(results)
    ItemRarityUtils.info(string.format("Gameplay anomaly audit written: targetMatches=%d | structurallyEmptyUnsupported=%d | unsupportedRarePlus=%d.", #targets, #empty, #fallbackHigh))
    return true
end
