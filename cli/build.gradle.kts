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
kotlin { jvmToolchain(17) }
dependencies {
    implementation("org.cat-emacs:android-project-core:0.1.4")
    implementation("com.google.code.gson:gson:2.13.2")
    testImplementation(kotlin("test-junit5"))
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}
version = providers.gradleProperty("cliVersion").get()

application {
    mainClass = "cat.preview.MainKt"
    applicationName = "compose-preview"
}
tasks.test {
    useJUnitPlatform()
    systemProperty("preview.test.gradle.home", gradle.gradleHomeDir!!.absolutePath)
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
