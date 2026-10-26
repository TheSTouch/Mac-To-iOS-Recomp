// The game's field of view, upright on an iPhone. Unity's fieldOfView is vertical, so a game made
// for landscape shows a narrow slice of the world on a tall screen (Valheim's 65° is about 33°
// across). Upright only, each perspective camera that draws to the screen is widened so that the
// view is as wide across as the game's value is tall (or the profile's "portrait_horizontal_fov"),
// and the game keeps reading its own fieldOfView. Orthographic cameras and cameras that draw into
// a texture (a minimap, reflections) are left alone.
//
// Two levers, so that the picture and the game's own screen maths agree:
//   - while the camera renders (Camera.onPreCull / onPostRender, or a scriptable pipeline's
//     begin/endCameraRendering), its fieldOfView is ours, so culling, LODs, shadows and an
//     anti-aliasing jitter that reads fieldOfView all see the wide view; then the game's is put back;
//   - between renders, from the start of each frame's Update, its projectionMatrix is a wide one
//     of its own, so WorldToScreenPoint / ScreenPointToRay in the game's Update and LateUpdate
//     (Valheim's enemy health bars, damage numbers, chat bubbles) match what is on the screen.
// Each orientation change logs, once per camera, the values applied ("[recomp] portrait camera").
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.LowLevel;
using UnityEngine.Rendering;

namespace Recomp
{
    static class PortraitCamera
    {
        static float _across;                  // degrees across upright; 0: the game's own value
        // Cameras widened since the last orientation change, and, while one renders, the game's value.
        static readonly HashSet<Camera> _widened = new HashSet<Camera>();
        static readonly Dictionary<Camera, float> _rendering = new Dictionary<Camera, float>();
        static readonly HashSet<Camera> _logged = new HashSet<Camera>();
        static readonly List<Camera> _gone = new List<Camera>();
        static int _frame = -1;
        static bool _upright, _wasUpright;

        public static void Install(float horizontalFov)
        {
            _across = horizontalFov > 0f && horizontalFov < 179f ? horizontalFov : 0f;
            Camera.onPreCull += Widen;
            Camera.onPostRender += Restore;
            RenderPipelineManager.beginCameraRendering += (_, camera) => Widen(camera);
            RenderPipelineManager.endCameraRendering += (_, camera) => Restore(camera);

            var loop = PlayerLoop.GetCurrentPlayerLoop();
            for (var i = 0; i < loop.subSystemList.Length; i++)
            {
                if (loop.subSystemList[i].type != typeof(UnityEngine.PlayerLoop.Update)) continue;
                var systems = new List<PlayerLoopSystem>(loop.subSystemList[i].subSystemList ?? new PlayerLoopSystem[0]);
                systems.Insert(0, new PlayerLoopSystem { type = typeof(PortraitCamera), updateDelegate = BeforeUpdate });
                loop.subSystemList[i].subSystemList = systems.ToArray();
            }
            PlayerLoop.SetPlayerLoop(loop);
        }

        static bool Upright()
        {
            if (_frame == Time.frameCount) return _upright;
            _frame = Time.frameCount;
            _upright = PhoneSettings.Upright();
            if (_upright != _wasUpright)
            {
                _wasUpright = _upright;
                _logged.Clear();
                if (!_upright) Debug.Log("[recomp] portrait camera: landscape, the game's own field of view");
            }
            return _upright;
        }

        static bool Applies(Camera camera) =>
            camera != null && !camera.orthographic && camera.targetTexture == null && camera.cameraType == CameraType.Game &&
            camera.aspect > 0f && camera.aspect < 1f;

        // The vertical field of view that shows the wanted width at this aspect.
        static float Tall(Camera camera, float game)
        {
            var across = _across > 0f ? _across : game;
            return Mathf.Min(170f, 2f * Mathf.Atan(Mathf.Tan(across * 0.5f * Mathf.Deg2Rad) / camera.aspect) * Mathf.Rad2Deg);
        }

        static void BeforeUpdate()
        {
            if (_widened.Count == 0) return;
            var upright = Upright();
            foreach (var camera in _widened)
            {
                if (camera == null)
                {
                    _gone.Add(camera);
                    continue;
                }
                if (upright && Applies(camera))
                {
                    var tall = Tall(camera, camera.fieldOfView);
                    camera.projectionMatrix = Matrix4x4.Perspective(tall, camera.aspect, camera.nearClipPlane, camera.farClipPlane);
                }
                else
                {
                    camera.ResetProjectionMatrix();
                    _gone.Add(camera);
                }
            }
            foreach (var camera in _gone) _widened.Remove(camera);
            _gone.Clear();
        }

        static void Widen(Camera camera)
        {
            if (!Applies(camera) || !Upright()) return;
            // The game's value, unless a render without its post-render left ours in place.
            var game = _rendering.TryGetValue(camera, out var left) ? left : camera.fieldOfView;
            var tall = Tall(camera, game);
            _rendering[camera] = game;
            _widened.Add(camera);
            camera.ResetProjectionMatrix();
            camera.fieldOfView = tall;
            if (_logged.Add(camera))
                Debug.Log($"[recomp] portrait camera: {camera.name}: the game's {game:0.#}° tall -> {tall:0.#}° tall, " +
                          $"{(_across > 0f ? _across : game):0.#}° across (aspect {camera.aspect:0.000}" +
                          (_across > 0f ? ", portrait_horizontal_fov)" : ")"));
        }

        static void Restore(Camera camera)
        {
            if (camera == null || !_rendering.TryGetValue(camera, out var game)) return;
            _rendering.Remove(camera);
            camera.fieldOfView = game;
        }
    }
}
