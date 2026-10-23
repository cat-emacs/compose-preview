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
        atomicJson(path.resolveSibling("model.receipt.json"),obj("environment" to buildEnvironment(),"modelHash" to hash(model),"inputs" to targetInputs(PreviewTarget.fromModel(model),assets()),"artifacts" to artifactSignature(model)))
        return path to model
    }
    private fun <T> engine(options: Options, block: (Engine) -> T): T {
        val processes = Processes()
        try { return block(Engine(options,assets(),processes)) } finally { processes.close() }
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
            atomicJson(path.resolveSibling("model.receipt.json"),obj("environment" to buildEnvironment(),"modelHash" to hash(model),
                "inputs" to targetInputs(PreviewTarget.fromModel(model),assets()),"artifacts" to artifactSignature(model)))
            engine(options("--model",path.toString(),"--no-build")) { assertTrue(it.prepare().reused) }
            external.resolve("Source.kt").writeText("changed without rebuilding the dependency")
            engine(options("--model",path.toString(),"--no-build")) { assertEquals("stale-model",assertFailsWith<Failure> { it.prepare() }.kind) }
            val target=PreviewTarget.fromModel(model)
            assertNotEquals(hash(target.json()),hash(target.copy(inputRoots=emptyList()).json()))
        } finally { external.resolve("Source.kt").deleteExisting(); external.deleteExisting() }
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
        atomicJson(path.resolveSibling("model.receipt.json"),obj("environment" to buildEnvironment(),"modelHash" to hash(model),
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
        atomicJson(path.resolveSibling("model.receipt.json"),obj("environment" to buildEnvironment(),"modelHash" to hash(model),
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
