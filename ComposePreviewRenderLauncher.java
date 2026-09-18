// Renders Compose previews through Android Studio's own standalone renderer.
//
// This exists because the renderer's bundled CLI entry point constructs
// RenderEnvironmentBootstrapper without rClassJars, which leaves
// StandaloneModuleDependencies.getResourcePackageNames() empty. ViewLoader then
// never parses any R class, and because finalIdsUsed is true every library
// resource id a dependency reads through its own R class resolves to 0. Any
// project whose libraries touch their own R class renders as a blank image.
//
// The launcher passes rClassJars (and resourceDirs) to the 8-argument
// bootstrapper, which is the same entry point Studio's screenshot test engine
// uses. Everything else reuses the renderer's own model and serialization.

import com.android.tools.render.RenderEnvironmentBootstrapper;
import com.android.tools.render.Renderer;
import com.android.tools.render.common.PreviewRenderingResult;
import com.android.tools.render.common.PreviewScreenshot;
import com.android.tools.render.common.PreviewScreenshotResult;
import com.android.tools.render.common.ScreenshotPreviewElement;
import com.android.tools.render.compose.ComposeScreenshot;
import com.android.tools.render.framework.IJFramework;
import com.android.tools.configurations.Configuration;
import com.android.tools.preview.ComposePreviewElement;
import com.android.tools.preview.ComposePreviewElementInstance;
import com.android.tools.preview.PreviewConfigurationKt;
import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import com.intellij.openapi.util.Disposer;

import java.io.BufferedReader;
import java.io.File;
import java.io.StringWriter;
import java.io.Writer;
import java.lang.reflect.Field;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

public final class ComposePreviewRenderLauncher {

    public static void main(String[] args) {
        if (args.length != 1) {
            System.err.println("Usage: ComposePreviewRenderLauncher <path-to-rendering-settings-json>");
            halt(2);
        }
        int exitCode = 0;
        try {
            exitCode = render(new File(args[0]));
        } catch (Throwable failure) {
            failure.printStackTrace();
            exitCode = 1;
        }
        halt(exitCode);
    }

    private static int render(File settingsFile) throws Exception {
        JsonObject settings;
        try (BufferedReader reader = Files.newBufferedReader(settingsFile.toPath(), StandardCharsets.UTF_8)) {
            settings = JsonParser.parseReader(reader).getAsJsonObject();
        }

        String outputFolder = requireString(settings, "outputFolder");
        String resultsFilePath = requireString(settings, "resultsFilePath");
        new File(outputFolder).mkdirs();

        List<PreviewScreenshot> screenshots = readScreenshots(settings.getAsJsonArray("screenshots"));

        PreviewRenderingResult result;
        List<Integer> densityDpis = new ArrayList<>();
        List<Integer> parameterIndices = new ArrayList<>();
        List<Integer> parameterCounts = new ArrayList<>();
        List<Boolean> parameterizedResults = new ArrayList<>();
        List<String> instanceIds = new ArrayList<>();
        List<String> displayNames = new ArrayList<>();
        List<String> parameterNames = new ArrayList<>();
        try {
            RenderEnvironmentBootstrapper bootstrapper = new RenderEnvironmentBootstrapper(
                    optionalString(settings, "fontsPath"),
                    optionalString(settings, "resourceApkPath"),
                    requireString(settings, "namespace"),
                    readStrings(settings, "classPath"),
                    readStrings(settings, "projectClassPath"),
                    requireString(settings, "layoutlibPath"),
                    readStrings(settings, "resourceDirs"),
                    readStrings(settings, "rClassJars"));
            List<PreviewScreenshotResult> results = new ArrayList<>();
            try (Renderer renderer = bootstrapper.bootstrap()) {
                for (PreviewScreenshot screenshot : screenshots) {
                    ScreenshotPreviewElement previewElement = null;
                    try {
                        previewElement = screenshot.toPreviewElement(renderer.getModule());
                    } catch (Throwable ignored) {
                        // Metadata is optional; rendering still uses the screenshot itself.
                    }
                    Integer densityDpi = previewElement == null
                            ? null : resolveDensityDpi(renderer, previewElement);
                    List<PreviewInstanceMetadata> previewMetadata =
                            previewElement == null
                                    ? new ArrayList<>()
                                    : resolvePreviewMetadata(previewElement);
                    List<PreviewScreenshotResult> screenshotResults =
                            renderer.render(screenshot, outputFolder);
                    results.addAll(screenshotResults);
                    boolean parameterized = screenshot instanceof ComposeScreenshot
                            && !((ComposeScreenshot) screenshot).getMethodParams().isEmpty();
                    for (int index = 0; index < screenshotResults.size(); index++) {
                        densityDpis.add(densityDpi);
                        parameterIndices.add(index);
                        parameterCounts.add(screenshotResults.size());
                        parameterizedResults.add(parameterized);
                        PreviewInstanceMetadata metadata = index < previewMetadata.size()
                                ? previewMetadata.get(index) : null;
                        instanceIds.add(metadata == null ? null : metadata.instanceId);
                        displayNames.add(metadata == null ? null : metadata.displayName);
                        parameterNames.add(metadata == null ? null : metadata.parameterName);
                    }
                }
            }
            result = new PreviewRenderingResult(null, results);
        } catch (Throwable failure) {
            result = new PreviewRenderingResult(stackTraceOf(failure), new ArrayList<>());
            densityDpis.clear();
            parameterIndices.clear();
            parameterCounts.clear();
            parameterizedResults.clear();
            instanceIds.clear();
            displayNames.clear();
            parameterNames.clear();
        }

        writeResult(resultsFilePath, result, densityDpis, parameterIndices,
                parameterCounts, parameterizedResults, instanceIds, displayNames,
                parameterNames);

        int failures = 0;
        if (result.getGlobalError() != null) {
            System.err.println(result.getGlobalError());
            failures++;
        }
        for (PreviewScreenshotResult single : result.getScreenshotResults()) {
            if (single.getImagePath() != null) {
                System.out.println(new File(outputFolder, single.getImagePath()).getAbsolutePath());
            }
            if (single.getError() != null) {
                failures++;
            }
        }
        return failures == 0 ? 0 : 1;
    }

    private static Integer resolveDensityDpi(
            Renderer renderer, ScreenshotPreviewElement previewElement) {
        try {
            Field baseConfiguration = Renderer.class.getDeclaredField("baseConfiguration");
            baseConfiguration.setAccessible(true);
            Configuration configuration =
                    ((Configuration) baseConfiguration.get(renderer)).clone();
            PreviewConfigurationKt.applyTo(
                    previewElement,
                    configuration,
                    ignored -> null);
            int densityDpi = configuration.getDensity().getDpiValue();
            return densityDpi > 0 ? densityDpi : null;
        } catch (Throwable ignored) {
            return null;
        }
    }

    private static List<PreviewInstanceMetadata> resolvePreviewMetadata(
            ScreenshotPreviewElement previewElement) {
        List<PreviewInstanceMetadata> metadata = new ArrayList<>();
        try {
            Field delegate = previewElement.getClass().getDeclaredField("composePreviewElement");
            delegate.setAccessible(true);
            ComposePreviewElement<?> element = (ComposePreviewElement<?>) delegate.get(previewElement);
            Iterator<? extends ComposePreviewElementInstance<?>> instances =
                    element.resolve().iterator();
            while (instances.hasNext()) {
                ComposePreviewElementInstance<?> instance = instances.next();
                metadata.add(new PreviewInstanceMetadata(
                        instance.getInstanceId(),
                        instance.getDisplaySettings().getName(),
                        instance.getDisplaySettings().getParameterName()));
            }
        } catch (Throwable ignored) {
            metadata.clear();
        }
        return metadata;
    }

    private static final class PreviewInstanceMetadata {
        private final String instanceId;
        private final String displayName;
        private final String parameterName;

        private PreviewInstanceMetadata(
                String instanceId, String displayName, String parameterName) {
            this.instanceId = instanceId;
            this.displayName = displayName;
            this.parameterName = parameterName;
        }
    }

    private static void writeResult(
            String resultsFilePath,
            PreviewRenderingResult result,
            List<Integer> densityDpis,
            List<Integer> parameterIndices,
            List<Integer> parameterCounts,
            List<Boolean> parameterizedResults,
            List<String> instanceIds,
            List<String> displayNames,
            List<String> parameterNames) throws Exception {
        StringWriter serialized = new StringWriter();
        com.android.tools.render.common.JsonSerializationKt.writePreviewRenderingResult(serialized, result);
        JsonObject json = JsonParser.parseString(serialized.toString()).getAsJsonObject();
        JsonArray screenshotResults = json.getAsJsonArray("screenshotResults");
        if (screenshotResults != null) {
            for (int index = 0; index < screenshotResults.size() && index < densityDpis.size(); index++) {
                Integer densityDpi = densityDpis.get(index);
                JsonObject screenshotResult = screenshotResults.get(index).getAsJsonObject();
                if (densityDpi != null) {
                    screenshotResult.addProperty("densityDpi", densityDpi);
                }
                if (parameterizedResults.get(index)) {
                    screenshotResult.addProperty("parameterIndex", parameterIndices.get(index));
                    screenshotResult.addProperty("parameterCount", parameterCounts.get(index));
                }
                if (instanceIds.get(index) != null) {
                    screenshotResult.addProperty("instanceId", instanceIds.get(index));
                }
                if (displayNames.get(index) != null) {
                    screenshotResult.addProperty("displayName", displayNames.get(index));
                }
                if (parameterNames.get(index) != null) {
                    screenshotResult.addProperty("parameterName", parameterNames.get(index));
                }
            }
        }

        File resultsFile = new File(resultsFilePath);
        if (resultsFile.getParentFile() != null) {
            resultsFile.getParentFile().mkdirs();
        }
        try (Writer writer = Files.newBufferedWriter(resultsFile.toPath(), StandardCharsets.UTF_8)) {
            writer.write(json.toString());
        }
    }

    private static List<PreviewScreenshot> readScreenshots(JsonArray array) {
        List<PreviewScreenshot> screenshots = new ArrayList<>();
        if (array == null) {
            return screenshots;
        }
        for (JsonElement element : array) {
            JsonObject entry = element.getAsJsonObject();
            List<Map<String, String>> methodParams = new ArrayList<>();
            JsonArray rawMethodParams = entry.getAsJsonArray("methodParams");
            if (rawMethodParams != null) {
                for (JsonElement rawMethodParam : rawMethodParams) {
                    methodParams.add(readStringMap(rawMethodParam.getAsJsonObject()));
                }
            }
            Map<String, String> previewParams = entry.has("previewParams")
                    ? readStringMap(entry.getAsJsonObject("previewParams"))
                    : new LinkedHashMap<>();
            screenshots.add(new ComposeScreenshot(
                    requireString(entry, "methodFQN"),
                    methodParams,
                    previewParams,
                    requireString(entry, "previewId"),
                    optionalString(entry, "previewWrapperFqn")));
        }
        return screenshots;
    }

    private static Map<String, String> readStringMap(JsonObject object) {
        Map<String, String> values = new LinkedHashMap<>();
        for (Map.Entry<String, JsonElement> entry : object.entrySet()) {
            values.put(entry.getKey(), entry.getValue().getAsString());
        }
        return values;
    }

    private static List<String> readStrings(JsonObject settings, String name) {
        List<String> values = new ArrayList<>();
        JsonArray array = settings.getAsJsonArray(name);
        if (array != null) {
            for (JsonElement element : array) {
                values.add(element.getAsString());
            }
        }
        return values;
    }

    private static String requireString(JsonObject object, String name) {
        JsonElement element = object.get(name);
        if (element == null || element.isJsonNull()) {
            throw new IllegalArgumentException("Missing required field: " + name);
        }
        return element.getAsString();
    }

    private static String optionalString(JsonObject object, String name) {
        JsonElement element = object.get(name);
        return element == null || element.isJsonNull() ? null : element.getAsString();
    }

    private static String stackTraceOf(Throwable failure) {
        java.io.StringWriter writer = new java.io.StringWriter();
        failure.printStackTrace(new java.io.PrintWriter(writer));
        return writer.toString();
    }

    // Layoutlib leaves non-daemon threads behind, so the JVM is halted explicitly.
    private static void halt(int exitCode) {
        try {
            Disposer.dispose(IJFramework.INSTANCE);
        } catch (Throwable ignored) {
            // Disposal is best effort; the process is about to end anyway.
        }
        Runtime.getRuntime().halt(exitCode);
    }

    private ComposePreviewRenderLauncher() {}
}
