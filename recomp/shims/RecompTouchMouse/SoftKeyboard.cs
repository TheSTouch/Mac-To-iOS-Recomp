// Lets TextMeshPro input fields open the iOS on-screen keyboard. Desktop games
// often set TMP_InputField.shouldHideSoftKeyboard (Valheim does, in its
// GuiInputField.Awake), which on a device without a keyboard leaves text
// fields such as a character name impossible to fill in. Found by reflection,
// so games without TextMeshPro are left alone.
using System;
using System.Reflection;
using UnityEngine;
using UnityEngine.EventSystems;
using Object = UnityEngine.Object;

namespace Recomp
{
    static class SoftKeyboard
    {
        const float ScanSeconds = 1f;

        static Type _field;
        static PropertyInfo _hide, _focused;
        static MethodInfo _activate, _deactivate;
        static bool _resolved;
        static float _nextScan;
        static GameObject _lastSelected;

        static bool Resolve()
        {
            if (_resolved) return _field != null;
            _resolved = true;
            foreach (var asm in AppDomain.CurrentDomain.GetAssemblies())
            {
                _field = asm.GetType("TMPro.TMP_InputField");
                if (_field != null) break;
            }
            if (_field == null) return false;
            _hide = _field.GetProperty("shouldHideSoftKeyboard");
            _focused = _field.GetProperty("isFocused");
            _activate = _field.GetMethod("ActivateInputField", Type.EmptyTypes);
            _deactivate = _field.GetMethod("DeactivateInputField", new[] { typeof(bool) });
            if (_hide == null || _focused == null || _activate == null || _deactivate == null)
            {
                Debug.Log("[recomp] TMP_InputField found without the expected members; soft keyboard left as is");
                _field = null;
                return false;
            }
            Debug.Log("[recomp] soft keyboard enabled for TextMeshPro input fields");
            return true;
        }

        /// Called from the Input System's dynamic update.
        public static void Update(float now)
        {
            if (!TouchScreenKeyboard.isSupported || !Resolve()) return;
            // The field just tapped may have been created since the last scan.
            var selected = EventSystem.current != null ? EventSystem.current.currentSelectedGameObject : null;
            if (selected != _lastSelected)
            {
                _lastSelected = selected;
                var field = selected != null ? selected.GetComponent(_field) : null;
                if (field != null) Allow(field);
            }
            if (now < _nextScan) return;
            _nextScan = now + ScanSeconds;
            foreach (var field in Object.FindObjectsByType(_field, FindObjectsInactive.Include, FindObjectsSortMode.None))
                Allow(field);
        }

        static void Allow(Object field)
        {
            if (!(bool)_hide.GetValue(field)) return;
            _hide.SetValue(field, false);
            // Already focused without a keyboard: focus it again so TMP opens one.
            if ((bool)_focused.GetValue(field))
            {
                _deactivate.Invoke(field, new object[] { false });
                _activate.Invoke(field, null);
            }
        }
    }
}
