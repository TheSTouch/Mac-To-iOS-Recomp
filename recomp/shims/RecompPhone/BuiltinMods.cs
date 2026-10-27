// The port's own mods (a game profile's "mods" "builtin" list) kept on, on iPhone and iPad: at
// every launch, before the first scene loads and so before the game's mod loader reads them, the
// PlayerPrefs key that says whether each one is on (unity_ios.py write_shim_config writes them to
// StreamingAssets/recomp.json "builtinModPrefs") is set to 1.
//
// A game whose first scene is a mod manager (Timberborn) starts the mods when the player leaves it,
// reading the keys again: until the next scene has loaded, a key the player sets back to 0 there is
// put back to 1 the next frame, so the mods start anyway (the manager's own box stays unticked).
using System;
using System.IO;
using UnityEngine;
using UnityEngine.SceneManagement;

namespace Recomp
{
    public static class BuiltinMods
    {
        [Serializable]
        class Config { public string[] builtinModPrefs; }

        static bool _installed;
        static string[] _keys;
        static int _scenes;

        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.BeforeSceneLoad)]
        public static void Install()
        {
            if (_installed) return;
            _installed = true;
            try
            {
                var path = Path.Combine(Application.streamingAssetsPath, "recomp.json");
                _keys = File.Exists(path) ? JsonUtility.FromJson<Config>(File.ReadAllText(path)).builtinModPrefs : null;
            }
            catch (Exception e)
            {
                Debug.Log("[recomp] built-in mods: cannot read recomp.json: " + e.Message);
                return;
            }
            if (_keys == null || _keys.Length == 0) return;
            foreach (var key in _keys)
            {
                var was = PlayerPrefs.HasKey(key) ? PlayerPrefs.GetInt(key).ToString() : "unset";
                PlayerPrefs.SetInt(key, 1);
                Debug.Log($"[recomp] built-in mod kept enabled: {key} (was {was})");
            }
            PlayerPrefs.Save();
            Application.onBeforeRender += Watch;
            SceneManager.sceneLoaded += OnSceneLoaded;
        }

        static void Watch()
        {
            var changed = false;
            foreach (var key in _keys)
            {
                if (PlayerPrefs.GetInt(key, 1) == 1) continue;
                PlayerPrefs.SetInt(key, 1);
                changed = true;
                Debug.Log($"[recomp] built-in mod kept enabled: {key} (turned off in the game, on again)");
            }
            if (changed) PlayerPrefs.Save();
        }

        static void OnSceneLoaded(Scene scene, LoadSceneMode mode)
        {
            if (++_scenes < 2) return;
            Application.onBeforeRender -= Watch;
            SceneManager.sceneLoaded -= OnSceneLoaded;
        }
    }
}
