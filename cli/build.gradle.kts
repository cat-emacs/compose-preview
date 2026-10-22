plugins {
    kotlin("jvm") version "2.3.0"
    application
}
repositories { mavenCentral() }
kotlin { jvmToolchain(17) }
dependencies {
    implementation("com.google.code.gson:gson:2.13.2")
    testImplementation(kotlin("test-junit5"))
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}
application {
    mainClass = "cat.preview.MainKt"
    applicationName = "compose-preview"
}
tasks.test { useJUnitPlatform() }
distributions {
    main {
        distributionBaseName = "compose-preview"
        contents {
            from(rootProject.file("gradle/preview.init.gradle")) { into("gradle") }
            from(rootProject.file("gradle/adapters")) { into("gradle/adapters") }
            from(rootProject.file("renderer")) { into("renderer") }
            from(rootProject.file("lisp")) { into("lisp"); exclude("*.elc") }
            from(rootProject.file("LICENSE"))
        }
    }
}
