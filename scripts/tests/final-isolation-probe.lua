local I=ItemRarityUtilityIsolation
local function equal(a,b,path)
 assert(type(a)==type(b),path..' type')
 if type(a)=='table' then
  for k,v in pairs(a) do equal(v,b[k],path..'.'..tostring(k)) end
  for k in pairs(b) do assert(a[k]~=nil,path..' extra') end
 else assert(a==b,path..' value') end
end
local function cfg(id) return {itemType=id,minLength=10,maxLength=22,maxWeight=4,weightFactor=2,lure={worm=2},isPredator=false} end
local function augmentation(invalid,legacy)
 I.beginScan()
 Fishing={fishes={cfg('Fixture.Fish')},Utils={skillSizeLimit={}}}
 for level=0,10 do Fishing.Utils.skillSizeLimit[level]=level+1 end
 local scripts={{getFullName=function() return 'Fixture.Fish' end}}
 if invalid then
  local missing=cfg('Fixture.Missing');missing.maxWeight=nil;Fishing.fishes[#Fishing.fishes+1]=missing
  scripts[#scripts+1]={getFullName=function() return 'Fixture.Missing' end}
  scripts[#scripts+1]=setmetatable({getFullName=function() return 'Fixture.ThrowingScript' end},{__index=function() error('malformed ScriptItem') end})
 end
 getScriptManager=function() return {getAllItems=function() return scripts end} end
 ItemRarityItemClassifier={getModule=function() return 'Fixture' end,getFunctionalCategory=function() return 'FOOD',{module='Fixture'} end}
 local rows={}
 local stats=(legacy and LEGACY_AUGMENT or ItemRarityUtilityCalculator.augmentUtilityOnly)(rows)
 assert(stats.total==1 and stats.fish==1 and stats.otherUtility==0)
 assert(stats.withScarcity==0 and stats.routeWeighted==0)
 assert(rows['Fixture.Fish'].source=='UTILITY_ONLY' and rows['Fixture.Fish'].rarityTier==nil)
 assert(rows['Fixture.Fish'].hasLootRoute==false and rows['Fixture.Fish'].tableAvailability.routeWeighted=='SKIPPED')
 assert(rows['Fixture.Missing']==nil and rows['Fixture.ThrowingScript']==nil)
 if invalid then assert(#I.report.entries>0,'invalid augmentation unreported') end
 return rows
end
local baseline=augmentation(false,false)
equal(augmentation(false,true),baseline,'augmentation PRE_POST')
equal(augmentation(true,false),baseline,'augmentation invalid cohort')
local warningCount=0;for _ in pairs(I.warningKeys) do warningCount=warningCount+1 end
augmentation(true,false)
local again=0;for _ in pairs(I.warningKeys) do again=again+1 end
assert(again==warningCount,'augmentation warning spam')
getScriptManager=nil
-- Exercise the existing fallback, not a reimplementation of its policy.
for _,tier in ipairs({'RARE','EPIC'}) do
 local row={fullType='Fixture.Fallback',rarityTier=tier,utility=99}
 local c={data=row,kind='CONTAINER',metrics={}}
 I.mark(c,'fixture','PARTIAL_DEFER','missing metric')
 ItemRarityUtilityCalculator.fixtureApplyTier(row,c)
 assert(row.finalRarityTier==tier and row.utility==nil,'fallback invented score/tier')
end
local unknown={fullType='Fixture.Unknown',utility=99}
local c={data=unknown,kind='FISH',metrics={}}
I.mark(c,'fixture','ERROR_ISOLATED','bad metric')
ItemRarityUtilityCalculator.fixtureApplyTier(unknown,c)
assert(unknown.finalRarityTier==nil and unknown.utility==nil,'missing evidence became COMMON/zero')
local valid={fullType='Fixture.Valid',category='MISC',rarityTier='RARE',finalRarityTier='RARE',tableAvailability={routeWeighted=12},utilityEligible=false}
local rows={['Fixture.Valid']=valid,['Fixture.Fish']=baseline['Fixture.Fish']}
local pre=LEGACY_PUBLISH(rows)
local post=ItemRarityRegistryPublisher.publish(rows)
equal(pre,post,'registry PRE_POST')
local malformed={false,'bad',UNEXPECTED_USERDATA,{}, {fullType='bad',finalRarityTier='WRONG'}}
for i,bad in ipairs(malformed) do rows['Fixture.Invalid'..i]=bad end
rows['Fixture.Unknown']=unknown
rows['Fixture.BadScore']={fullType='Fixture.BadScore',finalRarityTier='RARE',utility='bad'}
local cycle={};cycle.self=cycle
rows['Fixture.Cycle']={fullType='Fixture.Cycle',finalRarityTier='RARE',medicalDeclared=cycle}
equal(ItemRarityRegistryPublisher.publish(rows),post,'registry invalid cohort')
assert(ItemRarityRegistryPublisher.lastIsolationReport.isolated==8)
assert(not pcall(ItemRarityRegistryPublisher.publish,false),'global registry shape swallowed')
local saved=ItemRarity.setRegistry;ItemRarity.setRegistry=nil
assert(not pcall(ItemRarityRegistryPublisher.publish,{}),'global sink error swallowed');ItemRarity.setRegistry=saved
ModData={getOrCreate=function() error('global storage failure') end}
assert(not pcall(ItemRarityRegistryPublisher.publish,{['Fixture.Valid']=valid}),'global storage error swallowed');ModData=nil
ItemRarityScanner={rescan=function()
 local scanned=augmentation(true,false)
 scanned['Fixture.Valid']=valid
 ItemRarityRegistryPublisher.publish(scanned)
 I.report.calculateCompleted=true
 ItemRarityScanner.results=scanned
 ItemRarityScanner.lastScanSignature='fixture-stable'
end}
local originalRun=I.run
ItemRarityBatchComparison.runFinal('A')
local checkpoint=ItemRarityBatchComparison.runFinal('B')
assert(checkpoint.UTILITY_ONLY_HEALTHY_REGRESSION==0 and checkpoint.FALLBACK_HEALTHY_REGRESSION==0)
assert(checkpoint.REGISTRY_HEALTHY_REGRESSION==0 and checkpoint.POPULATION_CONTAMINATION==0)
assert(checkpoint.SECOND_RESCAN=='MATCH' and checkpoint.NEW_WARNING_KEYS_ON_B==0)
assert(I.run==originalRun and not ItemRarityBatchComparison.running,'final observer leaked')
local cleanScan=ItemRarityScanner.rescan
ItemRarityScanner.rescan=function()
 cleanScan()
 local proxy={data={fullType='Fixture.Proxy'},kind='FIREARM',utilityEligible=true,publishedFirearmTier='RARE',subgroup='RIFLE'}
 I.run(proxy,'Firearm:ReferenceAdmission',function() return true end)
 I.run(proxy,'Ammo:FirearmReference',function() I.mark(proxy,'Ammo:FirearmReference','PARTIAL_DEFER','missing reference key') end)
end
ItemRarityBatchComparison.runFinal('A')
local late=ItemRarityBatchComparison.finalSnapshots.A.lateFailures
assert(#late==1 and late[1].fullType=='Fixture.Proxy' and late[1].proxy and not late[1].realResultRow)
assert(late[1].ammoReferenceAccepted==false and late[1].admissionState=='SAFE')
assert(ItemRarityBatchComparison.finalSnapshots.A.populationContamination=='UNKNOWN_LATE_FAILURE','unproven late failure cleared')
ItemRarityScanner.rescan=function() error('global scan failure') end
assert(not pcall(ItemRarityBatchComparison.runFinal,'A'),'global scan swallowed')
assert(I.run==originalRun and not ItemRarityBatchComparison.running,'failed observer leaked')
return 'UTILITY_ONLY_HEALTHY_REGRESSION=0','FALLBACK_HEALTHY_REGRESSION=0','REGISTRY_HEALTHY_REGRESSION=0',
 'POPULATION_CONTAMINATION=0 (controlled augmentation cohort)','ITEM_LEVEL_FATALS_ISOLATED=yes','GLOBAL_SCAN_FATALS=0 (fixtures)',
 'GLOBAL_STRUCTURAL_ERRORS_PROPAGATE=yes','WORLD_SCAN=NOT_RUN'
