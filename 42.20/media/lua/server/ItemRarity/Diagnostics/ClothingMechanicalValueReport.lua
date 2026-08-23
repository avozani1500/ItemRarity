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
        "media/lua/shared/ItemRarity/RarityConfig.lua",
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

-- MEDICAL discovery is deliberately report-only.  It is colocated with this
-- hot-reloadable diagnostic because an already-open B42 world does not index
-- newly added server Lua files.  None of these fields flow into Utility,
-- FinalRarityTier, the registry, or its deterministic signature.
local function writeMedicalRuntimeAudit(results)
    if type(results) ~= "table" or not getFileWriter then return end
    local manager = getScriptManager and getScriptManager() or nil
    local function metric(runtime, script, getters, member)
        for _, getter in ipairs(getters) do
            local v = tonumber(call(runtime, getter))
            if v == nil then v = tonumber(call(script, getter)) end
            if v ~= nil then return v end
        end
        return tonumber(field(script, member))
    end
    local function boolMetric(runtime, script, getters, member)
        for _, getter in ipairs(getters) do
            local v = call(runtime, getter)
            if v == nil then v = call(script, getter) end
            if v ~= nil then return v == true end
        end
        local v = field(script, member)
        return v == true
    end
    local function groupFor(m, tags, hasOnEat, unpackRecipe)
        if m.canBandage or (m.bandagePower or 0) > 0 then return "WOUND_TREATMENT", "BandagePower/CanBandage" end
        if (m.alcoholPower or 0) > 0 then return "DISINFECTION", "AlcoholPower" end
        if (m.reduceInfectionPower or 0) > 0 then return "INFECTION_TREATMENT", "ReduceInfectionPower" end
        if (m.painReduction or 0) ~= 0 then return "PAIN_MEDICINE", "PainReduction" end
        if (m.fluReduction or 0) ~= 0 or (m.feverReduction or 0) ~= 0 then return "FEVER_TREATMENT", "Flu/Fever reduction" end
        if (m.foodSicknessChange or 0) < 0 then return "TOXIN_TREATMENT", "FoodSicknessChange" end
        if string.find(tags, "removebullet", 1, true) or string.find(tags, "removeglass", 1, true) or string.find(tags, "tweezers", 1, true) then return "PROCEDURE_TOOL", "procedure tag" end
        if unpackRecipe then return "MEDICAL_SUPPLY", "unpack recipe" end
        if hasOnEat then return "SPECIAL_MEDICAL", "OnEat behavior" end
        return "SPECIAL_MEDICAL", "Medical/FirstAid classification without quantified effect"
    end
    local function usesFor(m, isDrainable)
        -- InventoryItem exposes a default UseDelta even for normal items. It
        -- must not turn an ordinary Bandage into a fictional 32-use item.
        if not isDrainable then return 1 end
        if m.useDelta and m.useDelta > 0 and m.useDelta <= 1 then return math.max(1, math.floor((1 / m.useDelta) + .5)) end
        return 1
    end
    local function scoreFor(group, m, uses)
        local weight = math.max(.01, m.weight or 1)
        if group == "WOUND_TREATMENT" then return ((m.bandagePower or 0) * uses) / weight end
        if group == "DISINFECTION" then return ((m.alcoholPower or 0) * uses) / weight end
        if group == "INFECTION_TREATMENT" then return ((m.reduceInfectionPower or 0) * uses) / weight end
        if group == "PAIN_MEDICINE" then return (math.abs(m.painReduction or 0) * uses) / weight end
        if group == "FEVER_TREATMENT" then return ((math.abs(m.fluReduction or 0) + math.abs(m.feverReduction or 0)) * uses) / weight end
        if group == "TOXIN_TREATMENT" then return (math.abs(m.foodSicknessChange or 0) * uses) / weight end
        return nil
    end
    local function dominantEffect(group, m)
        if group == "WOUND_TREATMENT" then return m.bandagePower end
        if group == "DISINFECTION" then return m.alcoholPower end
        if group == "INFECTION_TREATMENT" then return m.reduceInfectionPower end
        if group == "PAIN_MEDICINE" then return math.abs(m.painReduction or 0) end
        if group == "FEVER_TREATMENT" then return math.abs(m.fluReduction or 0) + math.abs(m.feverReduction or 0) end
        if group == "TOXIN_TREATMENT" then return math.abs(m.foodSicknessChange or 0) end
        return nil
    end
    local function percentileIn(values, value)
        if #values == 0 or value == nil then return nil end
        if #values == 1 then return 50 end
        local below, equal = 0, 0
        for _, v in ipairs(values) do
            if v < value then below = below + 1 elseif v == value then equal = equal + 1 end
        end
        return clamp(((below + (equal - 1) * .5) / (#values - 1)) * 100, 0, 100)
    end
    local records, profiles, groups = {}, {}, {}
    for _, data in pairs(results) do
        local script = manager and manager:FindItem(data.fullType) or nil
        if script then
            local ok, runtime = pcall(function() return script:InstanceItem(nil, false) end)
            if not ok then runtime = nil end
            local tags = lower(call(script, "getTags") or field(script, "tags") or "")
            local display = tostring(data.displayCategory or call(script, "getDisplayCategory") or "")
            local scriptItemType = lower(call(script, "getItemType") or field(script, "itemType") or "")
            local isDrainable = string.find(scriptItemType, "drainable", 1, true) ~= nil
            local medical = boolMetric(runtime, script, { "isMedical", "getMedical" }, "medical")
            local m = {
                canBandage = boolMetric(runtime, script, { "isCanBandage", "getCanBandage" }, "canBandage"),
                bandagePower = metric(runtime, script, { "getBandagePower" }, "bandagePower"),
                alcoholPower = metric(runtime, script, { "getAlcoholPower" }, "alcoholPower"),
                reduceInfectionPower = metric(runtime, script, { "getReduceInfectionPower" }, "reduceInfectionPower"),
                painReduction = metric(runtime, script, { "getPainReduction", "getPainChange" }, "painReduction"),
                fluReduction = metric(runtime, script, { "getFluReduction" }, "fluReduction"),
                feverReduction = metric(runtime, script, { "getFeverReduction", "getReduceFever" }, "feverReduction"),
                foodSicknessChange = metric(runtime, script, { "getFoodSicknessChange" }, "foodSicknessChange"),
                fatigueChange = metric(runtime, script, { "getFatigueChange" }, "fatigueChange"),
                stressChange = metric(runtime, script, { "getStressChange" }, "stressChange"),
                unhappyChange = metric(runtime, script, { "getUnhappyChange" }, "unhappyChange"),
                useDelta = metric(runtime, script, { "getUseDelta" }, "useDelta"),
                uses = metric(runtime, script, { "getUses" }, "uses"),
                count = metric(runtime, script, { "getCount" }, "count"),
                weight = metric(runtime, script, { "getActualWeight", "getWeight" }, "actualWeight"),
            }
            local hasOnEat = (field(script, "onEat") or call(script, "getOnEat")) ~= nil
            local unpackRecipe = field(script, "doubleClickRecipe") or call(script, "getDoubleClickRecipe")
            local hasNumericEffect = (m.bandagePower or 0) > 0 or (m.alcoholPower or 0) > 0 or (m.reduceInfectionPower or 0) > 0
                or (m.painReduction or 0) ~= 0 or (m.fluReduction or 0) ~= 0 or (m.feverReduction or 0) ~= 0 or (m.foodSicknessChange or 0) < 0
            local firstAid = lower(display) == "firstaid"
            local procedureTag = string.find(tags, "removebullet", 1, true) or string.find(tags, "removeglass", 1, true) or string.find(tags, "tweezers", 1, true)
            if medical or firstAid or m.canBandage or hasNumericEffect or procedureTag then
                local group, reason = groupFor(m, tags, hasOnEat, unpackRecipe)
                local uses = usesFor(m, isDrainable)
                local partial = not hasNumericEffect and (hasOnEat or procedureTag or unpackRecipe or medical or firstAid)
                local status = hasNumericEffect and "MECHANICAL_VALUE_KNOWN" or (partial and "MECHANICAL_VALUE_PARTIAL" or "UTILITY_UNSUPPORTED")
                local profile = table.concat({ group, tostring(m.canBandage), tostring(m.bandagePower), tostring(m.alcoholPower), tostring(m.reduceInfectionPower), tostring(m.painReduction), tostring(m.fluReduction), tostring(m.feverReduction), tostring(m.foodSicknessChange), tostring(m.fatigueChange), tostring(m.useDelta), tostring(uses), tostring(m.weight), tostring(tags), tostring(hasOnEat), tostring(unpackRecipe) }, ":")
                local record = { data=data, script=script, display=display, scriptItemType=scriptItemType, isDrainable=isDrainable, medical=medical, tags=tags, m=m, uses=uses, group=group, groupReason=reason, status=status, hasOnEat=hasOnEat, unpackRecipe=unpackRecipe, profile=profile }
                record.score = scoreFor(group, m, uses)
                record.effect = dominantEffect(group, m)
                table.insert(records, record); profiles[profile] = profiles[profile] or {}; table.insert(profiles[profile], record)
                groups[group] = groups[group] or {}; table.insert(groups[group], record)
            end
        end
    end
    table.sort(records, function(a,b) return a.data.fullType < b.data.fullType end)
    local counts = { MECHANICAL_VALUE_KNOWN=0, MECHANICAL_VALUE_PARTIAL=0, UTILITY_UNSUPPORTED=0 }
    for _, r in ipairs(records) do counts[r.status] = counts[r.status] + 1 end
    for _, list in pairs(groups) do
        table.sort(list, function(a,b)
            local as, bs = a.score or -1, b.score or -1
            return as == bs and a.data.fullType < b.data.fullType or as > bs
        end)
    end
    -- MedicalUtility V1 candidates: efficacy dominates, uses are secondary,
    -- and weight deliberately has zero influence.  Normalize within function
    -- after deduplicating mechanical profiles, never across medical problems.
    local utilityModels = {}
    for group, list in pairs(groups) do
        local byProfile, profilesForGroup = {}, {}
        for _, r in ipairs(list) do
            if r.status == "MECHANICAL_VALUE_KNOWN" and r.effect ~= nil and not byProfile[r.profile] then
                byProfile[r.profile] = r; table.insert(profilesForGroup, r)
            end
        end
        local effects, uses = {}, {}
        for _, r in ipairs(profilesForGroup) do table.insert(effects, r.effect); table.insert(uses, r.uses) end
        table.sort(effects); table.sort(uses)
        local rows = {}
        for _, r in ipairs(list) do
            if r.status == "MECHANICAL_VALUE_KNOWN" and r.effect ~= nil then
                local ep, up = percentileIn(effects, r.effect), percentileIn(uses, r.uses)
                table.insert(rows, { record=r, effectPercentile=ep, usesPercentile=up, modelA=.90 * ep + .10 * up, modelB=.80 * ep + .20 * up })
            end
        end
        table.sort(rows, function(a,b) return a.modelA == b.modelA and a.record.data.fullType < b.record.data.fullType or a.modelA > b.modelA end)
        if #rows > 0 then utilityModels[group] = { profiles=#profilesForGroup, rows=rows } end
    end
    local unique = 0; for _ in pairs(profiles) do unique = unique + 1 end
    local writer = getFileWriter("ItemRarity_MedicalRuntimeAudit.txt", true, false); if not writer then return end
    writer:write("Item Rarity MEDICAL runtime audit (REPORT ONLY)\n")
    writer:write("No Utility, FinalRarityTier, registry, UI, or signature field is changed. Candidate detection uses runtime/script Medical, FirstAid display category, medical effects, and procedure tags; never names/fullTypes.\n")
    writer:write("KNOWN = a quantified medical effect is available. PARTIAL = medical/procedure/OnEat/unpack behavior exists but its effect is not quantified safely. UNSUPPORTED = no usable effect evidence. Scores are preliminary within-function efficiency (effect x real drainable uses / weight), not a tier model. B42 ScriptItem exposes vanilla Medical as false through this Lua bridge, so FirstAid/effect/tag evidence is the reliable detector.\n\n")
    writer:write(string.format("ITEMS=%d | UNIQUE_MECHANICAL_PROFILES=%d | KNOWN=%d | PARTIAL=%d | UNSUPPORTED=%d\n\n", #records, unique, counts.MECHANICAL_VALUE_KNOWN, counts.MECHANICAL_VALUE_PARTIAL, counts.UTILITY_UNSUPPORTED))
    writer:write("FUNCTIONAL GROUPS / PRELIMINARY RANKING\n")
    local orderedGroups={}; for group in pairs(groups) do table.insert(orderedGroups, group) end; table.sort(orderedGroups)
    for _, group in ipairs(orderedGroups) do
        local list, uniqueProfiles = groups[group], {}; for _,r in ipairs(list) do uniqueProfiles[r.profile]=true end
        local profileCount=0; for _ in pairs(uniqueProfiles) do profileCount=profileCount+1 end
        writer:write(string.format("\n[%s] items=%d | unique_profiles=%d\nrank | fullType | score | uses | weight | status | effect reason\n",group,#list,profileCount))
        for index,r in ipairs(list) do writer:write(string.format("%d | %s | %s | %d | %s | %s | %s\n",index,r.data.fullType,number(r.score),r.uses,number(r.m.weight),r.status,r.groupReason)) end
    end
    writer:write("\nMEDICALUTILITY V1 SIMULATION (NO WEIGHT)\n")
    writer:write("A = 90% dominant efficacy + 10% real uses; B = 80% dominant efficacy + 20% real uses. Both components are percentile-normalized only inside the same functional group, after mechanical-profile deduplication. This section is not active.\n")
    for _, group in ipairs(orderedGroups) do
        local model = utilityModels[group]
        if model then
            writer:write(string.format("\n[%s] unique_known_profiles=%d\nrank A | fullType | dominant effect | effect pctl | uses | uses pctl | Model A | Model B\n", group, model.profiles))
            for index, row in ipairs(model.rows) do
                writer:write(string.format("%d | %s | %s | %s | %d | %s | %s | %s\n", index, row.record.data.fullType, number(row.record.effect), number(row.effectPercentile), row.record.uses, number(row.usesPercentile), number(row.modelA), number(row.modelB)))
            end
        end
    end
    writer:write("\nALL MEDICAL CANDIDATES\nfullType | original category | DisplayCategory | ScriptItemType | drainable | Medical bridge | functional group | status | BandagePower | CanBandage | AlcoholPower | ReduceInfectionPower | PainReduction | FluReduction | FeverReduction | FoodSicknessChange | FatigueChange | uses | UseDelta | weight | tags | OnEat | unpack | ScarcityTier | ScarcityPercentile | preliminary score\n")
    for _,r in ipairs(records) do
        local d,m=r.data,r.m
        local scarcity = d.baseScarcityTier or d.rarityTier or "N/A"
        local p = d.scarcityPercentile or (d.tableAvailability and d.tableAvailability.routeWeightedPercentile)
        local row={d.fullType,d.category or "",r.display,r.scriptItemType,tostring(r.isDrainable),tostring(r.medical),r.group,r.status,number(m.bandagePower),tostring(m.canBandage),number(m.alcoholPower),number(m.reduceInfectionPower),number(m.painReduction),number(m.fluReduction),number(m.feverReduction),number(m.foodSicknessChange),number(m.fatigueChange),r.uses,number(m.useDelta),number(m.weight),r.tags,tostring(r.hasOnEat),tostring(r.unpackRecipe or ""),scarcity,number(p),number(r.score)}
        for i,v in ipairs(row) do row[i]=tostring(v) end; writer:write(table.concat(row," | ").."\n")
    end
    writer:write("\nIDENTICAL MECHANICAL PROFILES\n")
    local duplicateGroups={}; for _,list in pairs(profiles) do if #list>1 then table.insert(duplicateGroups,list) end end
    table.sort(duplicateGroups,function(a,b) return a[1].profile < b[1].profile end)
    for _,list in ipairs(duplicateGroups) do local names={}; for _,r in ipairs(list) do table.insert(names,r.data.fullType) end; table.sort(names); writer:write(table.concat(names,", ").."\n") end
    writer:close()
    ItemRarityUtils.info(string.format("MEDICAL runtime audit written: %d items, %d unique profiles, KNOWN=%d PARTIAL=%d UNSUPPORTED=%d.", #records, unique, counts.MECHANICAL_VALUE_KNOWN, counts.MECHANICAL_VALUE_PARTIAL, counts.UTILITY_UNSUPPORTED))
end

-- FOOD discovery is intentionally report-only.  Food has overlapping roles
-- (freshness, cooking, hydration, energy, ingredients and special effects),
-- so this audit records a primary role plus flags before any Utility formula
-- is considered.  It never changes the registry or FinalRarityTier.
local function writeFoodRuntimeAudit(results)
    if type(results) ~= "table" or not getFileWriter then return end
    local manager = getScriptManager and getScriptManager() or nil
    local function metric(runtime, script, getters, member)
        for _, getter in ipairs(getters) do
            local value = tonumber(call(runtime, getter))
            if value == nil then value = tonumber(call(script, getter)) end
            if value ~= nil then return value end
        end
        return tonumber(field(script, member))
    end
    local function boolean(runtime, script, getters, member)
        for _, getter in ipairs(getters) do
            local value = call(runtime, getter)
            if value == nil then value = call(script, getter) end
            if value ~= nil then return value == true end
        end
        return field(script, member) == true
    end
    local function realUses(metrics, drainable)
        if not drainable then return 1 end
        if metrics.useDelta and metrics.useDelta > 0 and metrics.useDelta <= 1 then
            return math.max(1, math.floor((1 / metrics.useDelta) + .5))
        end
        return 1
    end
    local function hasMedicalEffect(m)
        return (m.bandagePower or 0) > 0 or (m.alcoholPower or 0) > 0 or (m.reduceInfectionPower or 0) > 0
            or (m.painReduction or 0) ~= 0 or (m.fluReduction or 0) ~= 0 or (m.feverReduction or 0) ~= 0
            or (m.foodSicknessChange or 0) < 0
    end
    local function flagsFor(m)
        local flags = {}
        if m.cookable then table.insert(flags, "COOKABLE") end
        local fresh = (m.daysFresh or 0) > 0 and (m.daysFresh or 0) < 100000000
        local rotten = (m.daysTotallyRotten or 0) > 0 and (m.daysTotallyRotten or 0) < 100000000
        if fresh or rotten then table.insert(flags, "PERISHABLE") else table.insert(flags, "SHELF_STABLE") end
        if math.abs(m.thirstChange or 0) > 0 then table.insert(flags, "HYDRATION") end
        if (m.calories or 0) > 0 or (m.carbohydrates or 0) > 0 or (m.proteins or 0) > 0 or (m.lipids or 0) > 0 then table.insert(flags, "ENERGY_NUTRITION") end
        if m.dangerousUncooked then table.insert(flags, "RAW_RISK") end
        if m.poison or (m.poisonPower or 0) > 0 or (m.foodSicknessChange or 0) > 0 then table.insert(flags, "TOXIN_RISK") end
        if m.alcoholic or (m.alcoholPower or 0) > 0 then table.insert(flags, "ALCOHOL") end
        if m.preparationRequired then table.insert(flags, "PREPARATION_REQUIRED") end
        if m.preparationAmbiguous then table.insert(flags, "PREPARATION_AMBIGUOUS") end
        return table.concat(flags, ",")
    end
    local function primaryGroup(m)
        if m.cookable then return "COOKABLE" end
        if math.abs(m.thirstChange or 0) > math.abs(m.hungerChange or 0) and math.abs(m.thirstChange or 0) > 0 then return "DRINK_HYDRATION" end
        local fresh = (m.daysFresh or 0) > 0 and (m.daysFresh or 0) < 100000000
        local rotten = (m.daysTotallyRotten or 0) > 0 and (m.daysTotallyRotten or 0) < 100000000
        if fresh or rotten then return "PERISHABLE_READY_OR_INGREDIENT" end
        return "SHELF_STABLE_READY_OR_INGREDIENT"
    end
    local function foodFunction(m, tags, status)
        if status == "MECHANICAL_VALUE_PARTIAL" then return "SPECIAL_PARTIAL" end
        if m.cantEat then return "SPECIAL_PARTIAL" end
        if m.preparationRequired or m.preparationAmbiguous then return "SPECIAL_PARTIAL" end
        -- These B42 tags describe a mechanical recipe role rather than a
        -- display name.  They keep recipe components from silently competing
        -- as ordinary ready-to-eat meals.
        if string.find(tags, "ingredient", 1, true) or string.find(tags, "isseed", 1, true)
            or string.find(tags, "iscutting", 1, true) or string.find(tags, "pizzasauce", 1, true) then
            return "INGREDIENT"
        end
        local eatType, eatSound = lower(m.eatType), lower(m.customEatSound)
        if string.find(eatType,"drink",1,true) and string.find(eatSound,"drinking",1,true)
            and (m.thirstBenefit or 0) > (m.hungerBenefit or 0) then return "DRINK" end
        return "FOOD"
    end
    local records, profiles, groups, excludedMedical = {}, {}, {}, 0
    for _, data in pairs(results) do
        local script = manager and manager:FindItem(data.fullType) or nil
        if script then
            local ok, runtime = pcall(function() return script:InstanceItem(nil, false) end)
            if not ok then runtime = nil end
            local display = tostring(data.displayCategory or call(script, "getDisplayCategory") or "")
            -- ScriptItem:getType() is the actual B42 item class (Food,
            -- Weapon, Container…). getItemType() is a namespaced tag such as
            -- base:weapon and is not a Food discriminator.
            local itemType = lower(call(script, "getType") or field(script, "type") or "")
            local tags = lower(call(script, "getTags") or field(script, "tags") or "")
            local m = {
                hungerChange = metric(runtime, script, { "getHungerChange" }, "hungerChange"), thirstChange = metric(runtime, script, { "getThirstChange" }, "thirstChange"),
                calories = metric(runtime, script, { "getCalories" }, "calories"), carbohydrates = metric(runtime, script, { "getCarbohydrates" }, "carbohydrates"), proteins = metric(runtime, script, { "getProteins" }, "proteins"), lipids = metric(runtime, script, { "getLipids" }, "lipids"),
                weight = metric(runtime, script, { "getActualWeight", "getWeight" }, "actualWeight"), daysFresh = metric(runtime, script, { "getDaysFresh" }, "daysFresh"), daysTotallyRotten = metric(runtime, script, { "getDaysTotallyRotten" }, "daysTotallyRotten"),
                cookable = boolean(runtime, script, { "isCookable", "getIsCookable" }, "isCookable"), minutesToCook = metric(runtime, script, { "getMinutesToCook" }, "minutesToCook"), minutesToBurn = metric(runtime, script, { "getMinutesToBurn" }, "minutesToBurn"),
                unhappyChange = metric(runtime, script, { "getUnhappyChange" }, "unhappyChange"), boredomChange = metric(runtime, script, { "getBoredomChange" }, "boredomChange"), stressChange = metric(runtime, script, { "getStressChange" }, "stressChange"), fatigueChange = metric(runtime, script, { "getFatigueChange" }, "fatigueChange"), enduranceChange = metric(runtime, script, { "getEnduranceChange" }, "enduranceChange"),
                dangerousUncooked = boolean(runtime, script, { "isDangerousUncooked" }, "dangerousUncooked"), poison = boolean(runtime, script, { "isPoison" }, "poison"), poisonPower = metric(runtime, script, { "getPoisonPower" }, "poisonPower"),
                foodSicknessChange = metric(runtime, script, { "getFoodSicknessChange" }, "foodSicknessChange"), alcoholic = boolean(runtime, script, { "isAlcoholic" }, "alcoholic"), alcoholPower = metric(runtime, script, { "getAlcoholPower" }, "alcoholPower"),
                reduceFoodSickness = metric(runtime, script, { "getReduceFoodSickness" }, "reduceFoodSickness"), reduceInfectionPower = metric(runtime, script, { "getReduceInfectionPower" }, "reduceInfectionPower"), painReduction = metric(runtime, script, { "getPainReduction", "getPainChange" }, "painReduction"), fluReduction = metric(runtime, script, { "getFluReduction" }, "fluReduction"), feverReduction = metric(runtime, script, { "getFeverReduction", "getReduceFever" }, "feverReduction"),
                bandagePower = metric(runtime, script, { "getBandagePower" }, "bandagePower"), alcoholPowerMedical = metric(runtime, script, { "getAlcoholPower" }, "alcoholPower"), useDelta = metric(runtime, script, { "getUseDelta" }, "useDelta"),
                isDrink = boolean(runtime, script, { "isDrink", "getIsDrink" }, "isDrink"),
                cantEat = boolean(runtime, script, { "isCantEat", "getCantEat" }, "cantEat"),
                eatType = tostring(call(script, "getEatType") or field(script, "eatType") or ""), customEatSound = tostring(call(script, "getCustomEatSound") or field(script, "customEatSound") or ""),
                foodType = tostring(call(script, "getFoodType") or field(script, "foodType") or ""), replaceOnUse = tostring(call(script, "getReplaceOnUse") or field(script, "replaceOnUse") or ""), replaceOnDeplete = tostring(call(script, "getReplaceOnDeplete") or field(script, "replaceOnDeplete") or ""),
                onCooked = tostring(call(runtime, "getOnCooked") or call(script, "getOnCooked") or field(script, "onCooked") or ""), cookingSound = tostring(call(runtime, "getCookingSound") or call(script, "getCookingSound") or field(script, "cookingSound") or ""), evolvedRecipeName = tostring(call(script, "getEvolvedRecipeName") or field(script, "evolvedRecipeName") or ""), evolvedRecipes = tostring(call(script, "getEvolvedRecipe") or field(script, "evolvedRecipe") or ""), replaceOnCooked = tostring(call(runtime, "getReplaceOnCooked") or call(script, "getReplaceOnCooked") or field(script, "replaceOnCooked") or ""),
                removeNegativeEffectOnCooked = boolean(runtime, script, { "isRemoveNegativeEffectOnCooked", "isRemoveUnhappinessWhenCooked", "getRemoveUnhappinessWhenCooked" }, "removeUnhappinessWhenCooked"),
            }
            -- DisplayCategory=Cooking is intentionally *not* food evidence:
            -- B42 places pans, tins, utensils and preparation containers in
            -- that category.  They enter only if they also expose edible
            -- nutrition/hydration or actual cookability.
            local foodTyped = itemType == "food" or lower(display) == "food"
            local medical = hasMedicalEffect(m) or lower(display) == "firstaid" or field(script, "medical") == true
            local nutritive = (m.hungerChange or 0) ~= 0 or (m.thirstChange or 0) ~= 0 or (m.calories or 0) ~= 0 or (m.carbohydrates or 0) ~= 0 or (m.proteins or 0) ~= 0 or (m.lipids or 0) ~= 0
            -- Freshness fields default to 1e9 even on weapons, books and
            -- containers. They are reportable only after Food is established,
            -- never evidence that the item itself is edible.
            local foodEvidence = foodTyped or nutritive or m.cookable or string.find(tags, "food", 1, true) ~= nil
            if foodEvidence and medical then
                excludedMedical = excludedMedical + 1
            elseif foodEvidence then
                m.uses = realUses(m, string.find(itemType, "drainable", 1, true) ~= nil)
                m.hungerBenefit = math.max(0, -(m.hungerChange or 0))
                m.thirstBenefit = math.max(0, -(m.thirstChange or 0))
                m.hungerPerWeight = m.hungerBenefit / math.max(.01, m.weight or 1)
                m.caloriesPerWeight = math.max(0, m.calories or 0) / math.max(.01, m.weight or 1)
                -- Structural preparation evidence only. A food is not made
                -- partial merely because it can be cooked: raw meat remains
                -- directly consumable (with a risk). The Food runtime object
                -- exposes the actual OnCooked callback and cooked-negative
                -- transformation flag. EvolvedRecipe alone only means that an
                -- item *can be an ingredient*, so it is diagnostic evidence
                -- but deliberately not a preparation classifier.
                m.preparationRequired = m.cookable and (m.onCooked ~= "")
                m.preparationAmbiguous = (not m.preparationRequired) and (m.removeNegativeEffectOnCooked or (m.replaceOnCooked ~= "" and m.replaceOnCooked ~= "[]"))
                local group, flags = primaryGroup(m), flagsFor(m)
                local status = (m.hungerBenefit > 0 or m.thirstBenefit > 0 or (m.calories or 0) > 0) and "MECHANICAL_VALUE_KNOWN" or "MECHANICAL_VALUE_PARTIAL"
                local partialReason = nil
                if m.cantEat then partialReason = "CANT_EAT_REQUIRED"
                elseif m.preparationRequired then partialReason = "PREPARATION_REQUIRED"
                elseif m.preparationAmbiguous then partialReason = "PREPARATION_AMBIGUOUS"
                elseif status == "MECHANICAL_VALUE_PARTIAL" then partialReason = "SPECIAL_UNQUANTIFIED" end
                local preliminaryFunction = foodFunction(m, tags, status)
                if not partialReason and preliminaryFunction == "INGREDIENT" then partialReason = "INGREDIENT_UNQUANTIFIED" end
                local utilityStatus = partialReason and "PARTIAL" or "ELIGIBLE"
                local profile = table.concat({ group, tostring(m.hungerChange), tostring(m.thirstChange), tostring(m.calories), tostring(m.carbohydrates), tostring(m.proteins), tostring(m.lipids), tostring(m.daysFresh), tostring(m.daysTotallyRotten), tostring(m.cookable), tostring(m.minutesToCook), tostring(m.unhappyChange), tostring(m.boredomChange), tostring(m.stressChange), tostring(m.dangerousUncooked), tostring(m.poison), tostring(m.poisonPower), tostring(m.alcoholic), tostring(m.alcoholPower), tostring(m.uses) }, ":")
                local record = { data=data, m=m, group=group, functionalGroup=preliminaryFunction, flags=flags, status=status, foodUtilityStatus=utilityStatus, foodPartialReason=partialReason, display=display, itemType=itemType, tags=tags, profile=profile }
                table.insert(records, record); profiles[profile] = profiles[profile] or {}; table.insert(profiles[profile], record)
                groups[group] = groups[group] or {}; table.insert(groups[group], record)
            end
        end
    end
    table.sort(records, function(a,b) return a.data.fullType < b.data.fullType end)
    local function values(metric)
        local out, seen = {}, {}
        for _, r in ipairs(records) do if not seen[r.profile] then seen[r.profile] = true; table.insert(out, r.m[metric] or 0) end end
        return sortedCopy(out)
    end
    local function distribution(writer, metric)
        local v=values(metric); if #v == 0 then return end
        writer:write(string.format("%s | min=%s p10=%s p25=%s p50=%s p75=%s p90=%s p95=%s max=%s\\n", metric, number(quantile(v,0)), number(quantile(v,10)), number(quantile(v,25)), number(quantile(v,50)), number(quantile(v,75)), number(quantile(v,90)), number(quantile(v,95)), number(quantile(v,100))))
    end
    local function writeRank(writer, label, metric, descending)
        local rows={}; for _, r in ipairs(records) do if r.status == "MECHANICAL_VALUE_KNOWN" then table.insert(rows,r) end end
        table.sort(rows,function(a,b)
            local av,bv=a.m[metric] or 0,b.m[metric] or 0
            if av == bv then return a.data.fullType < b.data.fullType end
            if descending then return av > bv end
            return av < bv
        end)
        writer:write("\\n"..label.." (top/bottom 15; unique mechanics are marked by first occurrence)\\nfullType | value | hunger | calories | weight | flags | ScarcityTier\\n")
        local count, seen=0,{}; for _,r in ipairs(rows) do if not seen[r.profile] then seen[r.profile]=true; count=count+1; writer:write(string.format("%s | %s | %s | %s | %s | %s | %s\\n",r.data.fullType,number(r.m[metric]),number(r.m.hungerBenefit),number(r.m.calories),number(r.m.weight),r.flags,tostring(r.data.baseScarcityTier or r.data.rarityTier))); if count>=15 then break end end end
    end
    local function writeDefaults(writer, metric)
        local counts={}; for _,r in ipairs(records) do local key=tostring(r.m[metric] or 0); counts[key]=(counts[key] or 0)+1 end
        local rows={}; for value,count in pairs(counts) do table.insert(rows,{value=value,count=count}) end; table.sort(rows,function(a,b) return a.count == b.count and a.value < b.value or a.count > b.count end)
        local out={}; for i,row in ipairs(rows) do if i>5 then break end; table.insert(out,row.value.."="..row.count) end; writer:write(metric.." defaults/frequent values: "..table.concat(out,", ").."\\n")
    end
    local unique=0; for _ in pairs(profiles) do unique=unique+1 end
    local foodExperiment = nil -- implemented in FoodRuntimeAudit.lua after this raw audit is split.
    local writer=getFileWriter("ItemRarity_FoodRuntimeAudit.txt",true,false); if not writer then return end
    writer:write("Item Rarity FOOD runtime audit (REPORT ONLY)\\nNo Utility, FinalRarityTier, registry, UI, or signature field is changed. Medical-functional items are excluded using quantified medical effects/FirstAid/Medical evidence, never fullType or name.\\n\\n")
    writer:write(string.format("ITEMS=%d | UNIQUE_MECHANICAL_PROFILES=%d | EXCLUDED_AS_MEDICAL=%d\\n",#records,unique,excludedMedical))
    writer:write("Primary group is descriptive only; flags preserve overlapping food roles. No FoodUtility or hypothetical tier is calculated.\\n\\nGROUPS\\n")
    local groupNames={}; for group in pairs(groups) do table.insert(groupNames,group) end; table.sort(groupNames)
    for _,group in ipairs(groupNames) do local seen,n={},0; for _,r in ipairs(groups[group]) do if not seen[r.profile] then seen[r.profile]=true;n=n+1 end end; writer:write(group.." | items="..#groups[group].." | unique_profiles="..n.."\\n") end
    writer:write("\\nFoodQuality experiment was temporarily split out after hitting the B42 compiler's 200-local limit. Raw Food audit remains valid; no active data or tiers changed.\\n")
    writer:write("\\nATTRIBUTE DISTRIBUTIONS (unique mechanical profiles)\\n")
    for _,metric in ipairs({"hungerBenefit","thirstBenefit","calories","carbohydrates","proteins","lipids","weight","daysFresh","daysTotallyRotten","minutesToCook","minutesToBurn","unhappyChange","boredomChange","stressChange","fatigueChange","enduranceChange","poisonPower","foodSicknessChange","alcoholPower","uses"}) do distribution(writer,metric) end
    writer:write("\\nDEFAULTS / FREQUENT VALUES (all candidates; zero can be a generic runtime default, not necessarily an explicit declaration)\\n")
    for _,metric in ipairs({"hungerChange","thirstChange","calories","daysFresh","daysTotallyRotten","cookable","unhappyChange","boredomChange","stressChange","dangerousUncooked","poison","alcoholic","useDelta"}) do writeDefaults(writer,metric) end
    writeRank(writer,"TOP HUNGER BENEFIT","hungerBenefit",true); writeRank(writer,"BOTTOM HUNGER BENEFIT","hungerBenefit",false)
    writeRank(writer,"TOP CALORIES","calories",true); writeRank(writer,"BOTTOM CALORIES","calories",false)
    writeRank(writer,"TOP HUNGER / WEIGHT (diagnostic only)","hungerPerWeight",true); writeRank(writer,"BOTTOM HUNGER / WEIGHT (diagnostic only)","hungerPerWeight",false)
    writeRank(writer,"TOP CALORIES / WEIGHT (diagnostic only)","caloriesPerWeight",true); writeRank(writer,"BOTTOM CALORIES / WEIGHT (diagnostic only)","caloriesPerWeight",false)
    writeRank(writer,"BEST CONSERVATION: DaysTotallyRotten","daysTotallyRotten",true); writeRank(writer,"LOWEST CONSERVATION: DaysTotallyRotten","daysTotallyRotten",false)
    writer:write("\\nFUNCTIONAL GROUP EXAMPLES\\ngroup | fullType | HungerChange | ThirstChange | Calories | Fresh/Rotten | cookable | flags | ScarcityTier | ScarcityPercentile\\n")
    for _,group in ipairs(groupNames) do local count=0; for _,r in ipairs(groups[group]) do count=count+1; if count<=12 then local m=r.m; writer:write(string.format("%s | %s | %s | %s | %s | %s/%s | %s | %s | %s | %s\\n",group,r.data.fullType,number(m.hungerChange),number(m.thirstChange),number(m.calories),number(m.daysFresh),number(m.daysTotallyRotten),tostring(m.cookable),r.flags,tostring(r.data.baseScarcityTier or r.data.rarityTier),number(r.data.scarcityPercentile or (r.data.tableAvailability and r.data.tableAvailability.routeWeightedPercentile)))) end end end
    writer:write("\\nSPECIAL / AMBIGUOUS FOOD (PARTIAL or risk/special flags)\\nfullType | primary group | status | flags | hunger | thirst | calories | poison | food sickness | alcohol | tags | DisplayCategory\\n")
    for _,r in ipairs(records) do local m=r.m; if r.status ~= "MECHANICAL_VALUE_KNOWN" or string.find(r.flags,"RAW_RISK",1,true) or string.find(r.flags,"TOXIN_RISK",1,true) or string.find(r.flags,"ALCOHOL",1,true) then writer:write(string.format("%s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s\\n",r.data.fullType,r.group,r.status,r.flags,number(m.hungerChange),number(m.thirstChange),number(m.calories),tostring(m.poison),number(m.foodSicknessChange),tostring(m.alcoholic),r.tags,r.display)) end end
    writer:write("\\nALL FOOD CANDIDATES\\nfullType | originalCategory | DisplayCategory | ItemType | primaryGroup | flags | status | HungerChange | ThirstChange | Calories | Carbs | Proteins | Lipids | weight | Hunger/weight | Calories/weight | DaysFresh | DaysTotallyRotten | cookable | MinutesToCook | MinutesToBurn | Unhappy | Boredom | Stress | Fatigue | Endurance | DangerousUncooked | Poison | PoisonPower | FoodSickness | Alcoholic | AlcoholPower | uses | tags | ScarcityTier | ScarcityPercentile\\n")
    for _,r in ipairs(records) do local d,m=r.data,r.m; local row={d.fullType,d.category or "",r.display,r.itemType,r.group,r.flags,r.status,number(m.hungerChange),number(m.thirstChange),number(m.calories),number(m.carbohydrates),number(m.proteins),number(m.lipids),number(m.weight),number(m.hungerPerWeight),number(m.caloriesPerWeight),number(m.daysFresh),number(m.daysTotallyRotten),tostring(m.cookable),number(m.minutesToCook),number(m.minutesToBurn),number(m.unhappyChange),number(m.boredomChange),number(m.stressChange),number(m.fatigueChange),number(m.enduranceChange),tostring(m.dangerousUncooked),tostring(m.poison),number(m.poisonPower),number(m.foodSicknessChange),tostring(m.alcoholic),number(m.alcoholPower),number(m.uses),r.tags,tostring(d.baseScarcityTier or d.rarityTier),number(d.scarcityPercentile or (d.tableAvailability and d.tableAvailability.routeWeightedPercentile))}; writer:write(table.concat(row," | ").."\\n") end
    writer:close(); ItemRarityUtils.info(string.format("FOOD runtime audit written: %d items, %d unique profiles; medical excluded=%d (report only).",#records,unique,excludedMedical))
    if ItemRarityFoodQualityExperiment and ItemRarityFoodQualityExperiment.write then ItemRarityFoodQualityExperiment.write(records) end
end

ItemRarityFoodRuntimeAudit = ItemRarityFoodRuntimeAudit or {}
ItemRarityFoodRuntimeAudit.write = writeFoodRuntimeAudit

if reloadedActivePipelineForDevelopment and ItemRarityScanner and ItemRarityScanner.results then
    writeAccessoryMechanicalValueAudit(ItemRarityScanner.results)
    writeTrivialPolicySimulation(ItemRarityScanner.results)
    writeMedicalRuntimeAudit(ItemRarityScanner.results)
    writeFoodRuntimeAudit(ItemRarityScanner.results)
end
