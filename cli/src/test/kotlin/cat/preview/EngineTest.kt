package cat.preview

import cat.android.project.io.atomicJson
import cat.android.project.io.jsonArray as array
import cat.android.project.io.jsonHash as hash
import cat.android.project.io.jsonObject as obj
import cat.android.project.io.jsonStrings as strings
import cat.android.project.io.jsonText as text
import cat.android.project.io.readJsonObject as readJson
import com.google.gson.JsonArray
import com.google.gson.JsonObject
import java.nio.file.*
import kotlin.io.path.*
import kotlin.test.*
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir

class EngineTest {
    @TempDir lateinit var root: Path
    private fun assets(): Path = Path.of("..").toAbsolutePath().normalize()
    private fun options(vararg extra: String) = Options(listOf("render", "--cache-dir", root.resolve("build/cache").toString()) + extra)
    private fun fixture(): Pair<Path,JsonObject> {
        val classes = root.resolve("build/A.class"); Files.createDirectories(classes.parent); classes.writeText("bytecode")
        val model = obj("projectRoot" to root.toString(), "buildRoot" to root.toString(), "component" to "main", "componentName" to "debug", "moduleRoot" to root.toString(), "modulePath" to ":app", "variant" to "debug",
            "namespace" to "demo", "javaExecutable" to Path.of(System.getProperty("java.home"),"bin/java").toString(), "layoutlibPath" to "/layoutlib",
            "classPath" to listOf(classes.toString()), "projectClassPath" to listOf(classes.toString()), "rendererClassPath" to emptyList<String>(),
            "rClassJars" to emptyList<String>(), "previews" to emptyList<String>())
        val path = root.resolve("build/model.json"); atomicJson(path,model)
        atomicJson(path.resolveSibling("model.receipt.json"),obj("environment" to hash(listOf(buildEnvironment(),cat.android.project.gradleJvmSignature(root))),"modelHash" to hash(model),"inputs" to targetInputs(PreviewTarget.fromModel(model),assets()),"artifacts" to artifactSignature(model)))
        return path to model
    }
    private fun <T> engine(options: Options, block: (Engine) -> T): T {
        val processes = Processes()
        try { return block(Engine(options,assets(),processes)) } finally { processes.close() }
    }
    @Test fun `build Java selection is validated and bound to receipt freshness`() {
        val (path,_)=fixture()
        val home=Path.of(System.getProperty("java.home"))
        engine(options("--gradle-java-home",home.toString())) { assertEquals(home.toRealPath(),it.gradleJavaHome()) }
        engine(options("--gradle-java-home",root.resolve("missing").toString())) {
            assertEquals("input",assertFailsWith<Failure> { it.gradleJavaHome() }.kind)
        }
        val other=root.resolve("other-jdk").createDirectories()
        other.resolve("bin").createDirectories()
        other.resolve("bin").resolve(if(isWindows) "java.exe" else "java").writeText("other-jdk")
        other.resolve("release").writeText("JAVA_VERSION=17")
        assertNotEquals(buildEnvironment(),buildEnvironment(other))
        engine(options("--gradle-java-home",other.toString(),"--model",path.toString())) {
            assertEquals("stale-model",assertFailsWith<Failure> { it.prepare() }.kind)
        }
        val before=buildEnvironment(other)
        other.resolve("release").writeText("JAVA_VERSION=21.0.13")
        assertNotEquals(before,buildEnvironment(other))
    }
    @Test fun `doctor reports resolved core version from bundled build information`() {
        val java=Path.of(System.getProperty("java.home"),"bin",if(isWindows) "java.exe" else "java")
        val process=ProcessBuilder(java.toString(),"-Dcompose.preview.home=${assets()}","-cp",System.getProperty("preview.test.classpath"),
            "cat.preview.MainKt","doctor","--json").redirectError(root.resolve("doctor.log").toFile()).start()
        val output=process.inputStream.bufferedReader().use { it.readText() }
        assertEquals(0,process.waitFor(),output)
        val result=com.google.gson.JsonParser.parseString(output).asJsonObject
        assertEquals(System.getProperty("preview.test.core.version"),
            result.getAsJsonObject("capabilities").text("projectCoreVersion"))
        assertEquals(projectCoreVersion,System.getProperty("preview.test.core.version"))
        assertEquals(21,result["minimumJavaVersion"].asInt)
        assertTrue(Runtime.version().feature() >= 21)
        assertTrue(result.getAsJsonObject("capabilities")["staticCallbacks"].asBoolean)
        assertFalse(result.getAsJsonObject("capabilities")["warmRenderer"].asBoolean)
    }
    @Test fun `Preview embeds project core and preserves build environment and configuration cache`() {
        val home=Path.of(System.getProperty("preview.test.gradle.home"))
        root.resolve("settings.gradle").writeText("rootProject.name='preview-core-fixture'\n")
        root.resolve("build.gradle").writeText("""
            tasks.register('probe') {
                def marker = providers.environmentVariable('COMPOSE_PREVIEW_CORE_TEST')
                def output = layout.buildDirectory.file('probe.txt')
                doLast { output.get().asFile.parentFile.mkdirs(); output.get().asFile.text = marker.get() }
            }
            tasks.register('broken') { doLast { throw new GradleException('EXPECTED_CORE_FAILURE') } }
            tasks.register('slow') { doLast { Thread.sleep(30000) } }
        """.trimIndent())
        buildPreviewModel(root,":probe",listOf("--configuration-cache"),mapOf("COMPOSE_PREVIEW_CORE_TEST" to "in-process"),120,home)
        assertEquals("in-process",root.resolve("build/probe.txt").readText())
        assertTrue(root.resolve(".gradle/configuration-cache").exists())
        val failed=assertFailsWith<Failure> { buildPreviewModel(root,":broken",emptyList(),emptyMap(),120,home) }
        assertEquals("gradle",failed.kind)
        assertTrue(failed.message!!.contains("EXPECTED_CORE_FAILURE"))
        val timeout=assertFailsWith<Failure> { buildPreviewModel(root,":slow",emptyList(),emptyMap(),1,home) }
        assertEquals("timeout",timeout.kind)
        buildPreviewModel(root,":probe",emptyList(),mapOf("COMPOSE_PREVIEW_CORE_TEST" to "after-cancel"),120,home)
        assertEquals("after-cancel",root.resolve("build/probe.txt").readText())
    }
    @Test fun `tooling keeps entry distribution and selects included build project directory`() {
        val home=Path.of(System.getProperty("preview.test.gradle.home"))
        root.resolve("settings.gradle").writeText("rootProject.name='entry'\nincludeBuild('included')\n")
        val included=root.resolve("included").createDirectories()
        included.resolve("settings.gradle").writeText("rootProject.name='included'\n")
        included.resolve("build.gradle").writeText("tasks.register('probe') { doLast { file('build/selected').parentFile.mkdirs(); file('build/selected').text = rootDir.canonicalPath } }\n")
        buildPreviewModel(root,":probe",listOf("--project-dir",included.toString()),emptyMap(),120,home)
        assertEquals(included.toRealPath().toString(),included.resolve("build/selected").readText())
        assertFalse(root.resolve("build/selected").exists())
    }
    @Test fun `KMP adapter configures existing host resources without replacing user compilations`() {
        val adapter=assets().resolve("gradle/adapters/agp-9.3-kmp.init.gradle")
        val buildRoot=System.getenv("COMPOSE_PREVIEW_BUILD_ROOT") ?: root.toString()
        root.resolve("settings.gradle").writeText("rootProject.name='host-adapter'\n")
        root.resolve("build.gradle").writeText("""
            tasks.register('probe') {
                def adapterFile = file('${adapter.toString().replace("\\","/")}')
                def owningRoot = new File('${buildRoot.replace("\\","/")}')
                doLast {
                    def loader = new GroovyClassLoader(getClass().classLoader)
                    loader.parseClass('package com.android; class Version { public static final String ANDROID_GRADLE_PLUGIN_VERSION = "9.3.0" }')
                    def hostType = loader.parseClass('package com.android.build.api.dsl; class KotlinMultiplatformAndroidHostTestCompilation { String name; boolean includeAndroidResources; boolean returnDefaultValues = true; String sourceSet = "customSources" }')
                    def componentType = loader.parseClass('class Components { def callback; def finalizeDsl(c) { callback = c }; def selector() { this }; def withName(n) { this }; def onVariants(s,c) {} }')
                    for (state in ['missing','disabled','enabled']) {
                        def host = hostType.newInstance(name:'localChecks',includeAndroidResources:state == 'enabled')
                        def compilations = state == 'missing' ? [] : [host]
                        def creations = 0
                        def android = new Expando(compilations:compilations)
                        android.withHostTest = { c ->
                            creations++
                            c.delegate = host; c.resolveStrategy = Closure.DELEGATE_FIRST; c.call()
                            compilations.add(host)
                        }
                        def components = componentType.newInstance()
                        def extras = [:]
                        def project = new Expando(path:':shared',rootDir:owningRoot)
                        project.extensions = new Expando(extraProperties:new Expando(set:{ k,v -> extras[k]=v }))
                        project.extensions.findByName = { n -> n == 'androidComponents' ? components : new Expando(targets:new Expando(findByName:{ android })) }
                        project.plugins = new Expando(withId:{ id,c -> c.call() })
                        def gradle = new Expando(ext:new Expando(composePreviewTargetModulePath:':shared',composePreviewTargetVariant:'androidMain',composePreviewRegisterKmp:{ a,b,c,d -> }))
                        gradle.beforeProject = { c -> c.call(project) }
                        new GroovyShell(loader,new Binding([gradle:gradle])).evaluate('import org.gradle.api.GradleException\n' + adapterFile.text)
                        components.callback.call()
                        assert host.includeAndroidResources
                        assert host.returnDefaultValues && host.sourceSet == 'customSources' && host.name == 'localChecks'
                        assert creations == (state == 'missing' ? 1 : 0)
                        assert compilations.size() == 1 && compilations[0].is(host)
                    }
                    file('build/passed').parentFile.mkdirs(); file('build/passed').text = 'all-host-states'
                }
            }
        """.trimIndent())
        buildPreviewModel(root,":probe",emptyList(),mapOf("COMPOSE_PREVIEW_BUILD_ROOT" to root.toString()),120,
            Path.of(System.getProperty("preview.test.gradle.home")))
        assertEquals("all-host-states",root.resolve("build/passed").readText())
    }
    @Test fun `KMP Manifest fallback is lazy and preserves explicit host and main placeholders`() {
        val adapter=assets().resolve("gradle/adapters/agp-9.3-kmp.init.gradle")
        root.resolve("settings.gradle").writeText("rootProject.name='placeholder-adapter'\n")
        root.resolve("build.gradle").writeText("""
            def loader = new GroovyClassLoader(getClass().classLoader)
            def script = new GroovyShell(loader,new Binding([gradle:new Expando(
                ext:new Expando(composePreviewTargetModulePath:':app',composePreviewTargetVariant:'androidMain',composePreviewRegisterKmp:{}),
                beforeProject:{ c -> })])).parse('import org.gradle.api.GradleException\n' + file('${adapter.toString().replace("\\","/")}').text)
            script.run()
            def archive = file('dependency.aar')
            new java.util.zip.ZipOutputStream(new FileOutputStream(archive)).withCloseable { zip ->
                zip.putNextEntry(new java.util.zip.ZipEntry('AndroidManifest.xml'))
                zip.write('<manifest value="\${'$'}{qqappid}" main="\${'$'}{mainKey}" host="\${'$'}{hostKey}" app="\${'$'}{applicationId}"/>'.bytes)
                zip.closeEntry()
            }
            def resolved = false
            def fileType = loader.parseClass('class LazyFiles { def resolve; def getFiles() { resolve() } }')
            def incoming = new Expando(artifactView:{ c ->
                new Expando(files:fileType.newInstance(resolve:{ resolved = true; [archive] }))
            })
            def projectStub = new Expando(providers:providers,objects:objects)
            def variant = new Expando(runtimeConfiguration:new Expando(incoming:incoming))
            variant.manifestPlaceholders = objects.mapProperty(String,String).value([mainKey:'main-value',hostKey:'main-host'])
            def host = objects.mapProperty(String,String).value([hostKey:'host-value'])
            def keys = script.configurePreviewPlaceholders(projectStub,variant,new Expando(manifestPlaceholders:host))
            assert !resolved
            assert host.get() == [qqappid:'compose-preview',mainKey:'main-value',hostKey:'host-value']
            assert keys.get() == ['qqappid']
            host.put('qqappid','later-host')
            assert host.get().qqappid == 'later-host' && keys.get().isEmpty()
            assert resolved
            assert !host.get().containsKey('applicationId')
            def explicitHost = objects.mapProperty(String,String).value([qqappid:'explicit-host'])
            def explicitKeys = script.configurePreviewPlaceholders(projectStub,variant,new Expando(manifestPlaceholders:explicitHost))
            assert explicitHost.get().qqappid == 'explicit-host'
            assert explicitKeys.get().isEmpty()
            variant.manifestPlaceholders.put('qqappid','explicit-main')
            def mainHost = objects.mapProperty(String,String).value([:])
            def mainKeys = script.configurePreviewPlaceholders(projectStub,variant,new Expando(manifestPlaceholders:mainHost))
            assert mainHost.get().qqappid == 'explicit-main'
            assert mainKeys.get().isEmpty()
            tasks.register('probe') { doLast {} }
        """.trimIndent())
        buildPreviewModel(root,":probe",emptyList(),emptyMap(),120,Path.of(System.getProperty("preview.test.gradle.home")))
    }
    @Test fun `target identity rejects non main components before any build`() {
        for(component in listOf("androidTest","unitTest","screenshotTest","testFixtures","hostTest")) {
            val error=assertFailsWith<Failure> { PreviewTarget(root,root,":app","debug",component,"debugTest") }
            assertEquals("unsupported",error.kind)
        }
        assertFailsWith<Failure> { PreviewTarget(root,root,":app","release","main","debug") }
    }
    @Test fun `exact model cannot bypass owning build component or module root checks`() {
        val (path,model)=fixture()
        for(extra in listOf(listOf("--build-root",root.resolve("other").toString()),
            listOf("--module-root",root.resolve("other").toString()),listOf("--variant","release"),
            listOf("--component","androidTest","--component-name","debugAndroidTest"))) {
            engine(options("--model",path.toString(),"--no-build",*extra.toTypedArray())) { assertFailsWith<Failure> { it.prepare() } }
        }
        model.remove("buildRoot")
        atomicJson(path,model)
        engine(options("--model",path.toString())) { assertEquals("stale-model",assertFailsWith<Failure> { it.prepare() }.kind) }
    }
    @Test fun `owning build identity separates cache inputs and reports`() {
        val first=PreviewTarget(root,root.resolve("included-a"),":app","debug","main","debug")
        val second=first.copy(buildRoot=root.resolve("included-b"))
        assertNotEquals(hash(first.json()),hash(second.json()))
        val external=Files.createTempDirectory("preview-external-build")
        try {
            val target=first.copy(buildRoot=external)
            external.resolve("build.gradle").writeText("// first")
            val before=targetInputs(target,assets())
            external.resolve("build.gradle").writeText("// changed")
            assertNotEquals(before,targetInputs(target,assets()))
        } finally { external.resolve("build.gradle").deleteExisting(); external.deleteExisting() }
    }
    @Test fun `dependency source roots invalidate exact receipts and separate identities`() {
        val (path,model)=fixture()
        val external=Files.createTempDirectory("preview-dependency-input")
        try {
            external.resolve("Source.kt").writeText("initial")
            model.add("inputRoots",cat.android.project.io.jsonCodec.toJsonTree(listOf(external.toString())))
            atomicJson(path,model)
            atomicJson(path.resolveSibling("model.receipt.json"),obj("environment" to hash(listOf(buildEnvironment(),cat.android.project.gradleJvmSignature(root))),"modelHash" to hash(model),
                "inputs" to targetInputs(PreviewTarget.fromModel(model),assets()),"artifacts" to artifactSignature(model)))
            engine(options("--model",path.toString(),"--no-build")) { assertTrue(it.prepare().reused) }
            external.resolve("Source.kt").writeText("changed without rebuilding the dependency")
            engine(options("--model",path.toString(),"--no-build")) { assertEquals("stale-model",assertFailsWith<Failure> { it.prepare() }.kind) }
            val target=PreviewTarget.fromModel(model)
            assertNotEquals(hash(target.json()),hash(target.copy(inputRoots=emptyList()).json()))
        } finally { external.resolve("Source.kt").deleteExisting(); external.deleteExisting() }
    }
    @Test fun `explicit model cache diagnostics distinguish hit from stale without changing stdout`() {
        val (path,_)=fixture()
        val old=System.err
        val bytes=java.io.ByteArrayOutputStream()
        try {
            System.setErr(java.io.PrintStream(bytes))
            engine(options("--model",path.toString(),"--no-build")) { assertTrue(it.prepare().reused) }
            root.resolve("Changed.kt").writeText("changed")
            engine(options("--model",path.toString(),"--no-build")) { assertFailsWith<Failure> { it.prepare() } }
        } finally { System.setErr(old) }
        val log=bytes.toString(Charsets.UTF_8)
        assertTrue(log.contains("stage=model reason=explicit-model-fresh"))
        assertTrue(log.contains("stage=model reason=explicit-model-stale"))
    }
    @Test fun `obsolete project CLI selection is not accepted`() {
        assertFailsWith<Failure> { Options(listOf("render","--project-cli","unused")) }
    }
    @Test fun `project sync is not a Preview command`() {
        assertFailsWith<Failure> { Options(listOf("project","sync","--json")) }
    }
    @Test fun `input signature ignores documentation and outputs`() {
        root.resolve("A.kt").writeText("fun A() {}")
        val before = inputSignature(root,assets())
        root.resolve("README.md").writeText("docs")
        Files.createDirectories(root.resolve("build")); root.resolve("build/B.kt").writeText("generated")
        assertEquals(before,inputSignature(root,assets()))
        root.resolve("A.kt").writeText("fun Changed() {}")
        assertNotEquals(before,inputSignature(root,assets()))
    }
    @Test fun `Preview resource policy stays broader than project model inputs`() {
        val image=root.resolve("res/drawable/image.png")
        image.parent.createDirectories()
        image.writeText("resource")
        val previewBefore=inputSignature(root,assets())
        val projectBefore=cat.android.project.projectInputSignature(root)
        image.writeText("changed resource")
        assertNotEquals(previewBefore,inputSignature(root,assets()))
        assertEquals(projectBefore,cat.android.project.projectInputSignature(root))
        val run=root.resolve("owned-render")
        run.createDirectories()
        atomicJson(run.resolve(".compose-preview-run.json"),obj("owner" to OWNER))
        val beforeRun=inputSignature(root,assets())
        run.resolve("render.png").writeText("output")
        assertEquals(beforeRun,inputSignature(root,assets()))
    }
    @Test fun `identity separates configuration provider and annotation position`() {
        val p = obj("methodFQN" to "demo.AKt.Card", "methodParams" to listOf(mapOf("provider" to "A")))
        val annotation = obj("name" to "Phone", "widthDp" to 320)
        val first = previewId(p,annotation,0)
        assertEquals(first,previewId(p,obj("widthDp" to 320,"name" to "Phone"),0))
        assertNotEquals(first,previewId(p,annotation,1))
        assertNotEquals(first,previewId(p,obj("name" to "Phone","widthDp" to 640),0))
        assertNotEquals(first,previewId(obj("methodFQN" to "demo.AKt.Card","methodParams" to listOf(mapOf("provider" to "B"))),annotation,0))
    }
    @Test fun `overrides never mutate compiled annotation and source changes reset`() {
        val annotation = obj("widthDp" to 100,"device" to "id:phone")
        val preview = obj("methodFQN" to "demo.AKt.Card","annotations" to listOf(annotation))
        val id = previewId(preview,annotation,0)
        val overrides = obj(id to obj("baseline" to baseline(annotation),"values" to obj("widthDp" to 320)))
        val (configured,_) = settings(JsonObject(),listOf(preview),root,overrides)
        assertEquals(320,configured.array("screenshots")[0].asJsonObject.getAsJsonObject("previewParams")["widthDp"].asInt)
        assertEquals(100,annotation["widthDp"].asInt)
        val changed = obj("methodFQN" to "demo.AKt.Card","annotations" to listOf(obj("widthDp" to 100,"device" to "id:other")))
        val (reset,_) = settings(JsonObject(),listOf(changed),root,overrides)
        assertEquals(100,reset.array("screenshots")[0].asJsonObject.getAsJsonObject("previewParams")["widthDp"].asInt)
    }
    @Test fun `no build requires receipt and checks source and artifacts`() {
        val (path,model) = fixture()
        val args = options("--model",path.toString(),"--no-build")
        engine(args) { assertTrue(it.prepare().reused) }
        root.resolve("A.kt").writeText("modified")
        engine(args) { assertFailsWith<Failure> { it.prepare() } }
        root.resolve("A.kt").deleteExisting()
        Path.of(model.strings("classPath")[0]).writeText("different bytecode")
        engine(args) { assertFailsWith<Failure> { it.prepare() } }
        path.resolveSibling("model.receipt.json").deleteExisting()
        engine(args) { assertFailsWith<Failure> { it.prepare() } }
    }
    @Test fun `build environment mismatch invalidates compiled receipt`() {
        val (path,_) = fixture()
        val receipt=path.resolveSibling("model.receipt.json")
        val saved=readJson(receipt)
        saved.addProperty("environment","another-java-or-sdk")
        atomicJson(receipt,saved)
        engine(options("--model",path.toString(),"--no-build")) {
            assertFailsWith<Failure> { it.prepare() }
        }
    }
    @Test fun `launcher failure results support both renderer ABIs and nonnull empty image paths`() {
        val source=assets().resolve("renderer/ComposePreviewRenderLauncher.java").readText()
        val method=source.substring(source.indexOf("    private static PreviewScreenshotResult failureResult("),
            source.indexOf("    private static Integer resolveDensityDpi("))
        val java=Path.of(System.getProperty("java.home"),"bin",if(isWindows) "java.exe" else "java")
        val javac=java.resolveSibling(if(isWindows) "javac.exe" else "javac")
        for (modern in listOf(false,true)) {
            val directory=root.resolve(if(modern) "modern" else "legacy").createDirectories()
            val extra=if(modern) ", String display, List<Object> views, String tree" else ""
            directory.resolve("FailureProbe.java").writeText("""
                import java.util.*;
                public class FailureProbe {
                    public static class ScreenshotError { public ScreenshotError(Throwable failure) {} }
                    public static class PreviewScreenshot {
                        public String getPreviewId() { return "bad-card"; }
                        public String getMethodFQN() { return "demo.card"; }
                    }
                    public static class PreviewScreenshotResult {
                        public final String image;
                        public final ScreenshotError error;
                        public PreviewScreenshotResult(String id, String method, String image, ScreenshotError error$extra) {
                            this.image=Objects.requireNonNull(image); this.error=error;
                        }
                    }
                    $method
                    public static void main(String[] args) throws Exception {
                        PreviewScreenshotResult result=failureResult(new PreviewScreenshot(),new IllegalStateException("expected"));
                        if (!result.image.isEmpty() || result.error == null) throw new AssertionError();
                    }
                }
            """.trimIndent())
            val compile=ProcessBuilder(javac.toString(),"-d",directory.toString(),directory.resolve("FailureProbe.java").toString())
                .redirectErrorStream(true).start()
            val diagnostics=compile.inputStream.bufferedReader().readText()
            assertEquals(0,compile.waitFor(),diagnostics)
            val run=ProcessBuilder(java.toString(),"-cp",directory.toString(),"FailureProbe").redirectErrorStream(true).start()
            val output=run.inputStream.bufferedReader().readText()
            assertEquals(0,run.waitFor(),output)
        }
    }
    @Test fun `launcher refreshes project classes per card using only the public renderer API`() {
        val source=assets().resolve("renderer/ComposePreviewRenderLauncher.java").readText()
        val method=source.substring(source.indexOf("    private static void refreshProjectClasses("),
            source.indexOf("    private static PreviewScreenshotResult failureResult("))
        assertTrue(source.indexOf("refreshProjectClasses(renderer, settings);") < source.indexOf("renderer.render(screenshot, outputFolder)"))
        val java=Path.of(System.getProperty("java.home"),"bin",if(isWindows) "java.exe" else "java")
        val javac=java.resolveSibling(if(isWindows) "javac.exe" else "javac")
        for (modern in listOf(false,true)) {
            val directory=root.resolve(if(modern) "refresh-modern" else "refresh-legacy").createDirectories()
            val api=if(modern) "public void refreshClassPath(List<String> all, List<String> project) { calls++; if (!all.equals(List.of(\"all.jar\")) || !project.equals(List.of(\"project.jar\"))) throw new AssertionError(); }" else ""
            directory.resolve("RefreshProbe.java").writeText("""
                import java.util.*;
                public class RefreshProbe {
                    public static class JsonObject {}
                    public static class Renderer { public int calls; $api }
                    static List<String> readStrings(JsonObject settings, String name) {
                        return List.of(name.equals("classPath") ? "all.jar" : "project.jar");
                    }
                    $method
                    public static void main(String[] args) throws Exception {
                        Renderer renderer=new Renderer();
                        refreshProjectClasses(renderer,new JsonObject());
                        refreshProjectClasses(renderer,new JsonObject());
                        if (renderer.calls != ${if(modern) 2 else 0}) throw new AssertionError();
                    }
                }
            """.trimIndent())
            val compile=ProcessBuilder(javac.toString(),"-d",directory.toString(),directory.resolve("RefreshProbe.java").toString()).redirectErrorStream(true).start()
            val diagnostics=compile.inputStream.bufferedReader().readText()
            assertEquals(0,compile.waitFor(),diagnostics)
            val run=ProcessBuilder(java.toString(),"-cp",directory.toString(),"RefreshProbe").redirectErrorStream(true).start()
            val output=run.inputStream.bufferedReader().readText()
            assertEquals(0,run.waitFor(),output)
        }
    }
    @Test fun `default renderer pins agree across CLI frontend and Gradle`() {
        assertEquals("0.0.1-alpha17",versions["renderer"])
        assertTrue(assets().resolve("lisp/compose-preview.el").readText().contains("compose-preview-renderer-version \"${versions["renderer"]}\""))
        assertTrue(assets().resolve("gradle/preview.init.gradle").readText().contains("?: \"${versions["renderer"]}\""))
        assertEquals("32.5.1",versions["detector"])
        assertTrue(assets().resolve("lisp/compose-preview.el").readText().contains("compose-preview-detector-version \"${versions["detector"]}\""))
        assertTrue(assets().resolve("gradle/preview.init.gradle").readText().contains("?: \"${versions["detector"]}\""))
        assertEquals("17.0.4",versions["layoutlib"])
        assertTrue(assets().resolve("lisp/compose-preview.el").readText().contains("compose-preview-layoutlib-version \"${versions["layoutlib"]}\""))
        assertTrue(assets().resolve("gradle/preview.init.gradle").readText().contains("?: \"${versions["layoutlib"]}\""))
    }
    @Test fun `renderer environment tracks runtime and launcher changes`() {
        val (_,model)=fixture()
        val runtime=root.resolve("build/layoutlib")
        Files.createDirectories(runtime)
        runtime.resolve("bridge.jar").writeText("runtime")
        model.addProperty("layoutlibPath",runtime.toString())
        val home=root.resolve("build/assets")
        Files.createDirectories(home.resolve("renderer"))
        val launcher=home.resolve("renderer/ComposePreviewRenderLauncher.java")
        launcher.writeText("original adapter")
        val before=rendererEnvironment(model,home)
        runtime.resolve("bridge.jar").writeText("changed runtime")
        val changed=rendererEnvironment(model,home)
        assertNotEquals(before,changed)
        launcher.writeText("updated adapter")
        assertNotEquals(changed,rendererEnvironment(model,home))
    }
    @Test fun `model content tampering invalidates receipt`() {
        val (path, model)=fixture()
        model.addProperty("namespace","tampered")
        atomicJson(path,model)
        engine(options("--model",path.toString(),"--no-build")) { assertFailsWith<Failure> { it.prepare() } }
    }
    @Test fun `missing compiled artifacts are never fresh`() {
        val (path,model) = fixture()
        Path.of(model.strings("classPath")[0]).deleteExisting()
        engine(options("--model",path.toString(),"--no-build")) { assertFailsWith<Failure> { it.prepare() } }
    }
    @Test fun `empty file discovery needs no renderer process`() {
        val (path,_) = fixture()
        engine(options("--model",path.toString(),"--no-build")) {
            val (result,code) = it.render()
            assertEquals(0,code); assertTrue(result.array("results").isEmpty)
            assertTrue(Path.of(result.text("outputDirectory")!!).resolve("result.json").exists())
        }
    }
    @Test fun `fresh image run is reused only after authoritative model validation`() {
        val (path,_)=fixture()
        val args=options("--model",path.toString(),"--no-build")
        val first=engine(args) { it.render().first }
        val previous=Path.of(first.text("outputDirectory")!!).resolve("result.json")
        val second=engine(options("--model",path.toString(),"--no-build","--reuse","--previous-result",previous.toString())) { it.render().first }
        assertTrue(second["reusedImages"].asBoolean)
        assertEquals(first.text("outputDirectory"),second.text("outputDirectory"))
        root.resolve("Changed.kt").writeText("changed")
        engine(options("--model",path.toString(),"--no-build","--reuse","--previous-result",previous.toString())) {
            assertFailsWith<Failure> { it.render() }
        }
    }
    @Test fun `recompiled inputs never reuse old images with identical model paths`() {
        val (path,model)=fixture()
        val first=engine(options("--model",path.toString(),"--no-build")) { it.render().first }
        val previous=Path.of(first.text("outputDirectory")!!).resolve("result.json")
        root.resolve("Changed.kt").writeText("fun Changed() {}")
        atomicJson(path.resolveSibling("model.receipt.json"),obj("environment" to hash(listOf(buildEnvironment(),cat.android.project.gradleJvmSignature(root))),"modelHash" to hash(model),
            "inputs" to targetInputs(PreviewTarget.fromModel(model),assets()),"artifacts" to artifactSignature(model)))
        val second=engine(options("--model",path.toString(),"--no-build","--reuse","--previous-result",previous.toString())) { it.render().first }
        assertFalse(second["reusedImages"].asBoolean)
        assertNotEquals(first.text("outputDirectory"),second.text("outputDirectory"))
    }
    @Test fun `recompiled bytecode never reuses old images with identical model JSON`() {
        val (path,model)=fixture()
        val first=engine(options("--model",path.toString(),"--no-build")) { it.render().first }
        val previous=Path.of(first.text("outputDirectory")!!).resolve("result.json")
        Path.of(model.strings("classPath")[0]).writeText("changed bytecode")
        atomicJson(path.resolveSibling("model.receipt.json"),obj("environment" to hash(listOf(buildEnvironment(),cat.android.project.gradleJvmSignature(root))),"modelHash" to hash(model),
            "inputs" to targetInputs(PreviewTarget.fromModel(model),assets()),"artifacts" to artifactSignature(model)))
        val second=engine(options("--model",path.toString(),"--no-build","--reuse","--previous-result",previous.toString())) { it.render().first }
        assertFalse(second["reusedImages"].asBoolean)
    }
    @Test fun `source selection uses package filename and method not display name`() {
        val file = root.resolve("A.kt"); file.writeText("package demo\nfun Card() {}")
        val good = obj("methodFQN" to "demo.AKt.Card","sourceFile" to "A.kt")
        val model = obj("previews" to listOf(good,obj("methodFQN" to "other.AKt.Card","sourceFile" to "A.kt"),obj("methodFQN" to "demo.BKt.Card","sourceFile" to "B.kt")))
        assertEquals(listOf(good),declarations(model,file,null))
        assertTrue(declarations(model,file,"demo.AKt.Missing").isEmpty())
    }
    @Test fun `prune defaults dry run and protects unowned and kept runs`() {
        val runs = root.resolve("build/cache/runs"); val owned = runs.resolve("owned"); val unowned=runs.resolve("unowned")
        Files.createDirectories(owned); Files.createDirectories(unowned)
        atomicJson(owned.resolve(".compose-preview-run.json"),obj("owner" to OWNER,"created" to 0))
        val args=Options(listOf("cache","prune","--cache-dir",root.resolve("build/cache").toString()))
        engine(args) { assertEquals(1,it.prune().array("paths").size()) }
        assertTrue(owned.exists())
        engine(Options(listOf("cache","prune","--apply","--cache-dir",root.resolve("build/cache").toString(),"--keep",owned.toString()))) { assertTrue(it.prune().array("paths").isEmpty) }
        engine(Options(listOf("cache","prune","--apply","--cache-dir",root.resolve("build/cache").toString()))) { it.prune() }
        assertFalse(owned.exists()); assertTrue(unowned.exists())
    }
    @Test fun `active run lock prevents cleanup`() {
        val directory=root.resolve("build/cache/runs/active")
        Files.createDirectories(directory)
        atomicJson(directory.resolve(".compose-preview-run.json"),obj("owner" to OWNER,"created" to 0))
        locked(directory) {
            engine(Options(listOf("cache","prune","--apply","--cache-dir",root.resolve("build/cache").toString()))) {
                assertTrue(it.prune().array("paths").isEmpty)
            }
        }
        assertTrue(directory.exists())
    }
    @Test fun `invalid temporary dimensions are rejected`() {
        val annotation=obj("widthDp" to 100)
        val preview=obj("methodFQN" to "demo.Card","annotations" to listOf(annotation))
        val id=previewId(preview,annotation,0)
        val overrides=obj(id to obj("baseline" to baseline(annotation),"values" to obj("widthDp" to 0)))
        assertFailsWith<Failure> { settings(JsonObject(),listOf(preview),root,overrides) }
    }
    @Test fun `unknown options and invalid timeout fail explicitly`() {
        assertFailsWith<Failure> { Options(listOf("render","--invalid")) }
        assertFailsWith<Failure> { options("--timeout","-1").seconds("timeout",300) }
    }
    @Test fun `strict preview checks fail closed without changing the default`() {
        val (emptyPath, emptyModel) = fixture()
        val emptyCopy = root.resolve("build/empty-model.json")
        Files.copy(emptyPath, emptyCopy)
        Files.copy(emptyPath.resolveSibling("model.receipt.json"), emptyCopy.resolveSibling("empty-model.receipt.json"))
        val first = obj("name" to "One", "widthDp" to 100)
        val second = obj("name" to "Two", "widthDp" to 200)
        val preview = obj("methodFQN" to "demo.AKt.Card", "sourceFile" to "A.kt", "annotations" to listOf(first, second))
        emptyModel.add("previews", com.google.gson.JsonArray().apply { add(preview) })
        atomicJson(emptyPath, emptyModel)
        atomicJson(emptyPath.resolveSibling("model.receipt.json"), obj(
            "environment" to hash(listOf(buildEnvironment(), cat.android.project.gradleJvmSignature(root))),
            "modelHash" to hash(emptyModel), "inputs" to targetInputs(PreviewTarget.fromModel(emptyModel), assets()),
            "artifacts" to artifactSignature(emptyModel)))
        val ids = listOf(previewId(preview, first, 0), previewId(preview, second, 1)).sorted()
        val expectedFile = root.resolve("expected-ids.txt")
        expectedFile.writeText("# comment\n\n${ids[0]}\n${ids[1]}\n")
        val blank = root.resolve("blank-ids.txt"); blank.writeText("# none\n\n")
        assertEquals("input", assertFailsWith<Failure> { expectedPreviewIds(Options(listOf("list", "--expect-ids", "@$blank"))) }.kind)
        val evidence = Path.of("/tmp/preview-contract-evidence")
        evidence.toFile().deleteRecursively(); Files.createDirectories(evidence)
        val cases = listOf(
            "default-empty" to listOf("list", "--model", emptyCopy.toString(), "--no-build", "--json"),
            "require-empty" to listOf("list", "--model", emptyCopy.toString(), "--no-build", "--require-previews", "--json"),
            "missing" to listOf("list", "--model", emptyPath.toString(), "--no-build", "--expect-ids", "${ids[0]},missing-id", "--json"),
            "match" to listOf("list", "--model", emptyPath.toString(), "--no-build", "--require-previews", "--expect-ids", "@${expectedFile}", "--json"),
            "render-missing" to listOf("render", "--model", emptyPath.toString(), "--no-build", "--expect-ids", "missing-only", "--json"))
        cases.forEach { (name, args) ->
            val (exit, json) = runCli(*args.toTypedArray())
            Files.writeString(evidence.resolve("$name.json"), com.google.gson.GsonBuilder().setPrettyPrinting().create().toJson(json))
            Files.writeString(evidence.resolve("$name.exit"), exit.toString())
            when (name) {
                "default-empty" -> {
                    assertEquals(0, exit); assertEquals("ready", json.text("status")); assertFalse(json.has("previewCheck"))
                }
                "require-empty" -> {
                    assertEquals(1, exit); assertEquals("no-previews", json.getAsJsonObject("error").text("code"))
                    assertEquals("preview-check", json.getAsJsonObject("error").text("kind"))
                }
                "missing" -> {
                    assertEquals(1, exit)
                    val error = json.getAsJsonObject("error")
                    assertEquals("preview-set-mismatch", error.text("code"))
                    assertEquals(listOf("missing-id"), error.strings("missingIds"))
                    assertEquals(listOf(ids[1]), error.strings("unexpectedIds"))
                    assertEquals(ids, error.strings("actualIds"))
                }
                "match" -> {
                    assertEquals(0, exit); assertEquals("ok", json.getAsJsonObject("previewCheck").text("code"))
                    assertEquals(ids, json.getAsJsonObject("previewCheck").strings("actualIds"))
                }
                "render-missing" -> {
                    assertEquals(1, exit); assertEquals("preview-set-mismatch", json.getAsJsonObject("error").text("code"))
                    assertEquals(listOf("missing-only"), json.getAsJsonObject("error").strings("missingIds"))
                }
            }
        }
    }
    private fun runCli(vararg args: String): Pair<Int, com.google.gson.JsonObject> {
        val command = listOf(
            Path.of(System.getProperty("java.home"), "bin", if (isWindows) "java.exe" else "java").toString(),
            "-Dcompose.preview.home=${assets()}", "-cp", System.getProperty("preview.test.classpath"), "cat.preview.MainKt")
        val process = ProcessBuilder(command + args).redirectError(root.resolve("contract.log").toFile()).start()
        val output = process.inputStream.bufferedReader().use { it.readText() }
        val exit = process.waitFor()
        assertTrue(output.contains('{'), output)
        return exit to com.google.gson.JsonParser.parseString(output.substring(output.indexOf('{'))).asJsonObject
    }
    @Test fun `process timeout releases owned child`() {
        val processes=Processes()
        try {
            val java=Path.of(System.getProperty("java.home"),"bin",if(isWindows) "java.exe" else "java")
            val source=root.resolve("Wait.java");source.writeText("class Wait { public static void main(String[] a) throws Exception { Thread.sleep(30000); } }")
            val error=assertFailsWith<Failure> { processes.run(listOf(java.toString(),source.toString()),timeout=1) }
            assertEquals("timeout",error.kind)
        } finally { processes.close() }
    }
}
