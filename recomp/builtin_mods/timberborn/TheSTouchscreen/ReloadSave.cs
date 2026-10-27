// "Reload save now" (iPad): the Mobile UI toggle's way to apply "off" at once. Turning the layout
// off applies when a save loads (TouchLayout), so the button saves the running game and loads that
// save, through the game's own saver and its validating loader (the Load menu's path). It saves to
// the save the game was loaded from; after a new game never saved, or one loaded from an autosave,
// to the name the game's Save box would offer (SaveNameProvider: the settlement's name, numbered
// when taken). The save is written at once, like the game's exit autosave, so that a failure can
// be shown (the game's message box) and nothing is loaded.
using System;
using System.Linq;
using Timberborn.Common;
using Timberborn.CoreUI;
using Timberborn.GameSaveRepositorySystem;
using Timberborn.GameSaveRepositorySystemUI;
using Timberborn.GameSaveRuntimeSystem;
using Timberborn.GameSaveRuntimeSystemUI;
using Timberborn.SettlementNameSystem;
using Timberborn.SingletonSystem;
using UnityEngine;
using UnityEngine.UIElements;

namespace Recomp.TheSTouchscreen
{
    public class ReloadSave : ILoadableSingleton, IUnloadableSingleton
    {
        static ReloadSave _current;  // in a game

        readonly GameSaver _gameSaver;
        readonly GameLoader _gameLoader;
        readonly GameSaveRepository _gameSaveRepository;
        readonly GameSaveItemFactory _gameSaveItemFactory;
        readonly SaveNameProvider _saveNameProvider;
        readonly SettlementReferenceService _settlementReferenceService;
        readonly ValidatingGameLoader _validatingGameLoader;
        readonly DialogBoxShower _dialogBoxShower;

        public ReloadSave(GameSaver gameSaver, GameLoader gameLoader, GameSaveRepository gameSaveRepository,
                          GameSaveItemFactory gameSaveItemFactory, SaveNameProvider saveNameProvider,
                          SettlementReferenceService settlementReferenceService,
                          ValidatingGameLoader validatingGameLoader, DialogBoxShower dialogBoxShower)
        {
            _gameSaver = gameSaver;
            _gameLoader = gameLoader;
            _gameSaveRepository = gameSaveRepository;
            _gameSaveItemFactory = gameSaveItemFactory;
            _saveNameProvider = saveNameProvider;
            _settlementReferenceService = settlementReferenceService;
            _validatingGameLoader = validatingGameLoader;
            _dialogBoxShower = dialogBoxShower;
        }

        public void Load() => _current = this;

        public void Unload()
        {
            if (_current == this) _current = null;
        }

        /// Shown in a game while the layout is on but the choice is now off.
        internal static bool Wanted => _current != null && TouchLayout.On && !TouchLayout.Chosen;

        internal static Button CreateButton()
        {
            var button = new Button(() => _current?.SaveAndLoad()) { text = "Reload save now", name = "TheSTouchscreenReloadSave" };
            button.AddToClassList("menu-button");
            button.AddToClassList("menu-button--medium");
            Update(button);
            return button;
        }

        internal static void Update(VisualElement button) =>
            button.style.display = Wanted ? DisplayStyle.Flex : DisplayStyle.None;

        void SaveAndLoad()
        {
            var settlement = _settlementReferenceService.SettlementReference;
            var loaded = _gameLoader.LoadedSave;
            var save = loaded != null && loaded.SettlementReference == settlement
                       && !loaded.SaveName.EndsWith(GameSaveRepository.AutosaveNameSuffix, StringComparison.Ordinal)
                ? loaded
                : new SaveReference(_saveNameProvider.GetDefaultSaveName(
                      _gameSaveItemFactory.CreateForSettlement(settlement).Where(s => !s.IsAutosave).ToList().AsReadOnlyList()), settlement);
            if (_gameSaveRepository.NameIsInvalid(save.SaveName) || _gameSaveRepository.NameIsInvalid(settlement.SettlementName))
            {
                Fail($"name validation failed for {save}");
                return;
            }
            try
            {
                _gameSaver.SaveInstantlySkippingNameValidation(save, null);
            }
            catch (GameSaverException e)
            {
                Fail($"saving {save} failed: {e.InnerException?.Message ?? e.Message}");
                return;
            }
            Debug.Log($"[TheSTouchscreen] reload save now: saved {save}, loading it");
            _validatingGameLoader.LoadGame(save);
        }

        void Fail(string why)
        {
            Debug.LogWarning("[TheSTouchscreen] reload save now: " + why + "; not loading");
            _dialogBoxShower.Create().SetLocalizedMessage("Saving.Error").Show();
        }
    }
}
