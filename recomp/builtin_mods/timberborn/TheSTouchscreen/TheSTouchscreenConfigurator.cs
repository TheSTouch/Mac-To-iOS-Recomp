// TheSTouchscreen: TheSTouch's mod for Timberborn's iOS port, built into it. The port's shim
// (Recomp.TouchMouse) turns touches into the mouse in every Unity game; in the game scene this
// mod takes the world input over from it (WorldInput, InputPatches), tells it when a building
// is being placed and adds Place and Rows to the game's placement panel (see
// Recomp.Placement), and with its Touch layout (TouchLayout: always on an iPhone, the Mobile UI
// setting on an iPad) lays the HUD out for a small screen (MobileHud) and shows the game's Development
// controls as a touch-sized modal (DevControls). Further touch and
// redesign work on the game's UI goes here.
using Bindito.Core;

namespace Recomp.TheSTouchscreen
{
    [Context("Game")]
    public class TheSTouchscreenConfigurator : IConfigurator
    {
        public void Configure(IContainerDefinition containerDefinition)
        {
            containerDefinition.Bind<TouchLayout>().AsSingleton();
            containerDefinition.Bind<PlacementButtons>().AsSingleton();
            containerDefinition.Bind<MobileHud>().AsSingleton();
            containerDefinition.Bind<WorldInput>().AsSingleton();
            containerDefinition.Bind<DevControls>().AsSingleton();
            containerDefinition.Bind<KeyRow>().AsSingleton();
            containerDefinition.Bind<BarTooltips>().AsSingleton();
            containerDefinition.Bind<ReloadSave>().AsSingleton();
        }
    }
}
