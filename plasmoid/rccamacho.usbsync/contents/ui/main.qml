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
    property bool pendingComputing: false
    property var pendingMap: ({})      // pair_id -> {pending, n, error}

    ListModel { id: pairs }            // {id, source, dest_rel, del, last_ts, last_ok, last_files}

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
            // pares configurados (con su última sync por par)
            pairs.clear()
            var pl = d.pairs || []
            for (var i = 0; i < pl.length; i++) {
                var o = pl[i]
                var ls = o.last_sync
                pairs.append({
                    id: o.id, source: o.source, dest_rel: o.dest_rel, del: !!o.delete,
                    last_ts: ls ? ls.ts : "", last_ok: ls ? ls.ok === true : true,
                    last_files: ls ? (ls.files || 0) : 0
                })
            }
        })
    }

    function refreshPending() {
        apiGet("/api/pending", function(d) {
            if (!d) return
            root.pendingComputing = d.computing === true
            root.pendingMap = d.pairs || {}
        })
    }

    // ---- badges de cambios pendientes por par ----
    function badgeState(id) {
        if (root.syncRunning) return "sync"
        if (!root.ssdConnected) return "off"
        if (root.pendingComputing) return "calc"
        var e = root.pendingMap ? root.pendingMap[id] : null
        if (!e) return "off"
        if (e.error) return "err"
        if (e.pending === true) return "pend"
        if (e.pending === false) return "ok"
        return "off"
    }
    function badgeText(id) {
        var s = root.badgeState(id)
        if (s === "pend") {
            var e = root.pendingMap[id]
            return "⚠ " + e.n
        }
        if (s === "ok") return "✓"
        if (s === "calc") return "…"
        if (s === "err") return "?"
        if (s === "off") return "—"
        if (s === "sync") return "⇄"
        return ""
    }
    function badgeBg(id) {
        var s = root.badgeState(id)
        if (s === "pend") return "#3d2a0a"
        if (s === "ok") return "#0a3d1a"
        return "#12202a"
    }
    function badgeFg(id) {
        var s = root.badgeState(id)
        if (s === "pend") return root.cAmber
        if (s === "ok") return root.cGreen
        if (s === "calc" || s === "err") return root.cTextMed
        return root.cTextDim
    }
    function pairLastText(ts, ok, files) {
        if (!ts) return "Sin sincronizar todavía"
        var f = files > 0 ? (" · " + files + " arch") : ""
        return (ok ? "Última: " : "Falló: ") + ts + f
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

    // cambios pendientes: solo mientras el panel está expandido
    Timer {
        id: pendingTimer
        interval: 5000
        repeat: true
        running: root.expanded
        onTriggered: refreshPending()
    }
    onExpandedChanged: {
        if (root.expanded) root.refreshPending()
    }

    Component.onCompleted: refreshStatus()

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

            // ---------- pares configurados (solo lectura) ----------
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 24
                Layout.leftMargin: 14
                Layout.rightMargin: 14
                Layout.topMargin: 6
                visible: root.backendUp && pairs.count > 0
                PlasmaComponents3.Label {
                    text: "PARES CONFIGURADOS  ·  " + pairs.count
                    font.pixelSize: 9
                    font.weight: Font.DemiBold
                    color: root.cTextDim
                }
            }

            ListView {
                id: pairList
                Layout.fillWidth: true
                Layout.preferredHeight: contentHeight
                Layout.leftMargin: 10
                Layout.rightMargin: 10
                visible: pairs.count > 0
                clip: true
                model: pairs
                spacing: 2
                interactive: false

                delegate: Rectangle {
                    width: pairList.width - 20
                    height: 42
                    radius: 4
                    color: root.cPanel

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 8
                        anchors.rightMargin: 8
                        anchors.topMargin: 4
                        anchors.bottomMargin: 3
                        spacing: 1
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6
                            PlasmaComponents3.Label {
                                text: model.source
                                Layout.fillWidth: true
                                elide: Text.ElideMiddle
                                font.pixelSize: 11
                                color: root.cText
                            }
                            PlasmaComponents3.Label {
                                text: "→"
                                font.pixelSize: 11
                                color: root.cTextDim
                            }
                            PlasmaComponents3.Label {
                                text: model.dest_rel
                                Layout.fillWidth: true
                                elide: Text.ElideMiddle
                                font.pixelSize: 11
                                color: root.cTextMed
                            }
                            Item {
                                Layout.preferredWidth: badgeLabel.implicitWidth + 12
                                Layout.preferredHeight: 16
                                Rectangle {
                                    anchors.fill: parent
                                    radius: 8
                                    color: root.badgeBg(model.id)
                                    border.color: root.cBorder
                                    border.width: 1
                                }
                                PlasmaComponents3.Label {
                                    id: badgeLabel
                                    anchors.centerIn: parent
                                    text: root.badgeText(model.id)
                                    font.pixelSize: 9
                                    font.weight: Font.DemiBold
                                    color: root.badgeFg(model.id)
                                }
                            }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6
                            PlasmaComponents3.Label {
                                text: root.pairLastText(model.last_ts, model.last_ok, model.last_files)
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                font.pixelSize: 9
                                color: model.last_ok ? root.cTextDim : root.cRed
                            }
                            PlasmaComponents3.Label {
                                text: model.del ? "espejo exacto" : ""
                                font.pixelSize: 9
                                color: root.cTextDim
                                opacity: 0.7
                            }
                        }
                    }
                }
            }

            // ---------- placeholder sin pares ----------
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 34
                visible: pairs.count === 0 && root.backendUp
                PlasmaComponents3.Label {
                    anchors.centerIn: parent
                    text: "Sin pares — añádelos en Configurar → Pares"
                    font.pixelSize: 11
                    color: root.cTextDim
                    opacity: 0.9
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
