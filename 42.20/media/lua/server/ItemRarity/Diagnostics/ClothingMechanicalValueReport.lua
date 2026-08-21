require "ItemRarity/RarityUtils"
require "ItemRarity/UtilityCalculator"

-- Read-only audit. No fullType, module, display name, or slot determines
-- value/tier. BodyLocation tokens below are used only to print audit sections.
ItemRarityClothingMechanicalValueReport = ItemRarityClothingMechanicalValueReport or {}

-- Development-only bridge: the client debug console can already request a
-- reload of this allow-listed report on the authoritative host.  While the
-- scanner is idle, use that trusted request to reload the active clothing
-- pipeline too, then run its normal rescan path.  This avoids requiring a
-- world restart for an in-progress server-side Lua iteration.  It is never
-- entered when this report is loaded by the normal scan/report path.
local function reloadActivePipelineForDevelopment()
    if not reloadLuaFile or (ItemRarityScanner and ItemRarityScanner.isScanning) then return false end
    local files = {
        "media/lua/server/ItemRarity/UtilityCalculator.lua",
        "media/lua/server/ItemRarity/RarityRegistryPublisher.lua",
        "media/lua/server/ItemRarity/RarityScanner.lua",
    }
    for _, path in ipairs(files) do reloadLuaFile(path) end
    if ItemRarityUtils then
        ItemRarityUtils.info("Development runtime pipeline reloaded via clothingMechanicalValue diagnostic bridge")
    end
    if ItemRarityScanner and ItemRarityScanner.rescan then
        ItemRarityScanner.rescan("development runtime reload bridge")
    end
    return true
end

local reloadedActivePipelineForDevelopment = reloadActivePipelineForDevelopment()

local API = ItemRarityUtilityCalculator.getClothingDiagnosticApi()
local clamp, quantile, sortedCopy = API.clamp, API.quantile, API.sortedCopy

local function number(v) return v ~= nil and string.format("%.2f", v) or "N/A" end
local function lower(v) return string.lower(tostring(v or "")) end
local function field(o, name) local ok, v = pcall(function() return o and o[name] end); return ok and v or nil end
local function call(o, name) local fn = field(o, name); if type(fn) ~= "function" then return nil end; local ok, v = pcall(function() return fn(o) end); return ok and v or nil end

local function modifierLoss(v) return v == nil and 0 or clamp((1 - v) * 100, 0, 100) end
local function progressiveLoss(loss, free)
    local excess = math.max(0, loss - free)
    return excess == 0 and 0 or clamp(100 * ((excess / math.max(1, 100 - free)) ^ .72), 0, 100)
end

-- Exact approved provisional FunctionalCost curve, duplicated here so this
-- report cannot become a dependency of active ClothingUtility.
local function functionalCost(metrics, weightPctl)
    local c = {
        combat=progressiveLoss(modifierLoss(metrics.combatSpeedModifier),1)*.30,
        run=progressiveLoss(modifierLoss(metrics.runSpeedModifier),1)*.25,
        discomfort=progressiveLoss(clamp((metrics.discomfortModifier or 0)*100,0,100),2)*.10,
        vision=progressiveLoss(modifierLoss(metrics.visionModifier),1)*.15,
        hearing=progressiveLoss(modifierLoss(metrics.hearingModifier),1)*.15,
        weight=progressiveLoss(100-(weightPctl or 50),15)*.05,
    }
    local total = 0; for _, v in pairs(c) do total = total + v end
    local excess = math.max(0, total - 7)
    return excess == 0 and 0 or (excess ^ 1.28) / 5.5, total
end

local function robust(v, scale)
    if v == nil or not scale.low or not scale.high then return 0 end
    if scale.high <= scale.low then return v > 0 and 50 or 0 end
    return clamp((clamp(v,scale.low,scale.high)-scale.low)/(scale.high-scale.low)*100,0,100)
end

local function scale(records, metric)
    local seen, values = {}, {}
    for _, r in ipairs(records) do
        local value, profile = r.metrics[metric], r.data.utilityProfile or r.data.fullType
        if value ~= nil and not seen[profile] then seen[profile]=true; table.insert(values,value) end
    end
    values=sortedCopy(values); return { low=quantile(values,5), high=quantile(values,95) }
end

local function specialEvidence(fullType)
    local manager = getScriptManager and getScriptManager() or nil
    local item = manager and manager:FindItem(fullType) or nil
    if not item then return false, nil end
    local tags = tostring(field(item,"tags") or call(item,"getTags") or "")
    local activated = field(item,"activatedItem") == true or call(item,"isActivatedItem") == true
    local onCreate = field(item,"onCreate") or call(item,"getOnCreate")
    local keep = field(item,"keepOnDeplete") == true or call(item,"isKeepOnDeplete") == true
    local scba = string.find(lower(tags),"scba",1,true) ~= nil or string.find(lower(tags),"hazmatsuit",1,true) ~= nil
    if activated or onCreate or keep or scba then
        return true, string.format("activated=%s,onCreate=%s,keepOnDeplete=%s,specialTag=%s", tostring(activated), tostring(onCreate ~= nil), tostring(keep), tostring(scba))
    end
    return false, nil
end

local function coverage(r, maximum)
    local components = r.data.utilityComponents or {}
    if components.coverageFactor ~= nil then return components.coverageFactor end
    local evidence = r.metrics.coverageEvidenceCount or r.metrics.coverageZoneCount or 0
    return maximum <= 0 and .70 or (.70 + .30*clamp(evidence/maximum,0,1))
end

local function prepare(results)
    local records, bySlot, maxEvidence = {}, {}, 0
    for _, data in pairs(results) do if data.category == "CLOTHING" then
        local metrics, graph = data.utilityMetrics or {}, data.clothingEquipmentGraph or {}
        maxEvidence=math.max(maxEvidence,metrics.coverageEvidenceCount or metrics.coverageZoneCount or 0)
        local r={data=data,metrics=metrics,slot=tostring(graph.slotId or "UNRESOLVED"),profile=data.utilityProfile or data.fullType}
        table.insert(records,r); bySlot[r.slot]=bySlot[r.slot] or {}; table.insert(bySlot[r.slot],r)
    end end
    table.sort(records,function(a,b) return a.data.fullType < b.data.fullType end)
    local scales={ durability=scale(records,"durability"), insulation=scale(records,"insulation"), wind=scale(records,"windResistance"), water=scale(records,"waterResistance") }
    for _, slotRecords in pairs(bySlot) do
        local seen, weights={},{}
        for _,r in ipairs(slotRecords) do if r.metrics.weight~=nil and not seen[r.profile] then seen[r.profile]=true; table.insert(weights,r.metrics.weight) end end
        weights=sortedCopy(weights)
        for _,r in ipairs(slotRecords) do
            local m=r.metrics
            local weightPctl=m.weight~=nil and API.percentileRank(weights,m.weight,true) or 50
            r.coverage=coverage(r,maxEvidence)
            r.protection=((clamp(m.biteDefense or 0,0,100)*.50)+(clamp(m.scratchDefense or 0,0,100)*.35)+(clamp(m.bulletDefense or 0,0,100)*.15))*r.coverage
            r.weather=robust(m.insulation,scales.insulation)*.40+robust(m.windResistance,scales.wind)*.35+robust(m.waterResistance,scales.water)*.25
            r.durability=robust(m.durability,scales.durability)
            r.durabilityFactor=.75+.25*(r.durability/100)
            r.cost,r.costIndex=functionalCost(m,weightPctl)
            r.special,r.specialReason=specialEvidence(r.data.fullType)
            -- Durability has no autonomous contribution: it can only improve
            -- a real defensive/weather benefit already present.
            r.baseBenefit=r.protection*.85+r.weather*.15
            r.value=math.max(0,r.baseBenefit*r.durabilityFactor-r.cost)
            r.status=r.special and "MECHANICAL_VALUE_PARTIAL" or (r.baseBenefit <= .01 and "MECHANICALLY_TRIVIAL" or "MECHANICAL_VALUE_KNOWN")
        end
    end
    local values, profiles={},{}
    for _,r in ipairs(records) do if not profiles[r.profile] then profiles[r.profile]=true; table.insert(values,r.value) end end
    return records,sortedCopy(values),scales
end

local function cappedTier(r, cut)
    if r.status == "MECHANICAL_VALUE_PARTIAL" or r.value > cut then return r.data.finalRarityTier end
    return r.data.finalRarityTier == "COMMON" and "COMMON" or "UNCOMMON"
end

local function inSection(slot, section)
    slot=lower(slot)
    if section=="UNDERWEAR_AND_BRAS" then return string.find(slot,"underwear",1,true) or string.find(slot,"bra",1,true) end
    if section=="SOCKS" then return string.find(slot,"sock",1,true) end
    if section=="SHORTS" then return string.find(slot,"short",1,true) end
    if section=="BASIC_SHIRTS" then return string.find(slot,"shirt",1,true) end
    if section=="HATS_AND_CAPS" then return string.find(slot,"hat",1,true) or string.find(slot,"cap",1,true) end
end

function ItemRarityClothingMechanicalValueReport.write(results)
    if type(results)~="table" or not getFileWriter then return false end
    local writer=getFileWriter("ItemRarity_ClothingMechanicalValue.txt",true,true); if not writer then return false end
    local records,values=prepare(results)
    local cuts={Q20=quantile(values,20),Q30=quantile(values,30),Q40=quantile(values,40)}
    writer:write("Item Rarity AbsoluteMechanicalValue audit V2 (REPORT ONLY)\nNo active score/tier/registry/UI field changes.\n\n")
    writer:write("BaseBenefit = 85% actual protection x coverage + 15% robust weather. MechanicalValue = BaseBenefit x DurabilityFactor - approved FunctionalCost. DurabilityFactor ranges .75..1.00 and cannot create value when BaseBenefit=0.\n")
    writer:write("Status: TRIVIAL=known zero BaseBenefit; KNOWN=quantified nonzero benefit; PARTIAL=generic runtime/script evidence of special behavior not quantifiable by current metrics. PARTIAL is never capped.\n\n")
    writer:write(string.format("DISTRIBUTION | n=%d | min=%s | p10=%s | p20=%s | p25=%s | p30=%s | p40=%s | p50=%s | p60=%s | p75=%s | p90=%s | p95=%s | max=%s\n",#values,number(quantile(values,0)),number(quantile(values,10)),number(cuts.Q20),number(quantile(values,25)),number(cuts.Q30),number(cuts.Q40),number(quantile(values,50)),number(quantile(values,60)),number(quantile(values,75)),number(quantile(values,90)),number(quantile(values,95)),number(quantile(values,100))))
    for _,label in ipairs({"Q20","Q30","Q40"}) do
        local cut,rarePlus,trivialRare,reduced=cuts[label],0,0,0
        for _,r in ipairs(records) do
            local rare=r.data.finalRarityTier=="RARE" or r.data.finalRarityTier=="EPIC" or r.data.finalRarityTier=="EXOTIC"
            if rare and r.status=="MECHANICALLY_TRIVIAL" then trivialRare=trivialRare+1 end
            if rare and r.status~="MECHANICAL_VALUE_PARTIAL" and r.value<=cut then rarePlus=rarePlus+1 end
            if cappedTier(r,cut)~=r.data.finalRarityTier then reduced=reduced+1 end
        end
        writer:write(string.format("%s <= %s | RARE+ truly trivial=%d | RARE+ low known=%d | downgraded=%d\n",label,number(cut),trivialRare,rarePlus,reduced))
    end
    writer:write("\nTARGETS\nfullType | DIRECT_SLOT | BaseBenefit | DurabilityFactor | FunctionalCost | MechanicalValue | Status | special evidence | active | Q20/Q30/Q40 hypothetical\n")
    local targets={"Base.Briefs_SmallTrunks_Black","Base.Briefs_White","Base.Socks_Ankle","Base.Jacket_NavyBlue","Base.Jacket_Leather","Base.Jacket_Fireman","Base.Shoes_WorkBoots","Base.Shoes_BlueTrainers","Base.Cuirass_Metal","Base.Vambrace_Left","Base.Shoulderpad_Articulated_L_Metal","Base.HazmatSuit","Base.Hat_BaseballCap"}
    local byType={}; for _,r in ipairs(records) do byType[r.data.fullType]=r end
    for _,fullType in ipairs(targets) do
        local r=byType[fullType]
        if r then writer:write(string.format("%s | %s | %s | %s | %s | %s | %s | %s | %s | %s/%s/%s\n",fullType,r.slot,number(r.baseBenefit),number(r.durabilityFactor),number(r.cost),number(r.value),r.status,tostring(r.specialReason or "-"),r.data.finalRarityTier,cappedTier(r,cuts.Q20),cappedTier(r,cuts.Q30),cappedTier(r,cuts.Q40))) else writer:write(fullType.." | unavailable (not category CLOTHING)\n") end
    end
    for _,section in ipairs({"UNDERWEAR_AND_BRAS","SOCKS","SHORTS","BASIC_SHIRTS","HATS_AND_CAPS"}) do
        writer:write("\n"..section.." (resolved BodyLocation audit only)\n")
        for _,r in ipairs(records) do if inSection(r.slot,section) then writer:write(string.format("%s | value=%s | status=%s | base=%s | active=%s | Q30=%s\n",r.data.fullType,number(r.value),r.status,number(r.baseBenefit),r.data.finalRarityTier,cappedTier(r,cuts.Q30))) end end
    end
    writer:write("\nRARE+ MECHANICALLY_TRIVIAL\n")
    for _,r in ipairs(records) do if r.status=="MECHANICALLY_TRIVIAL" and r.data.finalRarityTier~="COMMON" and r.data.finalRarityTier~="UNCOMMON" then writer:write(string.format("%s | %s | active=%s | Q30=%s\n",r.data.fullType,r.slot,r.data.finalRarityTier,cappedTier(r,cuts.Q30))) end end
    writer:close(); ItemRarityUtils.info("AbsoluteMechanicalValue V2 audit written to Zomboid/Lua/ItemRarity_ClothingMechanicalValue.txt (report only)."); return true
end

-- B42 does not add a new server Lua file to its already-open require index.
-- Keep this first ACCESSORY investigation inside the allow-listed report that
-- can be hot-reloaded.  It is read-only and does not feed UtilityCalculator.
local function writeAccessoryMechanicalValueAudit(results)
    if type(results) ~= "table" or not getFileWriter then return end
    local manager = getScriptManager and getScriptManager() or nil
    local records, profiles, values, rareTrivial = {}, {}, {}, {}
    local function value(object, getter, member)
        local result = tonumber(call(object, getter))
        if result == nil then result = tonumber(field(object, member)) end
        return result
    end
    for _, data in pairs(results) do
        local item = manager and manager:FindItem(data.fullType) or nil
        local displayCategory = lower(data.displayCategory or call(item, "getDisplayCategory"))
        if item and (data.category == "ACCESSORY" or displayCategory == "accessory") then
            local ok, runtime = pcall(function() return item:InstanceItem(nil, false) end)
            if not ok then runtime = nil end
            local blood = call(runtime, "getBloodClothingType") or call(item, "getBloodClothingType")
                or call(runtime, "getBloodLocation") or call(item, "getBloodLocation") or field(item, "bloodLocation") or ""
            local body = call(runtime, "getBodyLocation") or call(item, "getBodyLocation") or field(item, "bodyLocation") or ""
            local m = {
                bite=value(runtime,"getBiteDefense","biteDefense") or value(item,"getBiteDefense","biteDefense"),
                scratch=value(runtime,"getScratchDefense","scratchDefense") or value(item,"getScratchDefense","scratchDefense"),
                bullet=value(runtime,"getBulletDefense","bulletDefense") or value(item,"getBulletDefense","bulletDefense"),
                insulation=value(runtime,"getInsulation","insulation") or value(item,"getInsulation","insulation"),
                wind=value(runtime,"getWindResistance","windResistance") or value(item,"getWindResistance","windResistance"),
                water=value(runtime,"getWaterResistance","waterResistance") or value(item,"getWaterResistance","waterResistance"),
                conditionMax=value(runtime,"getConditionMax","conditionMax") or value(item,"getConditionMax","conditionMax"),
                conditionLowerChance=value(runtime,"getConditionLowerChance","conditionLowerChance") or value(item,"getConditionLowerChance","conditionLowerChance"),
                weight=value(runtime,"getActualWeight","actualWeight") or value(item,"getActualWeight","actualWeight"),
                runSpeedModifier=value(runtime,"getRunSpeedModifier","runSpeedModifier") or value(item,"getRunSpeedModifier","runSpeedModifier"),
                combatSpeedModifier=value(runtime,"getCombatSpeedModifier","combatSpeedModifier") or value(item,"getCombatSpeedModifier","combatSpeedModifier"),
                discomfortModifier=value(runtime,"getDiscomfortModifier","discomfortModifier") or value(item,"getDiscomfortModifier","discomfortModifier"),
                visionModifier=value(runtime,"getVisionModifier","visionModifier") or value(item,"getVisionModifier","visionModifier"),
                hearingModifier=value(runtime,"getHearingModifier","hearingModifier") or value(item,"getHearingModifier","hearingModifier"),
            }
            if m.wind == nil then m.wind=value(runtime,"getWindresistance","windresistance") or value(item,"getWindresistance","windresistance") end
            local tags = tostring(call(item,"getTags") or field(item,"tags") or "")
            local activated = field(item,"activatedItem") == true or call(item,"isActivatedItem") == true
            local keep = field(item,"keepOnDeplete") == true or call(item,"isKeepOnDeplete") == true
            local special = activated or keep or string.find(lower(tags),"scba",1,true) ~= nil or string.find(lower(tags),"hazmat",1,true) ~= nil
            local zones, seen = 0, {}
            for token in string.gmatch(lower(blood), "[^;,%s]+") do seen[token]=true end
            for _ in pairs(seen) do zones=zones+1 end
            local coverage = zones == 0 and 0 or (.70 + .30 * math.min(1,zones/3))
            local protection = ((m.bite or 0)*.50 + (m.scratch or 0)*.35 + (m.bullet or 0)*.15) * coverage
            local weather = ((m.insulation or 0)*.40 + (m.wind or 0)*.35 + (m.water or 0)*.25) * 100
            local baseBenefit = protection*.85 + weather*.15
            local durabilitySignal = m.conditionMax and m.conditionLowerChance and math.log(1+math.max(0,m.conditionMax)*math.max(0,m.conditionLowerChance)) or 0
            local durabilityFactor = .75 + .25 * math.min(1,durabilitySignal/6)
            local cost = functionalCost({ runSpeedModifier=m.runSpeedModifier, combatSpeedModifier=m.combatSpeedModifier, discomfortModifier=m.discomfortModifier, visionModifier=m.visionModifier, hearingModifier=m.hearingModifier },50)
            local coreKnown = m.bite ~= nil and m.scratch ~= nil and m.bullet ~= nil and m.insulation ~= nil and m.wind ~= nil and m.water ~= nil
            local status = special and "MECHANICAL_VALUE_PARTIAL" or (not coreKnown and "MECHANICAL_VALUE_PARTIAL" or (baseBenefit <= .01 and "MECHANICALLY_TRIVIAL" or "MECHANICAL_VALUE_KNOWN"))
            local profile = table.concat({tostring(body),tostring(blood),tostring(m.bite),tostring(m.scratch),tostring(m.bullet),tostring(m.insulation),tostring(m.wind),tostring(m.water),tostring(m.conditionMax),tostring(m.conditionLowerChance),tostring(m.weight),tostring(m.runSpeedModifier),tostring(m.combatSpeedModifier),tostring(m.discomfortModifier),tostring(m.visionModifier),tostring(m.hearingModifier)},":")
            local record = { data=data, body=body, blood=blood, tags=tags, m=m, zones=zones, protection=protection, weather=weather, baseBenefit=baseBenefit, durabilityFactor=durabilityFactor, cost=cost, mechanicalValue=math.max(0,baseBenefit*durabilityFactor-cost), status=status, profile=profile, special=special }
            table.insert(records,record); profiles[profile]=profiles[profile] or {}; table.insert(profiles[profile],record)
        end
    end
    table.sort(records,function(a,b) return a.data.fullType < b.data.fullType end)
    local statusCounts={MECHANICALLY_TRIVIAL=0,MECHANICAL_VALUE_KNOWN=0,MECHANICAL_VALUE_PARTIAL=0}
    for _,record in ipairs(records) do
        statusCounts[record.status]=statusCounts[record.status]+1
        if #profiles[record.profile] == 1 then table.insert(values,record.mechanicalValue) end
        if record.status == "MECHANICALLY_TRIVIAL" and (record.data.finalRarityTier == "RARE" or record.data.finalRarityTier == "EPIC" or record.data.finalRarityTier == "EXOTIC") then table.insert(rareTrivial,record) end
    end
    values=sortedCopy(values)
    local writer=getFileWriter("ItemRarity_AccessoryMechanicalValue.txt",true,false); if not writer then return end
    writer:write("Item Rarity ACCESSORY MechanicalValue audit (REPORT ONLY)\nNo active tier, Utility, registry, classifier, or UI field changed. ACCESSORY uses runtime/script DisplayCategory=Accessory, never name/fullType.\n")
    writer:write("MechanicalValue is an investigation metric only: defensive/weather benefit modulated by durability, minus intrinsic functional cost. Durability cannot create benefit on its own. TRIVIAL=known zero benefit; KNOWN=measured benefit; PARTIAL=special behavior or incomplete core fields.\n\n")
    writer:write(string.format("ITEMS=%d | UNIQUE_PROFILES=%d | TRIVIAL=%d | KNOWN=%d | PARTIAL=%d | value min/p25/p50/p75/p95/max=%s/%s/%s/%s/%s/%s\n\n",#records,#values,statusCounts.MECHANICALLY_TRIVIAL,statusCounts.MECHANICAL_VALUE_KNOWN,statusCounts.MECHANICAL_VALUE_PARTIAL,number(quantile(values,0)),number(quantile(values,25)),number(quantile(values,50)),number(quantile(values,75)),number(quantile(values,95)),number(quantile(values,100))))
    writer:write("RARE+ MECHANICALLY_TRIVIAL\nfullType | tier | occurrences | distributions | BodyLocation | BloodLocation | tags\n")
    for _,r in ipairs(rareTrivial) do
        writer:write(tostring(r.data.fullType).." | "..tostring(r.data.finalRarityTier).." | "..tostring(r.data.occurrences or 0).." | "..tostring(#(r.data.distributions or {})).." | "..tostring(r.body).." | "..tostring(r.blood).." | "..tostring(r.tags).."\n")
    end
    writer:write("\nIDENTICAL MECHANICAL PROFILES\n")
    for _,group in pairs(profiles) do if #group > 1 then local names={}; for _,r in ipairs(group) do table.insert(names,r.data.fullType.."("..r.data.finalRarityTier..")") end; table.sort(names); writer:write(table.concat(names,", ").."\n") end end
    writer:write("\nALL ACCESSORIES\nfullType | tier | occurrences | BodyLocation | BloodLocation | bite | scratch | bullet | insulation | wind | water | conditionMax | conditionLowerChance | weight | run | combat | discomfort | vision | hearing | coverage | ProtectionBenefit | WeatherBenefit | DurabilityFactor | FunctionalCost | MechanicalValue | Status | tags\n")
    for _,r in ipairs(records) do
        local m=r.m
        local columns={r.data.fullType,r.data.finalRarityTier,r.data.occurrences or 0,r.body,r.blood,number(m.bite),number(m.scratch),number(m.bullet),number(m.insulation),number(m.wind),number(m.water),number(m.conditionMax),number(m.conditionLowerChance),number(m.weight),number(m.runSpeedModifier),number(m.combatSpeedModifier),number(m.discomfortModifier),number(m.visionModifier),number(m.hearingModifier),r.zones,number(r.protection),number(r.weather),number(r.durabilityFactor),number(r.cost),number(r.mechanicalValue),r.status,r.tags}
        for index,column in ipairs(columns) do columns[index]=tostring(column) end
        writer:write(table.concat(columns," | ").."\n")
    end
    writer:close(); ItemRarityUtils.info(string.format("ACCESSORY MechanicalValue audit written: %d items; %d RARE+ trivial candidates.",#records,#rareTrivial))
end

-- Alternative policy simulation only.  It never writes FinalRarityTier or
-- publishes a registry: it answers whether trivial wearable cosmetics should
-- collapse to COMMON unless their underlying Scarcity is EPIC/EXOTIC.
local function writeTrivialPolicySimulation(results)
    if type(results) ~= "table" or not getFileWriter then return end
    local tiers={"COMMON","UNCOMMON","RARE","EPIC","EXOTIC"}
    local current, policy2, policy3={},{},{}
    for _,tier in ipairs(tiers) do current[tier]=0; policy2[tier]=0; policy3[tier]=0 end
    local p2Changed, p2UncommonToCommon, p2RareScarcity, knownPartialChanged, examples = 0, 0, 0, 0, {}
    local p3Transitions={uncommonToCommon=0,rareToUncommon=0,epicToUncommon=0,exoticToUncommon=0}
    local function statusOf(data)
        return data.clothingMechanicalValueStatus or data.accessoryMechanicalValueStatus
    end
    local function groupOf(data)
        local location=lower(data.utilitySubgroup or (data.clothingDiscovery and data.clothingDiscovery.bodyLocation) or "")
        if data.utilityKind == "CLOTHING" then
            if string.find(location,"underwear",1,true) or string.find(location,"bra",1,true) then return "UNDERWEAR" end
            return "CLOTHING:"..(location ~= "" and location or "UNRESOLVED")
        end
        if string.find(location,"hat",1,true) then return "HEADWEAR" end
        if string.find(location,"eye",1,true) then return "EYEWEAR" end
        if string.find(location,"neck",1,true) then return "NECKWEAR" end
        if string.find(location,"ear",1,true) or string.find(location,"wrist",1,true) or string.find(location,"belly",1,true) or string.find(location,"nose",1,true) then return "JEWELLERY" end
        return "ACCESSORY:"..(location ~= "" and location or "UNRESOLVED")
    end
    for _,data in pairs(results) do
        local before=data.finalRarityTier or data.rarityTier
        current[before]=(current[before] or 0)+1
        local status=statusOf(data)
        local scarcity=data.baseScarcityTier or data.rarityTier
        local after2, after3=before, before
        if status == "MECHANICALLY_TRIVIAL" then
            after2=(scarcity == "EPIC" or scarcity == "EXOTIC") and "UNCOMMON" or "COMMON"
            after3=(scarcity == "COMMON" or scarcity == "UNCOMMON") and "COMMON" or "UNCOMMON"
        elseif status == "MECHANICAL_VALUE_KNOWN" or status == "MECHANICAL_VALUE_PARTIAL" then
            if after2 ~= before or after3 ~= before then knownPartialChanged=knownPartialChanged+1 end
        end
        policy2[after2]=(policy2[after2] or 0)+1
        policy3[after3]=(policy3[after3] or 0)+1
        if after2 ~= before then
            p2Changed=p2Changed+1
            if before == "UNCOMMON" and after2 == "COMMON" then p2UncommonToCommon=p2UncommonToCommon+1 end
            if scarcity == "RARE" then p2RareScarcity=p2RareScarcity+1 end
        end
        if after3 ~= before then
            if before == "UNCOMMON" and after3 == "COMMON" then p3Transitions.uncommonToCommon=p3Transitions.uncommonToCommon+1 end
            if before == "RARE" and after3 == "UNCOMMON" then p3Transitions.rareToUncommon=p3Transitions.rareToUncommon+1 end
            if before == "EPIC" and after3 == "UNCOMMON" then p3Transitions.epicToUncommon=p3Transitions.epicToUncommon+1 end
            if before == "EXOTIC" and after3 == "UNCOMMON" then p3Transitions.exoticToUncommon=p3Transitions.exoticToUncommon+1 end
            table.insert(examples,{fullType=data.fullType,group=groupOf(data),scarcity=scarcity,current=before,proposed=after3,status=status})
        end
    end
    table.sort(examples,function(a,b) return a.fullType < b.fullType end)
    local writer=getFileWriter("ItemRarity_TrivialPolicySimulation.txt",true,false); if not writer then return end
    writer:write("Item Rarity trivial wearable policy simulation (NOT ACTIVE)\n")
    writer:write("Active: MECHANICALLY_TRIVIAL <= UNCOMMON. Policy 2: Scarcity COMMON/UNCOMMON/RARE => COMMON; EPIC/EXOTIC => UNCOMMON. Policy 3: COMMON/UNCOMMON => COMMON; RARE/EPIC/EXOTIC => UNCOMMON. KNOWN and PARTIAL retain current final tier in both simulations.\n\n")
    writer:write("CURRENT C/U/R/E/X="..current.COMMON.."/"..current.UNCOMMON.."/"..current.RARE.."/"..current.EPIC.."/"..current.EXOTIC.."\n")
    writer:write("POLICY_2 C/U/R/E/X="..policy2.COMMON.."/"..policy2.UNCOMMON.."/"..policy2.RARE.."/"..policy2.EPIC.."/"..policy2.EXOTIC.." | changed="..p2Changed.." | UNCOMMON->COMMON="..p2UncommonToCommon.." | Policy2-changed items with Scarcity RARE="..p2RareScarcity.."\n")
    writer:write("POLICY_3 C/U/R/E/X="..policy3.COMMON.."/"..policy3.UNCOMMON.."/"..policy3.RARE.."/"..policy3.EPIC.."/"..policy3.EXOTIC.." | UNCOMMON->COMMON="..p3Transitions.uncommonToCommon.." | RARE->UNCOMMON="..p3Transitions.rareToUncommon.." | EPIC->UNCOMMON="..p3Transitions.epicToUncommon.." | EXOTIC->UNCOMMON="..p3Transitions.exoticToUncommon.." | KNOWN/PARTIAL_CHANGED="..knownPartialChanged.."\n\n")
    writer:write("POLICY_3 AFFECTED TRIVIAL ITEMS\nfullType | mechanical group | ScarcityTier | current | proposed | status\n")
    for _,row in ipairs(examples) do writer:write(row.fullType.." | "..row.group.." | "..tostring(row.scarcity).." | "..row.current.." | "..row.proposed.." | "..tostring(row.status).."\n") end
    writer:close()
    ItemRarityUtils.info("Trivial wearable policy simulation written: Policy2="..p2Changed.." changes; Policy3 U->C="..p3Transitions.uncommonToCommon..", R->U="..p3Transitions.rareToUncommon.."; KNOWN/PARTIAL changed="..knownPartialChanged)
end

if reloadedActivePipelineForDevelopment and ItemRarityScanner and ItemRarityScanner.results then
    writeAccessoryMechanicalValueAudit(ItemRarityScanner.results)
    writeTrivialPolicySimulation(ItemRarityScanner.results)
end
