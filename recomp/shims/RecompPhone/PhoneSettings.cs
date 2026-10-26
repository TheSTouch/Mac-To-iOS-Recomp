// Settings for a desktop game on an iPhone's small screen, applied once at startup and only
// on iPhones: the render resolution, frame rate and quality level of the profile's "iphone"
// block laid over the generic phone defaults (unity_ios.py write_shim_config writes them to
// StreamingAssets/recomp.json "phone"), and the game's own PlayerPrefs, each written only
// when the player has none yet, so their own choices stick.
//
// Games that keep graphics settings of their own apply them from PlayerPrefs after this runs,
// so for them player_prefs is the lever; the render resolution is put back once if the game
// resets the screen to its native size while loading a scene.
//
// Every 30 seconds a phone also logs its frame rate and memory ("[recomp] phone stats"),
// the numbers a profile's "iphone" block is tuned from.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using Unity.Profiling;
using UnityEngine;
using UnityEngine.SceneManagement;

namespace Recomp
{
    public static class PhoneSettings
    {
        [Serializable]
        class Pref { public string key, type, value; }

        [Serializable]
        class Phone
        {
            public float renderScale;          // 0: native
            public int targetFrameRate;        // 0: the game's own
            public int qualityLevel = -1;      // -1: the game's own
            public Pref[] playerPrefs;
        }

        [Serializable]
        class Config { public Phone phone; }

        const float StatsSeconds = 30f;

        static bool _installed, _checkOrientation;
        static int _width, _height, _nativeWidth, _nativeHeight, _setFrame;
        static ProfilerRecorder _memory;
        static int _frames;
        static float _statsSince;

        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.BeforeSceneLoad)]
        public static void Install()
        {
            if (_installed) return;
            _installed = true;
            if (!SystemInfo.deviceModel.StartsWith("iPhone", StringComparison.Ordinal)) return;
            _memory = ProfilerRecorder.StartNew(ProfilerCategory.Memory, "System Used Memory");
            _statsSince = Time.realtimeSinceStartup;
            Application.onBeforeRender += CountFrame;
            Phone phone;
            try
            {
                var path = Path.Combine(Application.streamingAssetsPath, "recomp.json");
                phone = File.Exists(path) ? JsonUtility.FromJson<Config>(File.ReadAllText(path)).phone : null;
            }
            catch (Exception e)
            {
                Debug.Log("[recomp] phone settings: cannot read recomp.json: " + e.Message);
                return;
            }
            if (phone == null)
            {
                Debug.Log("[recomp] phone settings: none in recomp.json");
                return;
            }
            var applied = new List<string> { SystemInfo.deviceModel };

            if (phone.renderScale > 0f && phone.renderScale < 1f)
            {
                // The game runs in landscape, whatever the screen reports this early.
                _nativeWidth = Mathf.Max(Screen.width, Screen.height);
                _nativeHeight = Mathf.Min(Screen.width, Screen.height);
                _width = Mathf.RoundToInt(_nativeWidth * phone.renderScale);
                _height = Mathf.RoundToInt(_nativeHeight * phone.renderScale);
                Screen.SetResolution(_width, _height, Screen.fullScreenMode);
                _setFrame = Time.frameCount;
                _checkOrientation = true;
                SceneManager.sceneLoaded += OnSceneLoaded;
                applied.Add($"render scale {phone.renderScale.ToString(CultureInfo.InvariantCulture)} " +
                            $"({_nativeWidth}x{_nativeHeight} -> {_width}x{_height})");
            }
            if (phone.targetFrameRate > 0)
            {
                Application.targetFrameRate = phone.targetFrameRate;
                applied.Add("target frame rate " + phone.targetFrameRate);
            }
            if (phone.qualityLevel >= 0)
            {
                var names = QualitySettings.names;
                if (phone.qualityLevel < names.Length)
                {
                    QualitySettings.SetQualityLevel(phone.qualityLevel, true);
                    applied.Add($"quality level {phone.qualityLevel} ({names[phone.qualityLevel]})");
                }
                else
                    applied.Add($"quality level {phone.qualityLevel} skipped (the game has {names.Length})");
            }
            var set = new List<string>();
            var kept = new List<string>();
            foreach (var p in phone.playerPrefs ?? new Pref[0])
            {
                if (string.IsNullOrEmpty(p.key)) continue;
                if (PlayerPrefs.HasKey(p.key))
                {
                    kept.Add(p.key);
                    continue;
                }
                switch (p.type)
                {
                    case "int": PlayerPrefs.SetInt(p.key, int.Parse(p.value, CultureInfo.InvariantCulture)); break;
                    case "float": PlayerPrefs.SetFloat(p.key, float.Parse(p.value, CultureInfo.InvariantCulture)); break;
                    default: PlayerPrefs.SetString(p.key, p.value); break;
                }
                set.Add(p.key + "=" + p.value);
            }
            if (set.Count > 0) PlayerPrefs.Save();
            if (set.Count > 0) applied.Add("player prefs set: " + string.Join(", ", set));
            if (kept.Count > 0) applied.Add("player prefs kept (the player's own): " + string.Join(", ", kept));
            Debug.Log("[recomp] phone settings: " + string.Join("; ", applied) +
                      $"; screen {Screen.width}x{Screen.height}, safe area {Screen.safeArea}");
        }

        // Once: a game that sets its desktop resolution while loading puts the screen back at native
        // size. SetResolution takes effect a frame later: a scene loaded before then still sees native.
        static void OnSceneLoaded(Scene scene, LoadSceneMode mode)
        {
            if (Time.frameCount < _setFrame + 3) return;
            if (Mathf.Max(Screen.width, Screen.height) != _nativeWidth || Mathf.Min(Screen.width, Screen.height) != _nativeHeight)
                return;
            SceneManager.sceneLoaded -= OnSceneLoaded;
            Screen.SetResolution(_width, _height, Screen.fullScreenMode);
            Debug.Log($"[recomp] phone settings: the game reset the screen to {_nativeWidth}x{_nativeHeight} " +
                      $"(scene {scene.name}); render size {_width}x{_height} again");
        }

        // iOS takes SetResolution's size in the display's portrait orientation (an iPhone 17 asked
        // for 1966x904 in landscape got a 904x1966 screen): once the size has applied, ask again
        // the other way round if it came out turned, and keep that order for later requests.
        static void CheckOrientation()
        {
            _checkOrientation = false;
            if (Screen.width > Screen.height || Screen.width == _nativeWidth) return;
            (_width, _height) = (_height, _width);
            Screen.SetResolution(_width, _height, Screen.fullScreenMode);
            Debug.Log($"[recomp] phone settings: the screen came out {Screen.width}x{Screen.height}; " +
                      $"asking for {_width}x{_height} instead");
        }

        static void CountFrame()
        {
            if (_checkOrientation && Time.frameCount >= _setFrame + 3) CheckOrientation();
            _frames++;
            var now = Time.realtimeSinceStartup;
            if (now - _statsSince < StatsSeconds) return;
            var memory = _memory.Valid ? (_memory.LastValue >> 20) + " MB" : "unknown";
            Debug.Log($"[recomp] phone stats: {_frames / (now - _statsSince):0.0} fps over the last {now - _statsSince:0} s, " +
                      $"system used memory {memory}, screen {Screen.width}x{Screen.height}, " +
                      $"target frame rate {Application.targetFrameRate}, quality level {QualitySettings.GetQualityLevel()}");
            _frames = 0;
            _statsSince = now;
        }
    }
}
