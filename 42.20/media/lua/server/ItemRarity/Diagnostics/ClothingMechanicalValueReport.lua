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
    if not reloadLuaFile or (ItemRarityScanner and ItemRarityScanner.isScanning) then return end
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
end

reloadActivePipelineForDevelopment()

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
