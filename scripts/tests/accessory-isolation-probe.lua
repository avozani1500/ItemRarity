local I=ItemRarityUtilityIsolation
local function c(id,n)
 return {data={fullType=id,module="Fixture",category="ACCESSORY",rarityTier="RARE",tableAvailability={routeWeightedPercentile=40}},
 kind="ACCESSORY",subgroup="neck",profile=id,utilityEligible=false,accessoryMechanicalCandidate=true,
 accessoryTrivialCosmeticEligible=true,metrics={biteDefense=n,scratchDefense=n,bulletDefense=n,insulation=0,windResistance=0,waterResistance=0}}
end
local function controls()
 local watch=c("Fixture.Watch",0);watch.accessoryTimepiecePartial=true
 local special=c("Fixture.Special",0);special.accessoryMechanicalSpecialBehavior=true
 return {c("Fixture.Cosmetic",0),c("Fixture.Mechanical",10),watch,special}
end
local function eq(a,b,p)
 assert(type(a)==type(b),p.." type")
 if type(a)=="table" then for k,v in pairs(a) do eq(v,b[k],p.."."..tostring(k)) end;for k in pairs(b) do assert(a[k]~=nil,p.." extra") end
 else assert(a==b,p.." value") end
end
local function run(cs,legacy)
 local rows,by={},{};for _,v in ipairs(cs) do rows[v.data.fullType]=v.data;by[v.data.fullType]=v end
 FIXTURE_DISCOVERY=function(d) return by[d.fullType] end
 local ok,err=pcall(legacy and LEGACY_CALCULATE or ItemRarityUtilityCalculator.calculate,rows)
 FIXTURE_DISCOVERY=nil;assert(ok,tostring(err));return rows
end
local baseline=run(controls());eq(run(controls(),true),baseline,"PRE_POST")
local warnings
for repetition=1,2 do
 local cs=controls();local bad={}
 for index,value in ipairs({false,"bad",UNEXPECTED_USERDATA,math.huge,0/0}) do
  local v=c("Fixture.Bad"..index,5);v.metrics.biteDefense=value;bad[#bad+1]=v;cs[#cs+1]=v
 end
 local missing=c("Fixture.Missing",5);missing.metrics.biteDefense=nil;cs[#cs+1]=missing
 local trivial=c("Fixture.TrivialNoCosts",0);trivial.metrics.weight=false;cs[#cs+1]=trivial
 local rows=run(cs);for id,row in pairs(baseline) do eq(row,rows[id],id) end
 for _,v in ipairs(bad) do assert(v.isolationStatus and v.utility==nil) end
 assert(missing.accessoryMechanicalValueStatus=="MECHANICAL_VALUE_PARTIAL" and missing.accessoryMechanicalValue==nil)
 assert(rows["Fixture.TrivialNoCosts"].finalRarityTier=="COMMON" and not trivial.isolationStatus,"structural policy blocked")
 local n=0;for _ in pairs(I.warningKeys) do n=n+1 end;if warnings then assert(n==warnings,"warning spam") end;warnings=n
end
return "UTILITY=ACCESSORY","HEALTHY_COMPARED=4","ITEM_FAILURE_ISOLATED=yes","HEALTHY_ITEM_REGRESSION=0",
 "POPULATION_CONTAMINATION=0 (no population)","GLOBAL_FATAL=0 (item fixtures)","STRUCTURAL_PRECEDENCE=preserved","WARNINGS_DEDUPLICATED=yes"
