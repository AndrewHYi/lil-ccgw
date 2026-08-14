import SwiftUI

@main
struct LilCcgwApp: App {
    @State private var model = GatewayModel()
    @AppStorage(DefaultsKey.titleMode) private var titleModeRaw = TitleMode.spendOfLimit.rawValue

    init() {
        UserDefaults.registerLilCcgwDefaults()
        Notifier.requestAuthorizationIfNeeded()
    }

    private var titleMode: TitleMode {
        TitleMode.resolve(titleModeRaw)
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            // MenuBarTitle reads the model inside its own body, which is what
            // registers the @Observable dependency and keeps the title live.
            MenuBarTitle(model: model, mode: titleMode)
                .task { model.start() }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }

        Window("lil-ccgw Help", id: "help") {
            HelpView()
        }
    }
}
