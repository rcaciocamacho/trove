import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as Controls
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM
import org.kde.plasma.components as PlasmaComponents3

KCM.SimpleKCM {
    id: page

    property string apiUrl: "http://127.0.0.1:8135"
    property string ssdUuid: ""
    property string ssdLabel: ""
    property bool autosync: true
    property bool defaultDelete: false
    property string statusText: ""
    property bool loaded: false

    ListModel { id: deviceModel }

    function apiGet(path, cb) {
        var x = new XMLHttpRequest()
        x.open("GET", page.apiUrl + path)
        x.timeout = 4000
        x.onreadystatechange = function() {
            if (x.readyState === XMLHttpRequest.DONE) {
                if (x.status === 200) { try { cb(JSON.parse(x.responseText)) } catch(e) { cb(null) } }
                else cb(null)
            }
        }
        x.send()
    }

    function apiPost(path, data, cb) {
        var x = new XMLHttpRequest()
        x.open("POST", page.apiUrl + path)
        x.setRequestHeader("Content-Type", "application/json")
        x.timeout = 4000
        x.onreadystatechange = function() {
            if (x.readyState === XMLHttpRequest.DONE) {
                if (x.status === 200) { try { cb(JSON.parse(x.responseText)) } catch(e) { cb(null) } }
                else cb(null)
            }
        }
        x.send(JSON.stringify(data || {}))
    }

    function uuidShort(u) {
        return u.length > 8 ? u.substring(0, 8) : u
    }

    function selectUuid(combo, uuid) {
        for (var i = 0; i < combo.count; i++) {
            if (combo.model.get(i).uuid === uuid) { combo.currentIndex = i; return }
        }
        combo.currentIndex = 0  // "Automático"
    }

    function load() {
        page.loaded = false
        deviceModel.clear()
        deviceModel.append({text: "Automático (única unidad extraíble)", uuid: ""})
        apiGet("/api/devices", function(d) {
            if (d && d.devices) {
                for (var i = 0; i < d.devices.length; i++) {
                    var dev = d.devices[i]
                    var name = dev.label || "(sin label)"
                    var detail = dev.size ? (" · " + dev.size) : ""
                    deviceModel.append({
                        text: name + "  (" + page.uuidShort(dev.uuid) + "…)" + detail,
                        uuid: dev.uuid
                    })
                }
            }
            apiGet("/api/config", function(c) {
                if (!c || !c.config) {
                    page.statusText = "Backend no disponible (inicia usbsync.service)"
                    page.loaded = true
                    return
                }
                page.ssdUuid = c.config.ssd_uuid || ""
                page.autosync = c.config.autosync_on_connect !== false
                page.defaultDelete = c.config.default_delete === true
                selectUuid(deviceCombo, page.ssdUuid)
                page.statusText = ""
                page.loaded = true
            })
        })
    }

    function save() {
        var uuid = deviceCombo.model.get(deviceCombo.currentIndex).uuid
        var label = ""
        for (var i = 0; i < deviceModel.count; i++) {
            if (deviceModel.get(i).uuid === uuid) { label = deviceModel.get(i).text.split("  (")[0]; break }
        }
        apiPost("/api/config", {
            ssd_uuid: uuid,
            ssd_label: label,
            autosync_on_connect: autosyncSwitch.checked,
            default_delete: deleteSwitch.checked
        }, function(d) {
            if (d && d.ok) {
                page.statusText = "Guardado ✓ — SSD objetivo fijada"
                page.load()
            } else {
                page.statusText = "Error al guardar — ¿está el backend activo?"
            }
        })
    }

    Component.onCompleted: load()

    ColumnLayout {
        Layout.fillWidth: true
        spacing: Kirigami.Units.largeSpacing

        Kirigami.FormLayout {
            Layout.fillWidth: true

            Controls.ComboBox {
                id: deviceCombo
                Layout.fillWidth: true
                model: deviceModel
                textRole: "text"
                enabled: page.loaded
                onActivated: page.statusText = ""
            }

            Controls.CheckBox {
                id: autosyncSwitch
                text: "Sincronizar automáticamente al conectar la SSD"
                checked: page.autosync
            }

            Controls.CheckBox {
                id: deleteSwitch
                text: "Espejo exacto por defecto en pares nuevos (--delete)"
                checked: page.defaultDelete
            }
        }

        Kirigami.Separator {
            Layout.fillWidth: true
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            Controls.Button {
                text: "Guardar"
                icon.name: "document-save"
                highlighted: true
                onClicked: page.save()
            }
            Controls.Button {
                text: "Recargar"
                icon.name: "view-refresh"
                onClicked: page.load()
            }
            Item { Layout.fillWidth: true }
            PlasmaComponents3.Label {
                text: page.statusText
                color: Kirigami.Theme.textColor
                opacity: 0.7
                visible: page.statusText !== ""
            }
        }

        Kirigami.InlineMessage {
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.smallSpacing
            visible: page.statusText.indexOf("Backend") === 0 || page.statusText.indexOf("Error") === 0
            type: Kirigami.MessageType.Error
            text: page.statusText
        }

        PlasmaComponents3.Label {
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.largeSpacing
            text: "Selecciona la SSD USB con la que sincronizar. El dispositivo se identifica por su UUID (identificador único de la partición), así que aunque cambies su nombre o label, el plasmoid siempre sabrá cuál es. «Automático» usa la única unidad extraíble montada."
            color: Kirigami.Theme.textColor
            opacity: 0.6
            wrapMode: Text.WordWrap
        }
    }
}
