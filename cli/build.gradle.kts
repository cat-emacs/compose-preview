plugins {
    kotlin("jvm") version "2.3.0"
    application
}
repositories {
    google()
    mavenCentral()
    maven("https://repo.gradle.org/gradle/libs-releases")
}
kotlin { jvmToolchain(17) }
dependencies {
    implementation("com.google.code.gson:gson:2.13.2")
    implementation("org.gradle:gradle-tooling-api:9.6.1")
    implementation("com.android.tools.build:builder-model:9.3.0")
    runtimeOnly("org.slf4j:slf4j-simple:2.0.17")
    testImplementation(kotlin("test-junit5"))
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}
application {
    mainClass = "cat.preview.MainKt"
    applicationName = "compose-preview"
}
tasks.test {
    useJUnitPlatform()
    systemProperty("preview.test.gradle.home", gradle.gradleHomeDir!!.absolutePath)
}
distributions {
    main {
        distributionBaseName = "compose-preview"
        contents {
            from(rootProject.file("gradle/preview.init.gradle")) { into("gradle") }
            from(rootProject.file("gradle/project.init.gradle")) { into("gradle") }
            from(rootProject.file("gradle/adapters")) { into("gradle/adapters") }
            from(rootProject.file("renderer")) { into("renderer") }
            from(rootProject.file("lisp")) { into("lisp"); exclude("*.elc") }
            from(rootProject.file("LICENSE"))
        }
    }
}
