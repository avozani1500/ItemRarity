import java.lang.reflect.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.io.ByteArrayOutputStream;

// Real game Kahlua, no game world and no InventoryItem/OnCreate calls.
public class ItemIsolationProbe {
    static String read(Path p) throws Exception { return new String(Files.readAllBytes(p), StandardCharsets.UTF_8); }
    static String slice(String s, String first, String last) {
        int a=s.indexOf(first), b=s.indexOf(last,a+first.length());
        if(a<0||b<0) throw new AssertionError("Missing source boundaries: "+first);
        return s.substring(a,b);
    }
    static String gitCalculator(Path repo, String revision) throws Exception {
        return gitFile(repo,revision,"42.20/media/lua/server/ItemRarity/UtilityCalculator.lua");
    }
    static String gitFile(Path repo, String revision, String path) throws Exception {
        Process process=new ProcessBuilder("git","-C",repo.toString(),"show",
            revision+":"+path).start();
        ByteArrayOutputStream buffer=new ByteArrayOutputStream();
        byte[] bytes=new byte[8192]; int length;
        while((length=process.getInputStream().read(bytes))!=-1)buffer.write(bytes,0,length);
        if(process.waitFor()!=0)throw new AssertionError("Cannot load committed scoring oracle");
        return new String(buffer.toByteArray(),StandardCharsets.UTF_8);
    }
    public static void main(String[] args) throws Exception {
        Path repo=Paths.get(args[0]);
        boolean batch4=args.length>1 && args[1].matches("(?i)(lightfire|explosive|incendiary|noisemaker|accessory)-isolation-probe\\.lua");
        boolean batch3=batch4 || (args.length>1 && args[1].matches("(?i)(magazine|ammo|fish|literature)-isolation-probe\\.lua"));
        String oracleRevision=batch4 ? "2fb7ebc" : batch3 ? "d660f37" : "4c8a0a6a5a2af71f8df695ecbdcfb9139c71d9ef";
        String source=read(repo.resolve("42.20/media/lua/server/ItemRarity/UtilityCalculator.lua"));
        if(Boolean.getBoolean("itemrarity.staged")) source=gitCalculator(repo, "");
        String isolation=read(repo.resolve("42.20/media/lua/server/ItemRarity/UtilityIsolation.lua"));
        Class<?> pt=Class.forName("se.krka.kahlua.vm.Platform"), tt=Class.forName("se.krka.kahlua.vm.KahluaTable");
        Class<?> pc=Class.forName("se.krka.kahlua.j2se.J2SEPlatform"), tc=Class.forName("se.krka.kahlua.vm.KahluaThread");
        Object platform=pc.getMethod("getInstance").invoke(null), env=pc.getMethod("newEnvironment").invoke(platform);
        tt.getMethod("rawset", Object.class,Object.class).invoke(env,"UNEXPECTED_USERDATA",new Object());
        Object thread=tc.getConstructor(pt,tt).newInstance(platform,env);
        tc.getField("debugOwnerThread").set(thread,Thread.currentThread());
        Method compile=Class.forName("se.krka.kahlua.luaj.compiler.LuaCompiler").getMethod("loadstring",String.class,String.class,tt);
        // Compile the complete production chunk as well (including Kahlua's
        // local-variable limits), without executing its live dependencies.
        compile.invoke(null,source,"UtilityCalculator syntax",env);
        Class.forName("se.krka.kahlua.luaj.compiler.LuaCompiler")
            .getMethod("loadis",java.io.Reader.class,String.class,tt)
            .invoke(null,new java.io.StringReader(source),"UtilityCalculator file syntax",env);
        Method pcall=tc.getMethod("pcall",Object.class,Object[].class);
        String instrumented=source.replace("local function candidateFor(data)",
            "local function candidateFor(data)\n if FIXTURE_DISCOVERY then return FIXTURE_DISCOVERY(data) end");
        int componentStart=instrumented.indexOf("local function firearmV1Components(");
        int componentEnd=instrumented.indexOf("local function scoreFirearmUtility(",componentStart);
        String componentCode=instrumented.substring(componentStart,componentEnd).replace("local m = candidate.metrics",
            "if FIREARM_COMPONENT_HOOK then FIREARM_COMPONENT_HOOK(candidate) end\n local m = candidate.metrics");
        instrumented=instrumented.substring(0,componentStart)+componentCode+instrumented.substring(componentEnd);
        instrumented=instrumented.replace("local absolute = absoluteParts[candidate]",
            "if FIREARM_FINAL_HOOK then FIREARM_FINAL_HOOK(candidate) end\n local absolute = absoluteParts[candidate]");
        instrumented=instrumented.replace("local p = function(name) return candidate.metricPercentiles",
            "if MELEE_FINAL_HOOK then MELEE_FINAL_HOOK(candidate) end\n local p = function(name) return candidate.metricPercentiles");
        String literatureHook="local function attemptCandidateBuilder(name, builder, data, scriptItem)";
        instrumented=instrumented.replace("local function makeMagazineCandidate(data, scriptItem)",
            "ItemRarityUtilityCalculator.fixtureFirearm=makeFirearmCandidate\nlocal function makeMagazineCandidate(data, scriptItem)");
        instrumented=instrumented.replace(literatureHook,
            "ItemRarityUtilityCalculator.fixtureLiterature=makeLiteratureCandidate\n"
            +"ItemRarityUtilityCalculator.fixtureBatch4Builders={LIGHTFIRE=makeLightFireCandidate,EXPLOSIVE=makeExplosiveCandidate,INCENDIARY=makeIncendiaryCandidate,NOISE_MAKER=makeNoiseMakerCandidate}\n"+literatureHook);
        instrumented=instrumented.replace("local function clothingNormalizationGroup(candidate, candidates)",
            "ItemRarityUtilityCalculator.fixtureAmmoInheritance=scoreAmmoInheritance\nlocal function clothingNormalizationGroup(candidate, candidates)");
        String[] setup={"require=function() end",
            read(repo.resolve("common/media/lua/shared/ItemRarity/RarityConfig.lua")),
            read(repo.resolve("common/media/lua/shared/ItemRarity/RarityTiers.lua")),
            read(repo.resolve("common/media/lua/shared/ItemRarity/RarityUtils.lua")),
            read(repo.resolve("common/media/lua/shared/ItemRarity/ItemClassifier.lua")),
            isolation,
            batch3 ? "POST_ISOLATION=ItemRarityUtilityIsolation; ItemRarityUtilityIsolation=nil" : "",
            batch3 ? gitFile(repo,oracleRevision,"42.20/media/lua/server/ItemRarity/UtilityIsolation.lua") : "",
            batch3 ? "PRE_ISOLATION=ItemRarityUtilityIsolation" : "",
            gitCalculator(repo,oracleRevision).replace("local function candidateFor(data)",
                "local function candidateFor(data)\n if FIXTURE_DISCOVERY then return FIXTURE_DISCOVERY(data) end")
                .replace(literatureHook,"ItemRarityUtilityCalculator.fixtureLiterature=makeLiteratureCandidate\n"+literatureHook),
            "LEGACY_CALCULATE=ItemRarityUtilityCalculator.calculate; LEGACY_LITERATURE=ItemRarityUtilityCalculator.fixtureLiterature",
            batch3 ? "local original=LEGACY_CALCULATE; LEGACY_CALCULATE=function(rows) "
                +"local saved=ItemRarityUtilityIsolation; ItemRarityUtilityIsolation=PRE_ISOLATION; "
                +"local ok,result=pcall(original,rows); ItemRarityUtilityIsolation=saved; "
                +"if not ok then error(result) end; return result end; ItemRarityUtilityIsolation=POST_ISOLATION" : "",
            // Test-only injection at discovery. The rest of calculate executes
            // unchanged, with all Utility passes and candidate publication.
            instrumented,
            read(repo.resolve("42.20/media/lua/server/ItemRarity/Diagnostics/BatchComparison.lua")),
            read(repo.resolve("42.20/media/lua/server/ItemRarity/Diagnostics/Batch3Coverage.lua"))};
        for(String chunk:setup) {
            Object[] loaded=(Object[])pcall.invoke(thread,compile.invoke(null,chunk,"Fixture setup",env),new Object[0]);
            if(!Boolean.TRUE.equals(loaded[0]))throw new AssertionError(java.util.Arrays.toString(loaded));
        }
        if(args.length>1 && args[1].equals("batch3-shadow-probe.lua")) {
            Method compileFile=Class.forName("se.krka.kahlua.luaj.compiler.LuaCompiler")
                .getMethod("loadis",java.io.Reader.class,String.class,tt);
            for(String name:new String[]{"Batch3ShadowGenerated.lua","Batch3Shadow.lua"}) {
                Object[] loaded=(Object[])pcall.invoke(thread,compileFile.invoke(null,
                    new java.io.StringReader(read(repo.resolve("42.20/media/lua/server/ItemRarity/Diagnostics/"+name))),name,env),new Object[0]);
                if(!Boolean.TRUE.equals(loaded[0]))throw new AssertionError(java.util.Arrays.toString(loaded));
            }
        }
        String code="\nlocal UTILITY=ItemRarityConfig.utility; local NORMALIZATION=UTILITY.normalization\n"
            +isolation.replace("\nreturn I", "\n")
            +slice(source,"local function clamp(","local function confidenceAtLeast(")
            +slice(source,"local function essentialsPresent(","local function scoreGroup(")
            +slice(source,"local function containerRankingConfidence(","local function scoreMeleeV2(")
            +(batch4 ? read(repo.resolve("scripts/tests/batch4-absolute-common.lua")) : "")
            +read(repo.resolve("scripts/tests/"+(args.length>1?args[1]:"item-isolation-probe.lua")));
        Object[] result=(Object[])tc.getMethod("pcall",Object.class,Object[].class).invoke(thread,
            compile.invoke(null,code,"ItemIsolationProbe",env),new Object[0]);
        if(!Boolean.TRUE.equals(result[0]))throw new AssertionError(java.util.Arrays.toString(result));
        for(int i=1;i<result.length;i++)System.out.println(result[i]);
        System.out.println("SCORING_ORACLE="+oracleRevision+"; CONTROLLED_INPUTS_ONLY=true; HISTORICAL_WORLD_REGISTRY=false");
    }
}
