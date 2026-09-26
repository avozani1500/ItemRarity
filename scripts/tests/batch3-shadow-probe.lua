Fishing={fishes={{itemType="Fixture.Fish",minLength=10,maxLength=25,maxWeight=3,weightFactor=2,lure={worm=1}}},Utils={skillSizeLimit={}}}
for n=0,10 do Fishing.Utils.skillSizeLimit[n]=n+1 end
local function candidate(id,kind,metrics)
 return {data={fullType=id,module="Fixture",category=kind,rarityTier="RARE",tableAvailability={routeWeightedPercentile=40}},
 kind=kind,metrics=metrics,utilityEligible=true,profile=id,subgroup=kind}
end
ItemRarityScanner={}
ItemRarityUtilityCalculator.augmentUtilityOnly=function(rows)
 local data={fullType="Fixture.UnpublishedAmmo",module="Fixture",category="AMMO"}
 local c=ItemRarityUtilityIsolation.optionalDiscover(data,"AMMO",function()
  return {data=data,kind="AMMO",utilityEligible=true,profile=data.fullType,metrics={ammoType="fixture:ammo"}}
 end)
 local ref={data={fullType="Base.Gun"},kind="FIREARM",utilityEligible=true,firearmFinalTier="RARE",firearmAmmoType=""}
 ItemRarityUtilityCalculator.fixtureAmmoInheritance({ref,c})
 assert(c.ammoInheritedFirearmTier==nil,"fixture unexpectedly published")
end
ItemRarityScanner.rescan=function()
 local fish=candidate("Fixture.Fish","FISH",{expectedHunger=10,expectedCalories=100,minimumFishingSkill=1,baitCount=1,conditionalSpeciesShare=.5})
 local gun=candidate("Base.Gun","FIREARM",{averageDamage=2,maxHitCount=1,criticalChance=10,criticalMultiplier=2,maxRange=8,maxAmmo=6,weight=2,recoilDelay=20,aimingTime=10,reloadTime=15,soundRadius=30})
 gun.firearmAmmoType="fixture:ammo";gun.subgroup="SHOTGUN"
 local ammo=candidate("Fixture.Ammo","AMMO",{ammoType="fixture:ammo"})
 local lit=candidate("Fixture.Lit","LITERATURE",{unhappy=0,boredom=0,stress=0})
 lit.functionalGroup="TRIVIAL_LITERATURE";lit.utility=0;lit.literatureFinalTier="COMMON"
 local rows,byId={},{}
 for _,c in ipairs({fish,gun,ammo,lit}) do rows[c.data.fullType]=c.data;byId[c.data.fullType]=c end
 FIXTURE_DISCOVERY=function(data) return byId[data.fullType] end
 ItemRarityUtilityCalculator.calculate(rows)
 FIXTURE_DISCOVERY=nil
 ItemRarityScanner.results=rows
 ItemRarityUtilityCalculator.augmentUtilityOnly(rows)
end
local result=assert(ItemRarityBatch3Shadow.run())
assert(result.counts.POST_VS_REAL_DIFF==0,"POST did not reproduce current published fields")
assert(result.counts.HEALTHY_REGISTRY_DIFF==0,"healthy shadow change")
assert(result.counts.POPULATION_CONTAMINATION==0,"membership change")
assert(result.counts.ITEMS_COMPARED==4)
assert(ItemRarityBatch3Shadow.PRE_SHADOW_REGISTRY["Fixture.UnpublishedAmmo"].presence==false)
assert(ItemRarityBatch3Shadow.POST_SHADOW_REGISTRY["Fixture.UnpublishedAmmo"].presence==false)
assert(ItemRarityScanner.results["Fixture.UnpublishedAmmo"]==nil,"shadow published a row")
return "SHADOW_HARNESS=PASS","POST_VS_REAL_FIXTURE_DIFF=0","PRE_POST_HEALTHY_DIFF=0","WORLD_VALIDATION=PENDING"
