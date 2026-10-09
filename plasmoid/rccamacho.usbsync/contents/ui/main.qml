import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as Controls
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasmoid 2.0
import org.kde.plasma.components as PlasmaComponents3

PlasmoidItem {
    id: root

    // ============================================================
    //  ESTILO — lenguaje visual de LibreLinkUp (theme-aware)
    //  Neutros derivados del tema (se adaptan a claro/oscuro).
    //  Acentos = semántica de estado: verde/ámbar/rojo/azul.
    // ============================================================
    readonly property color cText:   Kirigami.Theme.textColor
    readonly property color cMed:    Qt.alpha(Kirigami.Theme.textColor, 0.80)   // secundario destacado
    readonly property color cDim:    Qt.alpha(Kirigami.Theme.textColor, 0.60)   // pies / captions
    readonly property color cCard:   Qt.alpha(Kirigami.Theme.textColor, 0.05)   // fondo de tarjeta
    readonly property color cBorder: Qt.alpha(Kirigami.Theme.textColor, 0.10)   // borde / track / divisor
    readonly property color cOK:     "#2ecc71"   // verde  — conectado / ok
    readonly property color cWarn:   "#f39c12"   // ámbar  — aviso
    readonly property color cErr:    "#e74c3c"   // rojo   — crítico / caído
    readonly property color cInfo:   "#3498db"   // azul   — acento informativo (sincronización)

    // medidas (escala LibreLinkUp)
    readonly property int rCard:   8
    readonly property int mCard:   10   // margen interno de tarjeta
    readonly property int mMargin: 12   // margen del popup
    readonly property int gSpace:  8    // espaciado entre bloques
    readonly property int fsCap:   10   // caption
    readonly property int fsBody:  11   // cuerpo
    readonly property int fsVal:   22   // valor

    // ---- alias heredados (repintado: conservan los nombres que usa la lógica) ----
    readonly property color cBG:      Kirigami.Theme.backgroundColor
    readonly property color cPanel:   root.cCard
    readonly property color cPri:     root.cInfo
    readonly property color cGreen:   root.cOK
    readonly property color cRed:     root.cErr
    readonly property color cAmber:   root.cWarn
    readonly property color cTextDim: root.cDim
    readonly property color cTextMed: root.cMed
    // backup remoto (SSD -> core-server): tono propio, distinto del azul de la sync local
    readonly property color cRemote:  "#9b59b6"

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
    // estado del backup remoto (SSD -> core-server)
    property bool remoteBackupRunning: false
    property bool lastRemoteOk: true
    property string lastRemoteText: "Sin copia remota todavía"

    // ---- tooltip del icono (hover) ----
    // main = estado del último backup remoto (fecha/hora + resultado)
    // sub  = estado de la sync local / SSD
    // OJO KF6: toolTipMainText/SubText son propiedades DIRECTAS del PlasmoidItem raíz,
    // ya NO cuelgan del objeto Plasmoid adjunto (sintaxis Plasma 5, provoca
    // "Cannot assign to non-existent property").
    toolTipMainText: root.lastRemoteText
    toolTipSubText: root.syncRunning
        ? ("Sincronizando " + (root.syncPctGlobal !== "" ? root.syncPctGlobal + "%" : "…"))
        : (root.ssdConnected ? ("SSD " + root.ssdLabel + " conectada") : "SSD no conectada")

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
            // estado del backup remoto (SSD -> core-server)
            var rb = d.remote_backup || {}
            root.remoteBackupRunning = rb.running === true
            if (rb.running) {
                root.lastRemoteOk = true
                root.lastRemoteText = "Backup remoto EN CURSO" + (rb.pct ? "  " + rb.pct + "%" : "")
            } else if (rb.last_ts) {
                root.lastRemoteOk = rb.last_ok === true
                root.lastRemoteText = (rb.last_ok ? "Copia remota OK" : "Copia remota FALLÓ") + "  ·  " + rb.last_ts
            } else {
                root.lastRemoteOk = true
                root.lastRemoteText = "Sin copia remota todavía"
            }
            // tooltip del icono: main = último backup remoto, sub = sync/SSD (bindings en raíz)
            // (Plasmoid.toolTipMainText/SubText se actualizan por binding, no requiere asignación aquí)
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

    // Lectura ligera de la caché de pendientes (sin forzar dry-run): alimenta
    // el circulito del icono aunque el panel esté cerrado. El backend la
    // refresca periódicamente (cada check_interval_min).
    function refreshPendingLight() {
        apiGet("/api/pending?no_compute=1", function(d) {
            if (!d) return
            root.pendingMap = d.pairs || {}
        })
    }

    // ¿Hay algún par con cambios pendientes?
    function anyPending() {
        var keys = Object.keys(root.pendingMap)
        for (var i = 0; i < keys.length; i++) {
            var e = root.pendingMap[keys[i]]
            if (e && e.pending === true && !e.error) return true
        }
        return false
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
        if (s === "pend") return Qt.rgba(root.cWarn.r, root.cWarn.g, root.cWarn.b, 0.18)
        if (s === "ok")   return Qt.rgba(root.cOK.r, root.cOK.g, root.cOK.b, 0.18)
        return root.cCard
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

    // estado de pendientes del icono (fondo): sin forzar dry-run en cada tick
    Timer {
        id: pendingLightTimer
        interval: 30000
        repeat: true
        running: true
        onTriggered: refreshPendingLight()
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
                Image {
                    id: compactIcon
                    anchors.centerIn: parent
                    source: "../images/trove-usb.svg"
                    sourceSize: Qt.size(22, 22)
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
                    id: statusDot
                    anchors.right: parent.right
                    anchors.top: parent.top
                    width: 8
                    height: 8
                    radius: 4
                    color: root.syncRunning ? root.cPri
                         : (root.remoteBackupRunning ? root.cRemote
                         : (root.anyPending() ? root.cAmber
                         : (root.ssdConnected ? root.cGreen : root.cDim)))
                    border.color: root.cBorder
                    border.width: 1
                    // Pulso violeta mientras corre el backup remoto (distinto del giro cyan de sync)
                    SequentialAnimation on opacity {
                        running: root.remoteBackupRunning
                        loops: Animation.Infinite
                        NumberAnimation { to: 0.25; duration: 450; easing.type: Easing.InOutQuad }
                        NumberAnimation { to: 1.0;  duration: 450; easing.type: Easing.InOutQuad }
                    }
                }
            }
            PlasmaComponents3.Label {
                text: root.syncPctGlobal !== "" ? root.syncPctGlobal + "%" : ""
                visible: root.syncRunning
                font.pixelSize: root.fsCap
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
        implicitHeight: mainCol.implicitHeight + 2 * root.mMargin

        ColumnLayout {
            id: mainCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.leftMargin: root.mMargin
            anchors.rightMargin: root.mMargin
            anchors.topMargin: root.mMargin
            spacing: root.gSpace

            // ---------- header ----------
            RowLayout {
                Layout.fillWidth: true
                spacing: root.gSpace
                Image { source: "../images/trove-usb.svg"; sourceSize: Qt.size(22, 22); Layout.preferredWidth: 22; Layout.preferredHeight: 22 }
                PlasmaComponents3.Label {
                    text: "Trove · Sincronización USB"
                    font.weight: Font.DemiBold
                    font.pixelSize: 14
                    Layout.fillWidth: true
                }
                Rectangle {
                    Layout.preferredWidth: 9; Layout.preferredHeight: 9; radius: 5
                    color: root.syncRunning ? root.cPri
                         : (root.remoteBackupRunning ? root.cRemote
                         : (root.ssdConnected ? root.cGreen
                         : (root.ssdAmbiguous ? root.cAmber : root.cDim)))
                }
                PlasmaComponents3.Label {
                    text: root.remoteBackupRunning ? "Respaldando en core-server"
                         : (root.syncRunning ? "Sincronizando"
                         : (root.ssdConnected ? "SSD conectada"
                         : (root.ssdAmbiguous ? "SSD no identificada" : "SSD no detectada")))
                    font.pixelSize: root.fsBody
                    color: root.cMed
                }
            }

            // ---------- aviso backend caído (caja de estado) ----------
            Rectangle {
                Layout.fillWidth: true
                visible: !root.backendUp
                implicitHeight: backendLabel.contentHeight + 2 * root.mCard
                radius: 6
                color: Qt.rgba(root.cErr.r, root.cErr.g, root.cErr.b, 0.10)
                border.width: 1
                border.color: Qt.alpha(root.cErr, 0.20)
                PlasmaComponents3.Label {
                    id: backendLabel
                    anchors.fill: parent
                    anchors.margins: root.mCard
                    verticalAlignment: Text.AlignVCenter
                    wrapMode: Text.WordWrap
                    text: "⚠ Backend no disponible — inicia usbsync.service"
                    font.pixelSize: root.fsCap
                    color: root.cErr
                }
            }

            // ---------- tarjeta: estado SSD ----------
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: root.ssdConnected ? 52 : 44
                visible: root.backendUp
                radius: root.rCard
                color: root.cCard
                border.width: 1
                border.color: root.cBorder

                RowLayout {
                    anchors.fill: parent
                    anchors.margins: root.mCard
                    spacing: root.gSpace
                    Kirigami.Icon {
                        source: "drive-removable-media"
                        Layout.preferredWidth: 22
                        Layout.preferredHeight: 22
                        opacity: root.ssdConnected ? 1 : 0.5
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 1
                        PlasmaComponents3.Label {
                            text: "UNIDAD SSD"
                            font.pixelSize: root.fsCap
                            font.weight: Font.Medium
                            opacity: 0.6
                        }
                        PlasmaComponents3.Label {
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            text: root.ssdConnected ? ("●  " + root.ssdLabel + "   " + root.ssdMount)
                                 : (root.ssdAmbiguous ? "Hay varios dispositivos extraíbles — fija la SSD en Configurar"
                                 : (root.ssdLabelCfg ? ("○  " + root.ssdLabelCfg + " no conectada")
                                 : "○  Conecta la SSD USB para sincronizar"))
                            font.pixelSize: root.fsBody
                            color: root.ssdConnected ? root.cGreen
                                 : (root.ssdAmbiguous ? root.cAmber : root.cText)
                            opacity: 0.85
                        }
                    }
                }
            }

            // ---------- pares configurados (solo lectura) ----------
            PlasmaComponents3.Label {
                Layout.fillWidth: true
                Layout.leftMargin: 2
                Layout.rightMargin: 2
                Layout.topMargin: 2
                visible: root.backendUp && pairs.count > 0
                text: "PARES CONFIGURADOS  ·  " + pairs.count
                font.pixelSize: root.fsCap
                font.weight: Font.DemiBold
                opacity: 0.6
            }

            ListView {
                id: pairList
                Layout.fillWidth: true
                Layout.preferredHeight: contentHeight
                visible: pairs.count > 0
                clip: true
                model: pairs
                spacing: root.gSpace - 2
                interactive: false

                delegate: Rectangle {
                    width: pairList.width
                    height: 50
                    radius: root.rCard
                    color: root.cCard
                    border.width: 1
                    border.color: root.cBorder

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: root.mCard
                        spacing: 2
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6
                            PlasmaComponents3.Label {
                                text: model.source
                                Layout.fillWidth: true
                                elide: Text.ElideMiddle
                                font.pixelSize: root.fsBody
                                color: root.cText
                            }
                            PlasmaComponents3.Label {
                                text: "→"
                                font.pixelSize: root.fsBody
                                color: root.cDim
                            }
                            PlasmaComponents3.Label {
                                text: model.dest_rel
                                Layout.fillWidth: true
                                elide: Text.ElideMiddle
                                font.pixelSize: root.fsBody
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
                            }
                        }
                    }
                }
            }

            // ---------- placeholder sin pares ----------
            PlasmaComponents3.Label {
                Layout.fillWidth: true
                Layout.topMargin: 2
                visible: pairs.count === 0 && root.backendUp
                text: "Sin pares — añádelos en Configurar → Pares"
                font.pixelSize: root.fsBody
                color: root.cDim
                horizontalAlignment: Text.AlignHCenter
            }

            // ---------- botón sincronizar / detener ----------
            Item { Layout.preferredHeight: 2 }

            Controls.Button {
                Layout.fillWidth: true
                Layout.topMargin: 2
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
                Layout.topMargin: 3
                visible: root.backendUp && !root.ssdConnected
                text: "Conecta la SSD para habilitar la sincronización"
                font.pixelSize: root.fsCap
                color: root.cDim
                horizontalAlignment: Text.AlignHCenter
            }

            // ---------- progreso ----------
            Rectangle {
                Layout.fillWidth: true
                visible: root.syncRunning
                implicitHeight: progCol.implicitHeight + 2 * root.mCard
                radius: root.rCard
                color: root.cCard
                border.width: 1
                border.color: root.cBorder

                ColumnLayout {
                    id: progCol
                    anchors.fill: parent
                    anchors.margins: root.mCard
                    spacing: 4
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: root.gSpace
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 6
                            radius: 3
                            color: root.cBorder
                            Rectangle {
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width * Math.min(1, (root.syncPctGlobal !== "" ? parseFloat(root.syncPctGlobal) : 0) / 100)
                                height: 4
                                radius: 2
                                color: root.cPri
                            }
                        }
                        PlasmaComponents3.Label {
                            text: root.syncPctGlobal !== "" ? root.syncPctGlobal + "%" : ""
                            font.pixelSize: root.fsBody
                            font.weight: Font.DemiBold
                            color: root.cPri
                        }
                    }
                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        text: root.syncPairInfo + (root.syncLastLine ? "   ·   " + root.syncLastLine : "")
                        elide: Text.ElideRight
                        font.pixelSize: root.fsCap
                        color: root.cDim
                    }
                }
            }

            // ---------- última sincronización ----------
            PlasmaComponents3.Label {
                Layout.fillWidth: true
                Layout.leftMargin: 2
                Layout.rightMargin: 2
                Layout.topMargin: root.gSpace
                visible: root.backendUp && !root.syncRunning
                elide: Text.ElideRight
                text: "Última: " + root.lastSyncText
                font.pixelSize: root.fsBody
                color: root.lastSyncOk ? root.cTextMed : root.cRed
            }

            Item { Layout.preferredHeight: 2 }
        }
    }
}
