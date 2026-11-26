#!/usr/bin/env bash
# ======================================================================
#  YSTCore Rust Server - Linux (Ubuntu/Debian) kurulum
#
#  Tek satir (repo yoksa indirir, varsa gunceller, sonra kurar):
#    curl -fsSL https://raw.githubusercontent.com/Mtemizce/RustServer/main/install.sh | sudo bash
#
#  Ya da once ayarlari duzenleyip:
#    git clone https://github.com/Mtemizce/RustServer.git && cd RustServer
#    nano server_config.json
#    sudo ./install.sh
#
#  Hic soru sormaz; her sey server_config.json'dan okunur.
#  Tekrar calistirmak = guncelleme (idempotent).
# ======================================================================
set -euo pipefail

REPO_URL="${YST_REPO_URL:-https://github.com/Mtemizce/RustServer.git}"
REPO_BRANCH="${YST_REPO_BRANCH:-main}"

c_info=$'\e[36m'; c_ok=$'\e[32m'; c_warn=$'\e[33m'; c_err=$'\e[31m'; c_off=$'\e[0m'
info() { echo "${c_info}[YSTCore]${c_off} $*"; }
ok()   { echo "${c_ok}[  OK   ]${c_off} $*"; }
warn() { echo "${c_warn}[ UYARI ]${c_off} $*"; }
fail() { echo "${c_err}[ HATA  ]${c_off} $*" >&2; exit 1; }

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi
apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  $SUDO apt-get update -qq
  $SUDO apt-get install -y -qq "$@" >/dev/null
}

# ---------------------------------------------------------------- bootstrap
# curl | bash ile calistirildiysa: repoyu indir/guncelle ve oradan devam et.
SRC="${BASH_SOURCE[0]:-}"
if [ -n "$SRC" ] && [ -f "$SRC" ]; then BASE="$(cd "$(dirname "$SRC")" && pwd)"; else BASE=""; fi
if [ -z "$BASE" ] || [ ! -f "$BASE/server_config.json" ]; then
  TARGET="${YST_INSTALL_DIR:-$PWD/RustServer}"
  command -v git >/dev/null 2>&1 || { info "git kuruluyor..."; apt_install git ca-certificates; }
  if [ -d "$TARGET/.git" ]; then
    info "Repo guncelleniyor: $TARGET"; git -C "$TARGET" pull --ff-only
  else
    info "Repo indiriliyor: $REPO_URL -> $TARGET"; git clone --branch "$REPO_BRANCH" "$REPO_URL" "$TARGET"
  fi
  exec bash "$TARGET/install.sh" "$@"
fi

# ------------------------------------------------------------- bagimliliklar
NEED=()
command -v jq    >/dev/null 2>&1 || NEED+=(jq)
command -v curl  >/dev/null 2>&1 || NEED+=(curl)
command -v unzip >/dev/null 2>&1 || NEED+=(unzip)
dpkg -s lib32gcc-s1   >/dev/null 2>&1 || NEED+=(lib32gcc-s1)
dpkg -s lib32stdc++6  >/dev/null 2>&1 || NEED+=(lib32stdc++6)
dpkg -s ca-certificates >/dev/null 2>&1 || NEED+=(ca-certificates)
if [ ${#NEED[@]} -gt 0 ]; then info "Paketler kuruluyor: ${NEED[*]}"; apt_install "${NEED[@]}"; fi

# ------------------------------------------------------------------ config
CFG="$BASE/server_config.json"
jq empty "$CFG" 2>/dev/null || fail "server_config.json gecerli bir JSON degil."
j() { jq -r "$1 // empty" "$CFG"; }               # bos/null ise bos string
jd() { local v; v="$(j "$1")"; echo "${v:-$2}"; }  # varsayilanli
jb() { jq -r "if ($1) == false then \"false\" else \"true\" end" "$CFG"; }  # null => true

IDENTITY="$(jd .server.identity ystcore)"
[[ "$IDENTITY" =~ ^[A-Za-z0-9_-]+$ ]] || fail "server.identity sadece harf, rakam, - ve _ icerebilir."
FRAMEWORK="$(jd .mods.framework none | tr '[:upper:]' '[:lower:]')"
case "$FRAMEWORK" in none|oxide|carbon) ;; *) fail "mods.framework 'none', 'oxide' veya 'carbon' olmali.";; esac
BRANCH="$(jd .steam.branch public)"
RUN_USER="$(j .runtime.linuxServiceUser)"; RUN_USER="${RUN_USER:-${SUDO_USER:-$(id -un)}}"

STEAM_DIR="$BASE/steamcmd"; SERVER_DIR="$BASE/rustserver"; LOG_DIR="$BASE/logs"; STATE_DIR="$BASE/.kurulum"

info "Sunucu: $(j .server.hostname) | kapasite: $(jd .server.maxPlayers 50) | mod: $FRAMEWORK | branch: $BRANCH"
info "Kurulum klasoru: $BASE  |  calisacak kullanici: $RUN_USER"

# ------------------------------------------------------- calisma kullanicisi
if ! id "$RUN_USER" >/dev/null 2>&1; then
  [ "$(id -u)" -eq 0 ] || fail "'$RUN_USER' kullanicisi yok; olusturmak icin sudo ile calistirin."
  info "'$RUN_USER' kullanicisi olusturuluyor..."; useradd -m -s /bin/bash "$RUN_USER"
fi
[ "$RUN_USER" = "root" ] && warn "Sunucu root olarak calisacak. Guvenlik icin runtime.linuxServiceUser ayarlayin."
mkdir -p "$STEAM_DIR" "$SERVER_DIR" "$LOG_DIR" "$STATE_DIR"
if [ "$(id -un)" != "$RUN_USER" ]; then
  $SUDO chown -R "$RUN_USER": "$BASE"
  if [ "$(id -u)" -eq 0 ]; then
    as_user() { runuser -u "$RUN_USER" -- env HOME="$(getent passwd "$RUN_USER" | cut -d: -f6)" "$@"; }
  else
    as_user() { sudo -u "$RUN_USER" -H "$@"; }
  fi
else
  as_user() { "$@"; }
fi

# --------------------------------------------------- kalici durum (seed/sifre)
STATE="$STATE_DIR/state.json"
[ -f "$STATE" ] || echo '{}' > "$STATE"
st_get() { jq -r ".$1 // empty" "$STATE"; }
st_set() { local t; t="$(mktemp)"; jq --arg v "$2" ".$1 = \$v" "$STATE" > "$t" && mv "$t" "$STATE"; }

SEED="$(jd .server.seed 0)"
if [ "$SEED" -le 0 ] 2>/dev/null; then
  [ -n "$(st_get seed)" ] || st_set seed "$(( (RANDOM << 15 | RANDOM) % 2147483646 + 1 ))"
  SEED="$(st_get seed)"
fi
RCON_PW="$(j .rcon.password)"
if [ -z "$RCON_PW" ]; then
  [ -n "$(st_get rconPassword)" ] || st_set rconPassword "$(head -c 24 /dev/urandom | base64 | tr '+/=' 'xxx')"
  RCON_PW="$(st_get rconPassword)"
fi
chmod 600 "$STATE"; [ "$(id -un)" != "$RUN_USER" ] && $SUDO chown "$RUN_USER": "$STATE"

# ---------------------------------------------------------------- SteamCMD
if [ ! -x "$STEAM_DIR/steamcmd.sh" ]; then
  info "SteamCMD indiriliyor (Valve resmi CDN)..."
  as_user bash -c "curl -fsSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz | tar -xz -C '$STEAM_DIR'"
fi
ok "SteamCMD hazir."

# --------------------------------------------------- Rust Dedicated Server
MANIFEST="$SERVER_DIR/steamapps/appmanifest_258550.acf"
APP_ARGS=(+force_install_dir "$SERVER_DIR" +login anonymous +app_update 258550)
[ "$BRANCH" != "public" ] && APP_ARGS+=(-beta "$BRANCH")
APP_ARGS+=(validate +quit)
installed=0
for i in 1 2 3 4 5; do
  info "Rust Dedicated Server kuruluyor/guncelleniyor (deneme $i/5, ilk kurulum ~5 GB)..."
  as_user "$STEAM_DIR/steamcmd.sh" "${APP_ARGS[@]}" | grep -E --line-buffered 'Success|Error|Update state' || true
  if [ -x "$SERVER_DIR/RustDedicated" ] && [ -f "$MANIFEST" ] && grep -Eq '"StateFlags"\s+"4"' "$MANIFEST"; then
    installed=1; break
  fi
  [ "$i" -lt 5 ] && { warn "Kurulum tamamlanmadi, 10 sn sonra tekrar denenecek..."; sleep 10; }
done
[ "$installed" -eq 1 ] || fail "Rust Dedicated Server kurulamadi. $STEAM_DIR/logs/content_log.txt dosyasina bakin."
ok "Rust Dedicated Server kurulu ve guncel."

# ----------------------------------------------------------- mod framework
TMP="$STATE_DIR/dl"; mkdir -p "$TMP"
case "$FRAMEWORK" in
  oxide)
    info "Oxide (uMod) indiriliyor (umod.org -> OxideMod resmi surum)..."
    curl -fsSL -o "$TMP/oxide.zip" https://github.com/OxideMod/Oxide.Rust/releases/latest/download/Oxide.Rust-linux.zip
    as_user unzip -oq "$TMP/oxide.zip" -d "$SERVER_DIR"; ok "Oxide kuruldu." ;;
  carbon)
    info "Carbon indiriliyor (carbonmod.gg -> production build)..."
    curl -fsSL -o "$TMP/carbon.tar.gz" https://github.com/CarbonCommunity/Carbon/releases/download/production_build/Carbon.Linux.Release.tar.gz
    as_user tar -xzf "$TMP/carbon.tar.gz" -C "$SERVER_DIR"; ok "Carbon kuruldu." ;;
esac
rm -rf "$TMP"

# ---------------------------------------------------------------- server.cfg
CFG_DIR="$SERVER_DIR/server/$IDENTITY/cfg"; as_user mkdir -p "$CFG_DIR"
{
  echo "// BU DOSYA install.sh TARAFINDAN URETILIR - degisiklikleri server_config.json icinde yapin."
  jq -r '
    def q: "\"" + (tostring | gsub("\""; "'"'"'") | gsub("\n"; "\\n")) + "\"";
    def b: if . == true then "true" else "false" end;
    .server as $s |
    "server.hostname \($s.hostname // "" | q)",
    "server.description \($s.description // "" | q)",
    "server.url \($s.url // "" | q)",
    "server.headerimage \($s.headerImage // "" | q)",
    "server.logoimage \($s.logoImage // "" | q)",
    "server.tags \($s.tags // "" | q)",
    "server.maxplayers \($s.maxPlayers // 50)",
    "server.saveinterval \($s.saveInterval // 300)",
    "server.pve \($s.pve // false | b)",
    ((.extraConvars // {}) | to_entries[] |
      "\(.key) \(if (.value|type) == "string" then (.value|q) elif (.value|type) == "boolean" then (.value|b) else (.value|tostring) end)")
  ' "$CFG"
} | as_user tee "$CFG_DIR/server.cfg" >/dev/null
ok "server.cfg yazildi: server/$IDENTITY/cfg/server.cfg"

# ------------------------------------------------------- baslatma betikleri
GAME_PORT="$(jd .network.gamePort 28015)"; QUERY_PORT="$(jd .network.queryPort 28017)"
APP_PORT="$(jd .network.appPort 28082)";   RCON_PORT="$(jd .rcon.port 28016)"
RCON_IP="$(jd .rcon.ip 127.0.0.1)";        SERVER_IP="$(jd .network.ip 0.0.0.0)"
RCON_WEB=1; [ "$(jb .rcon.web)" = "false" ] && RCON_WEB=0
AUTO_RESTART="$(jb .runtime.autoRestart)"
USE_SYSTEMD=0
if [ "$(jb .runtime.linuxSystemdService)" = "true" ] && [ -d /run/systemd/system ] && [ "$(id -u)" -eq 0 -o -n "$SUDO" ]; then USE_SYSTEMD=1; fi

LAUNCH=(./RustDedicated -batchmode -nographics
  +server.identity "$IDENTITY" +server.ip "$SERVER_IP" +server.port "$GAME_PORT" +server.queryport "$QUERY_PORT"
  +server.level "$(jd .server.level 'Procedural Map')" +server.worldsize "$(jd .server.worldSize 3500)" +server.seed "$SEED"
  +rcon.ip "$RCON_IP" +rcon.port "$RCON_PORT" +rcon.web "$RCON_WEB" +rcon.password "$RCON_PW"
  +app.port "$APP_PORT" -logfile "$LOG_DIR/server_$IDENTITY.log")

{
  echo '#!/usr/bin/env bash'
  echo '# BU DOSYA install.sh TARAFINDAN URETILIR.'
  echo "cd $(printf %q "$SERVER_DIR") || exit 1"
  echo 'export LD_LIBRARY_PATH="$PWD/RustDedicated_Data/Plugins/x86_64:$PWD:${LD_LIBRARY_PATH:-}"'
  if [ "$FRAMEWORK" = "carbon" ]; then
    echo '[ -f carbon/tools/environment.sh ] && source carbon/tools/environment.sh'
  fi
  if [ "$AUTO_RESTART" = "true" ] && [ "$USE_SYSTEMD" -eq 0 ]; then
    echo 'while true; do'
    echo "  $(printf '%q ' "${LAUNCH[@]}")"
    echo '  echo "Sunucu kapandi, 10 sn icinde yeniden baslatiliyor... (Ctrl+C ile iptal)"; sleep 10'
    echo 'done'
  else
    echo "exec $(printf '%q ' "${LAUNCH[@]}")"
  fi
} > "$BASE/start_server.sh"
printf '#!/usr/bin/env bash\n# Guncelleme = kurulumu tekrar calistirmak (idempotent).\nexec bash "$(dirname "$0")/install.sh" "$@"\n' > "$BASE/update_server.sh"
chmod 750 "$BASE/start_server.sh" "$BASE/update_server.sh"
[ "$(id -un)" != "$RUN_USER" ] && $SUDO chown "$RUN_USER": "$BASE/start_server.sh" "$BASE/update_server.sh"
ok "start_server.sh ve update_server.sh olusturuldu."

# ------------------------------------------------------------------ systemd
SERVICE="ystcore-rust-$IDENTITY"
if [ "$USE_SYSTEMD" -eq 1 ]; then
  RESTART="no"; [ "$AUTO_RESTART" = "true" ] && RESTART="always"
  $SUDO tee "/etc/systemd/system/$SERVICE.service" >/dev/null <<EOF
[Unit]
Description=YSTCore Rust Server ($IDENTITY)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$RUN_USER
WorkingDirectory=$SERVER_DIR
ExecStart=$BASE/start_server.sh
Restart=$RESTART
RestartSec=10
KillSignal=SIGINT
TimeoutStopSec=120
LimitNOFILE=100000

[Install]
WantedBy=multi-user.target
EOF
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable "$SERVICE" >/dev/null 2>&1
  ok "systemd servisi: $SERVICE (acilista otomatik baslar)"
fi

# ----------------------------------------------------------------- firewall
if [ "$(jb .runtime.openFirewall)" = "true" ] && command -v ufw >/dev/null 2>&1 && $SUDO ufw status 2>/dev/null | grep -q "Status: active"; then
  $SUDO ufw allow "$GAME_PORT/udp" >/dev/null; $SUDO ufw allow "$QUERY_PORT/udp" >/dev/null; $SUDO ufw allow "$APP_PORT/tcp" >/dev/null
  [ "$RCON_IP" != "127.0.0.1" ] && $SUDO ufw allow "$RCON_PORT/tcp" >/dev/null
  ok "ufw kurallari eklendi."
fi

# ------------------------------------------------------------------- bitti
echo
ok "======================= KURULUM TAMAM ======================="
info "Baglanti : client.connect <IP>:$GAME_PORT"
info "RCON     : ws://$RCON_IP:$RCON_PORT  (sifre: $STATE_DIR/state.json veya server_config.json)"
if [ "$(jb .runtime.startAfterInstall)" = "true" ]; then
  if [ "$USE_SYSTEMD" -eq 1 ]; then
    $SUDO systemctl restart "$SERVICE"
    info "Sunucu baslatildi. Log: journalctl -u $SERVICE -f   |   $LOG_DIR/server_$IDENTITY.log"
  else
    as_user bash -c "nohup $(printf %q "$BASE/start_server.sh") > $(printf %q "$LOG_DIR/console.log") 2>&1 &"
    info "Sunucu arka planda baslatildi. Log: $LOG_DIR/server_$IDENTITY.log"
  fi
else
  info "Baslatmak icin: $([ "$USE_SYSTEMD" -eq 1 ] && echo "sudo systemctl start $SERVICE" || echo "$BASE/start_server.sh")"
fi
