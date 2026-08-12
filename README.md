# 💎 Trove — Plasmoid de KDE Plasma 6

> Guarda el tesoro de tus carpetas en una SSD USB. Backups unidireccionales
> (equipo → SSD) con un clic, o automáticos al conectar la unidad.

![Plasma 6](https://img.shields.io/badge/Plasma-6-blue)
![KDE Frameworks](https://img.shields.io/badge/KF-6.28-blue)
![Licencia](https://img.shields.io/badge/Licencia-GPL--2.0-green)

---

## ✨ Características

- 🔁 **Backup unidireccional** por par: carpeta del equipo → subcarpeta en la SSD
- ⚡ **Dos formas de sincronizar**:
  - *Manual*: botón **Sincronizar ahora** en el panel
  - *Auto*: al conectar la SSD USB (configurable)
- 🗂️ **Pares ilimitados**: gestión completa desde Clic derecho → *Configurar → Pares*
  (tabla con alta/edición/borrado y selector de carpetas nativo de KDE)
- ⏳ **Cambios pendientes**: el panel muestra con un badge (⚠ N / ✓ / …) si las carpetas
  del host tienen cambios aún no sincronizados (cálculo con `rsync --dry-run`, caché de 30s)
- 🕐 **Última sincronización por par** en el panel, además del resumen global
- 🔍 **Identificación por UUID**: aunque cambies el nombre de la unidad o tengas varias
  memorias USB conectadas, el plasmoid siempre sabe cuál es la suya
- 📁 **Selector de carpetas nativo de KDE** (KFileWidget — la misma UI de Dolphin) con
  botón Aceptar, o servicio *service menu* de Dolphin como respaldo
- 🪞 **Espejo exacto opcional** (`--delete`) por par
- 📊 **Progreso en vivo**: porcentaje, archivo actual y última sincronización
- 🌑 **Tema oscuro** integrado (paleta fija estilo HUD, coherente en cualquier color scheme)
- 📏 **Altura auto-ajustable** al contenido del panel
- 🔌 **Backend robusto**: si la SSD no está conectada, el panel lo indica sin fallar

---

## 🏗️ Arquitectura

```
┌─────────────────────────────────────────────────────────────┐
│  PLASMOID  rccamacho.usbsync                                │
│  ┌───────────────────────────────────────────────────────┐  │
│  │ Icono panel (estado + % sync)                        │  │
│  │ Popup: pares (solo lectura) · badge pendientes ⚠/✓  │  │
│  │ Última sync por par · Progreso · Botón sincronizar   │  │
│  │ Configurar: pestaña Pares (CRUD) + General (SSD)     │  │
│  └──────────────────────────┬────────────────────────────┘  │
└─────────────────────────────┼───────────────────────────────┘
                              │  HTTP 127.0.0.1:8135 (XMLHttpRequest)
                              ▼
┌─────────────────────────────────────────────────────────────┐
│  BACKEND  usbsync_backend.py  (Python 3 · stdlib · systemd) │
│  • Detección de SSD por UUID (lsblk)                        │
│  • Config JSON en ~/.config/usbsync/config.json             │
│  • rsync -a --partial --info=progress2 --stats [--delete]   │
│  • Selector de carpetas (kdialog / Dolphin service menu)    │
│  • Autosync al conectar (hilo monitor 2s)                   │
│  • Cambios pendientes por par (rsync --dry-run, caché 30s)   │
└─────────────────────────────────────────────────────────────┘
```

---

## 📋 Requisitos

| Paquete | Motivo |
|---------|--------|
| **KDE Plasma 6** (KF 6.x, Qt 6) | Entorno del plasmoid |
| **rsync** | Motor de sincronización |
| **kdialog** | Selector de carpetas nativo |
| **dolphin** | Respaldo del selector (service menu) |
| **python3** (solo stdlib) | Backend |

En Arch/CachyOS:

```bash
sudo pacman -S rsync kdialog dolphin
```

---

## 🚀 Instalación

### 1. Backend

```bash
cp backend/usbsync_backend.py ~/.local/bin/
chmod +x ~/.local/bin/usbsync_backend.py
cp backend/usbsync_pick.sh ~/.local/bin/
chmod +x ~/.local/bin/usbsync_pick.sh
mkdir -p ~/.local/share/kio/servicemenus
cp backend/usbsync-servicemenu.desktop ~/.local/share/kio/servicemenus/usbsync-select.desktop
```

### 2. Servicio systemd (usuario)

```bash
cp service/usbsync.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now usbsync.service
```

> ⚠️ Si tu usuario no es `rccamacho`, ajusta `ExecStart` de `usbsync.service`
> y las rutas de `usbsync-servicemenu.desktop` y `usbsync_pick.sh`.

### 3. Plasmoid

```bash
kpackagetool6 -t Plasma/Applet -i plasmoid/rccamacho.usbsync/
systemctl --user restart plasma-plasmashell.service
```

### 4. Añadir al panel

1. Clic derecho en el panel → **Añadir widgets** → busca **Trove**
2. Arrástralo al panel (el punto del icono muestra el estado: 🟢 SSD conectada, 🔵 sincronizando, ⚪ ausente)
3. El icono muestra los pares configurados (solo lectura) con su badge de cambios
   pendientes y su última sincronización; el botón **Sincronizar ahora** lanza el backup

### 5. Configurar los pares

Clic derecho en el widget → **Configurar** → pestaña **Pares** → **Añadir par** →
elige la carpeta origen del equipo y la subcarpeta destino en la SSD → **Guardar**.

- Clic en una fila para **editar**; el icono 🗑 la **borra**
- El badge del panel indica los cambios no sincronizados: ⚠ N (pendientes), ✓ (al día),
  … (calculando) o — (SSD ausente)

### 6. Fijar la SSD objetivo (opcional pero recomendado)

Clic derecho en el widget → **Configurar** → pestaña **General** → selecciona tu SSD
en el desplegable → **Guardar**. Se identifica por UUID: aunque tengas varias
unidades, siempre será esa.

---

## 🔄 Actualización

```bash
# 1. Copiar el nuevo backend y reiniciar el servicio
cp backend/usbsync_backend.py ~/.local/bin/
systemctl --user restart usbsync.service

# 2. Reinstalar el plasmoid (desde el repo, nunca desde ~/.local/share)
kpackagetool6 -t Plasma/Applet -r rccamacho.usbsync   # desinstala
kpackagetool6 -t Plasma/Applet -i plasmoid/rccamacho.usbsync/
rm -rf ~/.cache/plasmashell/qmlcache/                 # caché QML
systemctl --user restart plasma-plasmashell.service
```

---

## 🔌 API del backend

| Método | Ruta | Descripción |
|--------|------|-------------|
| GET | `/api/status` | Estado completo (SSD, sync en curso, última sincronización) |
| GET | `/api/pairs` | Lista de pares configurados |
| GET | `/api/devices` | Dispositivos extraíbles detectados (label, UUID, mount) |
| GET | `/api/config` | Configuración actual |
| GET | `/api/log` | Últimas 40 líneas del log |
| GET | `/api/pending` | Cambios pendientes por par (`{pair_id: {pending, n, error}}`, caché 30s) |
| POST | `/api/pairs` | Añadir/actualizar par `{id?, source, dest_rel, delete}` |
| POST | `/api/pairs/delete` | Borrar par `{id}` |
| POST | `/api/config` | Guardar config `{ssd_uuid, ssd_label, autosync_on_connect, default_delete}` |
| POST | `/api/sync` | Lanzar sincronización de todos los pares |
| POST | `/api/sync/stop` | Detener sincronización en curso |
| POST | `/api/pick_folder` | Abrir selector de carpetas `{start, field}` |

---

## 🛠️ Solución de problemas

| Problema | Causa | Solución |
|----------|-------|----------|
| El panel dice "Backend no disponible" | Servicio caído | `systemctl --user status usbsync.service` · `journalctl --user -u usbsync -f` |
| "SSD no identificada" | Varias unidades y ninguna fijada | Configurar → seleccionar la SSD por UUID |
| "StorageSSD no conectada" | La SSD fijada no está montada | Conecta la unidad; se detecta sola |
| El selector de carpetas no abre | kdialog ausente | `sudo pacman -S kdialog` (usa Dolphin como respaldo) |
| El submenú "Trove" no sale en Dolphin | Service menu cacheado | Cierra Dolphin del todo y vuelve a abrirlo |
| Los cambios del QML no se aplican | Caché QML de plasmashell | `rm -rf ~/.cache/plasmashell/qmlcache/` + reiniciar plasmashell |
| El panel no ajusta su alto | Tamaño de popup recordado | Eliminar `popupHeight`/`popupWidth` de la sección del applet en `~/.config/plasma-org.kde.plasma.desktop-appletsrc` |
| "0 archivos" tras sincronizar | Nada que copiar (o locale del resumen rsync) | Normal si ya estaba sincronizado; el backend fuerza `LC_ALL=C` para el conteo |

---

## 📁 Estructura del repositorio

```
trove-plasmoid/
├── backend/
│   ├── usbsync_backend.py            ← Backend Python (HTTP + monitor + rsync)
│   ├── usbsync_pick.sh               ← Helper del service menu de Dolphin
│   └── usbsync-servicemenu.desktop   ← Submenú "Trove" en Dolphin
├── service/
│   └── usbsync.service               ← Unidad systemd de usuario
└── plasmoid/
    └── rccamacho.usbsync/            ← El widget (metadata.json + QML)
        └── contents/
            ├── config/               ← ConfigPage nativa (Configurar)
            └── ui/                   ← main.qml + config/
```

## 📄 Licencia

GPL-2.0+ — hecho para el escritorio KDE, con cariño. 💙
