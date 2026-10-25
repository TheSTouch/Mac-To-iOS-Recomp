// Batchmode entry point for the shell project: configures iOS player settings
// and builds an Xcode project whose IL2CPP output covers the game's assemblies.
// Invoked by recomp/unity_ios.py with -executeMethod Recomp.Build.Run.
using System;
using System.IO;
using UnityEditor;
using UnityEditor.Build;
using UnityEditor.Build.Reporting;
using UnityEditor.iOS.Xcode;
using UnityEditor.SceneManagement;
using UnityEngine;

namespace Recomp
{
    public static class Build
    {
        const string ScenePath = "Assets/RecompShell.unity";

        static string Arg(string name, string fallback = null)
        {
            var args = Environment.GetCommandLineArgs();
            for (int i = 0; i < args.Length - 1; i++)
                if (args[i] == name) return args[i + 1];
            if (fallback == null) throw new ArgumentException("missing " + name);
            return fallback;
        }

        public static void Run()
        {
            var output = Arg("-recompOut");
            var ios = NamedBuildTarget.iOS;

            PlayerSettings.productName = Arg("-recompProduct");
            PlayerSettings.bundleVersion = Arg("-recompVersion", "1.0");
            PlayerSettings.SetApplicationIdentifier(ios, Arg("-recompBundleId"));
            PlayerSettings.iOS.appleDeveloperTeamID = Arg("-recompTeam");
            PlayerSettings.iOS.appleEnableAutomaticSigning = true;

            PlayerSettings.SetScriptingBackend(ios, ScriptingImplementation.IL2CPP);
            PlayerSettings.SetApiCompatibilityLevel(ios, ApiCompatibilityLevel.NET_Unity_4_8);
            PlayerSettings.SetManagedStrippingLevel(ios, ManagedStrippingLevel.Minimal);
            PlayerSettings.SetIl2CppCompilerConfiguration(ios, Il2CppCompilerConfiguration.Release);
            PlayerSettings.SetIl2CppCodeGeneration(ios, Il2CppCodeGeneration.OptimizeSize);
            // The game's scenes use engine classes the empty shell scene does not,
            // so every native engine module must stay in the player.
            PlayerSettings.stripEngineCode = false;

            PlayerSettings.SetUseDefaultGraphicsAPIs(BuildTarget.iOS, false);
            PlayerSettings.SetGraphicsAPIs(BuildTarget.iOS, new[] { UnityEngine.Rendering.GraphicsDeviceType.Metal });
            PlayerSettings.colorSpace = ColorSpace.Linear;

            PlayerSettings.iOS.targetDevice = iOSTargetDevice.iPadOnly;
            PlayerSettings.iOS.targetOSVersionString = "17.0";
            PlayerSettings.iOS.requiresFullScreen = true;
            PlayerSettings.defaultInterfaceOrientation = UIOrientation.AutoRotation;
            PlayerSettings.allowedAutorotateToLandscapeLeft = true;
            PlayerSettings.allowedAutorotateToLandscapeRight = true;
            PlayerSettings.allowedAutorotateToPortrait = false;
            PlayerSettings.allowedAutorotateToPortraitUpsideDown = false;

            EditorUserBuildSettings.iOSXcodeBuildConfig = XcodeBuildConfig.Release;

            if (!File.Exists(ScenePath))
            {
                var scene = EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
                EditorSceneManager.SaveScene(scene, ScenePath);
            }

            var report = BuildPipeline.BuildPlayer(new BuildPlayerOptions
            {
                scenes = new[] { ScenePath },
                locationPathName = output,
                target = BuildTarget.iOS,
                targetGroup = BuildTargetGroup.iOS,
                options = BuildOptions.None,
            });
            Debug.Log($"[recomp] build result: {report.summary.result}, {report.summary.totalErrors} errors");
            if (report.summary.result != BuildResult.Succeeded)
            {
                EditorApplication.Exit(1);
                return;
            }
            PostProcess(output);
        }

        // Entitlements for memory-hungry desktop games; Xcode's automatic signing
        // enables the matching App ID capabilities.
        const string Entitlements = @"<?xml version=""1.0"" encoding=""UTF-8""?>
<!DOCTYPE plist PUBLIC ""-//Apple//DTD PLIST 1.0//EN"" ""http://www.apple.com/DTDs/PropertyList-1.0.dtd"">
<plist version=""1.0"">
<dict>
    <key>com.apple.developer.kernel.increased-memory-limit</key>
    <true/>
    <key>com.apple.developer.kernel.extended-virtual-addressing</key>
    <true/>
</dict>
</plist>
";

        static void PostProcess(string xcodeDir)
        {
            // The game's user folder (saves, mods) lives in Documents: show it in the Files app.
            var plistPath = Path.Combine(xcodeDir, "Info.plist");
            var plist = new PlistDocument();
            plist.ReadFromFile(plistPath);
            plist.root.SetBoolean("UIFileSharingEnabled", true);
            plist.root.SetBoolean("LSSupportsOpeningDocumentsInPlace", true);
            plist.WriteToFile(plistPath);

            var projPath = PBXProject.GetPBXProjectPath(xcodeDir);
            var proj = new PBXProject();
            proj.ReadFromFile(projPath);
            var target = proj.GetUnityMainTargetGuid();
            const string entitlements = "Unity-iPhone/recomp.entitlements";
            File.WriteAllText(Path.Combine(xcodeDir, entitlements), Entitlements);
            proj.AddFile(entitlements, entitlements);
            proj.SetBuildProperty(target, "CODE_SIGN_ENTITLEMENTS", entitlements);
            proj.WriteToFile(projPath);
        }
    }
}
