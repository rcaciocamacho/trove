import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as Controls
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM
import org.kde.plasma.components as PlasmaComponents3

KCM.SimpleKCM {
    id: page

    property string apiUrl: "http://127.0.0.1:8135"
    property bool formVisible: false
    property string formMode: "add"      // "add" | "edit"
    property string formId: ""
    property string statusText: ""

    ListModel { id: pairModel }

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
        x.timeout = 90000   // el picker de carpeta (kdialog) puede tardar
        x.onreadystatechange = function() {
            if (x.readyState === XMLHttpRequest.DONE) {
                if (x.status === 200) { try { cb(JSON.parse(x.responseText)) } catch(e) { cb(null) } }
                else cb(null)
            }
        }
        x.send(JSON.stringify(data || {}))
    }

    function load() {
        apiGet("/api/pairs", function(d) {
            if (!d || !d.pairs) {
                page.statusText = "Backend no disponible (inicia usbsync.service)"
                return
            }
            pairModel.clear()
            for (var i = 0; i < d.pairs.length; i++) {
                var o = d.pairs[i]
                pairModel.append({id: o.id, source: o.source, dest_rel: o.dest_rel, del: !!o.delete})
            }
            page.statusText = ""
        })
    }

    function resetForm() {
        page.formVisible = false
        page.formMode = "add"
        page.formId = ""
        srcField.text = ""
        dstField.text = ""
        delCheck.checked = false
    }

    function showAdd() {
        page.resetForm()
        page.formMode = "add"
        page.formVisible = true
    }

    function selectPair(index) {
        if (index < 0 || index >= pairModel.count) return
        var p = pairModel.get(index)
        page.formMode = "edit"
        page.formId = p.id
        srcField.text = p.source
        dstField.text = p.dest_rel
        delCheck.checked = p.del
        page.formVisible = true
    }

    function saveForm() {
        var source = srcField.text.trim()
        var dest = dstField.text.trim()
        if (!source) { page.statusText = "El origen es obligatorio"; return }
        var payload = {source: source, dest_rel: dest, delete: delCheck.checked}
        if (page.formMode === "edit") payload.id = page.formId
        apiPost("/api/pairs", payload, function(d) {
            if (d && d.ok) {
                page.statusText = "Par guardado ✓"
                page.resetForm()
                page.load()
            } else {
                page.statusText = "Error al guardar — ¿está el backend activo?"
            }
        })
    }

    function deletePair(index) {
        var p = pairModel.get(index)
        apiPost("/api/pairs/delete", {id: p.id}, function(d) {
            page.statusText = d && d.ok ? "Par eliminado ✓" : "Error al eliminar"
            page.load()
        })
    }

    function pickFolder(start, field) {
        apiPost("/api/pick_folder", {start: start || "", field: field || "source"}, function(d) {
            if (!d || !d.picked) return
            if (field === "dest") {
                // destino = subcarpeta en la SSD → usar el nombre de la carpeta elegida
                var p = d.picked
                dstField.text = p.substring(p.lastIndexOf("/") + 1)
            } else {
                srcField.text = d.picked
            }
        })
    }

    Component.onCompleted: load()

    ColumnLayout {
        Layout.fillWidth: true
        spacing: Kirigami.Units.smallSpacing

        PlasmaComponents3.Label {
            text: "Pares de sincronización"
            font.weight: Font.DemiBold
        }

        // ---------- tabla de pares (clic en fila = editar) ----------
        Repeater {
            model: pairModel
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 30
                radius: 4
                color: "#0b1620"
                // MouseArea PRIMERO (z-order inferior) para que los botones reciban clics
                MouseArea {
                    anchors.fill: parent
                    onClicked: page.selectPair(index)
                }
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 8
                    anchors.rightMargin: 4
                    spacing: 6
                    PlasmaComponents3.Label {
                        text: model.source
                        Layout.fillWidth: true
                        elide: Text.ElideMiddle
                        font.pixelSize: 11
                    }
                    PlasmaComponents3.Label {
                        text: "→ " + model.dest_rel
                        Layout.fillWidth: true
                        elide: Text.ElideMiddle
                        font.pixelSize: 11
                        color: Kirigami.Theme.textColor
                        opacity: 0.7
                    }
                    PlasmaComponents3.Label {
                        text: model.del ? "✓" : "—"
                        Layout.preferredWidth: 30
                        font.pixelSize: 11
                        color: model.del ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.textColor
                        horizontalAlignment: Text.AlignHCenter
                    }
                    Controls.Button {
                        Layout.preferredWidth: 26
                        Layout.preferredHeight: 22
                        implicitWidth: 26
                        implicitHeight: 22
                        icon.name: "document-edit"
                        onClicked: page.selectPair(index)
                    }
                    Controls.Button {
                        Layout.preferredWidth: 26
                        Layout.preferredHeight: 22
                        implicitWidth: 26
                        implicitHeight: 22
                        icon.name: "edit-delete"
                        onClicked: page.deletePair(index)
                    }
                }
            }
        }

        PlasmaComponents3.Label {
            Layout.fillWidth: true
            visible: pairModel.count === 0
            text: "Sin pares configurados todavía."
            color: Kirigami.Theme.textColor
            opacity: 0.6
        }

        // ---------- botón añadir ----------
        Controls.Button {
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.smallSpacing
            visible: !page.formVisible
            text: "Añadir par"
            icon.name: "list-add"
            onClicked: page.showAdd()
        }

        // ---------- formulario añadir/editar (oculto hasta «Añadir par») ----------
        ColumnLayout {
            Layout.fillWidth: true
            visible: page.formVisible
            spacing: Kirigami.Units.smallSpacing

            PlasmaComponents3.Label {
                text: page.formMode === "edit" ? "✏  EDITAR PAR" : "➕  AÑADIR PAR"
                font.pixelSize: 12
                font.weight: Font.DemiBold
                color: page.formMode === "edit" ? Kirigami.Theme.neutralTextColor : Kirigami.Theme.highlightColor
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                PlasmaComponents3.Label {
                    text: "Origen"
                    Layout.preferredWidth: 52
                }
                Controls.TextField {
                    id: srcField
                    Layout.fillWidth: true
                    placeholderText: "carpeta del equipo (origen)"
                }
                Controls.Button {
                    Layout.preferredWidth: 30
                    Layout.preferredHeight: 28
                    implicitWidth: 30
                    implicitHeight: 28
                    icon.name: "folder-open"
                    onClicked: page.pickFolder(srcField.text, "source")
                }
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                PlasmaComponents3.Label {
                    text: "Destino"
                    Layout.preferredWidth: 52
                }
                Controls.TextField {
                    id: dstField
                    Layout.fillWidth: true
                    placeholderText: "subcarpeta en la SSD (destino)"
                }
                Controls.Button {
                    Layout.preferredWidth: 30
                    Layout.preferredHeight: 28
                    implicitWidth: 30
                    implicitHeight: 28
                    icon.name: "folder-open"
                    onClicked: page.pickFolder("", "dest")
                }
            }
            Controls.CheckBox {
                id: delCheck
                text: "Espejo exacto (--delete)"
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                Controls.Button {
                    text: "Cancelar"
                    icon.name: "dialog-cancel"
                    onClicked: page.resetForm()
                }
                Controls.Button {
                    text: "Guardar"
                    icon.name: "document-save"
                    highlighted: true
                    onClicked: page.saveForm()
                }
                Item { Layout.fillWidth: true }
            }
        }

        // ---------- recargar + estado ----------
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing
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
            visible: page.statusText.indexOf("Backend") === 0 || page.statusText.indexOf("Error") === 0
            type: Kirigami.MessageType.Error
            text: page.statusText
        }

        PlasmaComponents3.Label {
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.largeSpacing
            text: "Cada par copia una carpeta del equipo a una subcarpeta de la SSD (backup unidireccional). «Espejo exacto» hace que el destino sea una copia idéntica (--delete). El estado de cada par — última sincronización y cambios pendientes — se ve en el panel del plasmoid."
            color: Kirigami.Theme.textColor
            opacity: 0.6
            wrapMode: Text.WordWrap
        }
    }
}
