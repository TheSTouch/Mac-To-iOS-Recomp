// Logs what the game's EventSystem sees under the virtual mouse whenever a
// button goes down or up. Desktop games skip clicks and camera drags when
// IsPointerOverGameObject() is true, so a control that does nothing usually
// means something (often an overlay) is reported as UI under the pointer.
// Compiled only for games that ship uGUI (UnityEngine.UI.dll), see the .csproj.
#if RECOMP_UGUI
using System.Collections.Generic;
using System.Text;
using UnityEngine;
using UnityEngine.EventSystems;

namespace Recomp
{
    static class PointerDiagnostics
    {
        static readonly List<RaycastResult> Hits = new List<RaycastResult>();

        public static void Log(string what, Vector2 position, ushort buttons)
        {
            try
            {
                var es = EventSystem.current;
                var sb = new StringBuilder("[recomp] mouse ").Append(what)
                    .Append(" at ").Append(position).Append(" buttons=").Append(buttons);
                if (es == null)
                {
                    Debug.Log(sb.Append(" (no EventSystem)").ToString());
                    return;
                }
                sb.Append(" overUI=").Append(es.IsPointerOverGameObject());
                Hits.Clear();
                es.RaycastAll(new PointerEventData(es) { position = position }, Hits);
                sb.Append(" hits=").Append(Hits.Count);
                for (var i = 0; i < Hits.Count && i < 3; i++)
                    sb.Append(i == 0 ? " [" : ", ").Append(Hits[i].gameObject != null ? Hits[i].gameObject.name : "?")
                      .Append(" via ").Append(Hits[i].module != null ? Hits[i].module.GetType().Name : "?");
                if (Hits.Count > 0) sb.Append(']');
                Debug.Log(sb.ToString());
            }
            catch (System.Exception e)
            {
                Debug.Log("[recomp] pointer diagnostics failed: " + e.Message);
            }
        }
    }
}
#endif
