// Batchmode entry point for the shell project: configures iOS player settings
// and builds an Xcode project whose IL2CPP output covers the game's assemblies.
// Invoked by recomp/unity_ios.py with -executeMethod Recomp.Build.Run.
using System;
using System.IO;
using UnityEditor;
using UnityEditor.Build;
using UnityEditor.Build.Reporting;
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
                EditorApplication.Exit(1);
        }
    }
}
