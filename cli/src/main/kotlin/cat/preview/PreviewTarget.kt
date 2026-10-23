package cat.preview

import cat.android.project.io.jsonObject as obj
import cat.android.project.io.jsonText as text
import com.google.gson.JsonObject
import java.nio.file.Path

/** Sync entry and owning build are distinct; module paths are local to the owning build. */
internal data class PreviewTarget(
    val projectRoot: Path,
    val buildRoot: Path,
    val modulePath: String,
    val variant: String,
    val component: String,
    val componentName: String,
    val moduleRoot: Path? = null
) {
    init {
        if (!Regex(":(?:[\\w.+-]+(?::[\\w.+-]+)*)?").matches(modulePath))
            throw Failure("Invalid Gradle module path", "input")
        if (variant.isBlank() || componentName.isBlank()) throw Failure("Empty variant/component name", "input")
        if (component != "main")
            throw Failure("Preview component '$component' ($componentName) is unsupported; only main is implemented", "unsupported")
        if (componentName != variant)
            throw Failure("Main component '$componentName' does not match variant '$variant'", "input")
    }

    fun json(): JsonObject = obj("projectRoot" to projectRoot.toString(), "buildRoot" to buildRoot.toString(),
        "modulePath" to modulePath, "variant" to variant, "component" to component,
        "componentName" to componentName, "moduleRoot" to moduleRoot?.toString())

    fun verify(model: JsonObject) {
        val actual = fromModel(model)
        if (projectRoot != actual.projectRoot || buildRoot != actual.buildRoot || modulePath != actual.modulePath ||
            variant != actual.variant || component != actual.component || componentName != actual.componentName ||
            (moduleRoot != null && moduleRoot != actual.moduleRoot))
            throw Failure("Gradle returned another target's model", "model")
    }

    companion object {
        fun fromModel(model: JsonObject): PreviewTarget {
            fun field(key: String) = model.text(key) ?: throw Failure("Model missing target field $key; rebuild required", "stale-model")
            return PreviewTarget(Path.of(field("projectRoot")).toAbsolutePath().normalize(),
                Path.of(field("buildRoot")).toAbsolutePath().normalize(), field("modulePath"), field("variant"),
                field("component"), field("componentName"), Path.of(field("moduleRoot")).toAbsolutePath().normalize())
        }
    }
}

internal fun targetInputs(target: PreviewTarget, assets: Path): String {
    val roots = listOf(target.projectRoot, target.buildRoot).distinct()
    return cat.android.project.io.jsonHash(roots.map { listOf(it.toString(), inputSignature(it, assets)) })
}
