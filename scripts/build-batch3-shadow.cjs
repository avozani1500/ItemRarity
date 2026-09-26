// DEV generation only: never modifies UtilityCalculator or the installed mod.
const fs=require('fs'),path=require('path'),cp=require('child_process'),crypto=require('crypto');
const root=path.resolve(__dirname,'..'),file='42.20/media/lua/server/ItemRarity/UtilityCalculator.lua';
const read=p=>fs.readFileSync(path.join(root,p),'utf8').replace(/\r\n/g,'\n');
const historical=p=>cp.execFileSync('git',['show','d660f37:'+p],{cwd:root,encoding:'utf8',maxBuffer:4e6}).replace(/\r\n/g,'\n');
const post=read(file),old=historical(file);
function block(s,name){const start=s.indexOf('local function '+name+'(');if(start<0)throw Error(name);
 const rest=s.slice(start+1), m=/\n(?:local function |function ItemRarityUtilityCalculator\.)/.exec(rest);
 if(!m)throw Error('end '+name);return [start,start+1+m.index+1];}
// Only these blocks changed for batch 3. All other pending functional code
// remains the current POST source, including AmmoType and Firearm work.
const restored=['fishConfigurationFor','fishBaitProfile','fishMetricsForConfiguration',
 'makeMagazineCandidate','makeLiteratureCandidate','scoreMagazineUtility','scoreAmmoInheritance','scoreFishUtility'];
let pre=post;
for(const name of restored){const [a,b]=block(pre,name),[c,d]=block(old,name);pre=pre.slice(0,a)+old.slice(c,d)+pre.slice(b);}
const entry=`
return function(candidates)
 ItemRarityUtilityIsolation.beginScan()
 table.sort(candidates,function(a,b) return a.data.fullType<b.data.fullType end)
 for _,c in ipairs(candidates) do
  if c.kind=="LITERATURE" and ItemRarityUtilityIsolation.literaturePolicy then
   ItemRarityUtilityIsolation.run(c,"Literature:PolicyAdmission",function() return ItemRarityUtilityIsolation.literaturePolicy(c) end)
  end
 end
 scoreMagazineUtility(candidates)
 scoreAmmoInheritance(candidates)
 scoreFishUtility(candidates)
 local targets={}
 for _,c in ipairs(candidates) do if c.kind~="FIREARM" and c.failedUtilityKind~="FIREARM" then targets[#targets+1]=c end end
 publishCandidateFields(targets)
 for _,c in ipairs(targets) do
  if c.data.source=="UTILITY_ONLY" then
   c.data.finalRarityTier=c.kind=="FISH" and c.fishFinalTier or c.kind=="AMMO" and c.ammoInheritedFirearmTier or nil
  else applyTierAdjustment(c.data,c) end
 end
 return targets,ItemRarityUtilityIsolation.report
end
`;
function factory(source,isolation){
 // Extracted score replay deliberately never calls calculate/augmentation or
 // any builder. Complete candidate inputs and finalized firearm references
 // are supplied by the observer, not reconstructed from names or ScriptItems.
 const [a,b]=block(source,'scoreFishUtility');let fish=source.slice(a,b);
 fish=fish.replace('table.insert(references, reference)','table.insert(references, reference); shadowFishReference(reference)');
 source=source.slice(0,a)+fish+source.slice(b);
 isolation=isolation.replace(/\nreturn I\s*$/,'\n');
 // Separate function scopes: the engine's loadis compiler counts declarations
 // even across do/end blocks toward its 200-local table.
 return 'function(env)\nlocal function initializeIsolation()\n'+isolation+'\nend\n'
  +'setfenv(initializeIsolation,env)\ninitializeIsolation()\nlocal function chunk()\n'
  +source+'\n'+entry+'\nend\nsetfenv(chunk,env)\nreturn chunk()\nend';
}
const hash=s=>crypto.createHash('sha256').update(s).digest('hex');
const out='-- Generated explicit DEV-only evaluator. No automatic execution.\nItemRarityBatch3ShadowFactory={\n'
 +'postHash="'+hash(post)+'", preHash="'+hash(pre)+'",\n'
 +'PRE='+factory(pre,historical('42.20/media/lua/server/ItemRarity/UtilityIsolation.lua'))+',\n'
 +'POST='+factory(post,read('42.20/media/lua/server/ItemRarity/UtilityIsolation.lua'))+'\n}\n';
fs.writeFileSync(path.join(root,'42.20/media/lua/server/ItemRarity/Diagnostics/Batch3ShadowGenerated.lua'),out);
console.log('SHADOW_GENERATED; scope=candidate-score-and-public-fields; restored='+restored.join(','));
console.log('POST_SHA256='+hash(post));
