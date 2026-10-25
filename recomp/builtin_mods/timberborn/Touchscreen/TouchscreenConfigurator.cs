// The Touchscreen mod: the Timberborn side of the iOS port's touch controls. The port's
// shim (Recomp.TouchMouse) turns touches into the mouse in every Unity game; this mod
// tells it when a building is being placed and adds Place and Rows to the game's
// placement panel (see Recomp.Placement). Further touch tweaks of the game's UI go here.
using Bindito.Core;

namespace Recomp.Touchscreen
{
    [Context("Game")]
    public class TouchscreenConfigurator : IConfigurator
    {
        public void Configure(IContainerDefinition containerDefinition)
        {
            containerDefinition.Bind<PlacementButtons>().AsSingleton();
        }
    }
}
