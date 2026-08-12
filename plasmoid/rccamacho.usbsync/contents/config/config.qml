import org.kde.plasma.configuration 2.0

ConfigModel {
    ConfigCategory {
        name: i18n("Pares")
        icon: "folder-sync"
        source: "config/configPairs.qml"
    }
    ConfigCategory {
        name: i18n("General")
        icon: "preferences-system"
        source: "config/configGeneral.qml"
    }
}
