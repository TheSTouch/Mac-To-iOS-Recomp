// Where the on-screen controls go (TouchPad, KeyButtons). They are laid out in points of an
// iPad's 834-point-high landscape screen, so on an iPad one point is Screen.height / 834
// pixels, as always. An iPhone's screen is half as tall and fingers are not, so a phone counts
// PhoneHeight points instead (bigger points, fewer of them), and keeps the controls inside
// the safe area: clear of the Dynamic Island and the home indicator.
using UnityEngine;

namespace Recomp
{
    static class Layout
    {
        const float PadHeight = 834f, PhoneHeight = 500f;

        public static readonly bool Phone = SystemInfo.deviceModel.StartsWith("iPhone", System.StringComparison.Ordinal);

        /// Pixels per layout point.
        public static float Unit => Screen.height / (Phone ? PhoneHeight : PadHeight);

        /// The part of the screen the controls go in (screen pixels, origin bottom-left):
        /// the whole screen on an iPad, the safe area on a phone.
        public static Rect Area
        {
            get
            {
                var full = new Rect(0, 0, Screen.width, Screen.height);
                if (!Phone) return full;
                var safe = Screen.safeArea;
                // iOS reports the safe area in the display's pixels: after Screen.SetResolution
                // (Recomp.Phone's render scale) it can be larger than the screen.
                if (safe.xMax > Screen.width + 1 || safe.yMax > Screen.height + 1)
                {
                    float w = Display.main.systemWidth, h = Display.main.systemHeight;
                    if ((w > h) != (Screen.width > Screen.height)) (w, h) = (h, w);
                    if (w <= 0 || h <= 0) return full;
                    float sx = Screen.width / w, sy = Screen.height / h;
                    safe = new Rect(safe.x * sx, safe.y * sy, safe.width * sx, safe.height * sy);
                }
                var area = Rect.MinMaxRect(Mathf.Max(0, safe.xMin), Mathf.Max(0, safe.yMin),
                                           Mathf.Min(Screen.width, safe.xMax), Mathf.Min(Screen.height, safe.yMax));
                return area.width > 0 && area.height > 0 ? area : full;
            }
        }
    }
}
