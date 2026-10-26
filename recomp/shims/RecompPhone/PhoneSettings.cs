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
// The render size follows the orientation: on a game that opts into portrait it is asked
// again in the new order each time the phone turns (unless the engine carried it over), and
// each request is checked once it has applied, since iOS may read the size in the other order.
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
            public bool portrait;              // the iPhone also plays upright
            public float portraitHorizontalFov; // degrees across upright; 0: the game's field of view
        }

        [Serializable]
        class Config { public Phone phone; }

        const float StatsSeconds = 30f;

        static bool _installed;
        // The render size: _scale of the native _long x _short, in the order of the orientation
        // it was asked for (_upright). _turned[upright ? 1 : 0]: in that orientation the request
        // must go in the other order (an iPhone 17 asked for 1966x904 in landscape got 904x1966).
        static float _scale;
        static int _long, _short, _width, _height, _setFrame, _attempts;
        static bool _portrait, _upright, _check, _rotated;
        static readonly bool[] _turned = new bool[2];
        static int _rotatedFrame;
        static float _rotatedTime;
        static ProfilerRecorder _memory;
        static int _frames;
        static float _statsSince;

        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.BeforeSceneLoad)]
        public static void Install()
        {
            if (_installed) return;
            _installed = true;
            // Never upside down; portrait only on the iPhone of a game that opts in (the Info.plist
            // already keeps the iPad to the landscapes: this is the belt).
            Screen.autorotateToPortraitUpsideDown = false;
            if (!SystemInfo.deviceModel.StartsWith("iPhone", StringComparison.Ordinal))
            {
                Screen.autorotateToPortrait = false;
                return;
            }
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
                Screen.autorotateToPortrait = false;
                Debug.Log("[recomp] phone settings: cannot read recomp.json: " + e.Message);
                return;
            }
            if (phone == null)
            {
                Screen.autorotateToPortrait = false;
                Debug.Log("[recomp] phone settings: none in recomp.json");
                return;
            }
            var applied = new List<string> { SystemInfo.deviceModel };
            Screen.autorotateToPortrait = phone.portrait;
            applied.Add(phone.portrait ? "portrait and landscape" : "landscape only");
            if (phone.portrait) PortraitCamera.Install(phone.portraitHorizontalFov);

            if (phone.renderScale > 0f && phone.renderScale < 1f)
            {
                _scale = phone.renderScale;
                _long = Mathf.Max(Screen.width, Screen.height);
                _short = Mathf.Min(Screen.width, Screen.height);
                // A landscape-only game is landscape whatever the screen reports this early.
                _portrait = phone.portrait;
                _upright = _portrait && Upright();
                Request(null);
                SceneManager.sceneLoaded += OnSceneLoaded;
                applied.Add($"render scale {_scale.ToString(CultureInfo.InvariantCulture)} " +
                            $"({_long}x{_short} -> {_width}x{_height}, {Orientation()})");
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
            if (Mathf.Max(Screen.width, Screen.height) != _long || Mathf.Min(Screen.width, Screen.height) != _short)
                return;
            SceneManager.sceneLoaded -= OnSceneLoaded;
            Request($"the game reset the screen to {Screen.width}x{Screen.height} (scene {scene.name})");
        }

        // Whether the view stands upright: the display's own size turns with it (layer bounds,
        // not the render size); the content orientation is the fallback.
        internal static bool Upright()
        {
            var display = Display.main;
            if (display.systemWidth > 0 && display.systemHeight > 0 && display.systemWidth != display.systemHeight)
                return display.systemHeight > display.systemWidth;
            return Screen.orientation == ScreenOrientation.Portrait || Screen.orientation == ScreenOrientation.PortraitUpsideDown;
        }

        // The render size in an orientation's order.
        static (int, int) Wanted(bool upright)
        {
            var wide = Mathf.RoundToInt(_long * _scale);
            var narrow = Mathf.RoundToInt(_short * _scale);
            return upright ? (narrow, wide) : (wide, narrow);
        }

        static string Orientation() => (_upright ? "upright, " : "landscape, ") + Screen.orientation;

        // Asks for the render size in the current orientation's order, turned if that orientation
        // was seen to read it the other way round, and checks it once it has applied.
        static void Request(string why)
        {
            (_width, _height) = Wanted(_upright);
            var turned = _turned[_upright ? 1 : 0];
            var w = turned ? _height : _width;
            var h = turned ? _width : _height;
            Screen.SetResolution(w, h, Screen.fullScreenMode);
            _setFrame = Time.frameCount;
            _check = true;
            if (why != null)
                Debug.Log($"[recomp] phone settings: {why}; render size {_width}x{_height} ({Orientation()})" +
                          (turned ? $", asked as {w}x{h}" : ""));
        }

        // Once the size has applied: if it came out turned, this orientation reads the request the
        // other way round, so ask again turned and keep that for later requests in it.
        static void Check()
        {
            _check = false;
            if (Screen.width == _width && Screen.height == _height)
            {
                if (_attempts > 0)
                    Debug.Log($"[recomp] phone settings: the screen is {Screen.width}x{Screen.height} as asked ({Orientation()})");
                _attempts = 0;
                return;
            }
            if (++_attempts > 3)
            {
                Debug.Log($"[recomp] phone settings: the screen stays {Screen.width}x{Screen.height} instead of " +
                          $"{_width}x{_height} ({Orientation()}); not asking again");
                _attempts = 0;
                return;
            }
            var came = $"the screen came out {Screen.width}x{Screen.height}";
            if (Screen.width == _height && Screen.height == _width)
            {
                var i = _upright ? 1 : 0;
                _turned[i] = !_turned[i];
                came += _turned[i] ? ", turned: asking the other way round" : ", turned: asking in the screen's order again";
            }
            Request(came);
        }

        // The phone turned: once the rotation has settled, ask for the render size in the new order,
        // unless the engine carried it over.
        static void FollowOrientation()
        {
            var upright = _portrait && Upright();
            if (upright != _upright)
            {
                _upright = upright;
                _rotated = true;
                _rotatedFrame = Time.frameCount;
                _rotatedTime = Time.realtimeSinceStartup;
                _check = false;
                _attempts = 0;
                return;
            }
            if (_rotated)
            {
                if (Time.frameCount < _rotatedFrame + 3 || Time.realtimeSinceStartup < _rotatedTime + 0.5f) return;
                _rotated = false;
                if ((Screen.width, Screen.height) == Wanted(_upright))
                {
                    (_width, _height) = (Screen.width, Screen.height);
                    Debug.Log($"[recomp] phone settings: rotated, the render size followed: {_width}x{_height} ({Orientation()})");
                    return;
                }
                Request($"rotated, the screen is {Screen.width}x{Screen.height}");
                return;
            }
            if (_check && Time.frameCount >= _setFrame + 3) Check();
        }

        static void CountFrame()
        {
            if (_scale > 0f) FollowOrientation();
            _frames++;
            var now = Time.realtimeSinceStartup;
            if (now - _statsSince < StatsSeconds) return;
            var memory = _memory.Valid ? (_memory.LastValue >> 20) + " MB" : "unknown";
            Debug.Log($"[recomp] phone stats: {_frames / (now - _statsSince):0.0} fps over the last {now - _statsSince:0} s, " +
                      $"system used memory {memory}, screen {Screen.width}x{Screen.height} ({Screen.orientation}), " +
                      $"target frame rate {Application.targetFrameRate}, quality level {QualitySettings.GetQualityLevel()}");
            _frames = 0;
            _statsSince = now;
        }
    }
}
