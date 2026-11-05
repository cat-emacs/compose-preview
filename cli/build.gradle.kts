plugins {
    kotlin("jvm") version "2.3.0"
    application
}
val projectCoreRepository = providers.gradleProperty("androidProjectRepository")
    .orElse("https://maven.pkg.github.com/cat-emacs/android-project")
repositories {
    exclusiveContent {
        forRepository {
            maven {
                name = "androidProjectCore"
                url = uri(projectCoreRepository.get())
                if (url.scheme == "https") {
                    credentials {
                        username = providers.environmentVariable("GITHUB_ACTOR").orNull
                        password = providers.environmentVariable("GITHUB_TOKEN").orNull
                    }
                }
            }
        }
        filter { includeModule("org.cat-emacs", "android-project-core") }
    }
    google()
    mavenCentral()
    maven("https://repo.gradle.org/gradle/libs-releases")
}
kotlin { jvmToolchain(21) }
dependencies {
    implementation("org.cat-emacs:android-project-core:0.1.7")
    implementation("com.google.code.gson:gson:2.13.2")
    testImplementation(kotlin("test-junit5"))
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}
version = providers.gradleProperty("cliVersion").get()

val resolvedProjectCoreVersion = providers.provider {
    configurations.runtimeClasspath.get().incoming.artifacts.artifacts.mapNotNull {
        it.id.componentIdentifier as? org.gradle.api.artifacts.component.ModuleComponentIdentifier
    }.single { it.group == "org.cat-emacs" && it.module == "android-project-core" }.version
}
val buildInfoDirectory = layout.buildDirectory.dir("generated/build-info")
val generateBuildInfo by tasks.registering {
    inputs.property("projectCoreVersion", resolvedProjectCoreVersion)
    outputs.dir(buildInfoDirectory)
    doLast {
        val file = buildInfoDirectory.get().file("cat/preview/build-info.properties").asFile
        file.parentFile.mkdirs()
        file.writeText("projectCoreVersion=${resolvedProjectCoreVersion.get()}\n")
    }
}
tasks.processResources { from(generateBuildInfo) }

application {
    mainClass = "cat.preview.MainKt"
    applicationName = "compose-preview"
}
tasks.test {
    useJUnitPlatform()
    inputs.files(rootProject.fileTree("gradle"), rootProject.fileTree("renderer"), rootProject.fileTree("lisp") {
        include("*.el")
        exclude("*-autoloads.el", "*-pkg.el")
    })
    systemProperty("preview.test.gradle.home", gradle.gradleHomeDir!!.absolutePath)
    inputs.property("projectCoreVersion", resolvedProjectCoreVersion)
    doFirst {
        systemProperty("preview.test.core.version", resolvedProjectCoreVersion.get())
        systemProperty("preview.test.classpath", sourceSets.main.get().runtimeClasspath.asPath)
    }
}
tasks.distTar {
    compression = Compression.GZIP
    archiveExtension = "tar.gz"
}

distributions {
    main {
        distributionBaseName = "compose-preview"
        contents {
            from(rootProject.file("gradle/preview.init.gradle")) { into("gradle") }
            from(rootProject.file("gradle/adapters")) { into("gradle/adapters") }
            from(rootProject.file("renderer")) { into("renderer") }
            from(rootProject.file("lisp")) { into("lisp"); exclude("*.elc", "*-autoloads.el", "*-pkg.el") }
            from(rootProject.file("LICENSE"))
        }
    }
}
