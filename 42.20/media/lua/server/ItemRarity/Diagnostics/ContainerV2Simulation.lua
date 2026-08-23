require "ItemRarity/RarityUtils"

-- ContainerUtility V2 simulation only.  It has no dependency from the
-- scanner and never mutates active Utility, FinalRarityTier or the registry.
ItemRarityContainerV2Simulation = ItemRarityContainerV2Simulation or {}

local TARGETS={"Base.Bag_Schoolbag","Base.Bag_NormalHikingBag","Base.Bag_BigHikingBag","Base.Bag_ALICEpack","LB.Bag_LegendaryBackpack","Base.Bag_ChestRig","Base.Bag_ALICE_BeltSus","Base.AmmoStrap_Bullets","Base.Bag_FannyPackFront","Base.KeyRing"}
local BACK={capacity=.35,weightReduction=.35,emptyWeight=.15,attachments=.05}
-- Provisional structural sensitivity only; not an active or frozen formula.
local TORSO_A={capacity=.35,weightReduction=.35,attachments=.15,emptyWeight=.15}
local TORSO_B={capacity=.30,weightReduction=.30,attachments=.25,emptyWeight=.15}
local TORSO_C={capacity=.25,weightReduction=.30,attachments=.30,emptyWeight=.15}
local FANNY={capacity=.50,weightReduction=.30,emptyWeight=.20}
local ORDER={"capacity","weightReduction","emptyWeight","attachments","maxItemSize"}

local function call(o,m) if not o or type(o[m])~="function" then return nil end local ok,v=pcall(function() return o[m](o) end); return ok and v or nil end
local function field(o,m,f) local v=call(o,m); if v~=nil then return v end; local ok,x=pcall(function() return o and o[f] end); return ok and x or nil end
local function lower(v) return string.lower(tostring(v or "")) end
local function has(t,x) return string.find(lower(t),x,1,true)~=nil end
local function num(v) return tonumber(v) end
local function n(v) return v==nil and "N/A" or string.format("%.2f",tonumber(v) or 0) end
local function mod(ft) return string.match(tostring(ft),"^([^.]+)%.") or "UNKNOWN" end
local function script(ft) local m=getScriptManager and getScriptManager() or nil; return m and m:FindItem(ft) or nil end
local function runtime(s) if not s then return nil end local ok,i=pcall(function() return s:InstanceItem(nil,false) end); return ok and i or nil end
local function size(c) local v=call(c,"size"); return tonumber(v) or 0 end

local function row(data)
 local s=script(data.fullType); local r=runtime(s)
 -- B42's canBeEquipped bridge commonly returns the ItemBodyLocation enum,
 -- despite the misleading name.  Retain that structural enum, but discard a
 -- literal boolean should a future bridge return one instead.
 local equipped=field(r,"canBeEquipped","canBeEquipped")
 if type(equipped)=="boolean" then equipped=nil end
 local body=equipped or field(r,"getBodyLocation","bodyLocation") or field(s,"getBodyLocation","bodyLocation") or field(r,"getEquipLocation","equipLocation") or field(s,"getEquipLocation","equipLocation")
 if type(body)=="function" then body=nil end
 local accept=field(r,"getAcceptItemFunction","acceptItemFunction") or field(s,"getAcceptItemFunction","acceptItemFunction")
 if type(accept)=="function" then accept=nil end
 local max=num(field(r,"getMaxItemSize","maxItemSize")) or num(field(s,"getMaxItemSize","maxItemSize"))
 local tags=lower(field(s,"getTags","tags")); local m=data.utilityMetrics or {}
 local group
 if has(accept,"keyring") or has(tags,"keyring") then group="KEY_CONTAINER"
 elseif has(body,"fanny") then group="FANNY_PACK"
 elseif has(body,"ammo") then group="TORSO_AMMO"
 elseif has(body,"webbing") or has(body,"satchel") then group="TORSO_GENERAL"
 elseif has(body,"back") then group="BACK"
 else return nil end
 return {data=data,group=group,body=tostring(body or ""),metrics={capacity=m.capacity,weightReduction=m.weightReduction,emptyWeight=m.emptyWeight,attachments=size(call(r,"getAttachmentsProvided")),maxItemSize=max}}
end

local function profile(x)
 local a={}; for _,k in ipairs(ORDER) do local v=x.metrics[k]; table.insert(a,v==nil and "-" or string.format("%.5f",v)) end; return table.concat(a,":")
end
local function sort(a) table.sort(a); return a end
local function q(a,p) if #a==0 then return nil end local x=1+(#a-1)*p/100; local lo,hi=math.floor(x),math.ceil(x); return lo==hi and a[lo] or a[lo]+(a[hi]-a[lo])*(x-lo) end
local function unique(a) local r,s={},{}; for _,v in ipairs(a) do if not s[v] then s[v]=true;table.insert(r,v) end end; return sort(r) end
local function pctl(a,v,invert)
 if v==nil or #a==0 then return nil end; local f,l
 for i,x in ipairs(a) do if x==v then f=f or i;l=i end end; if not f then return nil end
 local p=#a==1 and 50 or ((f+l-2)/(2*(#a-1)))*100; return invert and 100-p or p
end
local function confidence(count) return count>=12 and "HIGH" or (count>=5 and "MEDIUM" or "LOW") end
local function refRows(rows) local by,output={},{}; for _,x in ipairs(rows) do local k=profile(x);if not by[k] then by[k]=x;table.insert(output,x) end end;return output end
local function score(x,refs,weights)
 local total,denom=0,0
 for k,w in pairs(weights) do
  if x.metrics[k]~=nil then local values={};for _,r in ipairs(refs) do if r.metrics[k]~=nil then table.insert(values,r.metrics[k]) end end
   if #values>0 then values=sort(values);local lo,hi=q(values,5),q(values,95);local v=math.max(lo,math.min(hi,x.metrics[k]));local a={};for _,z in ipairs(values) do table.insert(a,math.max(lo,math.min(hi,z))) end;local p=pctl(unique(a),v,k=="emptyWeight");if p then total=total+p*w;denom=denom+w end end
  end
 end
 return denom>0 and total/denom or nil
end
local function capRare(t) return (t=="EPIC" or t=="EXOTIC") and "RARE" or t end
local function p3(t) return (t=="COMMON" or t=="UNCOMMON") and "COMMON" or "UNCOMMON" end
local function simulatedTier(x,scoreV2,rankConfidence)
 local base=x.data.baseScarcityTier
 if x.group=="KEY_CONTAINER" then return p3(base),"KEY policy P3" end
 if rankConfidence=="LOW" then return capRare(base),"low ranking confidence: no promotion" end
 if scoreV2 and scoreV2>=85 then return base=="COMMON" and "UNCOMMON" or base=="UNCOMMON" and "RARE" or base=="RARE" and "EPIC" or base=="EPIC" and "EPIC" or "EXOTIC","V1 threshold compatibility" end
 if scoreV2 and scoreV2<=20 then return base=="EXOTIC" and "EPIC" or base=="EPIC" and "RARE" or base=="RARE" and "UNCOMMON" or base=="UNCOMMON" and "COMMON" or "COMMON","V1 demotion compatibility" end
 return base,"between V1 thresholds"
end

function ItemRarityContainerV2Simulation.write(results)
 if type(results)~="table" or not getFileWriter then return nil end
 local groups={};for _,d in pairs(results) do if d.category=="CONTAINER" then local x=row(d);if x then x.profile=profile(x);groups[x.group]=groups[x.group] or {};table.insert(groups[x.group],x) end end end
 local w=getFileWriter("ItemRarity_ContainerV2Simulation.txt",true,false);if not w then return nil end
 w:write("ContainerUtility V2 simulation (READ ONLY; active V1 unchanged)\n")
 w:write("V2 references are vanilla profiles inside each structural group. Modded items are scored against those references but never define them. Scarcity remains the loaded vanilla+mod universe.\n")
 w:write("RunSpeedModifier is deliberately absent: direct scripts declare it, but current B42 ScriptItem/runtime bridges do not expose it safely. Available weights are re-scaled; missing is never zero.\n")
 w:write("BACK weights: Capacity35/Reduction35/EmptyWeight15 inverse/Attachments5. FANNY provisional absolute-simple weights: Capacity50/Reduction30/EmptyWeight20 inverse.\n")
 w:write("TORSO_GENERAL calibrations: A=Capacity35/Reduction35/Attachments15/EmptyWeight15 inverse; B=30/30/25/15; C=25/30/30/15. RunSpeed is unavailable and excluded.\n\n")
 w:write("GROUP | all fullTypes | vanilla profiles | loaded profiles | RankingConfidence | normalizable now | note\n")
 local names={};for g in pairs(groups) do table.insert(names,g) end;table.sort(names)
 for _,g in ipairs(names) do local all=groups[g];local vanilla={};for _,x in ipairs(all) do if mod(x.data.fullType)=="Base" then table.insert(vanilla,x) end end;local vr,ar=refRows(vanilla),refRows(all);local note=g=="TORSO_AMMO" and "one profile; no mechanical differentiation" or g=="KEY_CONTAINER" and "trivial/special policy" or g=="FANNY_PACK" and "small population; no aggressive promotion" or "";w:write(string.format("%s | %d | %d | %d | %s | %s | %s\n",g,#all,#vr,#ar,confidence(#vr),g=="BACK" and "YES" or "SIMULATION_ONLY",note)) end
 w:write("\nACTIVE FINAL-TIER DISTRIBUTION (after a V2 rescan)\n")
 w:write("group | COMMON | UNCOMMON | RARE | EPIC | EXOTIC\n")
 for _,g in ipairs(names) do local tally={COMMON=0,UNCOMMON=0,RARE=0,EPIC=0,EXOTIC=0};for _,x in ipairs(groups[g]) do local tier=x.data.finalRarityTier or "COMMON";tally[tier]=(tally[tier] or 0)+1 end;w:write(string.format("%s | %d | %d | %d | %d | %d\n",g,tally.COMMON,tally.UNCOMMON,tally.RARE,tally.EPIC,tally.EXOTIC)) end
 local torso=groups.TORSO_GENERAL or {};local torsoVanilla={};for _,x in ipairs(torso) do if mod(x.data.fullType)=="Base" then table.insert(torsoVanilla,x) end end;table.sort(torsoVanilla,function(a,b)return a.data.fullType<b.data.fullType end)
 w:write("\nTORSO_GENERAL CALIBRATION (all vanilla fullTypes; RankingConfidence remains LOW)\n")
 w:write("fullType | body/equip location | Capacity | WeightReduction | EmptyWeight | Hotbar/Attachments | Score A | Score B | Score C | Scarcity | tier A | tier B | tier C\n")
 local torsoRefs=refRows(torsoVanilla);local torsoConf=confidence(#torsoRefs)
 for _,x in ipairs(torsoVanilla) do local a,b,c=score(x,torsoRefs,TORSO_A),score(x,torsoRefs,TORSO_B),score(x,torsoRefs,TORSO_C);local ta=simulatedTier(x,a,torsoConf);local tb=simulatedTier(x,b,torsoConf);local tc=simulatedTier(x,c,torsoConf);w:write(string.format("%s | %s | %s | %s | %s | %d | %s | %s | %s | %s | %s | %s | %s\n",x.data.fullType,x.body,n(x.metrics.capacity),n(x.metrics.weightReduction),n(x.metrics.emptyWeight),x.metrics.attachments or 0,n(a),n(b),n(c),tostring(x.data.baseScarcityTier),ta,tb,tc)) end
 w:write("\nTARGET COMPARISON\n")
 w:write("fullType | group | vanilla/modded | vanilla reference profiles | V1 | V2 vanilla-reference | Scarcity | V1 tier | V2 diagnostic tier | RankingConfidence | reason\n")
 for _,ft in ipairs(TARGETS) do
  local found=nil;for _,g in pairs(groups) do for _,x in ipairs(g) do if x.data.fullType==ft then found=x end end end
  if not found then w:write(ft.." | unavailable\n") else local all=groups[found.group];local vanilla={};for _,x in ipairs(all) do if mod(x.data.fullType)=="Base" then table.insert(vanilla,x) end end;local refs=refRows(vanilla);local weights=found.group=="BACK" and BACK or found.group=="TORSO_GENERAL" and TORSO_A or found.group=="FANNY_PACK" and FANNY or nil;local conf=confidence(#refs);local s=weights and score(found,refs,weights) or (found.group=="TORSO_AMMO" and 50 or nil);local tier,reason=simulatedTier(found,s,conf);w:write(string.format("%s | %s | %s | %d | %s | %s | %s | %s | %s | %s | %s\n",ft,found.group,mod(ft)=="Base" and "vanilla" or "modded",#refs,n(found.data.utility),n(s),tostring(found.data.baseScarcityTier),tostring(found.data.finalRarityTier),tier,conf,reason)) end
 end
 w:close();ItemRarityUtils.info("ContainerUtility V2 simulation written to Zomboid/Lua/ItemRarity_ContainerV2Simulation.txt (read-only).");return true
end
