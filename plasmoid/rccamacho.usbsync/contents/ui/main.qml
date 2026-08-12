import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as Controls
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasmoid 2.0
import org.kde.plasma.components as PlasmaComponents3

PlasmoidItem {
    id: root

    // Paleta oscura fija (patrón JARVIS — Kirigami.Theme no aplica el color scheme)
    readonly property color cBG:      "#00060a"
    readonly property color cPanel:   "#010d14"
    readonly property color cBorder:  "#0d3347"
    readonly property color cPri:     "#00d4ff"
    readonly property color cGreen:   "#00ff88"
    readonly property color cRed:     "#ff3366"
    readonly property color cAmber:   "#f5a623"
    readonly property color cText:    "#8ffcff"
    readonly property color cTextDim: "#3a8a9a"
    readonly property color cTextMed: "#5ab8cc"

    property string apiUrl: "http://127.0.0.1:8135"
    property bool backendUp: false
    property bool ssdConnected: false
    property bool ssdAmbiguous: false
    property string ssdLabel: ""
    property string ssdMount: ""
    property string ssdLabelCfg: ""
    property bool syncRunning: false
    property string syncPct: ""
    property string syncPctGlobal: ""
    property string syncPairInfo: ""
    property string syncLastLine: ""
    property string lastSyncText: "Sin sincronizaciones todavía"
    property bool lastSyncOk: true

    // ---- estado del formulario (propiedades root — los ids del form viven
    // dentro de fullRepresentation y NO son visibles desde funciones root) ----
    property string formMode: "add"     // "add" | "edit"
    property string formId: ""
    property bool formVisible: false
    property string formSource: ""
    property string formDest: ""
    property bool formDel: false
    property int currentRow: -1

    // ---- bridge para closures (picker de carpetas) ----
    property var pendingPick: null      // {field, path}
    onPendingPickChanged: {
        if (!pendingPick) return
        if (pendingPick.field === "source")
            root.formSource = pendingPick.path
        else
            root.formDest = pendingPick.path
        pendingPick = null
    }

    ListModel { id: pairs }

    // ---- API helpers ----
    function apiGet(path, cb) {
        var x = new XMLHttpRequest()
        x.open("GET", root.apiUrl + path)
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
        x.open("POST", root.apiUrl + path)
        x.setRequestHeader("Content-Type", "application/json")
        x.timeout = 90000   // el picker de carpeta puede tardar
        x.onreadystatechange = function() {
            if (x.readyState === XMLHttpRequest.DONE) {
                if (x.status === 200) { try { cb(JSON.parse(x.responseText)) } catch(e) { cb(null) } }
                else cb(null)
            }
        }
        x.send(JSON.stringify(data || {}))
    }

    // ---- estado ----
    function refreshStatus() {
        apiGet("/api/status", function(d) {
            if (!d) { root.backendUp = false; return }
            root.backendUp = true
            root.ssdConnected = d.ssd && d.ssd.connected === true
            root.ssdAmbiguous = d.ssd && d.ssd.ambiguous === true
            root.ssdLabel = d.ssd ? (d.ssd.label || "") : ""
            root.ssdMount = d.ssd ? (d.ssd.mount || "") : ""
            root.ssdLabelCfg = d.ssd_label_cfg || ""
            root.syncRunning = d.sync && d.sync.running === true
            root.syncPct = d.sync && d.sync.pct ? d.sync.pct : ""
            root.syncPctGlobal = d.sync && d.sync.pct_global != null ? d.sync.pct_global : ""
            var idx = d.sync && d.sync.pair_index != null ? d.sync.pair_index : 0
            var tot = d.sync && d.sync.pairs_total ? d.sync.pairs_total : 0
            root.syncPairInfo = tot > 0 ? ("Par " + (idx + 1) + " de " + tot) : ""
            root.syncLastLine = d.sync && d.sync.last_line ? d.sync.last_line : ""
            if (d.last_sync) {
                root.lastSyncOk = d.last_sync.ok === true
                root.lastSyncText = d.last_sync.ts + "  ·  " + d.last_sync.msg
            } else {
                root.lastSyncText = "Sin sincronizaciones todavía"
                root.lastSyncOk = true
            }
        })
    }

    function refreshPairs() {
        apiGet("/api/pairs", function(d) {
            if (!d || !d.pairs) return
            pairs.clear()
            for (var i = 0; i < d.pairs.length; i++) {
                var o = d.pairs[i]
                pairs.append({id: o.id, source: o.source, dest_rel: o.dest_rel, del: !!o.delete})
            }
            // si editábamos un par que ya no existe, volver a modo añadir
            if (root.formMode === "edit") {
                var found = false
                for (var j = 0; j < pairs.count; j++)
                    if (pairs.get(j).id === root.formId) { found = true; break }
                if (!found) resetForm()
            }
        })
    }

    function resetForm() {
        root.formMode = "add"
        root.formId = ""
        root.formVisible = false
        root.formSource = ""
        root.formDest = ""
        root.formDel = false
        root.currentRow = -1
    }

    function showAddForm() {
        resetForm()
        root.formMode = "add"
        root.formVisible = true
    }

    function selectPair(index) {
        if (index < 0 || index >= pairs.count) return
        var p = pairs.get(index)
        root.formMode = "edit"
        root.formId = p.id
        root.formSource = p.source
        root.formDest = p.dest_rel
        root.formDel = p.del
        root.currentRow = index
        root.formVisible = true
    }

    function saveForm() {
        var source = root.formSource.trim()
        var dest = root.formDest.trim()
        if (!source) return
        var payload = {source: source, dest_rel: dest, delete: root.formDel}
        if (root.formMode === "edit") payload.id = root.formId
        apiPost("/api/pairs", payload, function(d) {
            if (d && d.ok) { resetForm(); refreshPairs() }
        })
    }

    function deletePair(index) {
        var p = pairs.get(index)
        apiPost("/api/pairs/delete", {id: p.id}, function(){ refreshPairs() })
    }

    function pickFolder(start, field) {
        apiPost("/api/pick_folder", {start: start || "", field: field || "source"}, function(d) {
            if (d && d.picked) root.pendingPick = {field: field, path: d.picked}
        })
    }

    function syncNow() { apiPost("/api/sync", {}, function(){ refreshStatus() }) }
    function stopSync() { apiPost("/api/sync/stop", {}, function(){ refreshStatus() }) }

    // ---- polling ----
    Timer {
        interval: 2000
        repeat: true
        running: true
        onTriggered: refreshStatus()
    }

    Component.onCompleted: { refreshStatus(); refreshPairs() }

    // ============================================================
    //  ICONO DEL PANEL
    // ============================================================
    compactRepresentation: Item {
        Layout.minimumWidth: root.syncRunning ? 56 : 28
        Layout.minimumHeight: 28

        RowLayout {
            anchors.centerIn: parent
            spacing: 4
            Item {
                Layout.preferredWidth: 28
                Layout.preferredHeight: 28
                Kirigami.Icon {
                    id: compactIcon
                    anchors.centerIn: parent
                    source: "drive-removable-media-usb"
                    width: 22
                    height: 22
                    // Animación: el icono gira mientras sincroniza
                    RotationAnimation on rotation {
                        running: root.syncRunning
                        from: 0
                        to: 360
                        duration: 1200
                        loops: Animation.Infinite
                    }
                }
                Rectangle {
                    anchors.right: parent.right
                    anchors.top: parent.top
                    width: 8
                    height: 8
                    radius: 4
                    color: root.syncRunning ? root.cPri
                         : (root.ssdConnected ? root.cGreen : "#777777")
                    border.color: root.cBorder
                    border.width: 1
                }
            }
            PlasmaComponents3.Label {
                text: root.syncPctGlobal !== "" ? root.syncPctGlobal + "%" : ""
                visible: root.syncRunning
                font.pixelSize: 10
                font.weight: Font.DemiBold
                color: root.cPri
            }
        }
        MouseArea {
            anchors.fill: parent
            onClicked: root.expanded = !root.expanded
        }
    }

    // ============================================================
    //  PANEL EXPANDIDO
    // ============================================================
    fullRepresentation: Item {
        implicitWidth: 460
        implicitHeight: mainCol.implicitHeight

        Rectangle { anchors.fill: parent; color: root.cBG }

        ColumnLayout {
            id: mainCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            spacing: 0

            // ---------- header ----------
            Item { Layout.fillWidth: true; Layout.preferredHeight: 44
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 14
                    anchors.rightMargin: 14
                    spacing: 8
                    Kirigami.Icon { source: "drive-removable-media-usb"; Layout.preferredWidth: 22; Layout.preferredHeight: 22 }
                    PlasmaComponents3.Label {
                        text: "Trove · Sincronización USB"
                        font.weight: Font.DemiBold
                        font.pixelSize: 13
                        Layout.fillWidth: true
                    }
                    Rectangle {
                        Layout.preferredWidth: 9; Layout.preferredHeight: 9; radius: 5
                        color: root.syncRunning ? root.cPri
                             : (root.ssdConnected ? root.cGreen
                             : (root.ssdAmbiguous ? root.cAmber : "#777777"))
                    }
                    PlasmaComponents3.Label {
                        text: root.syncRunning ? "Sincronizando"
                             : (root.ssdConnected ? "SSD conectada"
                             : (root.ssdAmbiguous ? "SSD no identificada" : "SSD no detectada"))
                        font.pixelSize: 11
                        color: root.cText
                        opacity: 0.75
                    }
                }
            }

            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1
                color: root.cBorder
                opacity: 0.5 }

            // ---------- aviso backend caído ----------
            Rectangle {
                Layout.fillWidth: true
                visible: !root.backendUp
                color: "#3d0a0a"
                Layout.preferredHeight: 34
                PlasmaComponents3.Label {
                    anchors.fill: parent
                    anchors.leftMargin: 14
                    anchors.rightMargin: 14
                    verticalAlignment: Text.AlignVCenter
                    text: "⚠ Backend no disponible — inicia usbsync.service"
                    font.pixelSize: 11
                    color: "#ff8080"
                }
            }

            // ---------- estado SSD ----------
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: root.ssdConnected ? 30 : 26
                visible: root.backendUp
                PlasmaComponents3.Label {
                    anchors.fill: parent
                    anchors.leftMargin: 14
                    anchors.rightMargin: 14
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideRight
                    text: root.ssdConnected ? ("●  " + root.ssdLabel + "   " + root.ssdMount)
                         : (root.ssdAmbiguous ? "Hay varios dispositivos extraíbles — fija la SSD en Configurar"
                         : (root.ssdLabelCfg ? ("○  " + root.ssdLabelCfg + " no conectada")
                         : "○  Conecta la SSD USB para sincronizar"))
                    font.pixelSize: 11
                    color: root.ssdConnected ? root.cGreen
                         : (root.ssdAmbiguous ? root.cAmber : root.cText)
                    opacity: 0.85
                }
            }

            // ---------- cabecera de tabla ----------
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 24
                Layout.leftMargin: 10
                Layout.rightMargin: 10
                visible: pairs.count > 0
                RowLayout {
                    anchors.fill: parent
                    spacing: 6
                    PlasmaComponents3.Label { text: "ORIGEN"; Layout.fillWidth: true; font.pixelSize: 9; color: root.cTextDim; font.weight: Font.DemiBold }
                    PlasmaComponents3.Label { text: "DESTINO"; Layout.fillWidth: true; font.pixelSize: 9; color: root.cTextDim; font.weight: Font.DemiBold }
                    PlasmaComponents3.Label { text: "ESP"; Layout.preferredWidth: 34; font.pixelSize: 9; color: root.cTextDim; font.weight: Font.DemiBold; horizontalAlignment: Text.AlignHCenter }
                    Item { Layout.preferredWidth: 26 }
                }
            }

            // ---------- tabla de pares (solo lectura, clic = editar) ----------
            ListView {
                id: pairList
                Layout.fillWidth: true
                Layout.preferredHeight: contentHeight
                visible: pairs.count > 0
                clip: true
                model: pairs
                spacing: 2
                leftMargin: 10
                rightMargin: 10
                currentIndex: -1

                delegate: Rectangle {
                    width: pairList.width - 20
                    height: 30
                    radius: 4
                    color: root.currentRow === index ? root.cBorder : root.cPanel
                    border.color: "transparent"
                    border.width: 1

                    // MouseArea DEBAJO del contenido (declarado primero → z-order inferior)
                    MouseArea {
                        anchors.fill: parent
                        onClicked: selectPair(index)
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
                            font.pixelSize: 10
                            color: root.cText
                        }
                        PlasmaComponents3.Label {
                            text: "→ " + model.dest_rel
                            Layout.fillWidth: true
                            elide: Text.ElideMiddle
                            font.pixelSize: 10
                            color: root.cTextMed
                        }
                        PlasmaComponents3.Label {
                            text: model.del ? "✓" : "—"
                            Layout.preferredWidth: 34
                            font.pixelSize: 10
                            color: model.del ? root.cGreen : root.cTextDim
                            horizontalAlignment: Text.AlignHCenter
                        }
                        Controls.Button {
                            Layout.preferredWidth: 26
                            Layout.preferredHeight: 22
                            implicitWidth: 26
                            implicitHeight: 22
                            icon.name: "edit-delete"
                            onClicked: deletePair(index)
                        }
                    }
                }
            }

            // ---------- placeholder sin pares ----------
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 30
                visible: pairs.count === 0 && root.backendUp
                PlasmaComponents3.Label {
                    anchors.centerIn: parent
                    text: "Sin pares todavía — añade el primero abajo"
                    font.pixelSize: 11
                    color: root.cTextDim
                    opacity: 0.9
                }
            }

            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1
                color: root.cBorder
                opacity: 0.5 }

            // ---------- botón añadir (formulario oculto) ----------
            Controls.Button {
                Layout.fillWidth: true
                Layout.leftMargin: 10
                Layout.rightMargin: 10
                Layout.topMargin: 8
                implicitHeight: 30
                visible: root.backendUp && !root.formVisible
                text: "Añadir par"
                icon.name: "list-add"
                onClicked: showAddForm()
            }

            // ---------- formulario añadir/editar (oculto hasta «Añadir par») ----------
            ColumnLayout {
                id: formCol
                Layout.fillWidth: true
                visible: root.formVisible
                spacing: 0

                Item { Layout.fillWidth: true; Layout.preferredHeight: 8 }
                PlasmaComponents3.Label {
                    Layout.leftMargin: 12
                    Layout.rightMargin: 12
                    text: root.formMode === "edit" ? "✏  EDITAR PAR" : "➕  AÑADIR PAR"
                    font.pixelSize: 9
                    font.weight: Font.DemiBold
                    color: root.formMode === "edit" ? root.cAmber : root.cPri
                }
                Item { Layout.preferredHeight: 4 }
                RowLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: 12
                    Layout.rightMargin: 12
                    spacing: 6
                    PlasmaComponents3.Label {
                        text: "Origen"
                        font.pixelSize: 10
                        color: root.cTextDim
                        Layout.preferredWidth: 44
                    }
                    Controls.TextField {
                        id: srcInput
                        Layout.fillWidth: true
                        Layout.preferredHeight: 26
                        font.pixelSize: 11
                        placeholderText: "carpeta del equipo"
                        selectByMouse: true
                        text: root.formSource
                        onTextChanged: root.formSource = text
                    }
                    Controls.Button {
                        Layout.preferredWidth: 28
                        Layout.preferredHeight: 26
                        implicitWidth: 28
                        implicitHeight: 26
                        icon.name: "folder-open"
                        onClicked: pickFolder(srcInput.text, "source")
                    }
                }
                RowLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: 12
                    Layout.rightMargin: 12
                    Layout.topMargin: 4
                    spacing: 6
                    PlasmaComponents3.Label {
                        text: "Destino"
                        font.pixelSize: 10
                        color: root.cTextDim
                        Layout.preferredWidth: 44
                    }
                    Controls.TextField {
                        id: dstInput
                        Layout.fillWidth: true
                        Layout.preferredHeight: 26
                        font.pixelSize: 11
                        placeholderText: "subcarpeta en la SSD"
                        selectByMouse: true
                        text: root.formDest
                        onTextChanged: root.formDest = text
                    }
                    Controls.Button {
                        Layout.preferredWidth: 28
                        Layout.preferredHeight: 26
                        implicitWidth: 28
                        implicitHeight: 26
                        icon.name: "folder-open"
                        onClicked: pickFolder(root.ssdMount || dstInput.text, "dest")
                    }
                }
                RowLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: 12
                    Layout.rightMargin: 12
                    Layout.topMargin: 4
                    spacing: 8
                    Controls.CheckBox {
                        id: delCheck
                        text: "Espejo exacto (--delete)"
                        font.pixelSize: 10
                        checked: root.formDel
                        onToggled: root.formDel = checked
                    }
                    Item { Layout.fillWidth: true }
                    Controls.Button {
                        text: "Cancelar"
                        icon.name: "dialog-cancel"
                        onClicked: resetForm()
                    }
                    Controls.Button {
                        text: "Guardar"
                        icon.name: "document-save"
                        highlighted: true
                        onClicked: saveForm()
                    }
                }
            }

            // ---------- botón sincronizar / detener ----------
            Item { Layout.preferredHeight: 10 }
            Controls.Button {
                Layout.fillWidth: true
                Layout.leftMargin: 10
                Layout.rightMargin: 10
                implicitHeight: 34
                visible: root.backendUp
                enabled: root.ssdConnected
                text: root.syncRunning ? "Detener sincronización" : "Sincronizar ahora"
                icon.name: root.syncRunning ? "process-stop" : "view-refresh"
                highlighted: !root.syncRunning
                onClicked: root.syncRunning ? stopSync() : syncNow()
            }
            PlasmaComponents3.Label {
                Layout.fillWidth: true
                Layout.leftMargin: 10
                Layout.rightMargin: 10
                Layout.topMargin: 3
                visible: root.backendUp && !root.ssdConnected
                text: "Conecta la SSD para habilitar la sincronización"
                font.pixelSize: 10
                color: root.cTextDim
                opacity: 0.9
                horizontalAlignment: Text.AlignHCenter
            }

            // ---------- progreso ----------
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: root.syncRunning ? 44 : 0
                visible: root.syncRunning
                ColumnLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 14
                    anchors.rightMargin: 14
                    anchors.topMargin: 6
                    spacing: 3
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Controls.ProgressBar {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 6
                            from: 0
                            to: 100
                            value: root.syncPctGlobal !== "" ? parseFloat(root.syncPctGlobal) : 0
                        }
                        PlasmaComponents3.Label {
                            text: root.syncPctGlobal !== "" ? root.syncPctGlobal + "%" : ""
                            font.pixelSize: 10
                            color: root.cPri
                        }
                    }
                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        text: root.syncPairInfo + (root.syncLastLine ? "   ·   " + root.syncLastLine : "")
                        elide: Text.ElideRight
                        font.pixelSize: 10
                        color: root.cTextDim
                        opacity: 0.9
                    }
                }
            }

            // ---------- última sincronización ----------
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 30
                visible: root.backendUp && !root.syncRunning
                PlasmaComponents3.Label {
                    anchors.fill: parent
                    anchors.leftMargin: 14
                    anchors.rightMargin: 14
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideRight
                    text: "Última: " + root.lastSyncText
                    font.pixelSize: 10
                    color: root.lastSyncOk ? root.cTextMed : root.cRed
                    opacity: 0.85
                }
            }

            Item { Layout.preferredHeight: 6 }
        }
    }
}
