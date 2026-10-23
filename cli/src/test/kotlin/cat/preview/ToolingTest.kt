package cat.preview

import java.nio.file.Path
import java.nio.file.Files
import java.util.Base64
import kotlin.io.path.*
import kotlin.test.*
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir

class ToolingTest {
    @TempDir lateinit var root: Path
    private fun record(module: String, build: String): String {
        fun encoded(value: String) = Base64.getEncoder().encodeToString(value.toByteArray())
        val components = "${encoded("main")}:${encoded("debug")}:${encoded("src/main/kotlin") }"
        return "$module|$build/app|$build|debug|com.example|src/main/kotlin|assembleDebug|debug||true||com.android.application|com.example.test|com.example|$components|application|true"
    }
    @Test fun `supplement merges empty and populated included build sections`() {
        val output = "noise\n===FLAVORS_START===\n===FLAVORS_END===\n" +
            "===FLAVORS_START===\n${record(":app","/root")}\n===FLAVORS_END===\n" +
            "===FLAVORS_START===\n${record(":app","/included")}\n===FLAVORS_END===\n"
        val targets=projectTargets(output)
        assertEquals(2,targets.size)
        assertEquals(listOf("/root","/included"),targets.map { it.text("buildRoot") })
        assertEquals("main",targets[0].array("components")[0].asJsonObject.text("kind"))
        assertEquals("com.example.test",targets[0].text("testApplicationId"))
    }
    @Test fun `supplement rejects truncated records`() {
        assertFailsWith<Failure> { projectTargets("===FLAVORS_START===\n:app|bad\n===FLAVORS_END===") }
    }
    @Test fun `tooling action fetches real Gradle build and preview task honors configuration cache`() {
        // Reuse the exact Gradle distribution running these tests; no network/Android SDK required.
        val home=System.getProperty("preview.test.gradle.home") ?: return
        Files.createDirectories(root.resolve("gradle/wrapper"))
        root.resolve("settings.gradle").writeText("rootProject.name = 'tooling-fixture'\ninclude(':lib')\n")
        Files.createDirectories(root.resolve("lib"))
        root.resolve("build.gradle").writeText("tasks.register('probe') { doLast { println 'TOOLING_PROBE_OK' } }\n" +
            "tasks.register('broken') { doLast { throw new GradleException('EXPECTED_TOOLING_FAILURE') } }\n" +
            "tasks.register('slow') { doLast { Thread.sleep(30000) } }\n")
        val script=root.resolve("model.init.gradle")
        script.writeText("gradle.projectsEvaluated { println '===FLAVORS_START==='; println '===FLAVORS_END===' }\n")
        val (structure,output)=GradleTooling(Path.of(home)).use { it.project(root,script,120) }
        assertTrue(structure.modules.any { it.path == ":lib" })
        assertTrue(output.contains("===FLAVORS_START==="))
        GradleTooling(Path.of(home)).use { it.build(root,":probe",listOf("--configuration-cache"),emptyMap(),120) }
        assertTrue(root.resolve(".gradle/configuration-cache").exists())
        val failure=assertFailsWith<Failure> {
            GradleTooling(Path.of(home)).use { it.build(root,":broken",emptyList(),emptyMap(),120) }
        }
        assertTrue(failure.message!!.contains("EXPECTED_TOOLING_FAILURE"))
        val timeout=assertFailsWith<Failure> {
            GradleTooling(Path.of(home)).use { it.build(root,":slow",emptyList(),emptyMap(),1) }
        }
        assertEquals("timeout",timeout.kind)
        // Cancellation closes the connection but leaves the build service usable.
        GradleTooling(Path.of(home)).use { it.build(root,":probe",emptyList(),emptyMap(),120) }
        assertTrue(Path.of(home).exists())
    }
}
