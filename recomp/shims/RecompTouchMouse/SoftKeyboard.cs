// Lets TextMeshPro input fields open the iOS on-screen keyboard. Desktop games
// often set TMP_InputField.shouldHideSoftKeyboard (Valheim does, in its
// GuiInputField.Awake), which on a device without a keyboard leaves text
// fields such as a character name impossible to fill in. Found by reflection,
// so games without TextMeshPro are left alone.
//
// A field can also lose the keyboard as it opens: when a game answers an input
// device change by clearing the UI selection (Valheim's BuildUi does, on ZInput's
// OnInputLayoutChanged, which a device's ConfigurationChanged raises), the
// selection is dropped and TMP closes the keyboard. iOS reports such a change as
// the keyboard opens and as it closes. A focused field that loses the selection to
// nothing within RestoreSeconds of one is selected again, once until it is left;
// if its keyboard had just been closed with Done, the field is submitted instead,
// which TMP no longer does once the selection is gone.
using System;
using System.Reflection;
using UnityEngine;
using UnityEngine.Events;
using UnityEngine.EventSystems;
using UnityEngine.InputSystem;
using Object = UnityEngine.Object;

namespace Recomp
{
    static class SoftKeyboard
    {
        const float ScanSeconds = 1f;
        const float RestoreSeconds = 0.5f;

        static Type _field;
        static PropertyInfo _hide, _focused, _text, _onSubmit;
        static FieldInfo _softKeyboard;
        static MethodInfo _activate, _deactivate;
        static bool _resolved;
        static float _nextScan;
        static GameObject _lastSelected;
        static Component _editing;            // the field that was focused last frame
        static TouchScreenKeyboard _keyboard; // and its keyboard
        static Component _restored;           // selected again once already, until it is left
        static float _deviceChangedAt = -1f;

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
            _text = _field.GetProperty("text");
            _onSubmit = _field.GetProperty("onSubmit");
            _softKeyboard = _field.GetField("m_SoftKeyboard", BindingFlags.NonPublic | BindingFlags.Instance);
            if (_hide == null || _focused == null || _activate == null || _deactivate == null || _text == null || _onSubmit == null)
            {
                Debug.Log("[recomp] TMP_InputField found without the expected members; soft keyboard left as is");
                _field = null;
                return false;
            }
            InputSystem.onDeviceChange += (device, change) =>
            {
                if (change == InputDeviceChange.ConfigurationChanged) _deviceChangedAt = Time.realtimeSinceStartup;
                Debug.Log($"[recomp] input device {device.name}: {change}");
            };
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
                var was = _lastSelected;
                _lastSelected = selected;
                var field = FieldOf(selected);
                if (field != null) Allow(field);
                if (_editing != null && was == _editing.gameObject)
                {
                    bool deviceChange = _deviceChangedAt >= 0f && now - _deviceChangedAt < RestoreSeconds;
                    var status = _keyboard != null ? _keyboard.status : (TouchScreenKeyboard.Status?)null;
                    Debug.Log($"[recomp] soft keyboard: {was.name} lost the selection to {(selected != null ? selected.name : "nothing")}" +
                              (deviceChange ? $", {now - _deviceChangedAt:0.00} s after an input device change" : "") +
                              (status != null ? $", keyboard {status}" : ""));
                    if (selected == null && deviceChange && status == TouchScreenKeyboard.Status.Done)
                    {
                        Debug.Log($"[recomp] soft keyboard: {was.name} submitted");
                        var text = _keyboard.text ?? (string)_text.GetValue(_editing);
                        _text.SetValue(_editing, text);
                        ((UnityEvent<string>)_onSubmit.GetValue(_editing))?.Invoke(text);
                    }
                    else if (selected == null && deviceChange && status != TouchScreenKeyboard.Status.Canceled
                             && _restored != _editing && _editing.gameObject.activeInHierarchy)
                    {
                        _restored = _editing;
                        EventSystem.current.SetSelectedGameObject(_editing.gameObject);
                        _activate.Invoke(_editing, null);
                        Debug.Log($"[recomp] soft keyboard: {was.name} selected again");
                        return;
                    }
                }
                if (field == null) _restored = null;
            }
            var focused = FieldOf(selected);
            _editing = focused != null && (bool)_focused.GetValue(focused) ? focused : null;
            if (_editing == null) _keyboard = null;
            else if (_softKeyboard?.GetValue(_editing) is TouchScreenKeyboard k) _keyboard = k;
            if (now < _nextScan) return;
            _nextScan = now + ScanSeconds;
            foreach (var field in Object.FindObjectsByType(_field, FindObjectsInactive.Include, FindObjectsSortMode.None))
                Allow(field);
        }

        static Component FieldOf(GameObject selected) => selected != null ? selected.GetComponent(_field) : null;

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
