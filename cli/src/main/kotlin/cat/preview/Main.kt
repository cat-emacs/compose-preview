package cat.preview

import com.google.gson.*
import java.io.File
import java.nio.channels.FileChannel
import java.nio.file.*
import java.nio.file.attribute.BasicFileAttributes
import java.security.MessageDigest
import java.time.Instant
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlin.io.path.*
import kotlin.system.exitProcess

internal const val OWNER = "cat-emacs-compose-preview-v1"
internal val gson = GsonBuilder().serializeNulls().disableHtmlEscaping().create()
internal val versions = mapOf("renderer" to "0.0.1-alpha16", "layoutlib" to "16.1.0-jdk17", "detector" to "32.5.0-alpha05")
internal val skipped = setOf(".git", ".gradle", ".idea", "build", "node_modules", "__pycache__")
internal val suffixes = setOf("kt", "kts", "java", "groovy", "xml", "properties", "toml", "gradle", "jar", "aar", "png", "webp", "jpg", "jpeg", "svg", "ttf", "otf", "json")
internal class Failure(message: String, val kind: String = "error") : RuntimeException(message)
internal fun obj(vararg values: Pair<String, Any?>): JsonObject = gson.toJsonTree(mapOf(*values)).asJsonObject
internal fun JsonObject.text(key: String): String? = get(key)?.takeUnless { it.isJsonNull }?.let {
    if (!it.isJsonPrimitive || !it.asJsonPrimitive.isString) throw Failure("Expected string: $key", "protocol")
    it.asString
}
internal fun JsonObject.array(key: String): JsonArray = get(key)?.takeUnless { it.isJsonNull }?.asJsonArray ?: JsonArray()
internal fun JsonObject.strings(key: String): List<String> = array(key).map { it.asString }
internal fun readJson(path: Path): JsonObject = Files.newBufferedReader(path).use { JsonParser.parseReader(it).asJsonObject }
internal fun atomicJson(path: Path, value: JsonObject) {
    Files.createDirectories(path.parent)
    val temporary = Files.createTempFile(path.parent, ".preview-", ".json")
    try {
        Files.newBufferedWriter(temporary).use { gson.toJson(value, it) }
        try { Files.move(temporary, path, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING) }
        catch (_: AtomicMoveNotSupportedException) { Files.move(temporary, path, StandardCopyOption.REPLACE_EXISTING) }
    } finally { Files.deleteIfExists(temporary) }
}
internal fun canonical(value: JsonElement): JsonElement = when {
    value.isJsonObject -> JsonObject().also { output -> value.asJsonObject.entrySet().sortedBy { it.key }.forEach { (k,v) -> output.add(k, canonical(v)) } }
    value.isJsonArray -> JsonArray().also { output -> value.asJsonArray.forEach { output.add(canonical(it)) } }
    else -> value
}
internal fun hash(value: Any?): String = MessageDigest.getInstance("SHA-256").digest(gson.toJson(canonical(gson.toJsonTree(value))).toByteArray()).joinToString("") { "%02x".format(it) }
internal fun stamp(path: Path): List<Any>? = try {
    Files.readAttributes(path, BasicFileAttributes::class.java).let {
        val changed = try { Files.getAttribute(path,"unix:ctime").toString() } catch (_: UnsupportedOperationException) { it.creationTime().toString() } catch (_: IllegalArgumentException) { it.creationTime().toString() }
        listOf(it.size(), it.lastModifiedTime().toString(), changed)
    }
} catch (_: NoSuchFileException) { null }
internal fun ownedRun(directory: Path): Boolean = try {
    readJson(directory.resolve(".compose-preview-run.json")).text("owner") == OWNER
} catch (_: Exception) { false }
internal fun files(root: Path, excludeOutputs: Boolean): List<Path> {
    val result = mutableListOf<Path>()
    if (!Files.isDirectory(root)) return result
    Files.walkFileTree(root, object : SimpleFileVisitor<Path>() {
        override fun preVisitDirectory(dir: Path, attrs: BasicFileAttributes): FileVisitResult =
            if (dir != root && excludeOutputs && (dir.fileName.toString() in skipped || ownedRun(dir))) FileVisitResult.SKIP_SUBTREE else FileVisitResult.CONTINUE
        override fun visitFile(file: Path, attrs: BasicFileAttributes): FileVisitResult {
            result.add(file)
            return FileVisitResult.CONTINUE
        }
        override fun visitFileFailed(file: Path, error: java.io.IOException): FileVisitResult = throw error
    })
    return result.sortedBy { it.toString() }
}
internal fun inputSignature(root: Path, assets: Path): String {
    val relevant = files(root, true).filter { it.extension in suffixes || it.any { p -> p.toString() in setOf("res", "assets", "composeResources") } }
    return hash((relevant + files(assets.resolve("gradle"), false).filter { it.extension == "gradle" }).map { listOf(it.toString(), stamp(it), if (Files.isSymbolicLink(it)) Files.readSymbolicLink(it).toString() else null) })
}
internal fun artifactSignature(model: JsonObject): String? {
    val paths = (model.strings("classPath") + model.strings("projectClassPath") + model.strings("rendererClassPath") + model.strings("rClassJars") + listOfNotNull(model.text("resourceApkPath"))).distinct().sorted()
    if (paths.any { !Files.exists(Path.of(it)) }) return null
    return hash(paths.flatMap { value ->
        val path = Path.of(value)
        (if (Files.isDirectory(path)) files(path, false) else listOf(path)).map { listOf(it.toString(), stamp(it)) }
    })
}

internal class Options(arguments: List<String>) {
    private val values = mutableMapOf<String, MutableList<String>>()
    val command: String
    val action: String?
    val json: Boolean
    init {
        val args = arguments.filter { it != "--json" }
        json = "--json" in arguments
        command = args.firstOrNull() ?: "help"
        action = if (command == "cache") args.getOrNull(1) else null
        val booleans = setOf("no-build", "reuse", "no-daemon", "clean", "dry-run", "apply", "help")
        val known = booleans + setOf("project", "module", "variant", "model", "file", "method", "preview-id", "out", "overrides", "result-file", "previous-result", "cache-dir", "timeout", "build-timeout", "renderer-version", "layoutlib-version", "detector-version", "java-option", "older-than", "keep")
        var index = if (command == "cache") 2 else 1
        while (index < args.size) {
            val argument = args[index++]
            if (!argument.startsWith("--")) throw Failure("Unexpected argument: $argument", "input")
            val parts = argument.removePrefix("--").split("=", limit=2)
            val key = parts[0]
            if (key !in known) throw Failure("Unknown option --$key", "input")
            val value = if (key in booleans) "true" else parts.getOrNull(1) ?: args.getOrNull(index++) ?: throw Failure("Missing --$key value", "input")
            values.getOrPut(key) { mutableListOf() }.add(value)
        }
    }
    fun get(key: String, default: String? = null): String? = values[key]?.lastOrNull() ?: default
    fun all(key: String): List<String> = values[key].orEmpty()
    fun flag(key: String): Boolean = key in values
    fun seconds(key: String, default: Long): Long = (get(key)?.toLongOrNull() ?: if (get(key) == null) default else throw Failure("Invalid --$key", "input")).also {
        if (it <= 0) throw Failure("--$key must be positive", "input")
    }
    fun path(key: String): Path? = get(key)?.let { Path.of(it).toAbsolutePath().normalize() }
    fun version(key: String) = get("$key-version", versions.getValue(key))!!
}

internal class Processes {
    @Volatile private var current: Process? = null
    private val shutdown = Thread({ cancel() }, "preview-owned-process-cleanup")
    init { Runtime.getRuntime().addShutdownHook(shutdown) }
    @Synchronized fun cancel() {
        current?.let { process ->
            val descendants = process.descendants().filter { child ->
                val command = child.info().commandLine().orElse("")
                !command.contains("GradleDaemon") && !command.contains("KotlinCompileDaemon")
            }.toList()
            descendants.asReversed().forEach { it.destroy() }
            process.destroy()
            process.waitFor(2, TimeUnit.SECONDS)
            descendants.filter { it.isAlive }.forEach { it.destroyForcibly() }
            if (process.isAlive) process.destroyForcibly()
        }
        current = null
    }
    fun close() { cancel(); Runtime.getRuntime().removeShutdownHook(shutdown) }
    fun run(command: List<String>, cwd: Path? = null, env: Map<String,String> = emptyMap(), timeout: Long = 300, allowed: Set<Int> = setOf(0)): Int {
        System.err.println("$ " + command.joinToString(" "))
        val builder = ProcessBuilder(command).redirectErrorStream(true)
        // Drain all child output to stderr; stdout is exclusively the CLI protocol.
        if (cwd != null) builder.directory(cwd.toFile())
        builder.environment().putAll(env)
        val process = builder.start()
        current = process
        val drain = Thread({ process.inputStream.use { it.copyTo(System.err) } }, "preview-child-output").also { it.isDaemon=true; it.start() }
        try {
            if (!process.waitFor(timeout, TimeUnit.SECONDS)) {
                cancel()
                throw Failure("Process timed out", "timeout")
            }
            val status = process.exitValue()
            if (status !in allowed) throw Failure("Process exited with status $status", "process")
            return status
        } finally { drain.join(1000); current = null }
    }
}

internal fun <T> locked(directory: Path, timeout: Long = 60, body: () -> T): T {
    Files.createDirectories(directory)
    FileChannel.open(directory.resolve(".lock"), StandardOpenOption.CREATE, StandardOpenOption.WRITE).use { channel ->
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(timeout)
        var acquired: java.nio.channels.FileLock? = null
        while (acquired == null) {
            acquired = try { channel.tryLock() } catch (_: java.nio.channels.OverlappingFileLockException) { null }
            if (acquired == null) {
                if (System.nanoTime() > deadline) throw Failure("Preview cache is busy", "busy")
                Thread.sleep(50)
            }
        }
        acquired.use { return body() }
    }
}

internal class Engine(val options: Options, val assets: Path, val processes: Processes) {
    val cache: Path = (options.path("cache-dir") ?: System.getenv("COMPOSE_PREVIEW_CACHE_DIR")?.let { Path.of(it) }
        ?: Path.of(System.getenv("XDG_CACHE_HOME") ?: Path.of(System.getProperty("user.home"), ".cache").toString(), "compose-preview")).toAbsolutePath().normalize()
    fun target(): Triple<Path,Path,String> {
        val root = options.path("project") ?: Path.of("").toAbsolutePath().normalize()
        val wrapper = root.resolve(if (isWindows) "gradlew.bat" else "gradlew")
        if (!Files.isRegularFile(wrapper)) throw Failure("No Gradle wrapper under $root", "input")
        var module = options.get("module")
        if (module == null) {
            val source = options.path("file") ?: throw Failure("Specify --module or --file; modules are not guessed", "input")
            if (!source.startsWith(root)) throw Failure("Source outside project", "input")
            var directory = source.parent
            while (directory != root && !directory.resolve("build.gradle").exists() && !directory.resolve("build.gradle.kts").exists()) directory = directory.parent
            module = ":" + root.relativize(directory).joinToString(":")
        }
        if (!Regex(":(?:[\\w.+-]+(?::[\\w.+-]+)*)?").matches(module)) throw Failure("Invalid Gradle module path", "input")
        return Triple(root, wrapper, module)
    }
    fun validate(model: JsonObject): JsonObject {
        for (key in listOf("projectRoot", "moduleRoot", "modulePath", "variant", "namespace", "javaExecutable", "layoutlibPath"))
            if (model.text(key) == null) throw Failure("Model missing $key", "model")
        for (key in listOf("rendererClassPath", "classPath", "projectClassPath", "rClassJars", "previews"))
            if (!model.has(key) || !model[key].isJsonArray) throw Failure("Invalid model $key", "model")
        return model
    }
    data class Compiled(val path: Path, val model: JsonObject, val inputs: String, val reused: Boolean)
    private fun snapshot(path: Path, model: JsonObject, signature: String, reused: Boolean): Compiled {
        val immutable = path.parent.resolve("model-${hash(model).take(24)}.json")
        atomicJson(immutable, model)
        val saved = readJson(path.parent.resolve("model.receipt.json"))
        atomicJson(immutable.resolveSibling(immutable.nameWithoutExtension + ".receipt.json"), saved)
        return Compiled(immutable, model, signature, reused)
    }
    fun prepare(): Compiled {
        options.path("model")?.let { path ->
            val model = validate(readJson(path))
            val receipt = path.resolveSibling(path.nameWithoutExtension + ".receipt.json")
            if (!receipt.exists()) throw Failure("Model has no CLI validation receipt", "stale-model")
            val saved = readJson(receipt)
            val signature = inputSignature(Path.of(model.text("projectRoot")!!), assets)
            val artifacts = artifactSignature(model)
            if (artifacts == null || saved.text("modelHash") != hash(model) || saved.text("inputs") != signature || saved.text("artifacts") != artifacts)
                throw Failure("Compiled model is out of date", "stale-model")
            return Compiled(path, model, signature, true)
        }
        val (root, wrapper, module) = target()
        val variant = options.get("variant", "debug")!!
        val identity = obj("project" to root.toString(), "module" to module, "variant" to variant,
            "renderer" to options.version("renderer"), "layoutlib" to options.version("layoutlib"), "detector" to options.version("detector"))
        val directory = cache.resolve("models").resolve(hash(identity))
        return locked(directory, options.seconds("timeout",300)) {
            val path = directory.resolve("model.json")
            val receipt = directory.resolve("model.receipt.json")
            val before = inputSignature(root, assets)
            if (path.exists() && receipt.exists()) {
                try {
                    val model = validate(readJson(path))
                    val saved = readJson(receipt)
                    val artifact = artifactSignature(model)
                    if ((options.flag("reuse") || options.flag("no-build")) && artifact != null && saved["identity"] == identity && saved.text("modelHash") == hash(model) && saved.text("inputs") == before && saved.text("artifacts") == artifact)
                        return@locked snapshot(path, model, before, true)
                } catch (_: Exception) { /* Invalid derived cache is never authoritative. */ }
            }
            if (options.flag("no-build")) throw Failure("No fresh compiled model; save sources and refresh first", "stale-model")
            Files.deleteIfExists(receipt)
            val env = mapOf("COMPOSE_PREVIEW_MODULE_PATH" to module, "COMPOSE_PREVIEW_VARIANT" to variant,
                "COMPOSE_PREVIEW_MODEL_FILE" to path.toString(), "COMPOSE_PREVIEW_ADAPTER_DIRECTORY" to assets.resolve("gradle/adapters").toString(),
                "COMPOSE_PREVIEW_RENDERER_VERSION" to options.version("renderer"), "COMPOSE_PREVIEW_LAYOUTLIB_VERSION" to options.version("layoutlib"),
                "COMPOSE_PREVIEW_DETECTOR_VERSION" to options.version("detector"))
            val task = (if (module == ":") "" else module) + ":composePreviewModel"
            val command = mutableListOf(wrapper.toString(), task, "--init-script", assets.resolve("gradle/preview.init.gradle").toString(), "--console=plain",
                if (options.flag("no-daemon")) "--no-daemon" else "--daemon")
            if (options.flag("clean")) command.addAll(listOf("--no-build-cache", "--no-parallel"))
            processes.run(command, root, env, options.seconds("build-timeout",600))
            val model = validate(readJson(path))
            if (model.text("modulePath") != module || model.text("variant") != variant || Path.of(model.text("projectRoot")!!).normalize() != root)
                throw Failure("Gradle returned another target's model", "model")
            val after = inputSignature(root, assets)
            if (before != after) throw Failure("Inputs changed while building; retry", "stale-model")
            val artifact = artifactSignature(model) ?: throw Failure("Missing compiled artifacts", "model")
            atomicJson(receipt, obj("identity" to identity, "modelHash" to hash(model), "inputs" to after, "artifacts" to artifact))
            snapshot(path, model, after, false)
        }
    }
    fun compileLauncher(model: JsonObject): Path {
        val source = assets.resolve("renderer/ComposePreviewRenderLauncher.java")
        val key = hash(listOf(source.readText(), model.text("javaExecutable"), model.strings("rendererClassPath").map { listOf(it, stamp(Path.of(it))) }))
        val directory = cache.resolve("launchers").resolve(key)
        locked(directory) {
            if (!directory.resolve("ComposePreviewRenderLauncher.class").exists()) {
                val javac = Path.of(model.text("javaExecutable")!!).parent.resolve(if (isWindows) "javac.exe" else "javac")
                processes.run(listOf(javac.toString(), "-nowarn", "--release", "17", "-cp", model.strings("rendererClassPath").joinToString(File.pathSeparator), "-d", directory.toString(), source.toString()), timeout=options.seconds("build-timeout",600))
            }
        }
        return directory
    }
    fun render(): Pair<JsonObject,Int> {
        val compiled = prepare()
        val model = compiled.model
        val previews = declarations(model, options.path("file"), options.get("method"))
        val overrides = options.path("overrides")?.let { readJson(it) } ?: JsonObject()
        val requestIdentity = hash(listOf(model, previews, overrides, options.get("preview-id"), options.all("java-option")))
        if (options.flag("reuse") && !options.flag("clean")) {
            options.path("previous-result")?.let { previous ->
                try {
                    val old = readJson(previous)
                    val oldOutput = Path.of(old.text("outputDirectory")!!).toAbsolutePath().normalize()
                    val marker = readJson(oldOutput.resolve(".compose-preview-run.json"))
                    if (oldOutput.startsWith(cache.resolve("runs")) && marker.text("owner") == OWNER &&
                        old.text("status") == "ready" && old.text("requestIdentity") == requestIdentity &&
                        old.array("results").all { row ->
                            row.asJsonObject.text("imagePath")?.takeIf { it.isNotEmpty() }?.let { image ->
                                val path=Path.of(image).normalize()
                                path.startsWith(oldOutput) && path.isRegularFile()
                            } ?: true
                        }) {
                        old.addProperty("reusedImages",true)
                        old.addProperty("reusedModel",compiled.reused)
                        return old to 0
                    }
                } catch (_: Exception) { /* A bad UI image reference is never authoritative. */ }
            }
        }
        val directory = options.path("out") ?: cache.resolve("runs").resolve(UUID.randomUUID().toString())
        Files.createDirectories(directory)
        return locked(directory) {
            if (Files.list(directory).use { stream -> stream.anyMatch { it.fileName.toString() != ".lock" } })
                throw Failure("Output directory must be empty", "input")
            atomicJson(directory.resolve(".compose-preview-run.json"), obj("owner" to OWNER, "created" to Instant.now().epochSecond))
            val (settings, details) = settings(model, previews, directory, overrides, options.get("preview-id"))
            val settingsPath = directory.resolve("settings.json")
            atomicJson(settingsPath, settings)
            val beforeArtifacts = artifactSignature(model)
            var status = 0
            var rows = JsonArray()
            var global: String? = null
            if (settings.array("screenshots").size() > 0) {
                val launcher = compileLauncher(model)
                val javaOptions = options.all("java-option").ifEmpty { listOf("-Xmx1536m") }
                status = processes.run(listOf(model.text("javaExecutable")!!) + javaOptions + listOf("-Dlayoutlib.thread.profile.timeoutms=10000", "-cp",
                    (listOf(launcher.toString()) + model.strings("rendererClassPath")).joinToString(File.pathSeparator), "ComposePreviewRenderLauncher", settingsPath.toString()),
                    Path.of(model.text("projectRoot")!!), timeout=options.seconds("timeout",300), allowed=setOf(0,1))
                val rendered = readJson(directory.resolve("renderer-results.json"))
                rows = rendered.array("screenshotResults")
                global = rendered.text("globalError")
            }
            val stale = compiled.inputs != inputSignature(Path.of(model.text("projectRoot")!!), assets) || beforeArtifacts != artifactSignature(model)
            rows.forEach { element ->
                val row = element.asJsonObject
                row.text("imagePath")?.takeIf { it.isNotEmpty() }?.let { image ->
                    val path = directory.resolve(image).normalize()
                    if (!path.startsWith(directory) || (path.exists() && !path.toRealPath().startsWith(directory.toRealPath())))
                        throw Failure("Image escapes output directory", "protocol")
                    row.addProperty("imagePath", path.toString())
                }
                details[row.text("previewId")]?.entrySet()?.forEach { (key,value) -> row.add(key,value) }
            }
            val result = obj("schemaVersion" to 1, "status" to if (global != null) "failed" else if (stale) "stale" else if (status != 0) "partial" else "ready",
                "target" to obj(*listOf("projectRoot", "moduleRoot", "modulePath", "variant").map { it to model.text(it) }.toTypedArray()),
                "modelPath" to compiled.path.toString(), "outputDirectory" to directory.toString(), "reusedModel" to compiled.reused,
                "requestIdentity" to requestIdentity, "reusedImages" to false,
                "stale" to stale, "declarations" to previews, "results" to rows, "globalError" to global)
            atomicJson(directory.resolve("result.json"), result)
            options.path("result-file")?.let { atomicJson(it,result) }
            result to if (global != null) 2 else if (status != 0 || stale) 1 else 0
        }
    }
    fun prune(): JsonObject {
        if (options.action != "prune") throw Failure("Use cache prune", "input")
        if (options.flag("dry-run") && options.flag("apply")) throw Failure("Choose --dry-run or --apply, not both", "input")
        val root = cache.resolve("runs")
        val keep = options.all("keep").map { Path.of(it).toAbsolutePath().normalize() }.toSet()
        val age = options.get("older-than", "86400")!!.toLongOrNull()?.takeIf { it >= 0 } ?: throw Failure("Invalid age", "input")
        val paths = mutableListOf<String>()
        if (root.exists()) Files.list(root).use { stream -> stream.sorted().forEach { directory ->
            if (Files.isSymbolicLink(directory) || !Files.isDirectory(directory) || directory.toAbsolutePath().normalize() in keep) return@forEach
            try {
                locked(directory, 1) {
                    val marker = readJson(directory.resolve(".compose-preview-run.json"))
                    if (marker.text("owner") == OWNER && Instant.now().epochSecond - marker["created"].asLong >= age) {
                        paths.add(directory.toString())
                        if (options.flag("apply")) {
                            // Keep .lock until after the lock is released (Windows also permits this).
                            files(directory,false).filter { it.fileName.toString() != ".lock" }.forEach { Files.delete(it) }
                            Files.walk(directory).use { entries -> entries.sorted(Comparator.reverseOrder()).filter { it != directory && Files.isDirectory(it) }.forEach { Files.delete(it) } }
                        }
                    }
                }
                if (options.flag("apply") && directory.toString() in paths) { Files.deleteIfExists(directory.resolve(".lock")); Files.delete(directory) }
            } catch (_: Exception) { /* Never prune active, unowned, or malformed runs. */ }
        } }
        return obj("schemaVersion" to 1, "status" to "ready", "dryRun" to !options.flag("apply"), "paths" to paths)
    }
}

internal fun previewId(preview: JsonObject, annotation: JsonObject, index: Int) = preview.text("methodFQN")!! + "_" + hash(listOf(preview.text("methodFQN"), preview.array("methodParams"), preview.get("previewWrapperFQN"), annotation, index)).take(20)
internal fun baseline(annotation: JsonObject): JsonObject = obj(*listOf("device", "widthDp", "heightDp", "showSystemUi").map { it to annotation.get(it) }.toTypedArray())
internal fun declarations(model: JsonObject, file: Path?, method: String?): List<JsonObject> {
    val pkg = file?.readText()?.let { Regex("(?m)^\\s*package\\s+([\\w.]+)").find(it)?.groupValues?.get(1) }
    return model.array("previews").map { it.asJsonObject }.filter { preview ->
        val fqn = preview.text("methodFQN")!!
        (method == null || fqn == method) && (file == null || ((pkg == null || fqn.startsWith("$pkg.")) &&
            (preview.text("sourceFile")?.let { it == file.fileName.toString() } ?: fqn.substringBeforeLast('.').endsWith(file.nameWithoutExtension + "Kt"))))
    }
}
internal fun settings(model: JsonObject, previews: List<JsonObject>, output: Path, overrides: JsonObject, selected: String? = null): Pair<JsonObject,Map<String,JsonObject>> {
    val screenshots = JsonArray()
    val details = mutableMapOf<String,JsonObject>()
    previews.forEach { preview -> preview.array("annotations").forEachIndexed { index, value ->
        val annotation = if (value.isJsonNull) JsonObject() else value.asJsonObject
        val id = previewId(preview,annotation,index)
        if (selected != null && selected != id) return@forEachIndexed
        val effective = annotation.deepCopy()
        val override = overrides.getAsJsonObject(id)
        if (override != null && canonical(override.get("baseline")) == canonical(baseline(annotation))) {
            val values = override.getAsJsonObject("values") ?: throw Failure("Override values must be an object", "input")
            values.entrySet().forEach { (key,item) ->
                if (key !in setOf("device", "widthDp", "heightDp", "showSystemUi")) throw Failure("Invalid override $key", "input")
                when (key) {
                    "device" -> if (!item.isJsonPrimitive || !item.asJsonPrimitive.isString || !Regex("(?:id:|spec:).+").matches(item.asString)) throw Failure("Invalid device override", "input")
                    "widthDp", "heightDp" -> if (!item.isJsonPrimitive || !Regex("-?\\d+").matches(item.asString) || (item.asInt != -1 && item.asInt !in 1..10000)) throw Failure("Invalid dimension override", "input")
                    "showSystemUi" -> if (!item.isJsonPrimitive || !(item.asJsonPrimitive.isBoolean || item.asString in setOf("true","false"))) throw Failure("Invalid decoration override", "input")
                }
                effective.add(key,item)
            }
        }
        screenshots.add(obj("previewType" to "COMPOSE", "methodFQN" to preview.text("methodFQN"), "previewId" to id,
            "methodParams" to preview.array("methodParams"), "previewParams" to effective,
            "previewWrapperFqn" to preview.text("previewWrapperFQN")))
        details[id] = obj("configuration" to baseline(annotation), "previewName" to annotation.get("name"), "group" to annotation.get("group"),
            "sourceFile" to preview.text("sourceFile"), "parameterName" to preview.array("parameterNames").firstOrNull { it.isJsonPrimitive && it.asJsonPrimitive.isString })
    } }
    if (selected != null && screenshots.isEmpty) throw Failure("Unknown Preview ID", "input")
    return obj(*listOf("layoutlibPath", "fontsPath", "classPath", "projectClassPath", "rClassJars", "namespace", "resourceApkPath").map { it to model.get(it) }.toTypedArray()).also {
        it.addProperty("outputFolder",output.toString()); it.addProperty("metaDataFolder",output.resolve("metadata").toString())
        it.addProperty("resultsFilePath",output.resolve("renderer-results.json").toString()); it.add("screenshots",screenshots); it.add("resourceDirs",JsonArray())
    } to details
}
internal val isWindows = System.getProperty("os.name").startsWith("Windows")
private fun assets(): Path {
    System.getProperty("compose.preview.home")?.let { return Path.of(it).toAbsolutePath().normalize() }
    val jar = Path.of(Engine::class.java.protectionDomain.codeSource.location.toURI())
    val home = jar.parent?.parent
    if (home != null && home.resolve("gradle/preview.init.gradle").exists()) return home
    throw Failure("Cannot locate bundled Gradle/renderer assets", "setup")
}
private val help = """compose-preview — Android Studio project-level Preview CLI (JDK 17+)
Usage: compose-preview <command> [options] [--json]
  doctor                      Check runtime and installed resources (no auth)
  list --project DIR --module :app [--variant debug] [--file FILE]
  render --project DIR --module :app --file FILE [--out EMPTY_DIR]
  render --model MODEL --no-build --file FILE
  cache prune [--dry-run | --apply] [--older-than SECONDS] [--keep RUN]
Model options: --reuse --no-build --no-daemon --clean --cache-dir DIR
Render options: --preview-id ID --overrides JSON --method FQN --result-file FILE
               --timeout SECONDS --build-timeout SECONDS --java-option=-Xmx1536m
stdout is one schemaVersion=1 JSON object with --json; build/render logs use stderr.
Exit codes: 0 success, 1 partial/stale, 2 global/input error; signals cancel owned work.
"""
fun main(arguments: Array<String>) {
    if (arguments.isEmpty() || arguments.any { it in setOf("--help", "-h") }) { println(help); return }
    var options: Options? = null
    var code = 0
    var processes: Processes? = null
    val result = try {
        options = Options(arguments.toList())
        processes = Processes()
        val home = assets()
        val engine = Engine(options,home,processes)
        when (options.command) {
            "doctor" -> {
                val java = Path.of(System.getProperty("java.home"),"bin",if(isWindows) "java.exe" else "java")
                val resources = home.resolve("gradle/preview.init.gradle").exists() && home.resolve("renderer/ComposePreviewRenderLauncher.java").exists()
                if (!resources) code=2
                obj("schemaVersion" to 1,"status" to if(resources) "ready" else "missing-setup","java" to java.toString(),"javaVersion" to System.getProperty("java.version"),
                    "resources" to resources,"sdk" to (System.getenv("ANDROID_SDK_ROOT") ?: System.getenv("ANDROID_HOME")),
                    "versions" to versions,"authRequired" to false,
                    "capabilities" to obj("componentTree" to false,"inflateOnly" to false,"backend" to "studio-launcher"))
            }
            "list" -> {
                val compiled = engine.prepare()
                val rows = declarations(compiled.model, options.path("file"), options.get("method"))
                val previews = rows.flatMap { p -> p.array("annotations").mapIndexed { i,a ->
                    val annotation = if(a.isJsonNull) JsonObject() else a.asJsonObject
                    obj("previewId" to previewId(p,annotation,i),"methodFQN" to p.text("methodFQN"),"annotation" to annotation,"configuration" to baseline(annotation))
                } }
                obj("schemaVersion" to 1,"status" to "ready","modelPath" to compiled.path.toString(),"reusedModel" to compiled.reused,"declarations" to rows,"previews" to previews)
            }
            "render" -> engine.render().let { code=it.second; it.first }
            "cache" -> engine.prune()
            else -> throw Failure("Unknown command ${options.command}","input")
        }
    } catch (error: Exception) {
        code=2
        obj("schemaVersion" to 1,"status" to "failed","error" to obj("kind" to ((error as? Failure)?.kind ?: "error"),"message" to (error.message ?: error.javaClass.simpleName)))
    } finally { processes?.close() }
    val emitted = try {
        options?.path("result-file")?.let { atomicJson(it,result) }
        result
    } catch (error: Exception) {
        code=2
        obj("schemaVersion" to 1,"status" to "failed","error" to obj("kind" to "output","message" to error.message))
    }
    println(if(arguments.contains("--json")) gson.toJson(emitted) else GsonBuilder().serializeNulls().setPrettyPrinting().create().toJson(emitted))
    exitProcess(code)
}
