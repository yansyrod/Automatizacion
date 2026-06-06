#!/usr/bin/env bash
# =============================================================================
#  Vault — Cloud Storage personal · Proxmox VE Helper Script
#  PHP + MariaDB · Multi-usuario · 2FA · Visor de archivos · Streaming
#  Licencia: MIT
#  Autor: Yansy Rodriguez
#  Assisted by ChatGPT
# =============================================================================

# ── Colores ───────────────────────────────────────────────────────────────────
YW='\033[33m'; BL='\033[36m'; RD='\033[01;31m'
GN='\033[1;92m'; CL='\033[0m'; BOLD='\033[1m'
CM="${GN}✓${CL}"; CROSS="${RD}✗${CL}"; HOLD=" -"

msg_info()  { local m="$1"; echo -ne " ${HOLD} ${YW}${m}...${CL}"; }
msg_ok()    { local m="$1"; echo -e "\r ${CM} ${GN}${m}${CL}"; }
msg_error() { local m="$1"; echo -e "\r ${CROSS} ${RD}${m}${CL}"; exit 1; }

# ── Manejo de errores ─────────────────────────────────────────────────────────
set -Eeuo pipefail
trap 'echo -e "\n${RD}[ERROR]${CL} en línea $LINENO."; exit 1' ERR

# ── Verificar Proxmox ─────────────────────────────────────────────────────────
if ! command -v pveversion &>/dev/null; then
  echo -e "${RD}[ERROR]${CL} Este script debe ejecutarse en el host de Proxmox VE."
  exit 1
fi

# ── Verificar whiptail ────────────────────────────────────────────────────────
if ! command -v whiptail &>/dev/null; then
  apt-get install -y -qq whiptail 2>/dev/null || true
fi

# ── Generador de contraseñas ──────────────────────────────────────────────────
gen_pass() {
  local len="$1"
  ( set +o pipefail; tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c "$len" )
}

# ── Exit ──────────────────────────────────────────────────────────────────────
exit_script() { clear; echo -e "${YW}Instalación cancelada.${CL}\n"; exit 0; }

# ══════════════════════════════════════════════════════════════════════════════
# BANNER
# ══════════════════════════════════════════════════════════════════════════════
clear
echo -e "${BL}"
cat << 'BANNER'
   __      __    _ _
   \ \    / /_ _| | |_
    \ \/\/ / _` | |  _|
     \_/\_/\__,_|_|\__|   V A U L T

BANNER
echo -e "${CL}${YW}  Cloud storage personal · 2FA · Visor de archivos · Streaming${CL}"
echo -e "${BL}  ─────────────────────────────────────────────────────────────${CL}\n"
echo -e " ${GN}Proxmox VE:${CL} $(pveversion | head -1)"
echo -e " ${GN}Kernel:${CL} $(uname -r)\n"

# ══════════════════════════════════════════════════════════════════════════════
# DETECTAR RECURSOS DE PROXMOX
# ══════════════════════════════════════════════════════════════════════════════
NEXTID=$(pvesh get /cluster/nextid 2>/dev/null || echo "200")

# Storages para contenedor (rootdir)
mapfile -t _STOR_NAMES  < <(pvesm status -content rootdir 2>/dev/null | awk 'NR>1 && length($1)>2 {print $1}')
mapfile -t _STOR_TYPES  < <(pvesm status -content rootdir 2>/dev/null | awk 'NR>1 && length($1)>2 {print $2}')
mapfile -t _STOR_FREE   < <(pvesm status -content rootdir 2>/dev/null | awk 'NR>1 && length($1)>2 {avail=$5/1048576; printf "%.1fGB\n", avail}')
mapfile -t _STOR_USED   < <(pvesm status -content rootdir 2>/dev/null | awk 'NR>1 && length($1)>2 {used=$4/1048576; printf "%.1fGB\n", used}')
[[ ${#_STOR_NAMES[@]} -eq 0 ]] && _STOR_NAMES=("local-lvm") && _STOR_TYPES=("lvmthin") && _STOR_FREE=("?") && _STOR_USED=("?")
DEFAULT_STORAGE="${_STOR_NAMES[0]}"

# Storages para templates (vztmpl)
mapfile -t _TMPL_NAMES  < <(pvesm status -content vztmpl 2>/dev/null | awk 'NR>1 && length($1)>2 {print $1}')
[[ ${#_TMPL_NAMES[@]} -eq 0 ]] && _TMPL_NAMES=("local")
DEFAULT_TMPL="${_TMPL_NAMES[0]}"

# Bridges disponibles
mapfile -t _BRIDGES < <(ip link show | awk '/^[0-9]+: vmbr/{gsub(":",""); print $2}')
[[ ${#_BRIDGES[@]} -eq 0 ]] && _BRIDGES=("vmbr0")

# ══════════════════════════════════════════════════════════════════════════════
# PASO 1: MODO RÁPIDO O AVANZADO
# ══════════════════════════════════════════════════════════════════════════════
INSTALL_MODE=$(whiptail --title "VAULT INSTALLER" \
  --menu "\nBienvenido al instalador de Vault.\nElige el modo de instalación:" \
  15 60 2 \
  "quick"    "Rápido  (valores por defecto)" \
  "advanced" "Avanzado (personalizar todo)" \
  3>&1 1>&2 2>&3) || exit_script

if [[ "$INSTALL_MODE" == "quick" ]]; then
  # ── Modo rápido: solo pedir lo esencial ─────────────────────────────────────
  CT_ID="$NEXTID"
  CT_HOSTNAME="vault"
  CT_CORES="2"
  CT_RAM="2048"
  CT_DISK="20"
  CT_BRIDGE="${_BRIDGES[0]}"
  CT_IP="dhcp"
  CT_GW=""
  CT_STORAGE="$DEFAULT_STORAGE"
  TMPL_STORAGE="$DEFAULT_TMPL"
else
  # ══════════════════════════════════════════════════════════════════════════
  # MODO AVANZADO
  # ══════════════════════════════════════════════════════════════════════════

  # ── Paso A: ID del contenedor ──────────────────────────────────────────────
  CT_ID=$(whiptail --title "Container ID" \
    --inputbox "\nID para el nuevo contenedor LXC:" \
    10 50 "$NEXTID" \
    3>&1 1>&2 2>&3) || exit_script
  [[ -z "$CT_ID" ]] && CT_ID="$NEXTID"

  # ── Paso B: Hostname ──────────────────────────────────────────────────────
  CT_HOSTNAME=$(whiptail --title "Hostname" \
    --inputbox "\nNombre del contenedor:" \
    10 50 "vault" \
    3>&1 1>&2 2>&3) || exit_script
  [[ -z "$CT_HOSTNAME" ]] && CT_HOSTNAME="vault"

  # ── Paso C: Recursos ──────────────────────────────────────────────────────
  CT_CORES=$(whiptail --title "CPU Cores" \
    --inputbox "\nNúmero de cores:" \
    10 50 "2" \
    3>&1 1>&2 2>&3) || exit_script
  [[ -z "$CT_CORES" ]] && CT_CORES="2"

  CT_RAM=$(whiptail --title "RAM" \
    --inputbox "\nRAM en MB (mínimo recomendado: 1024):" \
    10 50 "2048" \
    3>&1 1>&2 2>&3) || exit_script
  [[ -z "$CT_RAM" ]] && CT_RAM="2048"

  CT_DISK=$(whiptail --title "Disco" \
    --inputbox "\nTamaño del disco en GB:" \
    10 50 "20" \
    3>&1 1>&2 2>&3) || exit_script
  [[ -z "$CT_DISK" ]] && CT_DISK="20"

  # ── Paso D: Storage del contenedor ────────────────────────────────────────
  _STOR_MENU=()
  for i in "${!_STOR_NAMES[@]}"; do
    _status="OFF"; [[ $i -eq 0 ]] && _status="ON"
    _STOR_MENU+=("${_STOR_NAMES[$i]}" "(${_STOR_TYPES[$i]}) Free:${_STOR_FREE[$i]} Used:${_STOR_USED[$i]}" "$_status")
  done
  CT_STORAGE=$(whiptail --title "Storage Pools" \
    --radiolist "\nWhich storage pool for container?\n(Spacebar to select)" \
    18 75 "${#_STOR_NAMES[@]}" \
    "${_STOR_MENU[@]}" \
    3>&1 1>&2 2>&3) || exit_script
  [[ -z "$CT_STORAGE" ]] && CT_STORAGE="$DEFAULT_STORAGE"

  # ── Paso E: Storage para templates ────────────────────────────────────────
  _TMPL_MENU=()
  mapfile -t _TMPL_FREE < <(pvesm status -content vztmpl 2>/dev/null | awk 'NR>1 && length($1)>2 {avail=$5/1048576; printf "%.1fGB\n", avail}')
  mapfile -t _TMPL_USED < <(pvesm status -content vztmpl 2>/dev/null | awk 'NR>1 && length($1)>2 {used=$4/1048576; printf "%.1fGB\n", used}')
  for i in "${!_TMPL_NAMES[@]}"; do
    _tstatus="OFF"; [[ $i -eq 0 ]] && _tstatus="ON"
    _TMPL_MENU+=("${_TMPL_NAMES[$i]}" "Free:${_TMPL_FREE[$i]:-?} Used:${_TMPL_USED[$i]:-?}" "$_tstatus")
  done
  TMPL_STORAGE=$(whiptail --title "Storage Pools" \
    --radiolist "\nWhich storage pool for container template?\n(Spacebar to select)" \
    16 75 "${#_TMPL_NAMES[@]}" \
    "${_TMPL_MENU[@]}" \
    3>&1 1>&2 2>&3) || exit_script
  [[ -z "$TMPL_STORAGE" ]] && TMPL_STORAGE="$DEFAULT_TMPL"

  # ── Paso F: Red ────────────────────────────────────────────────────────────
  _BRIDGE_MENU=()
  _bidx=0
  for b in "${_BRIDGES[@]}"; do
    _bstatus="OFF"; [[ $_bidx -eq 0 ]] && _bstatus="ON"
    _BRIDGE_MENU+=("$b" "Bridge de red" "$_bstatus")
    _bidx=$((_bidx+1))
  done
  CT_BRIDGE=$(whiptail --title "Network Bridge" \
    --radiolist "\nSelecciona el bridge de red:" \
    12 50 "${#_BRIDGES[@]}" \
    "${_BRIDGE_MENU[@]}" \
    3>&1 1>&2 2>&3) || exit_script
  [[ -z "$CT_BRIDGE" ]] && CT_BRIDGE="${_BRIDGES[0]}"

  # ── Paso G: IP ─────────────────────────────────────────────────────────────
  CT_IP=$(whiptail --title "IPv4 Address" \
    --inputbox "\nDirección IP en formato CIDR o 'dhcp':\nEjemplo: 192.168.1.100/24" \
    10 55 "dhcp" \
    3>&1 1>&2 2>&3) || exit_script
  [[ -z "$CT_IP" ]] && CT_IP="dhcp"

  CT_GW=""
  if [[ "$CT_IP" != "dhcp" ]]; then
    CT_GW=$(whiptail --title "Gateway" \
      --inputbox "\nGateway (dejar vacío para autodetectar):" \
      10 55 "" \
      3>&1 1>&2 2>&3) || exit_script
  fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# PASO 2: CUENTA DE ADMINISTRADOR
# ══════════════════════════════════════════════════════════════════════════════
APP_NAME=$(whiptail --title "Vault — Nombre de la app" \
  --inputbox "\nNombre que aparecerá en la interfaz:" \
  10 55 "Vault" \
  3>&1 1>&2 2>&3) || exit_script
[[ -z "$APP_NAME" ]] && APP_NAME="Vault"

ADMIN_USER=$(whiptail --title "Vault — Administrador" \
  --inputbox "\nNombre de usuario del administrador:" \
  10 55 "admin" \
  3>&1 1>&2 2>&3) || exit_script
[[ -z "$ADMIN_USER" ]] && ADMIN_USER="admin"

ADMIN_PASS=$(whiptail --title "Vault — Contraseña admin" \
  --passwordbox "\nContraseña del administrador:" \
  10 55 \
  3>&1 1>&2 2>&3) || exit_script
while [[ -z "$ADMIN_PASS" ]]; do
  ADMIN_PASS=$(whiptail --title "Vault — Contraseña admin" \
    --passwordbox "\n⚠ La contraseña no puede estar vacía:" \
    10 55 \
    3>&1 1>&2 2>&3) || exit_script
done

ADMIN_EMAIL=$(whiptail --title "Vault — Email admin" \
  --inputbox "\nEmail del administrador:" \
  10 55 "admin@example.com" \
  3>&1 1>&2 2>&3) || exit_script
[[ -z "$ADMIN_EMAIL" ]] && ADMIN_EMAIL="admin@example.com"

# ══════════════════════════════════════════════════════════════════════════════
# PASO 3: SMTP (OPCIONAL)
# ══════════════════════════════════════════════════════════════════════════════
SMTP_HOST=""; SMTP_PORT=""; SMTP_SECURITY=""; SMTP_USER=""; SMTP_PASS=""; SMTP_FROM=""

if whiptail --title "Vault — SMTP" \
  --yesno "\n¿Configurar envío de correos por SMTP?\n\nNecesario para compartir archivos por email." \
  10 55; then

  SMTP_HOST=$(whiptail --title "SMTP — Servidor" \
    --inputbox "\nServidor SMTP:" \
    10 55 "mail.example.com" \
    3>&1 1>&2 2>&3) || exit_script

  SMTP_PORT=$(whiptail --title "SMTP — Puerto" \
    --inputbox "\nPuerto SMTP:" \
    10 55 "465" \
    3>&1 1>&2 2>&3) || exit_script

  SMTP_SECURITY=$(whiptail --title "SMTP — Seguridad" \
    --radiolist "\nTipo de seguridad:" \
    12 45 3 \
    "ssl"  "SSL/TLS (puerto 465)" ON \
    "tls"  "STARTTLS (puerto 587)" OFF \
    "none" "Sin cifrado (no recomendado)" OFF \
    3>&1 1>&2 2>&3) || exit_script
  [[ -z "$SMTP_SECURITY" ]] && SMTP_SECURITY="ssl"

  SMTP_USER=$(whiptail --title "SMTP — Usuario" \
    --inputbox "\nUsuario (dirección de correo):" \
    10 55 "vault@example.com" \
    3>&1 1>&2 2>&3) || exit_script

  SMTP_PASS=$(whiptail --title "SMTP — Contraseña" \
    --passwordbox "\nContraseña SMTP:" \
    10 55 \
    3>&1 1>&2 2>&3) || exit_script

  SMTP_FROM="${SMTP_USER}"
fi

# ══════════════════════════════════════════════════════════════════════════════
# CONTRASEÑAS INTERNAS
# ══════════════════════════════════════════════════════════════════════════════
CT_PASSWORD=$(gen_pass 16)
DB_PASS=$(gen_pass 24)

# ══════════════════════════════════════════════════════════════════════════════
# RESUMEN FINAL — estilo community-scripts
# ══════════════════════════════════════════════════════════════════════════════
clear
echo -e "${BL}"
cat << 'BANNER'
   __      __    _ _
   \ \    / /_ _| | |_
    \ \/\/ / _` | |  _|
     \_/\_/\__,_|_|\__|   V A U L T
BANNER
echo -e "${CL}\n"
echo -e " 🔷 ${BOLD}PVE Version:${CL}    $(pveversion | head -1)"
echo -e " 🖥  ${BOLD}Container ID:${CL}   ${YW}${CT_ID}${CL}"
echo -e " 🏠 ${BOLD}Hostname:${CL}       ${YW}${CT_HOSTNAME}${CL}"
echo -e " 💾 ${BOLD}Disk Size:${CL}      ${YW}${CT_DISK} GB${CL}"
echo -e " 🔵 ${BOLD}CPU Cores:${CL}      ${YW}${CT_CORES}${CL}"
echo -e " 🧠 ${BOLD}RAM Size:${CL}       ${YW}${CT_RAM} MiB${CL}"
echo -e " 🌐 ${BOLD}Bridge:${CL}         ${YW}${CT_BRIDGE}${CL}"
echo -e " 📡 ${BOLD}IP:${CL}             ${YW}${CT_IP}${CL}"
echo -e " 📦 ${BOLD}Storage:${CL}        ${YW}${CT_STORAGE}${CL}"
echo -e " 📁 ${BOLD}Templates:${CL}      ${YW}${TMPL_STORAGE}${CL}"
echo -e " 🔒 ${BOLD}Nesting:${CL}        ${GN}Enabled${CL}"
echo -e " 🔑 ${BOLD}Keyctl:${CL}         ${GN}Enabled${CL}"
echo -e " 🚀 ${BOLD}App:${CL}            ${YW}${APP_NAME}${CL}"
echo -e " 👤 ${BOLD}Admin:${CL}          ${YW}${ADMIN_USER}${CL}"
[[ -n "$SMTP_HOST" ]] && echo -e " 📧 ${BOLD}SMTP:${CL}           ${YW}${SMTP_HOST}:${SMTP_PORT}${CL}" || echo -e " 📧 ${BOLD}SMTP:${CL}           ${YW}no configurado${CL}"
echo ""

if ! whiptail --title "Vault — Confirmar instalación" \
  --yesno "\n¿Crear el contenedor e instalar Vault con esta configuración?" \
  10 55; then
  exit_script
fi

echo ""
echo -e " ${BL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
echo -e " ${GN} INSTALANDO...${CL}"
echo -e " ${BL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}\n"

# ── Detectar template Debian 12 ────────────────────────────────────────────────
msg_info "Buscando template Debian 12"
TEMPLATE_VOLID=""
EXISTING=$(pveam list "$TMPL_STORAGE" 2>/dev/null | grep -oE "${TMPL_STORAGE}:vztmpl/debian-12-standard_[^[:space:]]+\.tar\.(zst|gz)" | head -1)
if [[ -z "$EXISTING" ]]; then
  EXISTING=$(pveam list local 2>/dev/null | grep -oE "local:vztmpl/debian-12-standard_[^[:space:]]+\.tar\.(zst|gz)" | head -1)
  [[ -n "$EXISTING" ]] && TMPL_STORAGE="local"
fi

if [[ -n "$EXISTING" ]]; then
  TEMPLATE_VOLID="$EXISTING"
  msg_ok "Template encontrado: $(basename "$TEMPLATE_VOLID")"
else
  pveam update &>/dev/null || true
  TEMPLATE=$(pveam available --section system 2>/dev/null | grep -oE 'debian-12-standard_[^[:space:]]+\.tar\.(zst|gz)' | sort -V | tail -1)
  [[ -z "$TEMPLATE" ]] && msg_error "No se encontró ningún template Debian 12. Ejecuta 'pveam update'."
  msg_info "Descargando $TEMPLATE"
  pveam download "$TMPL_STORAGE" "$TEMPLATE" &>/dev/null || msg_error "Error al descargar el template"
  TEMPLATE_VOLID="${TMPL_STORAGE}:vztmpl/${TEMPLATE}"
  msg_ok "Template descargado: $TEMPLATE"
fi

# ── Crear LXC ─────────────────────────────────────────────────────────────────
msg_info "Creando contenedor LXC ${CT_ID}"
NET_CONFIG="name=eth0,bridge=${CT_BRIDGE}"
if [[ "$CT_IP" == "dhcp" ]]; then
  NET_CONFIG+=",ip=dhcp"
else
  NET_CONFIG+=",ip=${CT_IP}"
  [[ -n "$CT_GW" ]] && NET_CONFIG+=",gw=${CT_GW}"
fi

if ! pct create "$CT_ID" "$TEMPLATE_VOLID" \
  --hostname "$CT_HOSTNAME" \
  --password "$CT_PASSWORD" \
  --cores "$CT_CORES" \
  --memory "$CT_RAM" \
  --swap 512 \
  --storage "$CT_STORAGE" \
  --rootfs "${CT_STORAGE}:${CT_DISK}" \
  --net0 "$NET_CONFIG" \
  --unprivileged 1 \
  --features nesting=1,keyctl=1 \
  --onboot 1 \
  --start 0 \
  --ostype debian 2>/tmp/vault_create_err; then
  echo ""; cat /tmp/vault_create_err 2>/dev/null || true
  msg_error "Error al crear el contenedor LXC ${CT_ID}"
fi
msg_ok "Contenedor LXC ${CT_ID} creado"

msg_info "Iniciando contenedor"
pct start "$CT_ID" &>/dev/null
for i in $(seq 1 30); do
  if pct exec "$CT_ID" -- ping -c1 -W2 deb.debian.org &>/dev/null || \
     pct exec "$CT_ID" -- ping -c1 -W2 8.8.8.8 &>/dev/null; then break; fi
  sleep 2
done
msg_ok "Contenedor iniciado y con red"


# ── Sistema y paquetes ────────────────────────────────────────────────────────
msg_info "Actualizando sistema (puede tardar)"
pct exec "$CT_ID" -- bash -c "
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get -o Dpkg::Options::='--force-confold' upgrade -y -qq
" || msg_error "Falló la actualización del sistema"
msg_ok "Sistema actualizado"

msg_info "Instalando Apache, PHP 8.2 y MariaDB (puede tardar)"
pct exec "$CT_ID" -- bash -c "
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq \
  apache2 mariadb-server \
  php8.2 php8.2-mysql php8.2-gd php8.2-curl php8.2-mbstring \
  php8.2-xml php8.2-zip php8.2-intl php8.2-bcmath \
  libapache2-mod-php8.2 unzip curl wget
apt-get install -y -qq php8.2-imagick ffmpeg imagemagick 2>/dev/null || true
# Cliente SMTP ligero para envío de correos
apt-get install -y -qq msmtp msmtp-mta ca-certificates 2>/dev/null || true
# Sincronización de hora (crítico para que el 2FA/TOTP funcione)
apt-get install -y -qq systemd-timesyncd locales 2>/dev/null || true
timedatectl set-ntp true 2>/dev/null || true
systemctl restart systemd-timesyncd 2>/dev/null || true
# Generar locales para evitar warnings de msmtp/apt
sed -i 's/# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen 2>/dev/null || true
locale-gen en_US.UTF-8 2>/dev/null || true
update-locale LANG=en_US.UTF-8 2>/dev/null || true
" || msg_error "Falló la instalación de paquetes"
msg_ok "Apache + PHP 8.2 + MariaDB instalados"

msg_info "Configurando MariaDB"
pct exec "$CT_ID" -- bash -c "
systemctl start mariadb
systemctl enable mariadb &>/dev/null
mysql -e \"CREATE DATABASE IF NOT EXISTS vault CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\"
mysql -e \"CREATE USER IF NOT EXISTS 'vault'@'localhost' IDENTIFIED BY '${DB_PASS}';\"
mysql -e \"GRANT ALL PRIVILEGES ON vault.* TO 'vault'@'localhost';\"
mysql -e \"FLUSH PRIVILEGES;\"
" || msg_error "Falló la configuración de MariaDB"
msg_ok "MariaDB configurado"

msg_info "Configurando PHP y Apache"
pct exec "$CT_ID" -- bash -c "
PHPINI=/etc/php/8.2/apache2/php.ini
sed -i 's/upload_max_filesize = .*/upload_max_filesize = 10G/' \$PHPINI
sed -i 's/post_max_size = .*/post_max_size = 10G/' \$PHPINI
sed -i 's/memory_limit = .*/memory_limit = 512M/' \$PHPINI
sed -i 's/max_execution_time = .*/max_execution_time = 3600/' \$PHPINI
sed -i 's|;date.timezone.*|date.timezone = Europe/Madrid|' \$PHPINI
sed -i 's/output_buffering = .*/output_buffering = Off/' \$PHPINI

a2enmod rewrite headers expires deflate &>/dev/null || true

cat > /etc/apache2/sites-available/vault.conf << 'APACHECONF'
<VirtualHost *:80>
    ServerName vault
    DocumentRoot /var/www/vault/public
    <Directory /var/www/vault/public>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog \${APACHE_LOG_DIR}/vault_error.log
    CustomLog \${APACHE_LOG_DIR}/vault_access.log combined
</VirtualHost>
APACHECONF

a2ensite vault.conf &>/dev/null || true
a2dissite 000-default.conf &>/dev/null || true
" || msg_error "Falló la configuración de PHP/Apache"
msg_ok "PHP y Apache configurados"

msg_info "Creando estructura de la aplicación"
pct exec "$CT_ID" -- bash -c "
mkdir -p /var/www/vault/public
mkdir -p /var/www/vault/src/auth
mkdir -p /var/www/vault/src/files
mkdir -p /var/www/vault/src/api
mkdir -p /var/www/vault/src/shared
mkdir -p /var/www/vault/src/views
mkdir -p /var/www/vault/storage/uploads
mkdir -p /var/www/vault/storage/thumbnails
mkdir -p /var/www/vault/storage/avatars
mkdir -p /var/www/vault/config
mkdir -p /var/www/vault/logs
mkdir -p /var/www/vault/storage/tmp_chunks
chmod -R 755 /var/www/vault
chown -R www-data:www-data /var/www/vault/storage /var/www/vault/logs

cat > /var/www/vault/config/config.php << PHPCONFIG
<?php
define('DB_HOST', 'localhost');
define('DB_NAME', 'vault');
define('DB_USER', 'vault');
define('DB_PASS', '${DB_PASS}');
define('APP_NAME', '${APP_NAME}');
define('APP_VERSION', '2.1.1-phase3-onedrive-fixes');
define('STORAGE_PATH', '/var/www/vault/storage/uploads');
define('THUMB_PATH', '/var/www/vault/storage/thumbnails');
define('LOG_PATH', '/var/www/vault/logs');
define('MAX_UPLOAD_SIZE', 10 * 1024 * 1024 * 1024);
define('SESSION_LIFETIME', 86400 * 7);
define('ADMIN_USER', '${ADMIN_USER}');
define('SMTP_HOST', '${SMTP_HOST}');
define('SMTP_PORT', '${SMTP_PORT}');
define('SMTP_SECURITY', '${SMTP_SECURITY}');
define('SMTP_USER', '${SMTP_USER}');
define('SMTP_PASS', '${SMTP_PASS}');
define('SMTP_FROM', '${SMTP_FROM}');
define('APP_URL', '');
define('CHUNK_TMP_PATH', '/var/www/vault/storage/tmp_chunks');
PHPCONFIG
" || msg_error "Falló la creación de la estructura"
msg_ok "Estructura de la aplicación creada"

# ── Configurar msmtp si se proporcionó SMTP ───────────────────────────────────
if [[ -n "$SMTP_HOST" ]]; then
  msg_info "Configurando envío de correos (SMTP)"
  # Para puerto 465 = SSL directo (tls on + starttls off); 587 = STARTTLS
  if [[ "$SMTP_SECURITY" == "ssl" ]]; then
    TLS_LINE="tls on"; STARTTLS_LINE="tls_starttls off"
  elif [[ "$SMTP_SECURITY" == "tls" ]]; then
    TLS_LINE="tls on"; STARTTLS_LINE="tls_starttls on"
  else
    TLS_LINE="tls off"; STARTTLS_LINE="tls_starttls off"
  fi
  pct exec "$CT_ID" -- bash -c "cat > /etc/msmtprc << MSMTPEOF
defaults
auth on
${TLS_LINE}
${STARTTLS_LINE}
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile /var/log/msmtp.log

account vault
host ${SMTP_HOST}
port ${SMTP_PORT}
from ${SMTP_FROM}
user ${SMTP_USER}
password ${SMTP_PASS}

account default : vault
MSMTPEOF
chmod 600 /etc/msmtprc
chown www-data:www-data /etc/msmtprc
touch /var/log/msmtp.log
chown www-data:www-data /var/log/msmtp.log
# Configurar PHP para usar msmtp como sendmail
echo 'sendmail_path = /usr/bin/msmtp -t' > /etc/php/8.2/apache2/conf.d/99-msmtp.ini
" || msg_error "Falló la configuración de SMTP"
  msg_ok "Correo SMTP configurado (${SMTP_HOST})"
else
  # Preparar /etc/msmtprc para que el panel Sistema pueda configurar SMTP después.
  pct exec "$CT_ID" -- bash -c "touch /etc/msmtprc /var/log/msmtp.log
chown www-data:www-data /etc/msmtprc /var/log/msmtp.log
chmod 600 /etc/msmtprc
mkdir -p /etc/php/8.2/apache2/conf.d
printf '%s\n' 'sendmail_path = /usr/bin/msmtp -t' > /etc/php/8.2/apache2/conf.d/99-msmtp.ini
" || true
fi

# ── Base de datos ─────────────────────────────────────────────────────────────
msg_info "Instalando base de datos"
pct exec "$CT_ID" -- bash -c "
cat > /tmp/schema.sql << 'SQLEOF'
USE vault;
CREATE TABLE IF NOT EXISTS users (
  id INT AUTO_INCREMENT PRIMARY KEY,
  username VARCHAR(64) NOT NULL UNIQUE,
  email VARCHAR(255) NOT NULL UNIQUE,
  password VARCHAR(255) NOT NULL,
  display_name VARCHAR(128),
  role ENUM('admin','user') DEFAULT 'user',
  storage_quota BIGINT DEFAULT 10737418240,
  storage_used BIGINT DEFAULT 0,
  avatar VARCHAR(255) DEFAULT NULL,
  active TINYINT(1) DEFAULT 1,
  totp_secret VARCHAR(64) DEFAULT NULL,
  totp_enabled TINYINT(1) DEFAULT 0,
  totp_backup TEXT DEFAULT NULL,
  theme ENUM('dark','light') DEFAULT 'light',
  language ENUM('es','en') DEFAULT 'es',
  session_version INT DEFAULT 1,
  last_login DATETIME DEFAULT NULL,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS files (
  id INT AUTO_INCREMENT PRIMARY KEY,
  user_id INT NOT NULL,
  parent_id INT DEFAULT NULL,
  name VARCHAR(512) NOT NULL,
  original_name VARCHAR(512) NOT NULL,
  type ENUM('file','folder') DEFAULT 'file',
  mime_type VARCHAR(128) DEFAULT NULL,
  size BIGINT DEFAULT 0,
  path VARCHAR(1024) NOT NULL,
  thumbnail VARCHAR(512) DEFAULT NULL,
  is_starred TINYINT(1) DEFAULT 0,
  is_trashed TINYINT(1) DEFAULT 0,
  trashed_at DATETIME DEFAULT NULL,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
  updated_at DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
  FOREIGN KEY (parent_id) REFERENCES files(id) ON DELETE CASCADE,
  INDEX idx_user_parent (user_id, parent_id)
);
CREATE TABLE IF NOT EXISTS shares (
  id INT AUTO_INCREMENT PRIMARY KEY,
  file_id INT NOT NULL,
  user_id INT NOT NULL,
  token VARCHAR(64) NOT NULL UNIQUE,
  password VARCHAR(255) DEFAULT NULL,
  expires_at DATETIME DEFAULT NULL,
  allow_download TINYINT(1) DEFAULT 1,
  downloads INT DEFAULT 0,
  max_downloads INT DEFAULT NULL,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE,
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS activity_log (
  id INT AUTO_INCREMENT PRIMARY KEY,
  user_id INT DEFAULT NULL,
  action VARCHAR(64) NOT NULL,
  target VARCHAR(512) DEFAULT NULL,
  ip VARCHAR(45) DEFAULT NULL,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_user (user_id)
);
CREATE TABLE IF NOT EXISTS app_settings (
  setting_key VARCHAR(80) PRIMARY KEY,
  setting_value TEXT NULL,
  updated_at DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);
SQLEOF
mysql vault < /tmp/schema.sql
cat > /tmp/settings.sql << SETEOF
INSERT INTO app_settings (setting_key,setting_value) VALUES
('app_name','${APP_NAME}'),('app_url',''),('max_upload_size','10737418240'),('timezone','Europe/Madrid'),
('smtp_enabled',IF('${SMTP_HOST}'='', '0', '1')),('smtp_host','${SMTP_HOST}'),('smtp_port','${SMTP_PORT}'),('smtp_security','${SMTP_SECURITY}'),('smtp_user','${SMTP_USER}'),('smtp_pass','${SMTP_PASS}'),('smtp_from','${SMTP_FROM}'),
('share_require_password','0'),('share_default_expiry_days','0'),('share_default_max_downloads','0'),
('trash_auto_purge','0'),('trash_retention_days','30'),('force_admin_2fa','0'),('session_lifetime','604800'),('default_language','es')
ON DUPLICATE KEY UPDATE setting_value=VALUES(setting_value);
SETEOF
mysql vault < /tmp/settings.sql
" || msg_error "Falló la creación de las tablas"
msg_ok "Base de datos instalada"

msg_info "Creando usuario administrador"
ADMIN_HASH=$(pct exec "$CT_ID" -- php -r "echo password_hash('${ADMIN_PASS}', PASSWORD_BCRYPT, ['cost'=>12]);")
pct exec "$CT_ID" -- mysql vault -e "
INSERT IGNORE INTO users (username,email,password,display_name,role,storage_quota)
VALUES ('${ADMIN_USER}','${ADMIN_EMAIL}','${ADMIN_HASH}','${ADMIN_USER}','admin',107374182400);
" || msg_error "Falló la creación del administrador"
msg_ok "Administrador '${ADMIN_USER}' creado"
msg_info "Desplegando núcleo PHP"

pct exec "$CT_ID" -- bash -c "cat > /var/www/vault/src/bootstrap.php" << 'PHPEOF'
<?php
// La cookie NO se marca como Secure: detrás de Cloudflare Tunnel la conexión
// interna es HTTP (Cloudflare termina el TLS), y marcarla Secure rompería la
// persistencia de sesión. El cifrado de cara al usuario lo aporta HTTPS/Cloudflare.
// Sigue protegida con HttpOnly + SameSite.
session_set_cookie_params([
    'lifetime' => defined('SESSION_LIFETIME') ? SESSION_LIFETIME : 604800,
    'path' => '/',
    'httponly' => true,
    'samesite' => 'Lax',
    'secure' => false,
]);
session_start();
spl_autoload_register(function ($class) {
    $paths = [__DIR__.'/auth/',__DIR__.'/files/',__DIR__.'/api/',__DIR__.'/shared/'];
    foreach ($paths as $p) { $f=$p.$class.'.php'; if(file_exists($f)){require_once $f;return;} }
});
class AuthException extends Exception {}
class NotFoundException extends Exception {}
class ValidationException extends Exception {}
function h($s){return htmlspecialchars($s??'',ENT_QUOTES,'UTF-8');}
function size_human($b){$b=intval($b);$u=['B','KB','MB','GB','TB'];$i=0;while($b>=1024&&$i<4){$b/=1024;$i++;}return round($b,$i?1:0).' '.$u[$i];}
PHPEOF

pct exec "$CT_ID" -- bash -c "cat > /var/www/vault/src/shared/Database.php" << 'PHPEOF'
<?php
class Database {
    private static ?Database $i=null;
    private PDO $pdo;
    private function __construct(){
        $this->pdo=new PDO('mysql:host='.DB_HOST.';dbname='.DB_NAME.';charset=utf8mb4',DB_USER,DB_PASS,[
            PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE=>PDO::FETCH_ASSOC,
            PDO::ATTR_EMULATE_PREPARES=>false,
        ]);
    }
    public static function getInstance():self{if(!self::$i)self::$i=new self();return self::$i;}
    public function fetch(string $sql,array $p=[]):?array{$s=$this->pdo->prepare($sql);$s->execute($p);return $s->fetch()?:null;}
    public function fetchAll(string $sql,array $p=[]):array{$s=$this->pdo->prepare($sql);$s->execute($p);return $s->fetchAll();}
    public function execute(string $sql,array $p=[]):int{$s=$this->pdo->prepare($sql);$s->execute($p);return (int)$this->pdo->lastInsertId()?:$s->rowCount();}
}
PHPEOF

pct exec "$CT_ID" -- bash -c "cat > /var/www/vault/src/shared/AppSettings.php" << 'PHPEOF'
<?php
class AppSettings {
    public static function get(string $key,$default=null){
        try{$r=Database::getInstance()->fetch('SELECT setting_value FROM app_settings WHERE setting_key=?',[$key]);return $r?$r['setting_value']:$default;}catch(Throwable $e){return $default;}
    }
    public static function set(string $key,$value):void{
        Database::getInstance()->execute('INSERT INTO app_settings (setting_key,setting_value) VALUES (?,?) ON DUPLICATE KEY UPDATE setting_value=VALUES(setting_value)',[$key,$value]);
    }
    public static function all():array{
        try{$rows=Database::getInstance()->fetchAll('SELECT setting_key,setting_value FROM app_settings');$out=[];foreach($rows as $r)$out[$r['setting_key']]=$r['setting_value'];return $out;}catch(Throwable $e){return [];}
    }
    public static function bool(string $key,bool $default=false):bool{return in_array((string)self::get($key,$default?'1':'0'),['1','true','yes','on'],true);}
}
PHPEOF

pct exec "$CT_ID" -- bash -c "cat > /var/www/vault/src/auth/Auth.php" << 'PHPEOF'
<?php
class Auth {
    public static function check():bool{
        if(!isset($_SESSION['user_id'])||empty($_SESSION['user_id'])||!empty($_SESSION['totp_pending']))return false;
        try{
            $r=Database::getInstance()->fetch('SELECT session_version,active FROM users WHERE id=?',[(int)$_SESSION['user_id']]);
            if(!$r||!(int)$r['active'])return false;
            if((int)($r['session_version']??1)!==(int)($_SESSION['session_version']??1)){self::logout(false);return false;}
            return true;
        }catch(Throwable $e){return true;}
    }
    public static function user():?array{if(!self::check())return null;return Database::getInstance()->fetch("SELECT id,username,email,display_name,role,storage_quota,storage_used,avatar,totp_enabled,theme,language,session_version FROM users WHERE id=? AND active=1",[$_SESSION['user_id']]);}
    public static function requireAuth():array{if(!self::check())throw new AuthException('Sesión requerida');$u=self::user();if(!$u){self::logout();throw new AuthException('Usuario no válido');}return $u;}
    public static function requireAdmin():array{$u=self::requireAuth();if($u['role']!=='admin')throw new AuthException('Permisos de administrador requeridos');return $u;}
    public static function login(string $user,string $pass):array{
        $db=Database::getInstance();
        $u=$db->fetch("SELECT * FROM users WHERE (username=? OR email=?) AND active=1",[$user,$user]);
        if(!$u||!password_verify($pass,$u['password'])){$db->execute("INSERT INTO activity_log (action,target,ip) VALUES (?,?,?)",['login_failed',$user,$_SERVER['REMOTE_ADDR']??'']);throw new AuthException('Usuario o contraseña incorrectos');}
        if($u['totp_enabled']){session_regenerate_id(true);$_SESSION['totp_pending']=$u['id'];return['status'=>'totp'];}
        self::finalizeLogin($u);return['status'=>'ok','user'=>$u];
    }
    public static function verifyTotp(string $code):array{
        if(empty($_SESSION['totp_pending']))throw new AuthException('No hay 2FA pendiente');
        $db=Database::getInstance();$uid=(int)$_SESSION['totp_pending'];
        $u=$db->fetch("SELECT * FROM users WHERE id=? AND active=1",[$uid]);
        if(!$u)throw new AuthException('Usuario no válido');
        $code=preg_replace('/\s/','',$code);
        if($u['totp_secret']&&self::totpVerify($u['totp_secret'],$code)){unset($_SESSION['totp_pending']);self::finalizeLogin($u);return $u;}
        if($u['totp_backup']){$bk=json_decode($u['totp_backup'],true)??[];foreach($bk as $i=>$b){if(hash_equals($b,hash('sha256',$code))){unset($bk[$i]);$db->execute("UPDATE users SET totp_backup=? WHERE id=?",[json_encode(array_values($bk)),$uid]);unset($_SESSION['totp_pending']);self::finalizeLogin($u);return $u;}}}
        throw new AuthException('Código 2FA incorrecto');
    }
    private static function finalizeLogin(array $u):void{session_regenerate_id(true);$_SESSION['user_id']=$u['id'];$_SESSION['user_role']=$u['role'];$_SESSION['session_version']=(int)($u['session_version']??1);$db=Database::getInstance();$db->execute("UPDATE users SET last_login=NOW() WHERE id=?",[$u['id']]);$db->execute("INSERT INTO activity_log (user_id,action,target,ip) VALUES (?,?,?,?)",[$u['id'],'login','Sesión iniciada',$_SERVER['REMOTE_ADDR']??'']);}
    public static function logout(bool $log=true):void{if($log&&isset($_SESSION['user_id'])){Database::getInstance()->execute("INSERT INTO activity_log (user_id,action,target,ip) VALUES (?,?,?,?)",[$_SESSION['user_id'],'logout','Sesión cerrada',$_SERVER['REMOTE_ADDR']??'']);}$_SESSION=[];session_destroy();}
    public static function totpGenerateSecret():string{$c='ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';$s='';for($i=0;$i<32;$i++)$s.=$c[random_int(0,31)];return $s;}
    public static function totpVerify(string $s,string $code,int $w=2):bool{$t=floor(time()/30);for($i=-$w;$i<=$w;$i++){if(self::totpCode($s,$t+$i)===$code)return true;}return false;}
    public static function debugCodes(string $s,int $w=2):array{$t=floor(time()/30);$out=[];for($i=-$w;$i<=$w;$i++){$out[]=self::totpCode($s,$t+$i);}return $out;}
    public static function totpCode(string $s,int $t):string{$k=self::b32d($s);$m=pack('N*',0).pack('N*',$t);$h=hash_hmac('sha1',$m,$k,true);$o=ord($h[19])&0xf;$c=((ord($h[$o])&0x7f)<<24)|((ord($h[$o+1])&0xff)<<16)|((ord($h[$o+2])&0xff)<<8)|(ord($h[$o+3])&0xff);return str_pad((string)($c%1000000),6,'0',STR_PAD_LEFT);}
    private static function b32d(string $s):string{static $m=['A'=>0,'B'=>1,'C'=>2,'D'=>3,'E'=>4,'F'=>5,'G'=>6,'H'=>7,'I'=>8,'J'=>9,'K'=>10,'L'=>11,'M'=>12,'N'=>13,'O'=>14,'P'=>15,'Q'=>16,'R'=>17,'S'=>18,'T'=>19,'U'=>20,'V'=>21,'W'=>22,'X'=>23,'Y'=>24,'Z'=>25,'2'=>26,'3'=>27,'4'=>28,'5'=>29,'6'=>30,'7'=>31];$s=strtoupper(rtrim($s,'='));$b=0;$bits=0;$out='';for($i=0;$i<strlen($s);$i++){if(!isset($m[$s[$i]]))continue;$b=($b<<5)|$m[$s[$i]];$bits+=5;if($bits>=8){$out.=chr(($b>>($bits-8))&0xff);$bits-=8;}}return $out;}
    public static function totpQrUrl(string $s,string $u,string $iss):string{$o="otpauth://totp/".rawurlencode("$iss:$u")."?secret=$s&issuer=".rawurlencode($iss)."&digits=6&period=30";return"https://api.qrserver.com/v1/create-qr-code/?size=220x220&data=".urlencode($o);}
    public static function generateBackupCodes():array{$c=[];for($i=0;$i<8;$i++){$c[]=strtolower(bin2hex(random_bytes(4))).'-'.strtolower(bin2hex(random_bytes(4)));}return $c;}
}
PHPEOF
pct exec "$CT_ID" -- bash -c "cat > /var/www/vault/src/shared/Mailer.php" << 'PHPEOF'
<?php
class Mailer {
    private static function cfg(string $key,string $const='',string $default=''):string{
        $v=class_exists('AppSettings')?AppSettings::get($key,null):null;
        if($v!==null && $v!=='')return (string)$v;
        return ($const && defined($const))?(string)constant($const):$default;
    }
    public static function isConfigured():bool{
        $enabled=class_exists('AppSettings')?AppSettings::bool('smtp_enabled',defined('SMTP_HOST')&&SMTP_HOST!==''):(defined('SMTP_HOST')&&SMTP_HOST!=='');
        return $enabled && self::cfg('smtp_host','SMTP_HOST')!=='';
    }
    public static function writeMsmtpConfig(array $cfg):void{
        $host=trim($cfg['smtp_host']??'');$port=trim((string)($cfg['smtp_port']??''));$sec=$cfg['smtp_security']??'ssl';$user=trim($cfg['smtp_user']??'');$pass=(string)($cfg['smtp_pass']??'');$from=trim($cfg['smtp_from']??$user);
        $enabled=!empty($cfg['smtp_enabled'])&&$host!=='';
        if(!$enabled){@file_put_contents('/etc/msmtprc',"# Vault SMTP deshabilitado\n");return;}
        $tls=$sec==='none'?'tls off':'tls on';$start=$sec==='tls'?'tls_starttls on':'tls_starttls off';
        $txt="defaults\nauth on\n$tls\n$start\ntls_trust_file /etc/ssl/certs/ca-certificates.crt\nlogfile /var/log/msmtp.log\n\naccount vault\nhost $host\nport $port\nfrom $from\nuser $user\npassword $pass\n\naccount default : vault\n";
        @file_put_contents('/etc/msmtprc',$txt);@chmod('/etc/msmtprc',0600);
    }
    public static function send(string $to,string $subject,string $htmlBody,string $textBody=''):bool{
        if(!self::isConfigured())return false;
        $from=self::cfg('smtp_from','SMTP_FROM')?:self::cfg('smtp_user','SMTP_USER');
        $appName=self::cfg('app_name','APP_NAME','Vault');
        if($textBody==='')$textBody=trim(strip_tags(str_replace(['<br>','</p>','</div>'],"\n",$htmlBody)));
        $eol="\r\n";$boundary='vault_'.md5(uniqid((string)mt_rand(),true));$domain=substr(strrchr($from,'@'),1)?:'localhost';
        $headers ='From: '.self::encodeHeader($appName).' <'.$from.'>'.$eol;
        $headers.='Reply-To: '.$from.$eol.'Return-Path: '.$from.$eol.'Message-ID: <'.$boundary.'@'.$domain.'>'.$eol.'Date: '.date('r').$eol.'X-Mailer: '.$appName.$eol.'MIME-Version: 1.0'.$eol.'Content-Type: multipart/alternative; boundary="'.$boundary.'"'.$eol;
        $body ='--'.$boundary.$eol.'Content-Type: text/plain; charset=UTF-8'.$eol.'Content-Transfer-Encoding: 8bit'.$eol.$eol.$textBody.$eol.$eol;
        $body.='--'.$boundary.$eol.'Content-Type: text/html; charset=UTF-8'.$eol.'Content-Transfer-Encoding: 8bit'.$eol.$eol.$htmlBody.$eol.$eol.'--'.$boundary.'--'.$eol;
        return @mail($to,self::encodeHeader($subject),$body,$headers,'-f'.$from);
    }
    private static function encodeHeader(string $s):string{return preg_match('/[\x80-\xff]/',$s)?'=?UTF-8?B?'.base64_encode($s).'?=':$s;}
    public static function sendShare(string $to,string $sender,string $url,string $filename,bool $isFolder=false):bool{
        $appName=self::cfg('app_name','APP_NAME','Vault');$u=htmlspecialchars($url,ENT_QUOTES);$n=htmlspecialchars($filename,ENT_QUOTES);$s=htmlspecialchars($sender,ENT_QUOTES);$tipo=$isFolder?'una carpeta':'un archivo';
        $subject=$sender.' ha compartido '.$tipo.' contigo';
        $textBody="Hola,\n\n".$sender.' ha compartido '.$tipo.' contigo a traves de '.$appName.': "'.$filename."\".\n\nPuedes acceder desde este enlace:\n".$url."\n\nSi no esperabas este mensaje, puedes ignorarlo.\n\n-- \n".$appName;
        $html='<!DOCTYPE html><html lang="es"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head><body style="margin:0;padding:0;background:#f4f3fb;font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif"><div style="max-width:520px;margin:0 auto;padding:32px 20px"><div style="text-align:center;margin-bottom:24px"><span style="font-size:20px;font-weight:bold;color:#0f6cbd">'.htmlspecialchars($appName).'</span></div><div style="background:#ffffff;border:1px solid #e6e4f0;border-radius:16px;padding:32px"><p style="font-size:16px;line-height:1.6;color:#1a1530;margin:0 0 20px">Hola,</p><p style="font-size:16px;line-height:1.6;color:#1a1530;margin:0 0 24px"><strong>'.$s.'</strong> ha compartido '.$tipo.' contigo: <strong>'.$n.'</strong></p><div style="text-align:center;margin:28px 0"><a href="'.$u.'" style="display:inline-block;background:#0f6cbd;color:#ffffff;text-decoration:none;padding:13px 30px;border-radius:10px;font-weight:bold;font-size:15px">Ver '.($isFolder?'carpeta':'archivo').'</a></div><p style="font-size:13px;color:#6b6489;line-height:1.6;margin:24px 0 0">Si el boton no funciona, copia y pega este enlace en tu navegador:<br><a href="'.$u.'" style="color:#0f6cbd;word-break:break-all">'.$u.'</a></p></div><p style="font-size:12px;color:#9d97b5;text-align:center;margin:20px 0 0">Si no esperabas este mensaje, puedes ignorarlo con seguridad.</p></div></body></html>';
        return self::send($to,$subject,$html,$textBody);
    }
}
PHPEOF
msg_ok "Núcleo PHP desplegado"
msg_info "Desplegando gestor de archivos"

pct exec "$CT_ID" -- bash -c "cat > /var/www/vault/src/files/FileManager.php" << 'PHPEOF'
<?php
class FileManager {
    private Database $db;
    public function __construct(){$this->db=Database::getInstance();}

    public function listFolder(int $uid,?int $pid):array{
        $sql="SELECT f.id,f.name,f.type,f.mime_type,f.size,f.thumbnail,f.is_starred,f.created_at,f.updated_at,
                     u.display_name AS owner_name,u.username AS owner_username,
                     (SELECT COUNT(*) FROM shares s WHERE s.file_id=f.id) AS share_count,
                     CASE WHEN f.type='folder' THEN (SELECT COUNT(*) FROM files c WHERE c.parent_id=f.id AND c.user_id=f.user_id AND c.is_trashed=0) ELSE NULL END AS item_count
              FROM files f
              JOIN users u ON u.id=f.user_id
              WHERE f.user_id=? AND f.is_trashed=0 AND ".($pid?"f.parent_id=?":"f.parent_id IS NULL")."
              ORDER BY f.type='folder' DESC, f.name ASC";
        return $this->enrichFolderStats($this->db->fetchAll($sql,$pid?[$uid,$pid]:[$uid]),$uid);
    }
    private function enrichFolderStats(array $rows,int $uid):array{
        foreach($rows as &$r){
            if(($r['type']??'')==='folder'){$st=$this->folderStats($uid,(int)$r['id']);$r['folder_size']=$st['size'];$r['item_count']=$st['count'];}
        }
        return $rows;
    }
    public function folderStats(int $uid,int $folderId):array{
        $items=$this->db->fetchAll("SELECT id,type,size FROM files WHERE parent_id=? AND user_id=? AND is_trashed=0",[$folderId,$uid]);
        $size=0;$count=0;
        foreach($items as $it){$count++;if($it['type']==='folder'){$st=$this->folderStats($uid,(int)$it['id']);$size+=(int)$st['size'];$count+=(int)$st['count'];}else{$size+=(int)$it['size'];}}
        return ['size'=>$size,'count'=>$count];
    }
    public function getBreadcrumb(int $uid,?int $fid):array{
        $p=[];$c=$fid;
        while($c){$f=$this->db->fetch("SELECT id,name,parent_id FROM files WHERE id=? AND user_id=? AND type='folder'",[$c,$uid]);if(!$f)break;array_unshift($p,$f);$c=$f['parent_id'];}
        return $p;
    }
    public function createFolder(int $uid,string $name,?int $pid):int{
        $name=$this->san($name);
        $ex=$this->db->fetch("SELECT id FROM files WHERE user_id=? AND ".($pid?"parent_id=?":"parent_id IS NULL")." AND name=? AND type='folder' AND is_trashed=0",$pid?[$uid,$pid,$name]:[$uid,$name]);
        if($ex)throw new ValidationException('Ya existe una carpeta con ese nombre');
        return $this->db->execute("INSERT INTO files (user_id,parent_id,name,original_name,type,path) VALUES (?,?,?,?,'folder','')",[$uid,$pid,$name,$name]);
    }
    public function ensureFolderPath(int $uid,?int $baseParent,string $relativePath):?int{
        $relativePath=str_replace('\\','/',$relativePath);
        $relativePath=trim($relativePath,'/');
        if($relativePath===''||!str_contains($relativePath,'/'))return $baseParent;
        $parts=array_values(array_filter(explode('/',$relativePath),fn($p)=>trim($p)!==''));
        array_pop($parts); // último elemento = nombre de archivo
        $parent=$baseParent;
        foreach($parts as $part){
            $name=$this->san($part);
            $existing=$parent===null
                ?$this->db->fetch("SELECT id FROM files WHERE user_id=? AND parent_id IS NULL AND name=? AND type='folder' AND is_trashed=0",[$uid,$name])
                :$this->db->fetch("SELECT id FROM files WHERE user_id=? AND parent_id=? AND name=? AND type='folder' AND is_trashed=0",[$uid,$parent,$name]);
            if($existing){$parent=(int)$existing['id'];continue;}
            $parent=$this->db->execute("INSERT INTO files (user_id,parent_id,name,original_name,type,path) VALUES (?,?,?,?,'folder','')",[$uid,$parent,$name,$name]);
        }
        return $parent;
    }
    public function uploadFile(int $uid,array $file,?int $pid):array{
        if($file['error']!==UPLOAD_ERR_OK)throw new ValidationException('Error en la subida');
        $u=$this->db->fetch("SELECT storage_used,storage_quota FROM users WHERE id=?",[$uid]);
        if($u['storage_used']+$file['size']>$u['storage_quota'])throw new ValidationException('Sin espacio disponible');
        $name=$this->san($file['name']);$ext=strtolower(pathinfo($name,PATHINFO_EXTENSION));
        $mime=mime_content_type($file['tmp_name'])?:'application/octet-stream';
        $sn=uniqid('f_',true).($ext?".$ext":'');$ud=STORAGE_PATH."/$uid";
        if(!is_dir($ud))mkdir($ud,0750,true);
        $dest="$ud/$sn";if(!move_uploaded_file($file['tmp_name'],$dest))throw new ValidationException('Error al guardar');
        $tn=null;if(str_starts_with($mime,'image/')&&function_exists('imagecreatefromstring'))$tn=$this->thumb($dest,$uid,$sn);
        $rp="$uid/$sn";
        $id=$this->db->execute("INSERT INTO files (user_id,parent_id,name,original_name,type,mime_type,size,path,thumbnail) VALUES (?,?,?,?,?,?,?,?,?)",[$uid,$pid,$name,$name,'file',$mime,$file['size'],$rp,$tn]);
        $this->db->execute("UPDATE users SET storage_used=storage_used+? WHERE id=?",[$file['size'],$uid]);
        return['id'=>$id,'name'=>$name,'size'=>$file['size'],'mime_type'=>$mime];
    }
    public function getFile(int $uid,int $id):array{
        $f=$this->db->fetch("SELECT * FROM files WHERE id=? AND user_id=? AND type='file' AND is_trashed=0",[$id,$uid]);
        if(!$f)throw new NotFoundException('Archivo no encontrado');
        $p=STORAGE_PATH.'/'.$f['path'];
        if(!file_exists($p))throw new NotFoundException('Archivo no encontrado en disco');
        return['file'=>$f,'path'=>$p];
    }
    // Devuelve la fila (archivo o carpeta) sin exigir que sea 'file'
    public function getItem(int $uid,int $id):?array{
        $it=$this->db->fetch("SELECT * FROM files WHERE id=? AND user_id=? AND is_trashed=0",[$id,$uid]);
        if($it&&$it['type']==='folder'){$st=$this->folderStats($uid,(int)$it['id']);$it['folder_size']=$st['size'];$it['item_count']=$st['count'];}
        return $it;
    }
    // Comprime una carpeta (recursivo) a un ZIP temporal y devuelve su ruta
    public function zipFolder(int $uid,int $folderId,string $folderName):string{
        if(!class_exists('ZipArchive'))throw new ValidationException('Compresión ZIP no disponible en el servidor');
        $tmp=tempnam(sys_get_temp_dir(),'vault_zip_');
        $zip=new ZipArchive();
        if($zip->open($tmp,ZipArchive::OVERWRITE)!==true)throw new ValidationException('No se pudo crear el ZIP');
        $this->addFolderToZip($zip,$uid,$folderId,trim($folderName)?:'carpeta');
        $zip->close();
        return $tmp;
    }
    private function addFolderToZip(ZipArchive $zip,int $uid,int $folderId,string $basePath):void{
        $items=$this->db->fetchAll("SELECT id,name,type,path FROM files WHERE parent_id=? AND user_id=? AND is_trashed=0",[$folderId,$uid]);
        if(empty($items)){$zip->addEmptyDir($basePath);return;}
        foreach($items as $it){
            $entryName=$basePath.'/'.$it['name'];
            if($it['type']==='folder'){
                $this->addFolderToZip($zip,$uid,$it['id'],$entryName);
            } else {
                $fp=STORAGE_PATH.'/'.$it['path'];
                if(file_exists($fp))$zip->addFile($fp,$entryName);
            }
        }
    }
    // Comprime varios elementos (archivos y/o carpetas) en un ZIP
    public function zipItems(int $uid,array $ids):string{
        if(!class_exists('ZipArchive'))throw new ValidationException('Compresión ZIP no disponible en el servidor');
        $tmp=tempnam(sys_get_temp_dir(),'vault_bulk_');
        $zip=new ZipArchive();
        if($zip->open($tmp,ZipArchive::OVERWRITE)!==true)throw new ValidationException('No se pudo crear el ZIP');
        $used=[];
        foreach($ids as $id){
            $it=$this->db->fetch("SELECT * FROM files WHERE id=? AND user_id=? AND is_trashed=0",[$id,$uid]);
            if(!$it)continue;
            $base=$this->san($it['name']?:('item_'.$id));$name=$base;$n=2;
            while(in_array($name,$used)){$name=$base.' ('.$n.')';$n++;}
            $used[]=$name;
            if($it['type']==='folder'){$this->addFolderToZip($zip,$uid,(int)$it['id'],$name);}
            else{$fp=STORAGE_PATH.'/'.$it['path'];if(file_exists($fp))$zip->addFile($fp,$name);}
        }
        if($zip->numFiles===0){$zip->close();@unlink($tmp);throw new NotFoundException('No se encontraron archivos');}
        $zip->close();return $tmp;
    }
    // Mueve un elemento a otra carpeta (parent_id=null = raíz) con manejo de conflictos
    public function moveItem(int $uid,int $id,$parentId,string $conflict='error'):void{
        $item=$this->db->fetch("SELECT id,name,type,parent_id FROM files WHERE id=? AND user_id=? AND is_trashed=0",[$id,$uid]);
        if(!$item)throw new NotFoundException('Elemento no encontrado');
        if($parentId===''||$parentId===0||$parentId==='0')$parentId=null;
        if($parentId!==null)$parentId=(int)$parentId;
        if($parentId!==null){
            $target=$this->db->fetch("SELECT id FROM files WHERE id=? AND user_id=? AND type='folder' AND is_trashed=0",[$parentId,$uid]);
            if(!$target)throw new ValidationException('Carpeta destino no válida');
            if($item['type']==='folder'){
                if((int)$item['id']===$parentId)throw new ValidationException('No puedes mover una carpeta dentro de sí misma');
                $cursor=$parentId;
                while($cursor){$p=$this->db->fetch("SELECT id,parent_id FROM files WHERE id=? AND user_id=? AND type='folder'",[$cursor,$uid]);if(!$p)break;if((int)$p['id']===(int)$item['id'])throw new ValidationException('No puedes mover una carpeta dentro de una subcarpeta propia');$cursor=$p['parent_id']?(int)$p['parent_id']:null;}
            }
        }
        $dup=$parentId===null
            ?$this->db->fetch("SELECT id FROM files WHERE user_id=? AND parent_id IS NULL AND name=? AND id<>? AND is_trashed=0",[$uid,$item['name'],$id])
            :$this->db->fetch("SELECT id FROM files WHERE user_id=? AND parent_id=? AND name=? AND id<>? AND is_trashed=0",[$uid,$parentId,$item['name'],$id]);
        if($dup){
            if($conflict==='rename'){
                $newName=$this->moveUniqueName($uid,$parentId,$item['name'],$id);
                $this->db->execute("UPDATE files SET parent_id=?,name=?,original_name=? WHERE id=? AND user_id=?",[$parentId,$newName,$newName,$id,$uid]);
                return;
            }elseif($conflict==='replace'){$this->delete($uid,(int)$dup['id']);}
            else{throw new ValidationException('DUPLICATE_NAME: Ya existe un elemento con ese nombre en el destino');}
        }
        $this->db->execute("UPDATE files SET parent_id=? WHERE id=? AND user_id=?",[$parentId,$id,$uid]);
    }
    private function moveUniqueName(int $uid,$parentId,string $name,int $excludeId):string{
        $base=$name;$ext='';$dot=strrpos($name,'.');
        if($dot!==false){$base=substr($name,0,$dot);$ext=substr($name,$dot);}
        $i=2;
        do{$cand=$base.' ('.$i.')'.$ext;
            $dup=$parentId===null
                ?$this->db->fetch("SELECT id FROM files WHERE user_id=? AND parent_id IS NULL AND name=? AND id<>? AND is_trashed=0",[$uid,$cand,$excludeId])
                :$this->db->fetch("SELECT id FROM files WHERE user_id=? AND parent_id=? AND name=? AND id<>? AND is_trashed=0",[$uid,$parentId,$cand,$excludeId]);
            $i++;
        }while($dup);
        return $cand;
    }
    public function trash(int $uid,int $id):void{$this->db->execute("UPDATE files SET is_trashed=1,trashed_at=NOW() WHERE id=? AND user_id=?",[$id,$uid]);}
    public function restore(int $uid,int $id):void{$this->db->execute("UPDATE files SET is_trashed=0,trashed_at=NULL WHERE id=? AND user_id=?",[$id,$uid]);}
    public function delete(int $uid,int $id):void{
        $f=$this->db->fetch("SELECT * FROM files WHERE id=? AND user_id=?",[$id,$uid]);if(!$f)return;
        if($f['type']==='folder'){
            // Borrar recursivamente el contenido (archivos físicos + restar espacio)
            $children=$this->db->fetchAll("SELECT id FROM files WHERE parent_id=? AND user_id=?",[$id,$uid]);
            foreach($children as $c){$this->delete($uid,$c['id']);}
        } else {
            $p=STORAGE_PATH.'/'.$f['path'];if(file_exists($p))unlink($p);
            if($f['thumbnail']){$t=THUMB_PATH.'/'.$f['thumbnail'];if(file_exists($t))unlink($t);}
            $this->db->execute("UPDATE users SET storage_used=GREATEST(0,storage_used-?) WHERE id=?",[$f['size'],$uid]);
        }
        $this->db->execute("DELETE FROM files WHERE id=? AND user_id=?",[$id,$uid]);
    }
    public function toggleStar(int $uid,int $id):bool{
        $f=$this->db->fetch("SELECT is_starred FROM files WHERE id=? AND user_id=?",[$id,$uid]);if(!$f)throw new NotFoundException('No encontrado');
        $v=$f['is_starred']?0:1;$this->db->execute("UPDATE files SET is_starred=? WHERE id=? AND user_id=?",[$v,$id,$uid]);return(bool)$v;
    }
    public function toggleStarOn(int $uid,int $id):void{$this->db->execute("UPDATE files SET is_starred=1 WHERE id=? AND user_id=?",[$id,$uid]);}
    public function rename(int $uid,int $id,string $name):void{$this->db->execute("UPDATE files SET name=? WHERE id=? AND user_id=?",[$this->san($name),$id,$uid]);}
    public function search(int $uid,string $q):array{return $this->enrichFolderStats($this->db->fetchAll("SELECT f.id,f.name,f.type,f.mime_type,f.size,f.thumbnail,f.is_starred,f.created_at,f.updated_at,u.display_name AS owner_name,u.username AS owner_username,(SELECT COUNT(*) FROM shares s WHERE s.file_id=f.id) AS share_count,CASE WHEN f.type='folder' THEN (SELECT COUNT(*) FROM files c WHERE c.parent_id=f.id AND c.user_id=f.user_id AND c.is_trashed=0) ELSE NULL END AS item_count FROM files f JOIN users u ON u.id=f.user_id WHERE f.user_id=? AND f.is_trashed=0 AND f.name LIKE ? ORDER BY f.type DESC,f.name ASC LIMIT 50",[$uid,"%$q%"]),$uid);}
    public function createShare(int $uid,int $fid,?string $pass,?string $exp,?int $maxdl):array{
        $f=$this->db->fetch("SELECT id FROM files WHERE id=? AND user_id=? AND is_trashed=0",[$fid,$uid]);if(!$f)throw new NotFoundException('No encontrado');
        $hasSecurity=($pass!==null&&$pass!=='')||($exp!==null&&$exp!=='')||($maxdl!==null&&$maxdl>0);
        if(!$hasSecurity){
            $existing=$this->db->fetch("SELECT id,token FROM shares WHERE file_id=? AND user_id=? AND password IS NULL AND expires_at IS NULL AND max_downloads IS NULL ORDER BY id DESC LIMIT 1",[$fid,$uid]);
            if($existing)return ['id'=>(int)$existing['id'],'token'=>$existing['token'],'created'=>false];
        }
        $tok=bin2hex(random_bytes(16));$hp=($pass!==null&&$pass!=='')?password_hash($pass,PASSWORD_BCRYPT):null;
        $exp=($exp!==null&&$exp!=='')?$exp:null;$maxdl=($maxdl!==null&&$maxdl>0)?$maxdl:null;
        $sid=$this->db->execute("INSERT INTO shares (file_id,user_id,token,password,expires_at,max_downloads) VALUES (?,?,?,?,?,?)",[$fid,$uid,$tok,$hp,$exp,$maxdl]);
        return ['id'=>(int)$sid,'token'=>$tok,'created'=>true];
    }
    public function updateShare(int $uid,int $sid,?string $pass,?string $exp,?int $maxdl):array{
        $s=$this->db->fetch("SELECT id,token FROM shares WHERE id=? AND user_id=?",[$sid,$uid]);if(!$s)throw new NotFoundException('Link no encontrado');
        $hp=($pass!==null&&$pass!=='')?password_hash($pass,PASSWORD_BCRYPT):null;
        $exp=($exp!==null&&$exp!=='')?$exp:null;$maxdl=($maxdl!==null&&$maxdl>0)?$maxdl:null;
        $this->db->execute("UPDATE shares SET password=?,expires_at=?,max_downloads=? WHERE id=? AND user_id=?",[$hp,$exp,$maxdl,$sid,$uid]);
        return ['id'=>(int)$s['id'],'token'=>$s['token']];
    }
    public function getShares(int $uid):array{return $this->db->fetchAll("SELECT s.*,f.name,f.type,f.size,f.mime_type,u.display_name AS owner_name,u.username AS owner_username FROM shares s JOIN files f ON s.file_id=f.id JOIN users u ON u.id=s.user_id WHERE s.user_id=? ORDER BY s.created_at DESC",[$uid]);}
    public function deleteShare(int $uid,int $id):void{$this->db->execute("DELETE FROM shares WHERE id=? AND user_id=?",[$id,$uid]);}

    // Streaming con soporte de Range (vídeo/audio/seek)
    public static function streamFile(string $path,string $mime,bool $inline=true):void{
        $size=filesize($path);$start=0;$end=$size-1;
        header('Content-Type: '.$mime);
        header('Accept-Ranges: bytes');
        $disp=$inline?'inline':'attachment';
        if(isset($_SERVER['HTTP_RANGE'])&&preg_match('/bytes=(\d+)-(\d*)/',$_SERVER['HTTP_RANGE'],$m)){
            $start=(int)$m[1];if($m[2]!=='')$end=(int)$m[2];
            if($start>$end||$start>=$size){header('HTTP/1.1 416 Range Not Satisfiable');header("Content-Range: bytes */$size");exit;}
            header('HTTP/1.1 206 Partial Content');
            header("Content-Range: bytes $start-$end/$size");
        }
        $len=$end-$start+1;
        header('Content-Length: '.$len);
        if($inline)header('Content-Disposition: inline');else header('Content-Disposition: attachment; filename="'.basename($path).'"');
        $fp=fopen($path,'rb');fseek($fp,$start);$buf=8192;$rem=$len;
        while($rem>0&&!feof($fp)){$read=($rem>$buf)?$buf:$rem;echo fread($fp,$read);$rem-=$read;flush();}
        fclose($fp);exit;
    }
    private function thumb(string $src,int $uid,string $name):?string{
        try{$img=imagecreatefromstring(file_get_contents($src));if(!$img)return null;
        $w=imagesx($img);$h=imagesy($img);$tw=400;$th=300;$r=min($tw/$w,$th/$h);$nw=(int)($w*$r);$nh=(int)($h*$r);
        $t=imagecreatetruecolor($nw,$nh);imagecopyresampled($t,$img,0,0,0,0,$nw,$nh,$w,$h);
        $td=THUMB_PATH."/$uid";if(!is_dir($td))mkdir($td,0750,true);$tn="$uid/thumb_$name.jpg";
        imagejpeg($t,THUMB_PATH."/$tn",82);imagedestroy($img);imagedestroy($t);return $tn;}catch(Throwable $e){return null;}
    }
    public function largestFiles(int $uid,int $limit=100):array{
        $limit=max(1,min(500,$limit));
        $rows=$this->db->fetchAll("SELECT f.id,f.name,f.type,f.mime_type,f.size,f.thumbnail,f.is_starred,f.parent_id,f.created_at,f.updated_at,
                     u.display_name AS owner_name,u.username AS owner_username,
                     (SELECT COUNT(*) FROM shares s WHERE s.file_id=f.id) AS share_count
              FROM files f
              JOIN users u ON u.id=f.user_id
              WHERE f.user_id=? AND f.type='file' AND f.is_trashed=0
              ORDER BY f.size DESC, f.updated_at DESC
              LIMIT $limit",[$uid]);
        foreach($rows as &$r){
            $r['location']=$this->folderPathText($uid,$r['parent_id']?intval($r['parent_id']):null);
            $r['location_folder_id']=$r['parent_id']?intval($r['parent_id']):null;
        }
        return $rows;
    }
    private function folderPathText(int $uid,?int $parentId):string{
        if($parentId===null)return 'Mis archivos';
        $names=[];$cursor=$parentId;$guard=0;
        while($cursor&&$guard<100){
            $f=$this->db->fetch("SELECT id,name,parent_id FROM files WHERE id=? AND user_id=? AND type='folder'",[$cursor,$uid]);
            if(!$f)break;
            array_unshift($names,$f['name']);
            $cursor=$f['parent_id']?intval($f['parent_id']):null;
            $guard++;
        }
        return 'Mis archivos'.(empty($names)?'':' › '.implode(' › ',$names));
    }

    public function makeThumb(string $src,int $uid,string $name):?string{return $this->thumb($src,$uid,$name);}
    private function san(string $s):string{return substr(trim(preg_replace('/[\/\\\\:*?"<>|]/','_',$s)),0,255)?:'sin_nombre';}
}
PHPEOF
msg_ok "Gestor de archivos desplegado"
msg_info "Desplegando enrutador API"

pct exec "$CT_ID" -- bash -c "cat > /var/www/vault/src/api/Router.php" << 'PHPEOF'
<?php
class Router {
    public function dispatch(string $method,string $route):void{
        $parts=array_values(array_filter(explode('/',trim($route,'/')),fn($p)=>$p!==''));
        $resource=$parts[0]??'';
        $id=null;$action='';
        if(isset($parts[1])){
            if(ctype_digit($parts[1])){$id=(int)$parts[1];$action=$parts[2]??'';}
            else{$action=$parts[1];if(isset($parts[2])&&ctype_digit($parts[2]))$id=(int)$parts[2];}
        }
        match($resource){
            'auth'=>$this->auth($method,$action),
            'files'=>$this->files($method,$id,$action),
            'folders'=>$this->folders($method,$id),
            'bulk-download'=>$this->bulkDownload($method),
            'bulk'=>$this->bulk($method,$action),
            'upload'=>$this->upload(),'upload-chunk'=>$this->uploadChunk(),'upload-complete'=>$this->uploadComplete(),
            'download'=>$this->download($id),
            'view'=>$this->view($id),
            'thumb'=>$this->thumb($id),
            'shares'=>$this->shares($method,$id,$action),
            'search'=>$this->search(),
            'trash'=>$this->trash($method,$id),
            'user'=>$this->user($method,$action),
            'admin'=>$this->admin($method,$action,$id),
            'avatar'=>$this->avatar($id),
            default=>throw new NotFoundException("Ruta no encontrada: $route"),
        };
    }
    private function auth(string $m,string $a):void{
        if($m==='POST'&&$a==='login'){$d=$this->json();$r=Auth::login($d['username']??'',$d['password']??'');if($r['status']==='totp'){echo json_encode(['ok'=>true,'totp_required'=>true]);}else{$u=$r['user'];echo json_encode(['ok'=>true,'user'=>['id'=>$u['id'],'username'=>$u['username'],'role'=>$u['role'],'display_name'=>$u['display_name']]]);}}
        elseif($m==='POST'&&$a==='totp-verify'){$d=$this->json();$u=Auth::verifyTotp($d['code']??'');echo json_encode(['ok'=>true,'user'=>['id'=>$u['id'],'username'=>$u['username'],'role'=>$u['role']]]);}
        elseif($m==='POST'&&$a==='logout'){Auth::logout();echo json_encode(['ok'=>true]);}
        elseif($m==='GET'&&$a==='me'){$u=Auth::requireAuth();echo json_encode(['ok'=>true,'user'=>$u]);}
        else throw new NotFoundException('Auth inválido');
    }
    private function files(string $m,?int $id,string $a):void{
        $u=Auth::requireAuth();$fm=new FileManager();
        if($m==='GET'&&$a==='largest'){$limit=isset($_GET['limit'])?(int)$_GET['limit']:100;echo json_encode(['ok'=>true,'files'=>$fm->largestFiles($u['id'],$limit)]);}
        elseif($m==='GET'&&$a==='starred'){$f=Database::getInstance()->fetchAll("SELECT f.id,f.name,f.type,f.mime_type,f.size,f.thumbnail,f.is_starred,f.created_at,f.updated_at,u.display_name AS owner_name,u.username AS owner_username,(SELECT COUNT(*) FROM shares s WHERE s.file_id=f.id) AS share_count,CASE WHEN f.type='folder' THEN (SELECT COUNT(*) FROM files c WHERE c.parent_id=f.id AND c.user_id=f.user_id AND c.is_trashed=0) ELSE NULL END AS item_count FROM files f JOIN users u ON u.id=f.user_id WHERE f.user_id=? AND f.is_starred=1 AND f.is_trashed=0 ORDER BY f.name",[$u['id']]);foreach($f as &$row){if($row['type']==='folder'){$st=$fm->folderStats($u['id'],(int)$row['id']);$row['folder_size']=$st['size'];$row['item_count']=$st['count'];}}echo json_encode(['ok'=>true,'files'=>$f]);}
        elseif($m==='GET'&&!$id){$pid=isset($_GET['folder'])?(int)$_GET['folder']:null;echo json_encode(['ok'=>true,'files'=>$fm->listFolder($u['id'],$pid),'breadcrumb'=>$fm->getBreadcrumb($u['id'],$pid)]);}
        elseif($m==='DELETE'&&$id){$fm->trash($u['id'],$id);echo json_encode(['ok'=>true]);}
        elseif($m==='PATCH'&&$id&&$a==='rename'){$d=$this->json();$fm->rename($u['id'],$id,$d['name']??'');echo json_encode(['ok'=>true]);}
        elseif($m==='PATCH'&&$id&&$a==='move'){$d=$this->json();$fm->moveItem($u['id'],$id,$d['parent_id']??null,$d['conflict']??'error');echo json_encode(['ok'=>true]);}
        elseif($m==='POST'&&$id&&$a==='star'){echo json_encode(['ok'=>true,'starred'=>$fm->toggleStar($u['id'],$id)]);}
        else throw new NotFoundException('Acción inválida');
    }
    private function folders(string $m,?int $id):void{
        $u=Auth::requireAuth();$fm=new FileManager();
        if($m==='GET'){echo json_encode(['ok'=>true,'folders'=>Database::getInstance()->fetchAll("SELECT id,name,parent_id FROM files WHERE user_id=? AND type='folder' AND is_trashed=0 ORDER BY name ASC",[$u['id']])]);}
        elseif($m==='POST'){$d=$this->json();echo json_encode(['ok'=>true,'id'=>$fm->createFolder($u['id'],$d['name']??'Nueva carpeta',$d['parent_id']??null)]);}
        elseif($m==='DELETE'&&$id){$fm->trash($u['id'],$id);echo json_encode(['ok'=>true]);}
        else throw new NotFoundException('Acción inválida');
    }
    private function bulk(string $m,string $a):void{
        $u=Auth::requireAuth();$fm=new FileManager();$d=$this->json();
        $ids=array_values(array_filter(array_map('intval',$d['ids']??[]),fn($v)=>$v>0));
        if(empty($ids))throw new ValidationException('No se recibieron elementos');
        if($m==='POST'&&$a==='star'){foreach($ids as $i)$fm->toggleStarOn($u['id'],$i);echo json_encode(['ok'=>true]);}
        elseif($m==='POST'&&$a==='trash'){foreach($ids as $i)$fm->trash($u['id'],$i);echo json_encode(['ok'=>true]);}
        elseif($m==='POST'&&$a==='move'){$pid=$d['parent_id']??null;$conflict=$d['conflict']??'error';foreach($ids as $i)$fm->moveItem($u['id'],$i,$pid,$conflict);echo json_encode(['ok'=>true]);}
        else throw new NotFoundException('Acción inválida');
    }
    private function bulkDownload(string $m):void{
        if($m!=='GET')throw new NotFoundException('Método inválido');
        $u=Auth::requireAuth();
        $raw=trim($_GET['ids']??'');
        if($raw==='')throw new ValidationException('No se recibieron elementos');
        $ids=array_values(array_unique(array_filter(array_map('intval',explode(',',$raw)),fn($v)=>$v>0)));
        if(empty($ids))throw new ValidationException('No se recibieron elementos válidos');
        $path=(new FileManager())->zipItems($u['id'],$ids);
        $name='vault-seleccion-'.date('Ymd-His').'.zip';
        while(ob_get_level()>0)@ob_end_clean();
        header('Content-Type: application/zip');
        header('Content-Disposition: attachment; filename="'.$name.'"');
        header('Content-Length: '.filesize($path));
        header('Cache-Control: no-store');
        readfile($path);@unlink($path);exit;
    }
    private function upload():void{
        $u=Auth::requireAuth();$fm=new FileManager();
        session_write_close(); // no bloquear navegación durante subidas pequeñas
        if(empty($_FILES['file']))throw new ValidationException('No se recibió archivo');
        $pid=isset($_POST['folder_id'])&&$_POST['folder_id']!==''?(int)$_POST['folder_id']:null;
        $rel=$_POST['relative_path']??'';
        if($rel!=='')$pid=$fm->ensureFolderPath($u['id'],$pid,$rel);
        echo json_encode(['ok'=>true,'file'=>$fm->uploadFile($u['id'],$_FILES['file'],$pid)]);
    }
    private function download(?int $id):void{
        if(!$id)throw new NotFoundException('ID requerido');
        $u=Auth::requireAuth();$fm=new FileManager();
        $item=$fm->getItem($u['id'],$id);
        if(!$item)throw new NotFoundException('No encontrado');
        if($item['type']==='folder'){
            // Comprimir carpeta a ZIP y servirla
            $zipPath=$fm->zipFolder($u['id'],$id,$item['name']);
            $zipName=preg_replace('/[\/\\\\:*?"<>|]/','_',$item['name']).'.zip';
            header('Content-Type: application/zip');
            header('Content-Disposition: attachment; filename="'.rawurlencode($zipName).'"');
            header('Content-Length: '.filesize($zipPath));
            readfile($zipPath);
            @unlink($zipPath);
            exit;
        }
        ['file'=>$f,'path'=>$p]=$fm->getFile($u['id'],$id);
        FileManager::streamFile($p,$f['mime_type']?:'application/octet-stream',false);
    }
    private function view(?int $id):void{
        // Streaming inline para visor (imágenes, pdf, vídeo, audio) con soporte Range
        if(!$id)throw new NotFoundException('ID requerido');
        $u=Auth::requireAuth();$fm=new FileManager();['file'=>$f,'path'=>$p]=$fm->getFile($u['id'],$id);
        FileManager::streamFile($p,$f['mime_type']?:'application/octet-stream',true);
    }
    private function thumb(?int $id):void{
        if(!$id)throw new NotFoundException('ID requerido');
        $u=Auth::requireAuth();
        $f=Database::getInstance()->fetch("SELECT thumbnail,path,mime_type FROM files WHERE id=? AND user_id=?",[$id,$u['id']]);
        if(!$f)throw new NotFoundException('No encontrado');
        if($f['thumbnail']){$tp=THUMB_PATH.'/'.$f['thumbnail'];if(file_exists($tp)){header('Content-Type:image/jpeg');header('Cache-Control:max-age=86400');readfile($tp);exit;}}
        if(str_starts_with($f['mime_type']??'','image/')){$fp=STORAGE_PATH.'/'.$f['path'];if(file_exists($fp)){header('Content-Type:'.$f['mime_type']);header('Cache-Control:max-age=86400');readfile($fp);exit;}}
        throw new NotFoundException('Sin miniatura');
    }
    private function shares(string $m,?int $id,string $a=''):void{
        $u=Auth::requireAuth();$fm=new FileManager();
        if($m==='GET'){echo json_encode(['ok'=>true,'shares'=>$fm->getShares($u['id'])]);}
        elseif($m==='POST'&&$a==='email'){
            // Enviar un link existente por correo
            $d=$this->json();$to=trim($d['email']??'');$url=$d['url']??'';
            if(!filter_var($to,FILTER_VALIDATE_EMAIL))throw new ValidationException('Email no válido');
            if(!$url)throw new ValidationException('Falta el enlace');
            if(!Mailer::isConfigured())throw new ValidationException('El servidor no tiene SMTP configurado');
            $sent=Mailer::sendShare($to,$u['display_name']?:$u['username'],$url,$d['filename']??'un archivo',!empty($d['is_folder']));
            if(!$sent)throw new ValidationException('No se pudo enviar el correo');
            echo json_encode(['ok'=>true]);
        }
        elseif($m==='POST'){$d=$this->json();$sh=$fm->createShare($u['id'],(int)($d['file_id']??0),$d['password']??null,$d['expires_at']??null,isset($d['max_downloads'])&&$d['max_downloads']?(int)$d['max_downloads']:null);echo json_encode(['ok'=>true,'id'=>$sh['id'],'token'=>$sh['token'],'url'=>self::baseUrl().'/s/'.$sh['token'],'smtp'=>Mailer::isConfigured(),'existing'=>empty($sh['created'])]);}
        elseif($m==='PATCH'&&$id){$d=$this->json();$sh=$fm->updateShare($u['id'],$id,$d['password']??null,$d['expires_at']??null,isset($d['max_downloads'])&&$d['max_downloads']?(int)$d['max_downloads']:null);echo json_encode(['ok'=>true,'id'=>$sh['id'],'token'=>$sh['token'],'url'=>self::baseUrl().'/s/'.$sh['token'],'smtp'=>Mailer::isConfigured()]);}
        elseif($m==='DELETE'&&$id){$fm->deleteShare($u['id'],$id);echo json_encode(['ok'=>true]);}
        else throw new NotFoundException('Acción inválida');
    }
    private static function baseUrl():string{
        $configured=class_exists('AppSettings')?trim((string)AppSettings::get('app_url','')):'';
        if($configured!=='')return rtrim($configured,'/');
        $https=(!empty($_SERVER['HTTPS'])&&$_SERVER['HTTPS']!=='off')||(($_SERVER['HTTP_X_FORWARDED_PROTO']??'')==='https');
        return ($https?'https':'http').'://'.($_SERVER['HTTP_HOST']??'localhost');
    }
    private function search():void{
        $u=Auth::requireAuth();$q=trim($_GET['q']??'');
        if(strlen($q)<2){echo json_encode(['ok'=>true,'files'=>[]]);return;}
        echo json_encode(['ok'=>true,'files'=>(new FileManager())->search($u['id'],$q)]);
    }
    private function trash(string $m,?int $id):void{
        $u=Auth::requireAuth();$db=Database::getInstance();$fm=new FileManager();
        if($m==='GET'){echo json_encode(['ok'=>true,'files'=>$db->fetchAll("SELECT f.id,f.name,f.type,f.mime_type,f.size,f.trashed_at,f.updated_at,f.created_at,u.display_name AS owner_name,u.username AS owner_username,(SELECT COUNT(*) FROM shares s WHERE s.file_id=f.id) AS share_count,CASE WHEN f.type='folder' THEN (SELECT COUNT(*) FROM files c WHERE c.parent_id=f.id AND c.user_id=f.user_id) ELSE NULL END AS item_count FROM files f JOIN users u ON u.id=f.user_id WHERE f.user_id=? AND f.is_trashed=1 ORDER BY f.trashed_at DESC",[$u['id']])]);}
        elseif($m==='POST'&&$id){$fm->restore($u['id'],$id);echo json_encode(['ok'=>true]);}
        elseif($m==='DELETE'&&$id){$fm->delete($u['id'],$id);echo json_encode(['ok'=>true]);}
        elseif($m==='DELETE'&&!$id){foreach($db->fetchAll("SELECT id FROM files WHERE user_id=? AND is_trashed=1",[$u['id']]) as $it)$fm->delete($u['id'],$it['id']);echo json_encode(['ok'=>true]);}
        else throw new NotFoundException('Acción inválida');
    }
    private function user(string $m,string $a):void{
        $u=Auth::requireAuth();$db=Database::getInstance();
        if($m==='POST'&&$a==='password'){$d=$this->json();$c=$db->fetch("SELECT password FROM users WHERE id=?",[$u['id']]);if(!password_verify($d['current']??'',$c['password']))throw new ValidationException('Contraseña actual incorrecta');$db->execute("UPDATE users SET password=? WHERE id=?",[password_hash($d['new']??'',PASSWORD_BCRYPT,['cost'=>12]),$u['id']]);echo json_encode(['ok'=>true]);}
        elseif($m==='POST'&&$a==='profile'){$d=$this->json();$lang=($d['language']??($u['language']??'es'))==='en'?'en':'es';$theme=($d['theme']??($u['theme']??'light'))==='dark'?'dark':'light';$db->execute("UPDATE users SET display_name=?,email=?,language=?,theme=? WHERE id=?",[$d['display_name']??$u['display_name'],$d['email']??$u['email'],$lang,$theme,$u['id']]);echo json_encode(['ok'=>true,'language'=>$lang,'theme'=>$theme]);}
        elseif($m==='POST'&&$a==='avatar'){
            if(empty($_FILES['avatar']))throw new ValidationException('No se recibió imagen');
            $f=$_FILES['avatar'];if($f['error']!==UPLOAD_ERR_OK)throw new ValidationException('Error subiendo imagen');
            if($f['size']>2*1024*1024)throw new ValidationException('La imagen no puede superar 2 MB');
            $mime=mime_content_type($f['tmp_name'])?:'';
            $allowed=['image/jpeg'=>'jpg','image/png'=>'png','image/webp'=>'webp'];
            if(!isset($allowed[$mime]))throw new ValidationException('Formato no válido. Usa JPG, PNG o WEBP');
            $dir='/var/www/vault/storage/avatars';if(!is_dir($dir))mkdir($dir,0750,true);
            $old=$db->fetch('SELECT avatar FROM users WHERE id=?',[$u['id']]);
            if($old&&$old['avatar'])@unlink($dir.'/'.$old['avatar']);
            $name='avatar_'.$u['id'].'_'.time().'.'.$allowed[$mime];
            if(!move_uploaded_file($f['tmp_name'],$dir.'/'.$name))throw new ValidationException('No se pudo guardar la imagen');
            @chmod($dir.'/'.$name,0640);
            $db->execute('UPDATE users SET avatar=? WHERE id=?',[$name,$u['id']]);
            echo json_encode(['ok'=>true,'avatar'=>$name,'url'=>'/api/avatar/'.$u['id'].'?v='.time()]);
        }
        elseif($m==='DELETE'&&$a==='avatar'){
            $old=$db->fetch('SELECT avatar FROM users WHERE id=?',[$u['id']]);
            if($old&&$old['avatar'])@unlink('/var/www/vault/storage/avatars/'.$old['avatar']);
            $db->execute('UPDATE users SET avatar=NULL WHERE id=?',[$u['id']]);
            echo json_encode(['ok'=>true]);
        }
        elseif($m==='POST'&&$a==='theme'){$d=$this->json();$t=($d['theme']??'dark')==='light'?'light':'dark';$db->execute("UPDATE users SET theme=? WHERE id=?",[$t,$u['id']]);echo json_encode(['ok'=>true,'theme'=>$t]);}
        elseif($m==='GET'&&$a==='totp-setup'){$s=Auth::totpGenerateSecret();$_SESSION['totp_setup_secret']=$s;echo json_encode(['ok'=>true,'secret'=>$s,'qr'=>Auth::totpQrUrl($s,$u['username'],APP_NAME)]);}
        elseif($m==='POST'&&$a==='totp-enable'){$d=$this->json();$s=$_SESSION['totp_setup_secret']??null;if(!$s)throw new ValidationException('Sesión de configuración expirada. Recarga la página e inténtalo de nuevo.');if(!Auth::totpVerify($s,$d['code']??''))throw new ValidationException('Código incorrecto. Verifica que la hora de tu teléfono esté sincronizada.');$bp=Auth::generateBackupCodes();$db->execute("UPDATE users SET totp_secret=?,totp_enabled=1,totp_backup=? WHERE id=?",[$s,json_encode(array_map(fn($c)=>hash('sha256',$c),$bp)),$u['id']]);unset($_SESSION['totp_setup_secret']);echo json_encode(['ok'=>true,'backup_codes'=>$bp]);}
        elseif($m==='POST'&&$a==='totp-disable'){$d=$this->json();$c=$db->fetch("SELECT password FROM users WHERE id=?",[$u['id']]);if(!password_verify($d['password']??'',$c['password']))throw new ValidationException('Contraseña incorrecta');$db->execute("UPDATE users SET totp_secret=NULL,totp_enabled=0,totp_backup=NULL WHERE id=?",[$u['id']]);echo json_encode(['ok'=>true]);}
        else throw new NotFoundException('Acción inválida');
    }
    private function admin(string $m,string $a,?int $id):void{
        Auth::requireAdmin();$db=Database::getInstance();
        if($a==='users'&&$m==='GET'){
            echo json_encode(['ok'=>true,'users'=>$db->fetchAll("SELECT id,username,email,display_name,role,storage_quota,storage_used,avatar,language,active,last_login,created_at,session_version FROM users ORDER BY created_at DESC")]);
        }
        elseif($a==='users'&&$m==='POST'){
            $d=$this->json();$h=password_hash($d['password']??'changeme',PASSWORD_BCRYPT,['cost'=>12]);
            $nid=$db->execute("INSERT INTO users (username,email,password,display_name,role,storage_quota,session_version) VALUES (?,?,?,?,?,?,1)",[$d['username'],$d['email'],$h,$d['display_name']??$d['username'],$d['role']??'user',(int)($d['storage_quota']??10737418240)]);
            @mkdir(STORAGE_PATH."/$nid",0750,true);echo json_encode(['ok'=>true,'id'=>$nid]);
        }
        elseif($a==='users'&&$m==='DELETE'&&$id){
            $me=Auth::user();if($id===$me['id'])throw new ValidationException('No puedes eliminar tu propio usuario');
            $db->execute("DELETE FROM users WHERE id=?",[$id]);echo json_encode(['ok'=>true]);
        }
        elseif($a==='users'&&$m==='PATCH'&&$id){
            $d=$this->json();
            if(isset($d['storage_quota'])){$db->execute("UPDATE users SET storage_quota=? WHERE id=?",[(int)$d['storage_quota'],$id]);}
            if(isset($d['role'])&&in_array($d['role'],['admin','user'])){$db->execute("UPDATE users SET role=? WHERE id=?",[$d['role'],$id]);}
            echo json_encode(['ok'=>true]);
        }
        elseif($a==='session'&&$m==='POST'&&$id){
            $me=Auth::user();if($id===(int)$me['id'])throw new ValidationException('No puedes cerrar tu propia sesión desde aquí');
            $target=$db->fetch("SELECT username,display_name,email FROM users WHERE id=?",[$id]);if(!$target)throw new NotFoundException('Usuario no encontrado');
            $db->execute("UPDATE users SET session_version=session_version+1 WHERE id=?",[$id]);
            $label=($target['display_name']?:$target['username']);
            $db->execute("INSERT INTO activity_log (user_id,action,target,ip) VALUES (?,?,?,?)",[$me['id'],'admin_force_logout','Sesión cerrada por administrador para '.$label,$_SERVER['REMOTE_ADDR']??'']);
            echo json_encode(['ok'=>true]);
        }
        elseif($a==='stats'&&$m==='GET'){
            echo json_encode(['ok'=>true,'stats'=>[
                'users'=>$db->fetch("SELECT COUNT(*) c FROM users")['c'],
                'files'=>$db->fetch("SELECT COUNT(*) c FROM files WHERE type='file' AND is_trashed=0")['c'],
                'total_size'=>$db->fetch("SELECT COALESCE(SUM(storage_used),0) s FROM users")['s'],
                'shares'=>$db->fetch("SELECT COUNT(*) c FROM shares")['c']
            ]]);
        }
        elseif($a==='shares'&&$m==='GET'){
            $rows=$db->fetchAll("SELECT s.id,s.file_id,s.user_id,s.token,s.password,s.expires_at,s.allow_download,s.downloads,s.max_downloads,s.created_at,
                    f.name,f.type,f.mime_type,f.size,f.is_trashed,
                    u.username AS owner_username,u.display_name AS owner_name,u.email AS owner_email
                FROM shares s
                JOIN files f ON f.id=s.file_id
                JOIN users u ON u.id=s.user_id
                ORDER BY s.created_at DESC LIMIT 300");
            $fm=new FileManager();foreach($rows as &$r){if($r['type']==='folder'){$st=$fm->folderStats((int)$r['user_id'],(int)$r['file_id']);$r['folder_size']=$st['size'];$r['item_count']=$st['count'];}$r['url']=self::baseUrl().'/s/'.$r['token'];$r['has_password']=!empty($r['password']);unset($r['password']);}
            echo json_encode(['ok'=>true,'shares'=>$rows]);
        }
        elseif($a==='shares'&&$m==='DELETE'&&$id){
            $db->execute("DELETE FROM shares WHERE id=?",[$id]);echo json_encode(['ok'=>true]);
        }
        elseif($a==='activity'&&$m==='GET'){
            $rows=$db->fetchAll("SELECT a.id,a.user_id,a.action,a.target,a.ip,a.created_at,u.username,u.display_name,u.email
                FROM activity_log a LEFT JOIN users u ON u.id=a.user_id
                ORDER BY a.created_at DESC LIMIT 300");
            foreach($rows as &$r){if(($r['target']??'')===''){$r['target']=match($r['action']){'login'=>'Sesión iniciada','logout'=>'Sesión cerrada',default=>'No disponible'};}}
            echo json_encode(['ok'=>true,'activity'=>$rows]);
        }
        elseif($a==='system'&&$m==='GET'){
            $settings=AppSettings::all();
            echo json_encode(['ok'=>true,'system'=>[
                'app_name'=>AppSettings::get('app_name',defined('APP_NAME')?APP_NAME:'Vault'),
                'app_url'=>AppSettings::get('app_url',defined('APP_URL')?APP_URL:''),
                'max_upload_size'=>(int)AppSettings::get('max_upload_size',defined('MAX_UPLOAD_SIZE')?MAX_UPLOAD_SIZE:10737418240),
                'timezone'=>AppSettings::get('timezone','Europe/Madrid'),
                'smtp_enabled'=>AppSettings::bool('smtp_enabled',Mailer::isConfigured()),
                'smtp_host'=>AppSettings::get('smtp_host',defined('SMTP_HOST')?SMTP_HOST:''),
                'smtp_port'=>AppSettings::get('smtp_port',defined('SMTP_PORT')?SMTP_PORT:''),
                'smtp_security'=>AppSettings::get('smtp_security',defined('SMTP_SECURITY')?SMTP_SECURITY:'ssl'),
                'smtp_user'=>AppSettings::get('smtp_user',defined('SMTP_USER')?SMTP_USER:''),
                'smtp_from'=>AppSettings::get('smtp_from',defined('SMTP_FROM')?SMTP_FROM:''),
                'share_require_password'=>AppSettings::bool('share_require_password',false),
                'share_default_expiry_days'=>(int)AppSettings::get('share_default_expiry_days','0'),
                'share_default_max_downloads'=>(int)AppSettings::get('share_default_max_downloads','0'),
                'trash_auto_purge'=>AppSettings::bool('trash_auto_purge',false),
                'trash_retention_days'=>(int)AppSettings::get('trash_retention_days','30'),
                'force_admin_2fa'=>AppSettings::bool('force_admin_2fa',false),
                'session_lifetime'=>(int)AppSettings::get('session_lifetime','604800')
            ]]);
        }
        elseif($a==='system'&&$m==='PATCH'){
            $d=$this->json();$allowed=['app_name','app_url','max_upload_size','timezone','smtp_enabled','smtp_host','smtp_port','smtp_security','smtp_user','smtp_pass','smtp_from','share_require_password','share_default_expiry_days','share_default_max_downloads','trash_auto_purge','trash_retention_days','force_admin_2fa','session_lifetime'];
            foreach($allowed as $k){if(array_key_exists($k,$d))AppSettings::set($k,is_bool($d[$k])?($d[$k]?'1':'0'):(string)$d[$k]);}
            $cfg=AppSettings::all();Mailer::writeMsmtpConfig($cfg);
            $me=Auth::user();$db->execute("INSERT INTO activity_log (user_id,action,target,ip) VALUES (?,?,?,?)",[$me['id'],'admin_system_update','Configuración del sistema actualizada',$_SERVER['REMOTE_ADDR']??'']);
            echo json_encode(['ok'=>true]);
        }
        elseif($a==='system-test-smtp'&&$m==='POST'){
            $d=$this->json();$to=trim($d['email']??'');if(!filter_var($to,FILTER_VALIDATE_EMAIL))throw new ValidationException('Email de prueba no válido');
            if(!Mailer::isConfigured())throw new ValidationException('SMTP no está configurado');
            $ok=Mailer::send($to,'Prueba SMTP de Vault','<p>SMTP configurado correctamente en Vault.</p>','SMTP configurado correctamente en Vault.');
            if(!$ok)throw new ValidationException('No se pudo enviar el correo de prueba');
            echo json_encode(['ok'=>true]);
        }
        else throw new NotFoundException('Admin inválido');
    }
private function uploadChunk():void{
    $u=Auth::requireAuth();
    session_write_close(); // liberar bloqueo de sesión durante escritura
    if(empty($_FILES['chunk']))throw new ValidationException('No se recibió chunk');
    $uid=preg_replace('/[^a-zA-Z0-9_-]/','',$_POST['upload_id']??'');
    $idx=(int)($_POST['chunk_index']??-1);
    $total=(int)($_POST['total_chunks']??0);
    if(!$uid||$idx<0||$total<1)throw new ValidationException('Parámetros de chunk inválidos');
    if($_FILES['chunk']['size']>12*1024*1024)throw new ValidationException('Chunk demasiado grande');
    $dir=CHUNK_TMP_PATH.'/'.$u['id'].'/'.$uid;
    if(!is_dir($dir))mkdir($dir,0750,true);
    $dest=$dir.'/chunk_'.str_pad((string)$idx,6,'0',STR_PAD_LEFT);
    if(!move_uploaded_file($_FILES['chunk']['tmp_name'],$dest))throw new ValidationException('Error guardando chunk');
    echo json_encode(['ok'=>true,'chunk'=>$idx]);
}
private function uploadComplete():void{
    $u=Auth::requireAuth();
    session_write_close(); // liberar bloqueo de sesión
    $d=$this->json();
    $uid=preg_replace('/[^a-zA-Z0-9_-]/','',$d['upload_id']??'');
    $total=(int)($d['total_chunks']??0);
    $fname=basename($d['file_name']??'archivo');
    $fsize=(int)($d['file_size']??0);
    $pid=isset($d['folder_id'])&&$d['folder_id']!==''&&$d['folder_id']!==null?(int)$d['folder_id']:null;
    $rel=$d['relative_path']??'';
    if(!$uid||$total<1||$fsize<1)throw new ValidationException('Parámetros inválidos');
    $fmPath=new FileManager();
    if($rel!=='')$pid=$fmPath->ensureFolderPath($u['id'],$pid,$rel);
    $db=Database::getInstance();
    $uobj=$db->fetch('SELECT storage_used,storage_quota FROM users WHERE id=?',[$u['id']]);
    if($uobj['storage_used']+$fsize>$uobj['storage_quota'])throw new ValidationException('Sin espacio disponible');
    $dir=CHUNK_TMP_PATH.'/'.$u['id'].'/'.$uid;
    $ext=strtolower(pathinfo($fname,PATHINFO_EXTENSION));
    $sn=uniqid('f_',true).($ext?".$ext":'');
    $ud=STORAGE_PATH.'/'.$u['id'];if(!is_dir($ud))mkdir($ud,0750,true);
    $finalPath="$ud/$sn";
    $out=fopen($finalPath,'wb');if(!$out)throw new ValidationException('No se pudo crear el archivo final');
    for($i=0;$i<$total;$i++){
        $cp=$dir.'/chunk_'.str_pad((string)$i,6,'0',STR_PAD_LEFT);
        if(!file_exists($cp)){fclose($out);@unlink($finalPath);throw new ValidationException('Falta el chunk '.$i);}
        $in=fopen($cp,'rb');stream_copy_to_stream($in,$out);fclose($in);
    }
    fclose($out);
    $realSize=filesize($finalPath);
    $mime=mime_content_type($finalPath)?:'application/octet-stream';
    $sname=substr(trim(preg_replace('/[\/\\\\:*?"<>|]/','_',$fname)),0,255)?:'archivo';
    $rp=$u['id'].'/'.$sn;
    $tn=null;if(str_starts_with($mime,'image/')&&function_exists('imagecreatefromstring')){$tn=$fmPath->makeThumb($finalPath,$u['id'],$sn);}
    $fid=$db->execute('INSERT INTO files (user_id,parent_id,name,original_name,type,mime_type,size,path,thumbnail) VALUES (?,?,?,?,?,?,?,?,?)',[$u['id'],$pid,$sname,$fname,'file',$mime,$realSize,$rp,$tn]);
    $db->execute('UPDATE users SET storage_used=storage_used+? WHERE id=?',[$realSize,$u['id']]);
    for($i=0;$i<$total;$i++){@unlink($dir.'/chunk_'.str_pad((string)$i,6,'0',STR_PAD_LEFT));}@rmdir($dir);
    $tmpBase=CHUNK_TMP_PATH.'/'.$u['id'];
    if(is_dir($tmpBase))foreach(scandir($tmpBase)as $entry){if($entry==='.'||$entry==='..')continue;$d2=$tmpBase.'/'.$entry;if(is_dir($d2)&&filemtime($d2)<time()-86400){$fs2=glob($d2.'/*');if($fs2)foreach($fs2 as $f2)@unlink($f2);@rmdir($d2);}}
    echo json_encode(['ok'=>true,'id'=>$fid,'name'=>$sname,'size'=>$realSize,'mime_type'=>$mime]);
}
    private function avatar(?int $id):void{
        Auth::requireAuth();
        if(!$id)throw new NotFoundException('ID requerido');
        $db=Database::getInstance();$r=$db->fetch('SELECT avatar FROM users WHERE id=? AND active=1',[$id]);
        if(!$r||empty($r['avatar']))throw new NotFoundException('Avatar no encontrado');
        $p='/var/www/vault/storage/avatars/'.basename($r['avatar']);
        if(!file_exists($p))throw new NotFoundException('Avatar no encontrado');
        $mime=mime_content_type($p)?:'image/jpeg';
        header('Content-Type: '.$mime);header('Cache-Control: max-age=3600');readfile($p);exit;
    }
    private function json():array{return json_decode(file_get_contents('php://input'),true)??[];}
}
PHPEOF
msg_ok "Enrutador API desplegado"
msg_info "Creando puntos de entrada"

pct exec "$CT_ID" -- bash -c "cat > /var/www/vault/public/index.php" << 'PHPEOF' || msg_error "Falló la creación de public/index.php"
<?php
require_once __DIR__.'/../config/config.php';
require_once __DIR__.'/../src/bootstrap.php';
if(!empty($_SESSION['totp_pending'])&&empty($_SESSION['user_id'])){require __DIR__.'/../src/views/totp.php';exit;}
if(!Auth::check()){require __DIR__.'/../src/views/login.php';exit;}
$user=Auth::user();
require __DIR__.'/../src/views/app.php';
PHPEOF

pct exec "$CT_ID" -- bash -c "cat > /var/www/vault/public/api.php" << 'PHPEOF' || msg_error "Falló la creación de public/api.php"
<?php
require_once __DIR__.'/../config/config.php';
require_once __DIR__.'/../src/bootstrap.php';
$route=$_GET['route']??'';
$method=$_SERVER['REQUEST_METHOD'];
// Las rutas de streaming/descarga NO envían JSON header
$isStream=preg_match('#^(view|download|thumb|bulk-download|upload-chunk|upload-complete)/?#',$route);
if(!$isStream)header('Content-Type: application/json');
header('X-Content-Type-Options: nosniff');
try{(new Router())->dispatch($method,$route);}
catch(AuthException $e){http_response_code(401);echo json_encode(['ok'=>false,'error'=>'No autorizado','message'=>$e->getMessage()]);}
catch(NotFoundException $e){http_response_code(404);echo json_encode(['ok'=>false,'error'=>'No encontrado','message'=>$e->getMessage()]);}
catch(ValidationException $e){http_response_code(422);echo json_encode(['ok'=>false,'error'=>'Validación','message'=>$e->getMessage()]);}
catch(Throwable $e){http_response_code(500);error_log('[Vault] '.$e->getMessage());echo json_encode(['ok'=>false,'error'=>'Error interno']);}
PHPEOF

pct exec "$CT_ID" -- bash -c "cat > /var/www/vault/public/share.php" << 'PHPEOF' || msg_error "Falló la creación de public/share.php"
<?php
require_once __DIR__.'/../config/config.php';
require_once __DIR__.'/../src/bootstrap.php';
$token=$_GET['token']??'';
if(!$token){http_response_code(404);die('Link no válido');}
$db=Database::getInstance();
$share=$db->fetch('SELECT s.*,f.name,f.type,f.size,f.mime_type,f.path,u.display_name as owner_name FROM shares s JOIN files f ON s.file_id=f.id JOIN users u ON s.user_id=u.id WHERE s.token=? AND f.is_trashed=0',[$token]);
if(!$share){http_response_code(404);die('Link no válido o expirado');}
if($share['expires_at']&&strtotime($share['expires_at'])<time()){http_response_code(410);die('Link expirado');}
if($share['max_downloads']&&$share['downloads']>=$share['max_downloads']){http_response_code(410);die('Límite de descargas alcanzado');}
// Autenticación: sin contraseña = acceso directo; con contraseña = validar y recordar en sesión
$sessionKey='share_auth_'.$token;
$authenticated=!$share['password'];
if($share['password']){
    if(!empty($_SESSION[$sessionKey])){$authenticated=true;}
    elseif(isset($_POST['share_pass'])){
        if(password_verify($_POST['share_pass'],$share['password'])){$authenticated=true;$_SESSION[$sessionKey]=true;}
        else{$passError=true;}
    }
}
// Descarga / streaming (solo si está autenticado)
if($authenticated&&isset($_GET['dl'])){
    if(empty($_GET['preview'])){$db->execute('UPDATE shares SET downloads=downloads+1 WHERE token=?',[$token]);}
    if($share['type']==='folder'){
        // Carpeta compartida -> servir como ZIP
        $fm=new FileManager();
        $zipPath=$fm->zipFolder($share['user_id'],$share['file_id'],$share['name']);
        $zipName=preg_replace('/[\/\\\\:*?\"<>|]/','_',$share['name']).'.zip';
        header('Content-Type: application/zip');
        header('Content-Disposition: attachment; filename="'.rawurlencode($zipName).'"');
        header('Content-Length: '.filesize($zipPath));
        readfile($zipPath);@unlink($zipPath);exit;
    }
    $fp=STORAGE_PATH.'/'.$share['path'];
    if(!file_exists($fp)){http_response_code(404);die('Archivo no encontrado');}
    $inline=!empty($_GET['preview']);
    FileManager::streamFile($fp,$share['mime_type']?:'application/octet-stream',$inline);
}
require __DIR__.'/../src/views/share.php';
PHPEOF

pct exec "$CT_ID" -- bash -c "cat > /var/www/vault/public/.htaccess" << 'HTEOF' || msg_error "Falló la creación de public/.htaccess"
RewriteEngine On
RewriteBase /
RewriteCond %{REQUEST_FILENAME} -f [OR]
RewriteCond %{REQUEST_FILENAME} -d
RewriteRule ^ - [L]
RewriteRule ^api/(.*)$ api.php?route=$1 [L,QSA]
RewriteRule ^s/([a-zA-Z0-9]+)$ share.php?token=$1 [L,QSA]
RewriteRule ^ index.php [L]
Options -Indexes
Header always set X-Content-Type-Options nosniff
Header always set X-Frame-Options SAMEORIGIN
HTEOF
msg_ok "Puntos de entrada creados"
msg_info "Desplegando vistas (login, 2FA, compartir)"

pct exec "$CT_ID" -- bash -c "cat > /var/www/vault/src/views/login.php" << 'VIEWEOF'
<?php $appName=APP_NAME;?><!DOCTYPE html><html lang="es"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title><?=h($appName)?> — Acceder</title><style>
@import url('https://fonts.googleapis.com/css2?family=Sora:wght@400;600;700;800&family=Inter:wght@300;400;500;600&display=swap');
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Inter',sans-serif;background:#f7f7f8;color:#1f1f1f;min-height:100vh;display:flex;align-items:center;justify-content:center;overflow:hidden;padding:20px}
.bg{position:fixed;inset:0;z-index:0;overflow:hidden;background:linear-gradient(135deg,#f7f7f8 0%,#ffffff 45%,#eef6ff 100%)}
.bg:before{content:'';position:absolute;inset:0;background:radial-gradient(circle at 16% 18%,rgba(15,108,189,.12),transparent 28%),radial-gradient(circle at 84% 86%,rgba(55,48,163,.10),transparent 30%)}
.orb{display:none}
.card{position:relative;z-index:2;width:100%;max-width:420px;background:#fff;border:1px solid #e1dfdd;border-radius:12px;padding:42px 40px;box-shadow:0 18px 44px rgba(0,0,0,.10)}
.brand{text-align:center;margin-bottom:32px}
.shield-logo{width:64px;height:64px;margin:0 auto 18px;position:relative}
.shield-glow{display:none}
.shield-icon{position:relative;width:64px;height:64px;background:linear-gradient(135deg,#0f6cbd,#3730a3);border-radius:16px;display:flex;align-items:center;justify-content:center;box-shadow:0 8px 22px rgba(15,108,189,.24)}
.brand h1{font-family:'Sora',sans-serif;font-size:28px;font-weight:800;letter-spacing:-.5px;color:#111;margin-bottom:6px}
.brand p{color:#605e5c;font-size:13px}
.field{margin-bottom:17px}
.field label{display:block;font-size:11px;font-weight:700;color:#605e5c;text-transform:uppercase;letter-spacing:.8px;margin-bottom:8px}
.iw{position:relative}
.iw .ico{position:absolute;left:14px;top:50%;transform:translateY(-50%);color:#605e5c;width:17px;height:17px}
.field input{width:100%;background:#fff;border:1px solid #c8c6c4;border-radius:6px;padding:13px 15px 13px 42px;color:#1f1f1f;font-family:'Inter',sans-serif;font-size:14px;outline:none;transition:all .15s}
.field input::placeholder{color:#8a8886}
.field input:focus{border-color:#0f6cbd;box-shadow:0 0 0 1px #0f6cbd;background:#fff}
.btn{width:100%;background:#0f6cbd;color:#fff;border:none;border-radius:6px;padding:14px;font-family:'Inter',sans-serif;font-size:15px;font-weight:700;cursor:pointer;margin-top:10px;transition:all .15s;box-shadow:none}
.btn:hover{background:#115ea3;transform:none;box-shadow:none}.btn:disabled{opacity:.55;cursor:not-allowed}
.error{background:#fde7e9;border:1px solid #f1bbbb;border-radius:6px;padding:12px 14px;color:#a80000;font-size:13px;margin-bottom:18px;display:none}.error.show{display:block}
.foot{text-align:center;margin-top:22px;font-size:12px;color:#605e5c}.foot .secure{display:inline-flex;align-items:center;gap:5px;color:#0f6cbd}
.sp{display:none;width:18px;height:18px;border:2px solid rgba(255,255,255,.45);border-top-color:#fff;border-radius:50%;animation:spin .7s linear infinite;margin:0 auto}@keyframes spin{to{transform:rotate(360deg)}}
@media(max-width:520px){.card{max-width:100%;padding:34px 24px;border-radius:10px}}
.sort-menu{position:fixed;top:58px;right:150px;background:#fff;border:1px solid #e1dfdd;border-radius:8px;box-shadow:0 14px 40px rgba(0,0,0,.18);z-index:2600;min-width:220px;padding:6px;display:none}.sort-menu.open{display:block}.sort-mi{display:flex;justify-content:space-between;gap:12px;align-items:center;padding:9px 10px;border-radius:6px;cursor:pointer;font-size:13px;color:#242424}.sort-mi:hover{background:#f3f2f1}.sort-mi.active{background:#eef6ff;color:#0f6cbd;font-weight:700}.sort-dir{font-size:12px;color:#605e5c}.system-form-grid{display:grid;grid-template-columns:repeat(2,minmax(260px,1fr));gap:14px}.system-section{background:#fff;border:1px solid #e1dfdd;border-radius:12px;padding:16px}.system-section h4{margin:0 0 12px;font-family:'Sora';font-size:15px}.system-section .mf{margin-bottom:10px}.system-section .mf input,.system-section .mf select{width:100%;background:#fafafa;border:1px solid #d0d7de;border-radius:8px;padding:9px 10px;font-size:13px}.system-actions{display:flex;gap:8px;flex-wrap:wrap;margin-top:10px}.system-help{font-size:12px;color:#605e5c;line-height:1.4;margin-top:-4px;margin-bottom:8px}.switchrow{display:flex;align-items:center;justify-content:space-between;gap:12px;margin:10px 0;font-size:13px}.switchrow input{width:auto}.admin-action-row{display:flex;gap:8px;flex-wrap:wrap;align-items:center}.ctxbar{right:20px!important}.ctxbar .ctx-spacer{flex:1;min-width:24px}.ctxbar .ctx-count{margin-left:auto!important}.ctxbar .ctx-details{margin-left:8px}.ctxbar .ctx-details svg{width:15px;height:15px}.ctxbar .ctx-close{order:90}.ctxbar .ctx-count{order:91}@media(max-width:560px){.system-form-grid{grid-template-columns:1fr}.sort-menu{right:12px;left:12px;top:54px}}

</style></head><body>
<div class="bg"><div class="orb o1"></div><div class="orb o2"></div><div class="orb o3"></div></div>
<div class="card">
<div class="brand">
<div class="shield-logo"><div class="shield-glow"></div><div class="shield-icon"><svg width="34" height="34" viewBox="0 0 24 24" fill="none"><path d="M12 3 L19 6 V11 C19 15.5 16 19 12 21 C8 19 5 15.5 5 11 V6 Z" fill="none" stroke="#fff" stroke-width="2" stroke-linejoin="round"/><path d="M9 11.5 l2 2 l4-4.5" fill="none" stroke="#fff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg></div></div>
<h1><?=h($appName)?></h1><p>Tu nube privada y segura</p>
</div>
<div class="error" id="err"></div>
<div class="field"><label>Usuario o email</label><div class="iw"><svg class="ico" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M20 21v-2a4 4 0 00-4-4H8a4 4 0 00-4 4v2"/><circle cx="12" cy="7" r="4"/></svg><input type="text" id="u" placeholder="admin" autocomplete="username"></div></div>
<div class="field"><label>Contraseña</label><div class="iw"><svg class="ico" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="11" width="18" height="11" rx="2"/><path d="M7 11V7a5 5 0 0110 0v4"/></svg><input type="password" id="p" placeholder="••••••••" autocomplete="current-password"></div></div>
<button class="btn" id="btn" onclick="go()"><span id="bt">Entrar</span><div class="sp" id="sp"></div></button>
<div class="foot"><span class="secure"><svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><rect x="3" y="11" width="18" height="11" rx="2"/><path d="M7 11V7a5 5 0 0110 0v4"/></svg>Conexión cifrada · 2FA disponible</span></div>
</div>
<script>
document.addEventListener('keydown',e=>{if(e.key==='Enter')go();});
async function go(){const u=document.getElementById('u').value.trim(),p=document.getElementById('p').value,btn=document.getElementById('btn'),err=document.getElementById('err'),bt=document.getElementById('bt'),sp=document.getElementById('sp');if(!u||!p){show('Rellena todos los campos');return;}btn.disabled=true;bt.style.display='none';sp.style.display='block';err.classList.remove('show');try{const r=await fetch('/api/auth/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username:u,password:p})});const d=await r.json();if(d.ok){window.location.href='/';}else show(d.message||'Usuario o contraseña incorrectos');}catch(e){show('Error de conexión');}finally{btn.disabled=false;bt.style.display='';sp.style.display='none';}}
function show(m){const e=document.getElementById('err');e.textContent=m;e.classList.add('show');}
</script></body></html>
VIEWEOF

pct exec "$CT_ID" -- bash -c "cat > /var/www/vault/src/views/totp.php" << 'VIEWEOF'
<?php $appName=APP_NAME;?><!DOCTYPE html><html lang="es"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title><?=h($appName)?> — 2FA</title><style>
@import url('https://fonts.googleapis.com/css2?family=Sora:wght@700;800&family=Inter:wght@400;500;600&display=swap');
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Inter',sans-serif;background:#f7f7f8;color:#242424;min-height:100vh;display:flex;align-items:center;justify-content:center;overflow:hidden;padding:20px}
.bg{position:fixed;inset:0;z-index:0;background:linear-gradient(135deg,#f7f7f8 0%,#eef6ff 48%,#ffffff 100%)}
.bg:before{content:"";position:absolute;width:520px;height:520px;border-radius:50%;background:radial-gradient(circle,rgba(0,120,212,.16),transparent 68%);top:-180px;left:-140px;filter:blur(8px)}
.bg:after{content:"";position:absolute;width:560px;height:560px;border-radius:50%;background:radial-gradient(circle,rgba(96,165,250,.13),transparent 70%);right:-180px;bottom:-220px;filter:blur(10px)}
.card{position:relative;z-index:2;width:100%;max-width:420px;background:#fff;border:1px solid #e1dfdd;border-radius:18px;padding:42px 36px 34px;box-shadow:0 24px 70px rgba(15,23,42,.12),0 2px 8px rgba(15,23,42,.06);text-align:center}
.sh{width:58px;height:58px;border-radius:16px;margin:0 auto 18px;background:#eef6ff;color:#0f6cbd;display:flex;align-items:center;justify-content:center;border:1px solid #cfe8ff}.sh svg{width:34px;height:34px;display:block}
h1{font-family:'Sora',sans-serif;font-size:22px;font-weight:800;margin-bottom:8px;color:#1f1f1f}.sub{font-size:13px;color:#605e5c;margin-bottom:30px;line-height:1.6}
.inputs{display:flex;gap:9px;justify-content:center;margin-bottom:16px}
.box{width:46px;height:54px;background:#fff;border:1.5px solid #c8c6c4;border-radius:8px;color:#242424;font-size:22px;font-weight:700;font-family:'Sora',sans-serif;text-align:center;outline:none;transition:border-color .16s,box-shadow .16s,background .16s}
.box:hover{border-color:#8a8886}.box:focus{border-color:#0f6cbd;box-shadow:0 0 0 3px rgba(15,108,189,.16);background:#fbfdff}.box.filled{border-color:#0f6cbd;background:#f8fbff}
.btn{width:100%;background:#0f6cbd;color:#fff;border:none;border-radius:8px;padding:13px 16px;font-family:'Inter',sans-serif;font-size:15px;font-weight:600;cursor:pointer;transition:background .16s,box-shadow .16s;margin-top:8px;box-shadow:0 2px 5px rgba(0,0,0,.08)}
.btn:hover{background:#115ea3}.btn:disabled{opacity:.55;cursor:not-allowed;box-shadow:none;background:#8bbce8}
.err{display:none;background:#fde7e9;border:1px solid #f3b6bd;color:#a80000;font-size:13px;margin:0 0 14px;padding:9px 11px;border-radius:8px;text-align:left;line-height:1.4}.err.show{display:block}
.back{font-size:13px;color:#605e5c;margin-top:18px;cursor:pointer;display:inline-flex;gap:6px;align-items:center}.back:hover{color:#0f6cbd;text-decoration:underline}
@media(max-width:480px){.card{padding:34px 22px;border-radius:16px}.inputs{gap:6px}.box{width:40px;height:50px}}
.sort-menu{position:fixed;top:58px;right:150px;background:#fff;border:1px solid #e1dfdd;border-radius:8px;box-shadow:0 14px 40px rgba(0,0,0,.18);z-index:2600;min-width:220px;padding:6px;display:none}.sort-menu.open{display:block}.sort-mi{display:flex;justify-content:space-between;gap:12px;align-items:center;padding:9px 10px;border-radius:6px;cursor:pointer;font-size:13px;color:#242424}.sort-mi:hover{background:#f3f2f1}.sort-mi.active{background:#eef6ff;color:#0f6cbd;font-weight:700}.sort-dir{font-size:12px;color:#605e5c}.system-form-grid{display:grid;grid-template-columns:repeat(2,minmax(260px,1fr));gap:14px}.system-section{background:#fff;border:1px solid #e1dfdd;border-radius:12px;padding:16px}.system-section h4{margin:0 0 12px;font-family:'Sora';font-size:15px}.system-section .mf{margin-bottom:10px}.system-section .mf input,.system-section .mf select{width:100%;background:#fafafa;border:1px solid #d0d7de;border-radius:8px;padding:9px 10px;font-size:13px}.system-actions{display:flex;gap:8px;flex-wrap:wrap;margin-top:10px}.system-help{font-size:12px;color:#605e5c;line-height:1.4;margin-top:-4px;margin-bottom:8px}.switchrow{display:flex;align-items:center;justify-content:space-between;gap:12px;margin:10px 0;font-size:13px}.switchrow input{width:auto}.admin-action-row{display:flex;gap:8px;flex-wrap:wrap;align-items:center}.ctxbar{right:20px!important}.ctxbar .ctx-spacer{flex:1;min-width:24px}.ctxbar .ctx-count{margin-left:auto!important}.ctxbar .ctx-details{margin-left:8px}.ctxbar .ctx-details svg{width:15px;height:15px}.ctxbar .ctx-close{order:90}.ctxbar .ctx-count{order:91}@media(max-width:560px){.system-form-grid{grid-template-columns:1fr}.sort-menu{right:12px;left:12px;top:54px}}

</style></head><body>
<div class="bg"></div>
<div class="card"><div class="sh"><svg viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="M12 3 L19 6 V11 C19 15.5 16 19 12 21 C8 19 5 15.5 5 11 V6 Z" stroke="#0f6cbd" stroke-width="2" stroke-linejoin="round"/><path d="M9 11.5 l2 2 l4-4.5" stroke="#0f6cbd" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg></div><h1>Verificación en dos pasos</h1><p class="sub">Introduce el código de 6 dígitos de tu app autenticadora.</p>
<div class="err" id="err"></div>
<div class="inputs" id="inp"><input type="tel" maxlength="1" class="box" inputmode="numeric" autocomplete="one-time-code"><input type="tel" maxlength="1" class="box" inputmode="numeric"><input type="tel" maxlength="1" class="box" inputmode="numeric"><input type="tel" maxlength="1" class="box" inputmode="numeric"><input type="tel" maxlength="1" class="box" inputmode="numeric"><input type="tel" maxlength="1" class="box" inputmode="numeric"></div>
<button class="btn" id="btn" onclick="go()" disabled>Verificar</button>
<div class="back" onclick="window.location.href='/'">← Volver</div>
</div>
<script>
const boxes=document.querySelectorAll('.box');const err=document.getElementById('err');function setErr(t){err.textContent=t||'';err.classList.toggle('show',!!t);}boxes.forEach((b,i)=>{b.addEventListener('input',e=>{setErr('');const v=e.target.value.replace(/\D/g,'');e.target.value=v?v[0]:'';e.target.classList.toggle('filled',!!v);if(v&&i<boxes.length-1)boxes[i+1].focus();chk();});b.addEventListener('keydown',e=>{if(e.key==='Backspace'&&!b.value&&i>0){boxes[i-1].focus();boxes[i-1].value='';boxes[i-1].classList.remove('filled');chk();}if(e.key==='Enter')go();});b.addEventListener('paste',e=>{e.preventDefault();setErr('');const t=(e.clipboardData||window.clipboardData).getData('text').replace(/\D/g,'').slice(0,6);[...t].forEach((c,j)=>{if(boxes[j]){boxes[j].value=c;boxes[j].classList.add('filled');}});chk();if(t.length===6)go();});});boxes[0].focus();
function chk(){document.getElementById('btn').disabled=![...boxes].every(b=>b.value);} 
async function go(){const btn=document.getElementById('btn');const code=[...boxes].map(b=>b.value).join('');if(code.length!==6)return;btn.disabled=true;try{const r=await fetch('/api/auth/totp-verify',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({code})});const d=await r.json();if(d.ok){window.location.href='/';}else{setErr(d.message||'Código incorrecto');boxes.forEach(b=>{b.value='';b.classList.remove('filled');});boxes[0].focus();btn.disabled=true;}}catch(e){setErr('Error de conexión');btn.disabled=false;}}
</script></body></html>
VIEWEOF

pct exec "$CT_ID" -- bash -c "cat > /var/www/vault/src/views/share.php" << 'VIEWEOF'
<?php $appName=APP_NAME;function mie($m){if(!$m)return'📄';if(str_starts_with($m,'image/'))return'🖼️';if(str_starts_with($m,'video/'))return'🎬';if(str_starts_with($m,'audio/'))return'🎵';if($m==='application/pdf')return'📕';if(str_contains($m,'zip')||str_contains($m,'rar'))return'📦';return'📄';}?><!DOCTYPE html><html lang="es"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title><?=h($appName)?> — Archivo compartido</title><style>
@import url('https://fonts.googleapis.com/css2?family=Sora:wght@700;800&family=Inter:wght@400;500;600;700&display=swap');
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Inter',sans-serif;background:#f7f7f8;color:#1f1f1f;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:24px;overflow:auto}.bg{position:fixed;inset:0;z-index:0;background:linear-gradient(135deg,#f7f7f8 0%,#fff 45%,#eef6ff 100%)}.bg:before{content:'';position:absolute;inset:0;background:radial-gradient(circle at 16% 18%,rgba(15,108,189,.12),transparent 28%),radial-gradient(circle at 84% 86%,rgba(55,48,163,.10),transparent 30%)}
.card{position:relative;z-index:2;background:#fff;border:1px solid #e1dfdd;border-radius:14px;padding:34px 36px;width:100%;max-width:460px;text-align:center;box-shadow:0 18px 44px rgba(0,0,0,.10)}.logo{display:inline-flex;align-items:center;gap:8px;font-family:'Sora',sans-serif;font-weight:800;font-size:16px;color:#0f6cbd;margin-bottom:26px}.logo svg{width:24px;height:24px}.fi{width:76px;height:76px;margin:0 auto 16px;border-radius:18px;background:#eef6ff;border:1px solid #cfe8ff;display:flex;align-items:center;justify-content:center;font-size:42px}.folderfi{background:#fff4ce;border-color:#fde68a}.fn{font-family:'Sora',sans-serif;font-size:21px;font-weight:800;margin-bottom:6px;word-break:break-word;color:#242424}.meta{font-size:13px;color:#605e5c;margin-bottom:7px}.own{font-size:12px;color:#605e5c;margin-bottom:24px}.btn{display:inline-flex;align-items:center;justify-content:center;gap:8px;background:#0f6cbd;color:#fff;border:none;border-radius:6px;padding:12px 24px;font-family:'Inter',sans-serif;font-size:14px;font-weight:700;cursor:pointer;text-decoration:none;box-shadow:none;transition:background .15s}.btn:hover{background:#115ea3}.pi{width:100%;background:#fff;border:1px solid #c8c6c4;border-radius:6px;padding:12px;color:#242424;font-size:14px;outline:none;margin-bottom:12px;text-align:center}.pi:focus{border-color:#0f6cbd;box-shadow:0 0 0 1px #0f6cbd}.err{background:#fde7e9;border:1px solid #f1bbbb;border-radius:6px;padding:10px 12px;color:#a80000;font-size:13px;margin-bottom:12px}.media-preview{margin-bottom:20px;border-radius:10px;overflow:hidden;max-height:320px;border:1px solid #e1dfdd;background:#fafafa}.media-preview img,.media-preview video{width:100%;max-height:320px;object-fit:contain;display:block}.limit{font-size:11px;color:#605e5c;margin-top:12px}@media(max-width:520px){body{padding:16px}.card{padding:28px 22px;border-radius:12px}}
.sort-menu{position:fixed;top:58px;right:150px;background:#fff;border:1px solid #e1dfdd;border-radius:8px;box-shadow:0 14px 40px rgba(0,0,0,.18);z-index:2600;min-width:220px;padding:6px;display:none}.sort-menu.open{display:block}.sort-mi{display:flex;justify-content:space-between;gap:12px;align-items:center;padding:9px 10px;border-radius:6px;cursor:pointer;font-size:13px;color:#242424}.sort-mi:hover{background:#f3f2f1}.sort-mi.active{background:#eef6ff;color:#0f6cbd;font-weight:700}.sort-dir{font-size:12px;color:#605e5c}.system-form-grid{display:grid;grid-template-columns:repeat(2,minmax(260px,1fr));gap:14px}.system-section{background:#fff;border:1px solid #e1dfdd;border-radius:12px;padding:16px}.system-section h4{margin:0 0 12px;font-family:'Sora';font-size:15px}.system-section .mf{margin-bottom:10px}.system-section .mf input,.system-section .mf select{width:100%;background:#fafafa;border:1px solid #d0d7de;border-radius:8px;padding:9px 10px;font-size:13px}.system-actions{display:flex;gap:8px;flex-wrap:wrap;margin-top:10px}.system-help{font-size:12px;color:#605e5c;line-height:1.4;margin-top:-4px;margin-bottom:8px}.switchrow{display:flex;align-items:center;justify-content:space-between;gap:12px;margin:10px 0;font-size:13px}.switchrow input{width:auto}.admin-action-row{display:flex;gap:8px;flex-wrap:wrap;align-items:center}.ctxbar{right:20px!important}.ctxbar .ctx-spacer{flex:1;min-width:24px}.ctxbar .ctx-count{margin-left:auto!important}.ctxbar .ctx-details{margin-left:8px}.ctxbar .ctx-details svg{width:15px;height:15px}.ctxbar .ctx-close{order:90}.ctxbar .ctx-count{order:91}@media(max-width:560px){.system-form-grid{grid-template-columns:1fr}.sort-menu{right:12px;left:12px;top:54px}}

</style></head><body><div class="bg"></div><div class="card"><div class="logo"><svg viewBox="0 0 24 24" fill="none"><path d="M12 3 L19 6 V11 C19 15.5 16 19 12 21 C8 19 5 15.5 5 11 V6 Z" stroke="#0f6cbd" stroke-width="2" stroke-linejoin="round"/><path d="M9 11.5 l2 2 l4-4.5" stroke="#0f6cbd" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg> <?=h($appName)?></div>
<?php if(!$authenticated):?><div class="fi">🔒</div><div class="fn">Archivo protegido</div><div class="meta">Este enlace requiere contraseña</div><form method="POST"><?php if(isset($passError)):?><div class="err">Contraseña incorrecta</div><?php endif;?><input type="password" name="share_pass" class="pi" placeholder="Contraseña" autofocus><button type="submit" class="btn">Acceder</button></form>
<?php else:$mime=$share['mime_type']??'';$isFolder=$share['type']==='folder';$isImg=!$isFolder&&str_starts_with($mime,'image/');$isVid=!$isFolder&&str_starts_with($mime,'video/');?>
<?php if($isFolder):?><div class="fi folderfi">📁</div><?php elseif($isImg):?><div class="media-preview"><img src="?token=<?=h($token)?>&dl=1&preview=1" alt=""></div><?php elseif($isVid):?><div class="media-preview"><video controls src="?token=<?=h($token)?>&dl=1&preview=1"></video></div><?php else:?><div class="fi"><?=mie($mime)?></div><?php endif;?>
<div class="fn"><?=h($share['name'])?></div><div class="meta"><?=$share['type']==='file'?size_human($share['size']):'Carpeta'?></div><div class="own">Compartido por <strong><?=h($share['owner_name'])?></strong></div><?php if($share['allow_download']):?><a href="?token=<?=h($token)?>&dl=1" class="btn" download><?=$isFolder?'Descargar ZIP':'Descargar'?></a><?php endif;?><?php if($share['max_downloads']):?><p class="limit"><?=$share['downloads']?> / <?=$share['max_downloads']?> descargas</p><?php endif;?><?php endif;?></div></body></html>
VIEWEOF
msg_ok "Vistas de login, 2FA y compartir desplegadas"
msg_info "Desplegando interfaz principal"

pct exec "$CT_ID" -- bash -c "cat > /var/www/vault/src/views/app.php" << 'VIEWEOF'
<?php
$appName=APP_NAME;$userName=$user['display_name']?:$user['username'];
$isAdmin=$user['role']==='admin';$quota=$user['storage_quota'];$used=$user['storage_used'];
$usedPct=$quota>0?min(100,round($used/$quota*100,1)):0;
$theme=$user['theme']??'light';
$language=$user['language']??'es';
?><!DOCTYPE html><html lang="<?=h($language)?>" data-theme="<?=h($theme)?>"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title><?=h($appName)?></title><style>
@import url('https://fonts.googleapis.com/css2?family=Sora:wght@400;600;700;800&family=Inter:wght@300;400;500;600&display=swap');
*{box-sizing:border-box;margin:0;padding:0}
:root{
  --bg:#0f0a1e;--surface:#16122a;--surface2:#1c172f;--surface3:#241d3d;
  --border:rgba(255,255,255,.08);--border2:rgba(255,255,255,.14);
  --accent:#6366f1;--accent2:#ec4899;--accent-grad:linear-gradient(135deg,#6366f1,#ec4899);
  --accent-dim:rgba(99,102,241,.15);--text:#ECEAF5;--muted:#9d97b5;--muted2:#6b6489;
  --danger:#ff6b6b;--success:#34d399;--sidebar-w:240px;
}
[data-theme="light"]{
  --bg:#f4f3fb;--surface:#ffffff;--surface2:#f7f6fd;--surface3:#eeecfa;
  --border:rgba(20,15,40,.08);--border2:rgba(20,15,40,.16);
  --accent:#6366f1;--accent2:#ec4899;--accent-dim:rgba(99,102,241,.1);
  --text:#1a1530;--muted:#6b6489;--muted2:#a39dc0;--danger:#e53e3e;--success:#059669;
}
body{font-family:'Inter',sans-serif;background:var(--bg);color:var(--text);height:100vh;display:flex;overflow:hidden;font-size:14px;transition:background .3s,color .3s}
/* ── Sidebar ── */
.sidebar{width:var(--sidebar-w);background:var(--surface);border-right:1px solid var(--border);display:flex;flex-direction:column;flex-shrink:0;transition:transform .3s ease}
.sh{padding:20px 18px 16px;border-bottom:1px solid var(--border)}
.brand{display:flex;align-items:center;gap:11px}
.brand .logo{width:38px;height:38px;background:var(--accent-grad);border-radius:12px;display:flex;align-items:center;justify-content:center;box-shadow:0 6px 18px rgba(99,102,241,.4);flex-shrink:0}
.brand .name{font-family:'Sora',sans-serif;font-weight:800;font-size:16px;background:linear-gradient(135deg,#c7d2fe,#fbcfe8);-webkit-background-clip:text;-webkit-text-fill-color:transparent}
[data-theme="light"] .brand .name{background:var(--accent-grad);-webkit-background-clip:text}
.nav{flex:1;padding:12px 10px;overflow-y:auto}
.ns{font-size:10px;font-weight:600;color:var(--muted2);text-transform:uppercase;letter-spacing:1px;padding:10px 10px 5px;margin-top:6px}
.ni{display:flex;align-items:center;gap:11px;padding:9px 12px;border-radius:11px;cursor:pointer;color:var(--muted);font-size:13px;font-weight:500;transition:all .15s;-webkit-tap-highlight-color:transparent}
.ni:hover{background:var(--surface2);color:var(--text)}
.ni.active{background:var(--accent-dim);color:#c7d2fe}
[data-theme="light"] .ni.active{color:var(--accent)}
.ni svg{width:18px;height:18px;flex-shrink:0}
.sf{padding:14px;border-top:1px solid var(--border)}
.ql{display:flex;justify-content:space-between;font-size:11px;color:var(--muted);margin-bottom:6px}
.qb{height:5px;background:var(--surface3);border-radius:3px;margin-bottom:12px;overflow:hidden}
.qf{height:100%;border-radius:3px;background:var(--accent-grad)}
.ur{display:flex;align-items:center;gap:10px}
.av{width:32px;height:32px;border-radius:50%;background:var(--accent-grad);display:flex;align-items:center;justify-content:center;font-size:13px;font-weight:700;font-family:'Sora',sans-serif;color:#fff;flex-shrink:0}
.un{font-size:12px;font-weight:600;flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.lb{background:none;border:none;cursor:pointer;color:var(--muted);font-size:16px;padding:4px;border-radius:6px}.lb:hover{color:var(--danger)}
/* ── Layout principal ── */
.main{flex:1;display:flex;flex-direction:column;min-width:0;overflow:hidden}
.topbar{padding:0 16px;height:58px;display:flex;align-items:center;gap:10px;border-bottom:1px solid var(--border);flex-shrink:0}
/* Botón hamburger (solo móvil) */
.hbtn{display:none;width:38px;height:38px;border-radius:10px;border:1px solid var(--border);background:var(--surface2);color:var(--muted);cursor:pointer;align-items:center;justify-content:center;flex-shrink:0;-webkit-tap-highlight-color:transparent}
.hbtn svg{width:18px;height:18px}
.sw{flex:1;max-width:420px;position:relative}
.sw input{width:100%;background:var(--surface2);border:1px solid var(--border);border-radius:12px;padding:9px 14px 9px 38px;color:var(--text);font-family:'Inter',sans-serif;font-size:13px;outline:none;transition:all .2s}
.sw input:focus{border-color:var(--accent)}
.sw .si{position:absolute;left:12px;top:50%;transform:translateY(-50%);color:var(--muted);width:16px;height:16px}
.sw .clr{position:absolute;right:10px;top:50%;transform:translateY(-50%);color:var(--muted);cursor:pointer;display:none;width:18px;height:18px;border:none;background:none}
.sw .clr.show{display:block}
.tr{margin-left:auto;display:flex;gap:7px;align-items:center}
.bi{width:36px;height:36px;border-radius:10px;border:1px solid var(--border);background:var(--surface2);color:var(--muted);cursor:pointer;display:flex;align-items:center;justify-content:center;transition:all .15s;-webkit-tap-highlight-color:transparent}
.bi:hover{background:var(--surface3);color:var(--text)}.bi svg{width:17px;height:17px}
.vt{display:flex;background:var(--surface2);border:1px solid var(--border);border-radius:9px;padding:2px}
.vb{padding:5px 9px;border-radius:7px;border:none;background:none;cursor:pointer;color:var(--muted);display:flex;align-items:center;transition:all .15s}
.vb svg{width:16px;height:16px}.vb.active{background:var(--surface3);color:var(--text)}
.content{flex:1;overflow-y:auto;padding:20px}
.page{display:none;animation:fade .25s ease}.page.active{display:block}
@keyframes fade{from{opacity:0;transform:translateY(8px)}to{opacity:1;transform:none}}
.tbar{display:flex;align-items:center;gap:12px;margin-bottom:16px;flex-wrap:wrap}
.tbar h2{font-family:'Sora',sans-serif;font-weight:700;font-size:19px;flex:1}
.bc{display:flex;align-items:center;gap:4px;font-size:12px;color:var(--muted);margin-bottom:16px;flex-wrap:wrap}
.bc span{cursor:pointer;padding:3px 7px;border-radius:7px;transition:all .15s}.bc span:hover{color:var(--text);background:var(--surface2)}
.bc .sep{color:var(--muted2)}
.btn{display:inline-flex;align-items:center;gap:6px;padding:8px 15px;border-radius:10px;border:none;cursor:pointer;font-family:'Inter',sans-serif;font-size:13px;font-weight:600;transition:all .15s;-webkit-tap-highlight-color:transparent}
.bp{background:var(--accent-grad);color:#fff;box-shadow:0 4px 14px rgba(99,102,241,.35)}.bp:hover{transform:translateY(-1px);box-shadow:0 6px 20px rgba(99,102,241,.5)}
.bs{background:var(--surface2);color:var(--text);border:1px solid var(--border)}.bs:hover{background:var(--surface3)}
.bd{background:rgba(255,107,107,.12);color:var(--danger);border:1px solid rgba(255,107,107,.25)}.bd:hover{background:rgba(255,107,107,.2)}
/* ── Grid y lista de archivos ── */
.fg{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:12px}
.fl{display:flex;flex-direction:column;gap:4px}
.fc{background:var(--surface);border:1px solid var(--border);border-radius:15px;overflow:hidden;cursor:pointer;transition:all .2s;position:relative;-webkit-tap-highlight-color:transparent}
.fc:hover{transform:translateY(-3px);box-shadow:0 12px 30px rgba(99,102,241,.18);border-color:var(--border2)}
/* Resaltado al soltar drag interno encima de carpeta */
.fc.drop-target{border-color:var(--accent);box-shadow:0 0 0 3px rgba(99,102,241,.35);background:var(--accent-dim)}
.ft{height:100px;display:flex;align-items:center;justify-content:center;font-size:36px;position:relative;overflow:hidden;background:linear-gradient(135deg,rgba(99,102,241,.08),rgba(236,72,153,.05))}
.ft img{width:100%;height:100%;object-fit:cover}
.fi-b{padding:10px 12px}
.fn{font-size:12px;font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;margin-bottom:2px}
.fm{font-size:10px;color:var(--muted)}
.fa{position:absolute;top:6px;right:6px;display:none;gap:4px}.fc:hover .fa{display:flex}
.fab{width:27px;height:27px;border-radius:8px;background:rgba(15,10,30,.85);border:1px solid var(--border2);color:#fff;cursor:pointer;display:flex;align-items:center;justify-content:center;font-size:12px;backdrop-filter:blur(6px);transition:all .15s;-webkit-tap-highlight-color:transparent}
.fab:hover{background:var(--accent)}
.fr{display:flex;align-items:center;gap:12px;padding:10px 14px;border-radius:12px;cursor:pointer;transition:all .15s;border:1px solid transparent;-webkit-tap-highlight-color:transparent}
.fr:hover{background:var(--surface2);border-color:var(--border)}
.fr.drop-target{border-color:var(--accent);background:var(--accent-dim)}
.fr .ri{font-size:20px;width:30px;text-align:center;flex-shrink:0}
.fr .rn{flex:1;font-size:13px;font-weight:500;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.fr .rs{width:80px;text-align:right;font-size:12px;color:var(--muted)}
.fr .rd{width:130px;text-align:right;font-size:12px;color:var(--muted)}
.fr .ra{width:90px;display:none;gap:5px;justify-content:flex-end}.fr:hover .ra{display:flex}
.empty{text-align:center;padding:70px 20px;color:var(--muted)}
.empty .ei{font-size:50px;margin-bottom:14px;opacity:.4}
.empty h3{font-family:'Sora',sans-serif;font-size:16px;color:var(--text);margin-bottom:6px}
/* ── Modales ── */
.mo{position:fixed;inset:0;background:rgba(0,0,0,.7);backdrop-filter:blur(6px);z-index:1000;display:none;align-items:center;justify-content:center;padding:20px}
.mo.open{display:flex}
.md{background:var(--surface);border:1px solid var(--border);border-radius:20px;padding:28px;width:100%;max-width:480px;max-height:90vh;overflow-y:auto;box-shadow:0 40px 90px rgba(0,0,0,.6);animation:mi .25s ease}
@keyframes mi{from{opacity:0;transform:scale(.95) translateY(10px)}to{opacity:1;transform:none}}
.md h3{font-family:'Sora',sans-serif;font-weight:700;font-size:18px;margin-bottom:20px}
.mf{margin-bottom:16px}
.mf label{display:block;font-size:10px;font-weight:600;color:var(--muted);text-transform:uppercase;letter-spacing:.7px;margin-bottom:6px}
.mf input,.mf select{width:100%;background:var(--surface2);border:1px solid var(--border);border-radius:10px;padding:10px 12px;color:var(--text);font-family:'Inter',sans-serif;font-size:13px;outline:none}
.mf input:focus,.mf select:focus{border-color:var(--accent)}
.mf select option{background:var(--surface2)}
.ma{display:flex;gap:10px;justify-content:flex-end;margin-top:20px;flex-wrap:wrap}
.uz{border:2px dashed var(--border2);border-radius:16px;padding:40px 24px;text-align:center;transition:all .2s;cursor:pointer;position:relative;margin-bottom:16px}
.uz.drag{border-color:var(--accent);background:var(--accent-dim)}.uz:hover{background:var(--surface2)}
.uz .ui{font-size:36px;margin-bottom:10px}.uz p{color:var(--muted);font-size:13px}.uz strong{color:#c7d2fe}
.uz input[type=file]{position:absolute;inset:0;opacity:0;cursor:pointer}
.up{background:var(--surface2);border-radius:8px;overflow:hidden;height:6px;margin:6px 0}.upf{height:100%;background:var(--accent-grad);transition:width .3s}
/* ── Toasts ── */
.toasts{position:fixed;bottom:24px;right:24px;z-index:2000;display:flex;flex-direction:column;gap:8px}
.toast{background:var(--surface);border:1px solid var(--border);border-radius:12px;padding:12px 15px;font-size:13px;display:flex;align-items:center;gap:10px;box-shadow:0 10px 30px rgba(0,0,0,.4);animation:ti .25s ease;min-width:220px}
@keyframes ti{from{opacity:0;transform:translateY(10px)}to{opacity:1;transform:none}}
.toast.success{border-color:rgba(52,211,153,.3)}.toast.error{border-color:rgba(255,107,107,.3)}
/* ── Ajustes y admin ── */
.sgr{display:grid;grid-template-columns:repeat(auto-fill,minmax(180px,1fr));gap:13px;margin-bottom:22px}
.stc{background:var(--surface);border:1px solid var(--border);border-radius:15px;padding:18px}
.stc .sic{width:38px;height:38px;border-radius:10px;background:var(--accent-dim);display:flex;align-items:center;justify-content:center;margin-bottom:12px;font-size:18px}
.stc .sl{font-size:10px;color:var(--muted);text-transform:uppercase;letter-spacing:.8px;margin-bottom:4px}
.stc .sv{font-family:'Sora',sans-serif;font-size:26px;font-weight:800}
.setg{display:grid;grid-template-columns:1fr 1fr;gap:16px;max-width:780px}
.sc{background:var(--surface);border:1px solid var(--border);border-radius:16px;padding:22px}
.sc h3{font-family:'Sora',sans-serif;font-weight:700;margin-bottom:16px;font-size:15px}
.sc.full{grid-column:span 2}
.ts{display:inline-flex;align-items:center;gap:6px;font-size:11px;padding:3px 10px;border-radius:20px;font-weight:600}
.ton{background:rgba(52,211,153,.15);color:var(--success)}.toff{background:rgba(255,107,107,.12);color:var(--danger)}
.su{font-family:monospace;font-size:11px;background:var(--surface2);border:1px solid var(--border);border-radius:10px;padding:10px 12px;color:#c7d2fe;margin-top:8px;cursor:pointer;word-break:break-all}
/* ── Tabla admin ── */
table{width:100%;border-collapse:collapse}
th{font-size:10px;font-weight:600;color:var(--muted);text-transform:uppercase;letter-spacing:.7px;padding:8px 11px;text-align:left;border-bottom:1px solid var(--border)}
td{padding:10px 11px;border-bottom:1px solid var(--border);font-size:13px;vertical-align:middle}
tr:last-child td{border:none}tr:hover td{background:var(--surface2)}
.rb{font-size:10px;padding:2px 9px;border-radius:20px;font-weight:600}
.rba{background:var(--accent-dim);color:#c7d2fe}.rbu{background:var(--surface3);color:var(--muted)}
.qedit{display:inline-flex;align-items:center;gap:5px}
.qedit input{width:56px;background:var(--surface2);border:1px solid var(--border);border-radius:7px;padding:5px 7px;color:var(--text);font-size:12px;text-align:right}
.qedit .un2{font-size:11px;color:var(--muted)}
.qedit .qsave{background:var(--success);border:none;color:#fff;border-radius:6px;width:24px;height:24px;cursor:pointer;font-size:12px}
/* ── Menú contextual ── */
.ctx{position:fixed;background:var(--surface);border:1px solid var(--border);border-radius:12px;padding:6px;min-width:185px;box-shadow:0 16px 44px rgba(0,0,0,.55);z-index:500;animation:ci .15s ease}
@keyframes ci{from{opacity:0;transform:scale(.96)}to{opacity:1;transform:none}}
.cxi{display:flex;align-items:center;gap:10px;padding:9px 12px;border-radius:8px;cursor:pointer;font-size:13px;color:var(--text);transition:background .15s;-webkit-tap-highlight-color:transparent}
.cxi:hover{background:var(--surface2)}.cxi.danger{color:var(--danger)}.cxi.danger:hover{background:rgba(255,107,107,.1)}
.cxs{height:1px;background:var(--border);margin:4px 6px}
/* ── Visor de archivos ── */
.viewer{position:fixed;inset:0;background:rgba(8,5,18,.94);backdrop-filter:blur(10px);z-index:3000;display:none;flex-direction:column}
.viewer.open{display:flex}
.viewer-top{padding:14px 20px;display:flex;align-items:center;gap:14px;border-bottom:1px solid var(--border)}
.viewer-top .vtitle{flex:1;font-size:14px;font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.viewer-top .vbtn{width:36px;height:36px;border-radius:10px;background:var(--surface2);border:1px solid var(--border);color:var(--text);cursor:pointer;display:flex;align-items:center;justify-content:center;font-size:15px;transition:all .15s}
.viewer-top .vbtn:hover{background:var(--surface3)}
.viewer-body{flex:1;display:flex;align-items:center;justify-content:center;overflow:auto;padding:24px;position:relative}
.viewer-body img{max-width:100%;max-height:100%;object-fit:contain;border-radius:8px;transition:transform .2s}
.viewer-body video{max-width:90%;max-height:90%;border-radius:12px;background:#000}
.viewer-body audio{width:80%;max-width:500px}
.viewer-body iframe{width:90%;height:100%;border:none;border-radius:8px;background:#fff}
.viewer-body .noprev{text-align:center;color:var(--muted)}
.viewer-body .noprev .npi{font-size:64px;margin-bottom:16px}
.viewer-nav{position:absolute;top:50%;transform:translateY(-50%);width:48px;height:48px;border-radius:50%;background:rgba(22,18,42,.8);border:1px solid var(--border);color:#fff;cursor:pointer;display:flex;align-items:center;justify-content:center;font-size:20px;transition:all .15s}
.viewer-nav:hover{background:var(--accent)}
.viewer-nav.prev{left:20px}.viewer-nav.next{right:20px}
/* ── Overlay de subida externa ── */
#dropOverlay{position:fixed;inset:0;z-index:5000;background:rgba(99,102,241,.18);backdrop-filter:blur(8px);display:none;align-items:center;justify-content:center;pointer-events:none}
#dropOverlay.show{display:flex}
#dropOverlay .drop-inner{background:var(--surface);border:2px dashed var(--accent);border-radius:24px;padding:48px 64px;text-align:center;box-shadow:0 30px 80px rgba(0,0,0,.5)}
/* ── Ghost de drag interno ── */
#dragGhost{position:fixed;z-index:9000;pointer-events:none;background:var(--surface);border:2px solid var(--accent);border-radius:12px;padding:8px 14px;font-size:12px;font-weight:600;color:var(--text);box-shadow:0 12px 36px rgba(0,0,0,.5);display:none;align-items:center;gap:8px;white-space:nowrap;max-width:220px;opacity:.92}
/* ── Selección múltiple ── */
.fc.sel,.fr.sel{outline:2px solid var(--accent);outline-offset:1px;background:var(--accent-dim)}
.selcheck{position:absolute;top:6px;left:6px;width:22px;height:22px;border-radius:50%;background:rgba(15,10,30,.55);border:2px solid rgba(255,255,255,.7);display:flex;align-items:center;justify-content:center;z-index:3;cursor:pointer;-webkit-tap-highlight-color:transparent;opacity:0;transition:opacity .15s}
.fc:hover .selcheck,.selmode .selcheck{opacity:1}
.selcheck.on{opacity:1!important;background:var(--accent-grad);border-color:transparent}
.selcheck.on{background:var(--accent-grad);border-color:transparent}
.selcheck svg{width:13px;height:13px;color:#fff;opacity:0}.selcheck.on svg{opacity:1}
.rsel{width:22px;height:22px;border-radius:50%;border:2px solid var(--border2);display:none;align-items:center;justify-content:center;cursor:pointer;flex-shrink:0;-webkit-tap-highlight-color:transparent}
.selmode .rsel{display:flex}.rsel.on{background:var(--accent-grad);border-color:transparent}
.rsel svg{width:12px;height:12px;color:#fff;opacity:0}.rsel.on svg{opacity:1}
/* ── Barra contextual inferior ── */
.ctxbar{position:fixed;bottom:28px;left:50%;transform:translateX(-50%) translateY(calc(100% + 48px));z-index:1500;background:var(--surface);border:1px solid var(--border2);border-radius:18px;padding:8px 10px;display:flex;align-items:center;gap:4px;box-shadow:0 20px 60px rgba(0,0,0,.25),0 0 0 1px var(--border);transition:transform .3s cubic-bezier(.34,1.56,.64,1),opacity .18s ease,visibility .18s ease;max-width:96vw;flex-wrap:nowrap;overflow-x:auto;opacity:0;visibility:hidden;pointer-events:none}
.ctxbar.show{transform:translateX(-50%) translateY(0);opacity:1;visibility:visible;pointer-events:auto}
.ctxbar .cnt{font-size:13px;font-weight:700;font-family:Sora,sans-serif;padding:0 8px 0 4px;white-space:nowrap;color:var(--text);border-right:1px solid var(--border);margin-right:2px}
.ctxbar button{display:inline-flex;align-items:center;gap:5px;padding:7px 11px;border-radius:12px;border:none;background:transparent;color:var(--muted);cursor:pointer;font-size:12px;font-weight:600;white-space:nowrap;-webkit-tap-highlight-color:transparent;transition:all .15s}
.ctxbar button:hover{background:var(--surface2);color:var(--text)}
.ctxbar button.danger{color:var(--danger)}.ctxbar button.danger:hover{background:rgba(255,107,107,.1)}
.ctxbar button svg{width:15px;height:15px;flex-shrink:0}
.ctxbar .div{width:1px;height:22px;background:var(--border);margin:0 2px;flex-shrink:0}
[data-theme="light"] .ctxbar{box-shadow:0 8px 32px rgba(99,102,241,.15),0 2px 8px rgba(0,0,0,.08),0 0 0 1px rgba(99,102,241,.12)}
/* ── Modal mover: árbol de carpetas ── */
.foldertree{max-height:280px;overflow-y:auto;border:1px solid var(--border);border-radius:12px;padding:6px;margin-bottom:8px}
.ftrow{display:flex;align-items:center;gap:8px;padding:9px 11px;border-radius:9px;cursor:pointer;font-size:13px}
.ftrow:hover{background:var(--surface2)}.ftrow.on{background:var(--accent-dim);color:#c7d2fe}
.ftrow .ico{font-size:16px}
/* ── Panel de progreso de subida (inferior derecha) ── */
#uploadPanel{position:fixed;bottom:24px;right:24px;z-index:1800;width:300px;background:var(--surface);border:1px solid var(--border2);border-radius:16px;box-shadow:0 16px 50px rgba(0,0,0,.5);display:none;flex-direction:column;overflow:hidden}
#uploadPanel.show{display:flex}
#uploadPanel .uph{padding:12px 14px;display:flex;align-items:center;gap:8px;border-bottom:1px solid var(--border);font-size:13px;font-weight:600;font-family:'Sora',sans-serif}
#uploadPanel .uph span{flex:1}
#uploadPanel .uph button{background:none;border:none;cursor:pointer;color:var(--muted);font-size:15px;padding:2px 6px;border-radius:6px}.upclose:hover{color:var(--text)}
#uploadPanel .uplist{max-height:220px;overflow-y:auto;padding:8px}
.upitem{padding:7px 8px;border-radius:8px;margin-bottom:4px}
.upitem .upname{font-size:12px;font-weight:500;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;margin-bottom:4px}
.upitem .uprow{display:flex;align-items:center;gap:8px}
.upitem .upbar{flex:1;height:4px;background:var(--surface3);border-radius:2px;overflow:hidden}
.upitem .upfill{height:100%;border-radius:2px;background:var(--accent-grad);transition:width .3s}
.upitem .uppct{font-size:10px;color:var(--muted);width:32px;text-align:right}
.upitem.done .upfill{background:var(--success)}
.upitem.err .upfill{background:var(--danger)}
/* ── Scrollbar ── */
::-webkit-scrollbar{width:6px;height:6px}::-webkit-scrollbar-track{background:transparent}::-webkit-scrollbar-thumb{background:var(--border2);border-radius:3px}
/* ══════════════════════════════════════════════════
   RESPONSIVE — MÓVIL
   ══════════════════════════════════════════════════ */
@media(max-width:768px){
  /* Sidebar oculta por defecto en móvil, desliza desde la izquierda */
  .sidebar{position:fixed;top:0;left:0;height:100%;z-index:2000;transform:translateX(-100%)}
  .sidebar.open{transform:translateX(0)}
  /* Overlay oscuro detrás del sidebar en móvil */
  #sideOverlay{position:fixed;inset:0;background:rgba(0,0,0,.55);z-index:1999;display:none}
  #sideOverlay.show{display:block}
  /* Botón hamburger visible */
  .hbtn{display:flex}
  /* Topbar más compacto */
  .topbar{padding:0 10px;gap:8px;height:54px}
  .sw{max-width:none;flex:1}
  /* Ocultar botones secundarios en móvil para no saturar */
  .tr .bi:not(#themeBtn):not(.hbtn){display:none}
  .vt{display:none}
  /* Contenido con menos padding */
  .content{padding:12px}
  /* Grid más estrecho */
  .fg{grid-template-columns:repeat(auto-fill,minmax(130px,1fr));gap:9px}
  /* Lista: ocultar columnas fecha y tamaño */
  .fr .rs,.fr .rd{display:none}
  /* Tarjeta: botones acción siempre visibles en móvil (no hace hover) */
  .fc .fa{display:flex}
  .fr .ra{display:flex}
  /* Ajustes en grid de 1 col */
  .setg{grid-template-columns:1fr}
  .sc.full{grid-column:span 1}
  /* Tabla admin simplificada */
  .adminmail,.adminlogin{display:none}
  /* Ctxbar más compacto */
  .ctxbar{bottom:12px;padding:8px 10px;gap:4px}
  .ctxbar button{padding:7px 10px;font-size:11px}
  .ctxbar .cnt{padding:0 6px;font-size:12px}
  /* Visor: sin padding lateral */
  .viewer-body{padding:10px}
  .viewer-body video{max-width:100%;max-height:85%}
  .viewer-nav{width:38px;height:38px;font-size:16px}
  .viewer-nav.prev{left:8px}.viewer-nav.next{right:8px}
  /* Panel de subida más pequeño */
  #uploadPanel{width:260px;bottom:12px;right:12px}
  /* Toasts */
  .toasts{bottom:12px;right:12px;left:12px;align-items:stretch}
  .toast{min-width:unset}
  /* Tbar botones */
  .tbar .btn{padding:7px 11px;font-size:12px}
  /* Modales ocupan más pantalla */
  .md{padding:20px 18px;border-radius:16px}
  /* Ghost drag */
  #dragGhost{font-size:11px;padding:6px 10px}
}
@media(max-width:420px){
  .fg{grid-template-columns:repeat(auto-fill,minmax(110px,1fr));gap:8px}
  .ft{height:80px;font-size:28px}
  .tbar h2{font-size:16px}
}

/* ──────────────────────────────────────────────────────────────────────────
   Vault OneDrive Phase 1 — UI neutra, tabla principal y subida discreta
   Autor: Yansy Rodriguez · Assisted by ChatGPT
   ────────────────────────────────────────────────────────────────────────── */
:root{
  --bg:#f7f7f8;--surface:#ffffff;--surface2:#f3f2f1;--surface3:#edebe9;
  --border:#e1dfdd;--border2:#c8c6c4;--accent:#2563eb;--accent2:#3730a3;
  --accent-grad:linear-gradient(135deg,#0f6cbd,#2b2fbb);--accent-dim:#e8f2ff;
  --text:#1f1f1f;--muted:#605e5c;--muted2:#8a8886;--danger:#c50f1f;--success:#107c10;
  --sidebar-w:292px;
}
[data-theme="light"],html[data-theme="light"]{
  --bg:#f7f7f8;--surface:#ffffff;--surface2:#f3f2f1;--surface3:#edebe9;
  --border:#e1dfdd;--border2:#c8c6c4;--accent:#0f6cbd;--accent2:#3730a3;
  --accent-grad:linear-gradient(135deg,#0f6cbd,#3730a3);--accent-dim:#e8f2ff;
  --text:#1f1f1f;--muted:#605e5c;--muted2:#8a8886;--danger:#c50f1f;--success:#107c10;
}
body{background:var(--bg);font-size:15px;color:var(--text)}
.sidebar{background:#f7f7f8;border-right:1px solid #e6e6e6;padding:20px 10px 12px;gap:8px}
.sh{border:0;padding:0 8px 10px}.brand .logo{display:none}.brand .name{background:none!important;-webkit-text-fill-color:initial;color:#111;font-size:14px;font-family:'Inter',sans-serif;font-weight:700}
.od-create-wrap{position:relative;margin:4px 6px 22px}.od-create{height:42px;padding:0 18px;border:0;border-radius:22px;background:linear-gradient(135deg,#0078d4,#3730a3);color:#fff;font-weight:700;font-size:14px;display:inline-flex;align-items:center;gap:9px;cursor:pointer;box-shadow:0 1px 2px rgba(0,0,0,.10)}
.od-create svg{width:18px;height:18px}.od-menu{display:none;position:absolute;top:48px;left:0;width:268px;background:#fff;border:1px solid #e5e5e5;border-radius:8px;box-shadow:0 8px 30px rgba(0,0,0,.16);z-index:2200;padding:8px 0}.od-menu.show{display:block}.od-mi{display:flex;align-items:center;gap:12px;padding:12px 16px;color:#323130;cursor:pointer;font-size:14px}.od-mi:hover{background:#f3f2f1}.od-mi .ico{width:20px;text-align:center}.od-sep{height:1px;background:#edebe9;margin:4px 10px}
.nav{padding:0 0 8px}.ns{font-size:14px;color:#111;text-transform:none;letter-spacing:0;font-weight:700;margin:18px 8px 8px;padding:0}.ns.od-muted{font-size:13px;color:#605e5c;margin-top:24px}.ni{border-radius:6px;color:#242424;font-size:15px;font-weight:400;padding:9px 10px;margin:2px 0;position:relative}.ni:hover{background:#edebe9}.ni.active{background:#edebe9;color:#111;font-weight:600;box-shadow:inset 2px 0 0 #0078d4}.ni svg{width:20px;height:20px;color:#424242}.sf{border-top:1px solid #e1dfdd;padding:12px 8px 0}.ql,.un{color:#323130}.qb{background:#edebe9}.qf{background:#8a8886}.av{background:#0f6cbd;color:#fff}.lb{color:#605e5c}
.main{background:#fff}.topbar{height:72px;background:#fff;border-bottom:0;padding:0 20px}.sw{max-width:520px}.sw input{height:40px;background:#f7f7f8;border-color:#e1dfdd;border-radius:8px;font-size:14px}.sw input:focus{background:#fff;border-color:#0f6cbd;box-shadow:0 0 0 1px #0f6cbd}.tr{gap:10px}.bi{border:0;background:#fff;color:#323130;width:auto;min-width:34px;height:34px;border-radius:5px;padding:0 8px}.bi:hover{background:#f3f2f1}.top-label{font-size:14px;margin-left:5px}.vt{background:#fff;border:0;padding:0;gap:2px}.vb{height:34px;border-radius:5px;padding:7px 9px}.vb.active{background:#edebe9}.content{background:#fff;padding:0 20px 24px}.tbar{height:52px;margin:0;align-items:center}.tbar h2{font-family:'Inter',sans-serif;font-size:21px;font-weight:700;color:#111}.page#page-files>.tbar .btn{display:none}.bc{margin:0 0 8px;color:#605e5c}.btn{border-radius:6px}.bp{background:#0f6cbd;box-shadow:none}.bp:hover{background:#115ea3;box-shadow:none;transform:none}.bs{background:#fff;border:1px solid #e1dfdd}.bd{background:#fff4f4;color:#c50f1f;border-color:#f1bbbb}
.fl{gap:0;border:1px solid #e5e5e5;border-radius:10px;overflow:hidden;background:#fff}.flh{display:grid;grid-template-columns:42px minmax(260px,1.9fr) minmax(130px,.85fr) minmax(150px,.9fr) minmax(110px,.6fr) minmax(120px,.7fr) minmax(170px,.9fr);align-items:center;height:52px;border-bottom:1px solid #e5e5e5;background:#fff;color:#323130;font-size:14px;font-weight:600}.flh div{padding:0 14px}.flh .sort:after{content:'⌄';font-size:12px;margin-left:6px;color:#605e5c}.fr{display:grid;grid-template-columns:42px minmax(260px,1.9fr) minmax(130px,.85fr) minmax(150px,.9fr) minmax(110px,.6fr) minmax(120px,.7fr) minmax(170px,.9fr);gap:0;min-height:52px;padding:0;border:0;border-radius:0;border-bottom:1px solid #edebe9;background:#fff}.fr:hover{background:#f8f8f8;border-color:#edebe9}.fr>div{padding:0 14px;display:flex;align-items:center}.fr .rsel{justify-content:center;padding:0}.fr .ri{display:none}.fr .rn{font-size:15px;font-weight:400;color:#242424;gap:12px}.fr .rn .fileico{font-size:24px;width:28px;display:inline-flex;justify-content:center}.fr .rd,.fr .rs,.fr .rmod,.fr .rshare,.fr .ract{width:auto;text-align:left;color:#605e5c;font-size:14px}.fr .ra{display:none!important}.fg{grid-template-columns:repeat(auto-fill,minmax(170px,1fr));gap:14px}.fc{border-color:#e5e5e5;border-radius:8px;box-shadow:none}.fc:hover{transform:none;box-shadow:0 3px 10px rgba(0,0,0,.08);border-color:#c8c6c4}.ft{background:#fafafa}.fn{font-size:13px}.fm{font-size:12px}.selcheck,.rsel{color:#0f6cbd}.fr .rsel{opacity:0;display:flex!important;transition:opacity .12s ease,border-color .12s ease,background .12s ease}.fr:hover .rsel,.selmode .fr .rsel,.fr.sel .rsel{opacity:1}.fr .rsel.on{opacity:1;background:#0f6cbd;border-color:#0f6cbd}.fc .selcheck{background:#fff;border:1.5px solid #8a8886;color:#0f6cbd}.fc:hover .selcheck,.selmode .fc .selcheck,.fc.sel .selcheck{opacity:1}.fc .selcheck.on{background:#0f6cbd;border-color:#0f6cbd}.empty{color:#605e5c}.empty h3{font-family:'Inter',sans-serif;color:#242424}
#uploadPanel{left:50%;right:auto;bottom:22px;transform:translateX(-50%);width:min(430px,92vw);border-radius:4px;background:#292827;color:#fff;border:0;box-shadow:0 8px 28px rgba(0,0,0,.24);min-height:52px}#uploadPanel .uph{border:0;padding:10px 14px 8px;font-family:'Inter',sans-serif;font-weight:600;gap:10px;min-height:44px}#uploadPanel .uph span{font-size:14px}#uploadPanel .upstatus{width:18px;height:18px;border-radius:50%;display:flex;align-items:center;justify-content:center;flex:0 0 18px;background:transparent;color:#c8e7ff;font-weight:700;font-size:14px}#uploadPanel.running .upstatus{animation:none;color:#c8e7ff}#uploadPanel.done .upstatus{animation:none;background:#6ccb5f;color:#111;font-size:12px}#uploadPanel.err .upstatus{animation:none;background:#ff7b72;color:#111;font-size:12px}#uploadPanel .upprogress{height:2px;background:#4a4948;margin:0 0 0 0;overflow:hidden}#uploadPanel .upprogress div{height:100%;width:0;background:#60a5fa;transition:width .18s ease}#uploadPanel.done .upprogress div{background:#6ccb5f}#uploadPanel.err .upprogress div{background:#ff7b72}#uploadPanel .upexpand,#uploadPanel .upclose{background:transparent;border:0;color:#fff!important;cursor:pointer;font-size:17px;line-height:1;padding:2px 5px;border-radius:4px}#uploadPanel .upexpand:hover,#uploadPanel .upclose:hover{background:#3b3a39}.upexpand{margin-left:auto}.upclose{margin-left:2px}#uploadPanel .uplist{display:none;padding:6px 12px 12px;max-height:210px;overflow:auto}#uploadPanel.expanded .uplist{display:block}.upitem{background:#292827;color:#fff;padding:8px 4px}.upitem .upname{font-size:12px}.updest{color:#8ec7ff;font-weight:600}.upitem .upbar{background:#4a4948;height:2px}.upitem .upfill{background:#60a5fa}.upitem.done .upfill{background:#6ccb5f}.upitem.err .upfill{background:#ff7b72}.upitem .uppct{color:#d0d0d0;font-size:11px}.toast{border-radius:4px;background:#292827;color:#fff}.toast.success span:first-child{background:#6ccb5f;color:#111}.toast.error span:first-child{background:#ff7b72;color:#111}
.ctxbar{border-radius:8px;background:#fff;color:#323130;border:1px solid #d0d7de;box-shadow:0 10px 34px rgba(15,23,42,.14),0 2px 8px rgba(15,23,42,.08)}.ctxbar .cnt{color:#242424;border-right-color:#e1dfdd}.ctxbar button{color:#323130}.ctxbar button:hover{background:#f3f2f1;color:#111}.ctxbar button.danger{color:#c50f1f}.ctxbar button.danger:hover{background:#fde7e9;color:#a80000}.ctxbar .div{background:#e1dfdd}.ctx{border-radius:6px;border:1px solid #e5e5e5;box-shadow:0 10px 32px rgba(0,0,0,.16)}.cxi:hover{background:#f3f2f1}.mo{background:rgba(0,0,0,.38)}.md{border-radius:8px;box-shadow:0 24px 60px rgba(0,0,0,.28)}.md h3{font-family:'Inter',sans-serif}.uz{border-radius:8px;background:#fafafa}.uz:hover{background:#f3f2f1}
@media(max-width:980px){:root{--sidebar-w:280px}.flh{display:none}.fr{grid-template-columns:42px minmax(180px,1fr) 100px}.fr .rmod,.fr .rshare,.fr .ract{display:none}.fr .rs{font-size:13px}.sidebar{position:fixed;z-index:900;inset:0 auto 0 0;transform:translateX(-105%);box-shadow:12px 0 30px rgba(0,0,0,.18)}.sidebar.open{transform:translateX(0)}.hbtn{display:flex}.topbar{height:62px}.content{padding:0 12px 18px}}


/* Vault Phase 3.1 — Upload panel visual hotfix
   Corrige el check final enorme/ovalado: la regla antigua #uploadPanel .uph span{flex:1}
   afectaba al span del icono. Se fuerza tamaño fijo solo para el icono y flex para el título. */
#uploadPanel .uph .upstatus{
  flex:0 0 18px!important;
  width:18px!important;
  height:18px!important;
  min-width:18px!important;
  max-width:18px!important;
  border-radius:50%!important;
  padding:0!important;
  margin:0 2px 0 0!important;
  line-height:18px!important;
  font-size:11px!important;
  display:inline-flex!important;
  align-items:center!important;
  justify-content:center!important;
}
#uploadPanel .uph #uploadTitle{
  flex:1 1 auto!important;
  min-width:0!important;
  font-size:14px!important;
  line-height:18px!important;
}
#uploadPanel.done .uph .upstatus{
  background:#6ccb5f!important;
  color:#111!important;
  box-shadow:none!important;
  transform:none!important;
}
#uploadPanel.running .uph .upstatus{
  background:transparent!important;
  color:#c8e7ff!important;
}
#uploadPanel .upprogress{
  height:2px!important;
}

/* Vault Phase 3.1 — Fix menú móvil: overlay detrás del sidebar y no por encima */
@media(max-width:980px){
  .sidebar{z-index:3001!important;touch-action:manipulation}
  .mo{z-index:3000!important;pointer-events:auto}
  .sidebar.open ~ .mo,.mo.show{pointer-events:auto}
  .sidebar.open{pointer-events:auto}
}

/* ──────────────────────────────────────────────────────────────────────────
   Vault OneDrive Phase 2 — barra superior contextual, login claro y selección
   Autor: Yansy Rodriguez · Assisted by ChatGPT
   ────────────────────────────────────────────────────────────────────────── */
body.selmode .topbar .sw,body.selmode .topbar .tr,body.trashselmode .topbar .sw,body.trashselmode .topbar .tr{opacity:0;pointer-events:none}
.ctxbar{top:12px!important;bottom:auto!important;left:calc(var(--sidebar-w) + 20px)!important;right:20px!important;transform:translateY(-14px)!important;max-width:none!important;min-height:48px;border-radius:10px!important;background:#fff!important;border:1px solid #e1dfdd!important;box-shadow:0 8px 22px rgba(0,0,0,.12)!important;justify-content:flex-start;padding:7px 12px!important;z-index:2500!important;overflow-x:auto}
.ctxbar.show{transform:translateY(0)!important;opacity:1;visibility:visible;pointer-events:auto}
.ctxbar .cnt{order:20;margin-left:auto;border:1px solid #d0d7de!important;border-radius:20px;padding:6px 13px!important;margin-right:8px;color:#242424!important;background:#fff;font-family:'Inter',sans-serif;font-size:14px;font-weight:500}
.ctxbar button{border-radius:6px!important;padding:8px 10px!important;color:#242424!important;font-size:14px!important;font-weight:500!important}
.ctxbar button:hover{background:#f3f2f1!important;color:#111!important}.ctxbar button.danger{color:#c50f1f!important}.ctxbar button.danger:hover{background:#fde7e9!important;color:#a80000!important}.ctxbar .div{height:28px!important;background:#e1dfdd!important;margin:0 8px!important}.ctxbar button:last-child{order:19;border:1px solid #d0d7de!important;border-radius:20px!important;margin-left:auto!important}
.flh,.fr{grid-template-columns:58px minmax(260px,1.9fr) minmax(130px,.85fr) minmax(150px,.9fr) minmax(110px,.6fr) minmax(120px,.7fr) minmax(170px,.9fr)!important}.flh{min-height:52px}.flh .hsel{height:52px;display:flex;align-items:center;justify-content:center;padding:0!important}.selectAllCircle{width:24px;height:24px;border-radius:50%;border:1.5px solid #8a8886;background:#fff;color:#0f6cbd;display:flex;align-items:center;justify-content:center;opacity:0;cursor:pointer;transition:opacity .12s,background .12s,border-color .12s}.fl:hover .selectAllCircle,.selmode .selectAllCircle,.trashselmode .selectAllCircle{opacity:1}.selectAllCircle.on{opacity:1;background:#0f6cbd;border-color:#0f6cbd;color:#fff}.selectAllCircle svg{width:14px;height:14px;opacity:.95}
.fr .rsel{width:24px!important;height:24px!important;justify-self:center!important;align-self:center!important;margin:auto!important;padding:0!important;border:1.5px solid #8a8886!important;background:#fff}.fr .rsel.on{background:#0f6cbd!important;border-color:#0f6cbd!important}.fr>div:first-child{padding:0!important;justify-content:center!important}.fc .selcheck{width:24px!important;height:24px!important;left:8px!important;top:8px!important}.fr.sel{background:#eaf3ff!important}.fc.sel{background:#eaf3ff!important;outline:1px solid #0f6cbd!important;outline-offset:0!important}
@media(max-width:980px){.ctxbar{left:12px!important;right:12px!important;top:8px!important}.flh,.fr{grid-template-columns:50px minmax(180px,1fr) 100px!important}.ctxbar .cnt{order:0;margin-left:0}.ctxbar button:last-child{margin-left:0!important}}


/* ── Fase 3.2: fixes OneDrive mobile/upload/share/admin ─────────────────── */
#uploadPanel{min-height:52px!important}#uploadPanel .uph{display:flex!important;align-items:center!important;gap:10px!important}#uploadPanel .uph .upstatus,#uploadStatusIcon{width:20px!important;height:20px!important;min-width:20px!important;max-width:20px!important;flex:0 0 20px!important;border-radius:50%!important;display:inline-flex!important;align-items:center!important;justify-content:center!important;padding:0!important;margin:0!important;font-size:12px!important;line-height:20px!important;overflow:hidden!important}#uploadPanel .uph #uploadTitle{flex:1 1 auto!important;min-width:0!important;font-size:14px!important;line-height:18px!important;white-space:normal!important}#uploadPanel.done .uph .upstatus{background:#6ccb5f!important;color:#111!important}#uploadPanel.running .uph .upstatus{background:transparent!important;color:#c8e7ff!important}#uploadPanel .upprogress{height:2px!important}
.share-toast{width:min(520px,92vw);background:#fff!important;color:#242424!important;border:1px solid #e1dfdd!important;border-radius:8px!important;box-shadow:0 18px 48px rgba(0,0,0,.22)!important;padding:22px 26px!important;display:grid!important;grid-template-columns:20px 1fr auto!important;gap:12px!important;align-items:start!important}.share-toast .st-ico{width:18px!important;height:18px!important;border-radius:50%!important;border:1.5px solid #107c10!important;color:#107c10!important;background:#fff!important;display:flex!important;align-items:center!important;justify-content:center!important;font-size:12px!important;font-weight:800!important;grid-row:1 / span 2!important;margin-top:2px!important}.share-toast .st-title{font-size:20px!important;font-weight:700!important;color:#242424!important;line-height:1.2!important}.share-toast .st-sub{grid-column:2 / span 2;font-size:14px!important;color:#323130!important;margin-top:2px!important}.share-toast .st-actions{display:flex!important;gap:12px!important;align-items:center!important}.share-toast button{border:0;background:transparent;color:#0f6cbd;cursor:pointer;font:inherit;font-weight:500;padding:4px}.share-toast .st-close{color:#323130;font-size:18px;line-height:1}.share-toast .st-settings{display:inline-flex;align-items:center;gap:6px}.share-toast .st-settings svg{width:16px;height:16px}
.admin-shell{display:flex;flex-direction:column;gap:18px}.admin-hero{display:flex;align-items:center;justify-content:space-between;gap:16px;flex-wrap:wrap}.admin-hero h3{font-family:'Sora';font-size:18px;margin:0}.admin-tabs{display:flex;gap:6px;border-bottom:1px solid var(--border);margin-bottom:2px}.admin-tab{border:0;background:transparent;color:var(--muted);padding:10px 12px;border-bottom:2px solid transparent;cursor:pointer;font-weight:600}.admin-tab.active{color:#0f6cbd;border-bottom-color:#0f6cbd}.sgr.admin-kpis{grid-template-columns:repeat(4,minmax(160px,1fr));gap:14px}.admin-kpis .stc{border-radius:12px;background:#fff;border:1px solid #e1dfdd;box-shadow:0 1px 2px rgba(0,0,0,.03);padding:18px 20px}.admin-kpis .sic{width:42px;height:42px;border-radius:10px;background:#eef6ff;color:#0f6cbd;display:flex;align-items:center;justify-content:center;margin-bottom:14px}.admin-kpis .sic svg{width:22px;height:22px}.admin-kpis .sl{font-size:11px;letter-spacing:.8px;color:#605e5c}.admin-kpis .sv{font-size:25px;color:#111}.admin-table-wrap{background:#fff;border:1px solid #e1dfdd;border-radius:12px;overflow:hidden}.admin-table{width:100%;border-collapse:collapse}.admin-user{display:flex;align-items:center;gap:10px}.admin-avatar{width:32px;height:32px;border-radius:50%;background:#0f6cbd;color:#fff;display:flex;align-items:center;justify-content:center;font-weight:800;overflow:hidden}.admin-avatar img{width:100%;height:100%;object-fit:cover}.admin-name{font-weight:700}.admin-sub{font-size:12px;color:#605e5c}.quota-wrap{min-width:180px}.quota-line{display:flex;align-items:center;gap:8px}.quota-bar{height:5px;background:#edebe9;border-radius:999px;overflow:hidden;margin-top:7px}.quota-fill{height:100%;background:#0f6cbd}.admin-actions{display:flex;justify-content:flex-end;gap:6px}.icon-btn{width:32px;height:32px;border-radius:6px;border:1px solid #e1dfdd;background:#fff;color:#323130;cursor:pointer;display:inline-flex;align-items:center;justify-content:center}.icon-btn:hover{background:#f3f2f1}.icon-btn.danger{color:#a80000;background:#fff;border-color:#f1bbbb}.icon-btn svg{width:16px;height:16px}
.admin-panel{display:none}.admin-panel.active{display:block}.admin-sec-title{display:flex;align-items:center;justify-content:space-between;gap:12px;margin:4px 0 12px}.admin-sec-title h3{font-family:'Sora';font-size:18px;margin:0}.admin-muted{font-size:12px;color:#605e5c}.admin-empty{padding:30px;border:1px dashed #c8c6c4;border-radius:12px;color:#605e5c;background:#fafafa}.admin-table td,.admin-table th{padding:12px 14px;border-bottom:1px solid #edebe9;text-align:left;vertical-align:middle}.admin-table th{font-size:11px;text-transform:uppercase;letter-spacing:.7px;color:#605e5c;background:#fff}.admin-table tr:last-child td{border-bottom:0}.admin-pill{display:inline-flex;align-items:center;border-radius:999px;padding:3px 8px;font-size:11px;font-weight:700;background:#eef6ff;color:#0f6cbd}.admin-pill.warn{background:#fff4ce;color:#8a6100}.admin-pill.ok{background:#dff6dd;color:#107c10}.admin-pill.bad{background:#fde7e9;color:#a80000}.system-grid{display:grid;grid-template-columns:repeat(2,minmax(220px,1fr));gap:12px}.system-card{border:1px solid #e1dfdd;border-radius:12px;background:#fff;padding:14px}.system-card .k{font-size:11px;text-transform:uppercase;letter-spacing:.7px;color:#605e5c;margin-bottom:6px}.system-card .v{font-weight:700;color:#242424;word-break:break-word}.profile-avatar-edit{display:flex;align-items:center;gap:14px;margin-bottom:14px}.profile-photo{width:64px;height:64px;border-radius:50%;background:#0f6cbd;color:#fff;display:flex;align-items:center;justify-content:center;font-weight:800;font-size:24px;overflow:hidden}.profile-photo img{width:100%;height:100%;object-fit:cover}.details-panel{position:fixed;top:0;right:0;width:360px;max-width:94vw;height:100vh;background:#fff;border-left:1px solid #e1dfdd;box-shadow:-18px 0 40px rgba(0,0,0,.12);z-index:1500;transform:translateX(105%);transition:transform .18s ease;display:flex;flex-direction:column}.details-panel.open{transform:translateX(0)}.dp-head{height:58px;border-bottom:1px solid #edebe9;display:flex;align-items:center;justify-content:space-between;padding:0 18px}.dp-head h3{font-family:'Sora';font-size:17px}.dp-head button{border:0;background:#fff;font-size:24px;cursor:pointer;color:#323130}.dp-body{padding:18px;overflow:auto}.dp-empty{color:#605e5c;font-size:13px;line-height:1.5}.dp-icon{width:72px;height:72px;border-radius:16px;background:#eef6ff;display:flex;align-items:center;justify-content:center;font-size:38px;margin-bottom:14px}.dp-name{font-size:18px;font-weight:800;margin-bottom:4px;word-break:break-word}.dp-type{font-size:13px;color:#605e5c;margin-bottom:18px}.dp-row{display:grid;grid-template-columns:120px 1fr;gap:10px;padding:10px 0;border-bottom:1px solid #f3f2f1;font-size:13px}.dp-row .k{color:#605e5c}.dp-row .v{color:#242424;word-break:break-word}.dp-actions{display:flex;gap:8px;flex-wrap:wrap;margin-top:18px}
@media(max-width:980px){#sideOverlay{z-index:1200!important}.sidebar{z-index:1300!important}.admin-kpis.sgr{grid-template-columns:repeat(2,minmax(140px,1fr))}.adminmail,.adminlogin{display:none!important}}@media(max-width:560px){.share-toast{grid-template-columns:20px 1fr auto!important;padding:18px!important}.share-toast .st-title{font-size:18px!important}.share-toast .st-actions{grid-column:2 / span 2}.admin-kpis.sgr{grid-template-columns:1fr}.admin-table-wrap{overflow-x:auto}.admin-table{min-width:760px}.system-grid{grid-template-columns:1fr}.details-panel{width:100vw;max-width:100vw}}

.sort-menu{position:fixed;top:58px;right:150px;background:#fff;border:1px solid #e1dfdd;border-radius:8px;box-shadow:0 14px 40px rgba(0,0,0,.18);z-index:2600;min-width:220px;padding:6px;display:none}.sort-menu.open{display:block}.sort-mi{display:flex;justify-content:space-between;gap:12px;align-items:center;padding:9px 10px;border-radius:6px;cursor:pointer;font-size:13px;color:#242424}.sort-mi:hover{background:#f3f2f1}.sort-mi.active{background:#eef6ff;color:#0f6cbd;font-weight:700}.sort-dir{font-size:12px;color:#605e5c}.system-form-grid{display:grid;grid-template-columns:repeat(2,minmax(260px,1fr));gap:14px}.system-section{background:#fff;border:1px solid #e1dfdd;border-radius:12px;padding:16px}.system-section h4{margin:0 0 12px;font-family:'Sora';font-size:15px}.system-section .mf{margin-bottom:10px}.system-section .mf input,.system-section .mf select{width:100%;background:#fafafa;border:1px solid #d0d7de;border-radius:8px;padding:9px 10px;font-size:13px}.system-actions{display:flex;gap:8px;flex-wrap:wrap;margin-top:10px}.system-help{font-size:12px;color:#605e5c;line-height:1.4;margin-top:-4px;margin-bottom:8px}.switchrow{display:flex;align-items:center;justify-content:space-between;gap:12px;margin:10px 0;font-size:13px}.switchrow input{width:auto}.admin-action-row{display:flex;gap:8px;flex-wrap:wrap;align-items:center}.ctxbar{right:20px!important}.ctxbar .ctx-spacer{flex:1;min-width:24px}.ctxbar .ctx-count{margin-left:auto!important}.ctxbar .ctx-details{margin-left:8px}.ctxbar .ctx-details svg{width:15px;height:15px}.ctxbar .ctx-close{order:90}.ctxbar .ctx-count{order:91}@media(max-width:560px){.system-form-grid{grid-template-columns:1fr}.sort-menu{right:12px;left:12px;top:54px}}

/* Phase 3.2.5 — toolbar/details alignment fix */
.ctxbar#ctxbar{position:fixed!important;top:12px!important;bottom:auto!important;left:calc(var(--sidebar-w) + 20px)!important;right:330px!important;transform:translateY(-14px)!important;max-width:none!important;min-height:46px!important;border-radius:10px!important;background:#fff!important;border:1px solid #e1dfdd!important;box-shadow:0 8px 22px rgba(0,0,0,.12)!important;display:flex!important;align-items:center!important;justify-content:flex-start!important;gap:6px!important;padding:6px 10px!important;z-index:2400!important;overflow-x:auto!important;opacity:0;visibility:hidden;pointer-events:none}
.ctxbar#ctxbar.show{transform:translateY(0)!important;opacity:1!important;visibility:visible!important;pointer-events:auto!important}
.ctxbar#ctxbar button{border:0!important;border-radius:6px!important;background:transparent!important;padding:8px 10px!important;color:#242424!important;font-size:14px!important;font-weight:500!important;white-space:nowrap!important;display:inline-flex!important;align-items:center!important;gap:6px!important}
.ctxbar#ctxbar button:hover{background:#f3f2f1!important;color:#111!important}.ctxbar#ctxbar button.danger{color:#c50f1f!important}.ctxbar#ctxbar button.danger:hover{background:#fde7e9!important;color:#a80000!important}
.ctxbar#ctxbar .ctx-spacer{flex:1 1 auto!important;min-width:16px!important}.ctxbar#ctxbar .ctx-close{margin-left:auto!important;border:1px solid #d0d7de!important;border-radius:999px!important;width:34px!important;height:34px!important;padding:0!important;justify-content:center!important;font-size:18px!important;line-height:1!important;color:#605e5c!important;order:unset!important}.ctxbar#ctxbar .cnt{border:1px solid #d0d7de!important;border-radius:999px!important;background:#fff!important;color:#242424!important;font-family:'Inter',sans-serif!important;font-size:14px!important;font-weight:500!important;padding:7px 13px!important;margin:0 0 0 6px!important;white-space:nowrap!important;order:unset!important}
.ctxbar#trashSelBar{z-index:2300!important}body.selmode .tr{visibility:visible!important;opacity:1!important;pointer-events:auto!important}.details-panel{z-index:1450!important}.details-panel:not(.open){pointer-events:none!important}
@media(max-width:980px){.ctxbar#ctxbar{left:12px!important;right:12px!important;top:8px!important}.ctxbar#ctxbar .ctx-spacer{display:none!important}.ctxbar#ctxbar .cnt{font-size:12px!important;padding:6px 10px!important}.ctxbar#ctxbar button{font-size:12px!important;padding:7px 8px!important}}


/* Phase 3.2.6 — polish final validado: toolbar, tema, sistema y perfil */
.system-form-grid{display:grid!important;grid-template-columns:minmax(260px,1fr) minmax(320px,1fr)!important;gap:14px!important;align-items:start!important}.system-section{align-self:start!important;height:auto!important}.system-section h4{margin-bottom:12px!important}.system-section .mf:last-child{margin-bottom:0!important}
@media(max-width:900px){.system-form-grid{grid-template-columns:1fr!important}}
/* La barra contextual termina antes de Ordenar/Vista/Detalles/Tema. Esos controles se quedan siempre en su sitio. */
.ctxbar#ctxbar{left:calc(var(--sidebar-w) + 20px)!important;right:360px!important;top:12px!important;bottom:auto!important;min-height:46px!important;border-radius:10px!important;background:#fff!important;border:1px solid #e1dfdd!important;box-shadow:0 8px 22px rgba(0,0,0,.12)!important;padding:6px 10px!important;gap:6px!important;overflow-x:auto!important;z-index:2300!important}.ctxbar#ctxbar .ctx-spacer{flex:1 1 auto!important;min-width:10px!important}.ctxbar#ctxbar .ctx-close{margin-left:auto!important;width:30px!important;height:30px!important;min-width:30px!important;border:1px solid #d0d7de!important;border-radius:999px!important;padding:0!important;font-size:17px!important;color:#605e5c!important}.ctxbar#ctxbar .cnt{border:1px solid #d0d7de!important;border-radius:999px!important;background:#fff!important;color:#242424!important;font-size:13px!important;font-weight:500!important;padding:6px 11px!important;margin-left:4px!important;white-space:nowrap!important}.ctxbar#ctxbar button.danger svg{width:15px!important;height:15px!important}.ctxbar#ctxbar button.danger{color:#c50f1f!important}
body.selmode .tr{visibility:visible!important;opacity:1!important;pointer-events:auto!important}.details-panel:not(.open){pointer-events:none!important}
@media(max-width:980px){.ctxbar#ctxbar{left:12px!important;right:12px!important;top:8px!important}.ctxbar#ctxbar .ctx-spacer{display:none!important}.ctxbar#ctxbar button{font-size:12px!important;padding:7px 8px!important}.ctxbar#ctxbar .cnt{font-size:12px!important;padding:6px 10px!important}}
/* Tema oscuro real: no deja el botón de tema como decorativo */
html[data-theme="dark"]{--bg:#111827;--surface:#1f2937;--surface2:#273244;--surface3:#374151;--border:#374151;--border2:#4b5563;--accent:#60a5fa;--accent2:#818cf8;--accent-grad:linear-gradient(135deg,#2563eb,#4f46e5);--accent-dim:rgba(96,165,250,.16);--text:#f9fafb;--muted:#cbd5e1;--muted2:#94a3b8;--danger:#f87171;--success:#22c55e}
html[data-theme="dark"] body,html[data-theme="dark"] .main,html[data-theme="dark"] .content,html[data-theme="dark"] .topbar{background:#111827!important;color:#f9fafb!important}html[data-theme="dark"] .sidebar{background:#0f172a!important;border-right-color:#263244!important}html[data-theme="dark"] .brand .name,html[data-theme="dark"] .tbar h2,html[data-theme="dark"] .admin-hero h3,html[data-theme="dark"] .md h3,html[data-theme="dark"] .dp-head h3{color:#f9fafb!important;-webkit-text-fill-color:initial!important}html[data-theme="dark"] .ni,html[data-theme="dark"] .ns,html[data-theme="dark"] .ql,html[data-theme="dark"] .un,html[data-theme="dark"] .bi,html[data-theme="dark"] .vb,html[data-theme="dark"] .top-label{color:#dbeafe!important}html[data-theme="dark"] .ni:hover,html[data-theme="dark"] .ni.active,html[data-theme="dark"] .vb.active,html[data-theme="dark"] .bi:hover{background:#1f2937!important;color:#fff!important}html[data-theme="dark"] .sw input,html[data-theme="dark"] input,html[data-theme="dark"] select,html[data-theme="dark"] textarea{background:#111827!important;border-color:#374151!important;color:#f9fafb!important}html[data-theme="dark"] .fl,html[data-theme="dark"] .flh,html[data-theme="dark"] .fr,html[data-theme="dark"] .fc,html[data-theme="dark"] .sc,html[data-theme="dark"] .md,html[data-theme="dark"] .admin-kpis .stc,html[data-theme="dark"] .admin-table-wrap,html[data-theme="dark"] .system-section,html[data-theme="dark"] .system-card,html[data-theme="dark"] .details-panel,html[data-theme="dark"] .dp-head{background:#1f2937!important;border-color:#374151!important;color:#f9fafb!important}html[data-theme="dark"] .fr:hover{background:#273244!important}html[data-theme="dark"] .flh,html[data-theme="dark"] .fr{border-bottom-color:#374151!important}html[data-theme="dark"] .fr .rn,html[data-theme="dark"] .dp-name,html[data-theme="dark"] .dp-row .v,html[data-theme="dark"] .admin-name{color:#f9fafb!important}html[data-theme="dark"] .fr .rd,html[data-theme="dark"] .fr .rs,html[data-theme="dark"] .fr .rmod,html[data-theme="dark"] .fr .rshare,html[data-theme="dark"] .fr .ract,html[data-theme="dark"] .bc,html[data-theme="dark"] .admin-sub,html[data-theme="dark"] .admin-muted,html[data-theme="dark"] .dp-row .k,html[data-theme="dark"] .dp-type{color:#cbd5e1!important}html[data-theme="dark"] .ctxbar#ctxbar{background:#1f2937!important;border-color:#374151!important;box-shadow:0 8px 22px rgba(0,0,0,.35)!important}html[data-theme="dark"] .ctxbar#ctxbar button,html[data-theme="dark"] .ctxbar#ctxbar .cnt{color:#f9fafb!important;background:#1f2937!important;border-color:#4b5563!important}html[data-theme="dark"] .ctxbar#ctxbar button:hover{background:#273244!important}html[data-theme="dark"] .od-menu,html[data-theme="dark"] .sort-menu,html[data-theme="dark"] .ctx{background:#1f2937!important;border-color:#374151!important;color:#f9fafb!important}html[data-theme="dark"] .od-mi,html[data-theme="dark"] .sort-mi,html[data-theme="dark"] .cxi{color:#f9fafb!important}html[data-theme="dark"] .od-mi:hover,html[data-theme="dark"] .sort-mi:hover,html[data-theme="dark"] .cxi:hover{background:#273244!important}html[data-theme="dark"] .system-help{color:#cbd5e1!important}html[data-theme="dark"] .profile-photo{background:#2563eb!important}
/* Phase 3.2.7 — dark mode contrast and system masonry layout */
html[data-theme="dark"] .tr .bi,
html[data-theme="dark"] #sortBtn,
html[data-theme="dark"] #detailsBtn,
html[data-theme="dark"] #themeBtn,
html[data-theme="dark"] .vt{background:#1f2937!important;color:#e5edf8!important;border-color:#475569!important;box-shadow:none!important}
html[data-theme="dark"] .tr .bi svg,html[data-theme="dark"] .tr .bi .top-label,html[data-theme="dark"] .vb svg,html[data-theme="dark"] #themeBtn svg{color:#e5edf8!important;stroke:currentColor!important;opacity:1!important}
html[data-theme="dark"] .tr .bi:hover,html[data-theme="dark"] #sortBtn:hover,html[data-theme="dark"] #detailsBtn:hover,html[data-theme="dark"] #themeBtn:hover,html[data-theme="dark"] .vb:hover{background:#334155!important;color:#fff!important;border-color:#64748b!important}
html[data-theme="dark"] .vb.active{background:#475569!important;color:#fff!important;box-shadow:inset 0 0 0 1px rgba(255,255,255,.08)!important}
html[data-theme="dark"] .sort-menu{background:#1f2937!important;border-color:#475569!important;box-shadow:0 18px 45px rgba(0,0,0,.5)!important}
html[data-theme="dark"] .sort-mi{color:#e5edf8!important}html[data-theme="dark"] .sort-dir{color:#cbd5e1!important}
html[data-theme="dark"] .sort-mi.active{background:#0f3769!important;color:#fff!important}html[data-theme="dark"] .sort-mi:hover{background:#334155!important}
html[data-theme="dark"] .admin-table th,html[data-theme="dark"] th{background:#1f2937!important;color:#cbd5e1!important;border-color:#374151!important}
html[data-theme="dark"] tr:hover td{background:#273244!important}
html[data-theme="dark"] .btn.bs,html[data-theme="dark"] .icon-btn{background:#1f2937!important;color:#e5edf8!important;border-color:#475569!important}
html[data-theme="dark"] .btn.bs:hover,html[data-theme="dark"] .icon-btn:hover{background:#334155!important;color:#fff!important}
.system-form-grid.system-columns{display:grid;grid-template-columns:repeat(2,minmax(260px,1fr));gap:14px;align-items:start}
.system-column{display:flex;flex-direction:column;gap:14px;min-width:0}
.system-form-grid.system-columns .system-section{height:auto!important;align-self:start}
@media(max-width:900px){.system-form-grid.system-columns{grid-template-columns:1fr}}
.avatar-pending-note{font-size:12px;color:var(--muted);margin-top:6px}.profile-actions{display:flex;gap:8px;flex-wrap:wrap}.pref-row{display:grid;grid-template-columns:1fr 1fr;gap:12px}.pref-row .mf{margin-bottom:0}@media(max-width:640px){.pref-row{grid-template-columns:1fr}}


/* Phase 3.2.8 — System layout mockup + OneDrive storage block */
.od-storage{padding:0 8px 14px;margin:0 0 10px;border-bottom:1px solid var(--border)}
.od-storage-title{font-size:13px;font-weight:700;color:var(--text);margin:0 0 8px}
.od-storage-bar{height:3px;background:var(--line);border-radius:999px;overflow:hidden;margin-bottom:7px}
.od-storage-fill{height:100%;background:#0f6cbd;border-radius:999px;min-width:2px}
.od-storage-text{font-size:11.5px;color:var(--muted);line-height:1.25}
html[data-theme="dark"] .od-storage{border-color:#273244}html[data-theme="dark"] .od-storage-bar{background:#334155}html[data-theme="dark"] .od-storage-fill{background:#60a5fa}html[data-theme="dark"] .od-storage-title{color:#f8fafc}html[data-theme="dark"] .od-storage-text{color:#cbd5e1}
.od-storage-used-link{color:#0f6cbd;text-decoration:underline;cursor:pointer}.od-storage-used-link:hover{color:#115ea3}.largest-help{display:flex;align-items:center;gap:10px;margin:2px 0 22px;color:var(--muted);font-size:14px}.largest-help strong{font-size:19px;color:var(--text);font-family:'Sora';font-weight:800}.largest-help .sep{height:20px;width:1px;background:var(--border)}.largest-help a{color:#0f6cbd;text-decoration:underline;cursor:pointer}.largest-list .flh,.largest-list .fr{grid-template-columns:58px minmax(260px,1.65fr) minmax(150px,.9fr) minmax(130px,.75fr) minmax(115px,.6fr) minmax(260px,1.25fr)!important}.largest-list .fr .rloc,.largest-list .flh .rloc{display:flex;align-items:center;color:var(--muted);font-size:13px;overflow:hidden;white-space:nowrap;text-overflow:ellipsis}.largest-list .loc-link{color:#475569;cursor:pointer;overflow:hidden;text-overflow:ellipsis}.largest-list .loc-link:hover{color:#0f6cbd;text-decoration:underline}.largest-list .fileico{font-size:23px;width:28px;display:inline-flex;justify-content:center}html[data-theme="dark"] .od-storage-used-link,html[data-theme="dark"] .largest-help a{color:#60a5fa}html[data-theme="dark"] .largest-list .loc-link{color:#cbd5e1}html[data-theme="dark"] .largest-list .loc-link:hover{color:#93c5fd}
#admin-panel-sistema .admin-system-head{display:flex;align-items:flex-end;justify-content:space-between;margin:0 0 14px}
#admin-panel-sistema .admin-system-head h3{font-family:'Sora';font-size:20px;margin:0 0 5px;color:var(--text)}
#admin-panel-sistema .admin-system-head p{margin:0;color:var(--muted);font-size:13px}
#admin-panel-sistema .system-form-grid.system-mockup{display:grid!important;grid-template-columns:minmax(420px,1fr) minmax(520px,1fr)!important;gap:28px!important;align-items:start!important;max-width:1500px!important;width:100%!important;margin:0!important}
#admin-panel-sistema .system-column{display:flex!important;flex-direction:column!important;gap:18px!important;min-width:0!important;width:100%!important}
#admin-panel-sistema .system-section{width:100%!important;box-sizing:border-box!important;background:var(--card)!important;border:1px solid var(--border)!important;border-radius:14px!important;padding:18px!important;box-shadow:0 1px 2px rgba(0,0,0,.03)!important}
#admin-panel-sistema .system-section h4{font-family:'Sora';font-size:17px!important;margin:0 0 16px!important;color:var(--text)!important}
#admin-panel-sistema .system-section .mf{margin-bottom:13px!important}
#admin-panel-sistema .system-section .mf label{display:block;font-size:11px;text-transform:uppercase;letter-spacing:.7px;font-weight:700;color:var(--muted);margin:0 0 6px}
#admin-panel-sistema .system-section .mf input,#admin-panel-sistema .system-section .mf select{width:100%!important;height:38px!important;box-sizing:border-box!important;background:var(--soft)!important;color:var(--text)!important;border:1px solid var(--border)!important;border-radius:8px!important;padding:8px 10px!important;font-size:13px!important;outline:none!important}
#admin-panel-sistema .system-section .mf input:focus,#admin-panel-sistema .system-section .mf select:focus{border-color:#0f6cbd!important;box-shadow:0 0 0 2px rgba(15,108,189,.15)!important;background:var(--card)!important}
#admin-panel-sistema .system-two{display:grid;grid-template-columns:1fr 1fr;gap:14px}
#admin-panel-sistema .system-card-title{display:flex;align-items:center;justify-content:space-between;gap:12px;margin-bottom:14px}
#admin-panel-sistema .system-card-title h4{margin:0!important}
#admin-panel-sistema .inline-check{display:flex;align-items:center;gap:8px;font-size:13px;color:var(--text);white-space:nowrap}
#admin-panel-sistema .switchrow{display:flex!important;align-items:center!important;justify-content:space-between!important;gap:16px!important;margin:12px 0!important;color:var(--text)!important}
#admin-panel-sistema .switchrow span{display:flex;flex-direction:column;gap:3px;font-size:13px;line-height:1.25}
#admin-panel-sistema .switchrow small{font-size:12px;color:var(--muted);font-weight:400}
#admin-panel-sistema .switchrow input,#admin-panel-sistema .inline-check input{width:16px!important;height:16px!important;flex:0 0 auto!important;accent-color:#0f6cbd}
#admin-panel-sistema .system-help{font-size:12px!important;color:var(--muted)!important;line-height:1.35!important;margin:-4px 0 10px!important}
#admin-panel-sistema .system-actions{display:flex!important;gap:10px!important;align-items:center!important;flex-wrap:wrap!important;margin-top:10px!important}
#admin-panel-sistema .system-savebar{max-width:1500px;margin:20px 0 0;display:flex;justify-content:flex-start}
html[data-theme="dark"] #admin-panel-sistema .system-section{background:#111827!important;border-color:#334155!important;box-shadow:none!important}
html[data-theme="dark"] #admin-panel-sistema .system-section .mf input,html[data-theme="dark"] #admin-panel-sistema .system-section .mf select{background:#0f172a!important;border-color:#475569!important;color:#f8fafc!important}
html[data-theme="dark"] #admin-panel-sistema .system-section .mf input:focus,html[data-theme="dark"] #admin-panel-sistema .system-section .mf select:focus{background:#111827!important;border-color:#60a5fa!important;box-shadow:0 0 0 2px rgba(96,165,250,.22)!important}
@media(max-width:1100px){#admin-panel-sistema .system-form-grid.system-mockup{grid-template-columns:1fr!important;max-width:900px!important}#admin-panel-sistema .system-two{grid-template-columns:1fr}}

</style></head>
<body>
<!-- Overlay para cerrar sidebar en móvil -->
<div id="sideOverlay" onclick="closeSidebar()"></div>
<!-- Ghost de drag interno -->
<div id="dragGhost"></div>
<aside class="sidebar" id="sidebar">
<div class="od-create-wrap">
  <button class="od-create" onclick="toggleCreateMenu(event)"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4"><path d="M12 5v14M5 12h14"/></svg> Crear o subir</button>
  <div class="od-menu" id="createMenu">
    <div class="od-mi" onclick="closeCreateMenu();showNewFolder()"><span class="ico">📁</span><span>Carpeta</span></div>
    <div class="od-sep"></div>
    <div class="od-mi" onclick="closeCreateMenu();showUpload()"><span class="ico">📄</span><span>Subir archivos</span></div>
    <div class="od-mi" onclick="closeCreateMenu();showFolderUpload()"><span class="ico">🗂️</span><span>Subir carpeta</span></div>
  </div>
  <input type="file" id="fileUploadInput" multiple style="display:none" onchange="handleFiles(this.files);this.value=''">
  <input type="file" id="folderUploadInput" multiple webkitdirectory directory style="display:none" onchange="handleFiles(this.files);this.value=''">
</div>
<div class="sh"><div class="brand"><div class="logo"><svg width="22" height="22" viewBox="0 0 24 24" fill="none"><path d="M12 3 L19 6 V11 C19 15.5 16 19 12 21 C8 19 5 15.5 5 11 V6 Z" stroke="#fff" stroke-width="2" stroke-linejoin="round"/><path d="M9 11.5 l2 2 l4-4.5" stroke="#fff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg></div><span class="name"><?=h($userName)?></span></div></div>
<nav class="nav">
<div class="ni" onclick="showPage('files');loadFiles(null);closeSidebar()" data-page="home"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M3 9l9-7 9 7v11a2 2 0 01-2 2H5a2 2 0 01-2-2z"/></svg> Home</div>
<div class="ni active" onclick="showPage('files');closeSidebar()" data-page="files"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M3 7h6l2 3h10v8a2 2 0 01-2 2H5a2 2 0 01-2-2V7z"/></svg> Mis archivos</div>
<div class="ni" onclick="showPage('starred');closeSidebar()" data-page="starred"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 2l3 7h7l-5.5 4 2 7L12 16l-6.5 4 2-7L2 9h7z"/></svg> Favoritos</div>
<div class="ni" onclick="showPage('shares');closeSidebar()" data-page="shares"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M10 13a5 5 0 007 0l3-3a5 5 0 00-7-7l-1 1"/><path d="M14 11a5 5 0 00-7 0l-3 3a5 5 0 007 7l1-1"/></svg> Compartidos</div>
<div class="ni" onclick="showPage('trash');closeSidebar()" data-page="trash"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M3 6h18M19 6l-1 14a2 2 0 01-2 2H8a2 2 0 01-2-2L5 6m3 0V4a2 2 0 012-2h4a2 2 0 012 2v2"/></svg> Papelera de reciclaje</div>
<?php if($isAdmin):?><div class="ns od-muted">Administración</div>
<div class="ni" onclick="showPage('admin');closeSidebar()" data-page="admin"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="3"/><path d="M19 12a7 7 0 00-.1-1l2-1.5-2-3.5-2.4 1a7 7 0 00-1.7-1L14.5 2h-5l-.3 2.5a7 7 0 00-1.7 1l-2.4-1-2 3.5 2 1.5a7 7 0 000 2l-2 1.5 2 3.5 2.4-1a7 7 0 001.7 1l.3 2.5h5l.3-2.5a7 7 0 001.7-1l2.4 1 2-3.5-2-1.5a7 7 0 00.1-1z"/></svg> Panel admin</div><?php endif;?>
<div class="ns od-muted">Cuenta</div>
<div class="ni" onclick="showPage('settings');closeSidebar()" data-page="settings"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="8" r="4"/><path d="M4 21v-1a6 6 0 016-6h4a6 6 0 016 6v1"/></svg> Ajustes</div>
</nav>
<div class="sf">
<?php $storagePctTxt = rtrim(rtrim(number_format($usedPct, 1, '.', ''), '0'), '.'); ?>
<div class="od-storage" id="sidebarStorageBox">
  <div class="od-storage-title"><?=($language==='en'?'Storage':'Almacenamiento')?></div>
  <div class="od-storage-bar" aria-label="<?=($language==='en'?'Storage usage':'Uso de almacenamiento')?>"><div class="od-storage-fill" style="width:<?=$usedPct?>%"></div></div>
  <div class="od-storage-text" data-used="<?=h(size_human($used))?>" data-quota="<?=h(size_human($quota))?>" data-pct="<?=h($storagePctTxt)?>"><span class="od-storage-used-link" onclick="openLargestFiles()" title="<?=($language==='en'?'View largest files':'Ver archivos más grandes')?>"><?=h(size_human($used))?></span> <span class="od-storage-rest"><?=($language==='en'?'used of':'usados de')?> <?=h(size_human($quota))?> (<?=h($storagePctTxt)?>%)</span></div>
</div>
<div class="ur"><div class="av"><?php if(!empty($user['avatar'])): ?><img src="/api/avatar/<?=intval($user['id'])?>?v=<?=time()?>" style="width:100%;height:100%;object-fit:cover;border-radius:50%" alt="avatar"><?php else: ?><?=strtoupper(substr($userName,0,1))?><?php endif; ?></div><span class="un"><?=h($userName)?></span><button class="lb" onclick="logout()" title="Salir">⤶</button></div>
</div>
</aside>
<main class="main">
<div class="topbar">
<button class="hbtn" id="hbtn" onclick="openSidebar()" title="Menú"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M3 12h18M3 6h18M3 18h18"/></svg></button>
<div class="sw"><svg class="si" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="11" cy="11" r="8"/><path d="M21 21l-4-4"/></svg><input type="search" id="searchInput" name="vault_search" placeholder="Buscar archivos..." autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false" oninput="debSearch(this.value)"><button class="clr" id="clrBtn" onclick="clearSearch()"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M18 6L6 18M6 6l12 12"/></svg></button></div>
<div class="tr">
<button class="bi" id="sortBtn" onclick="toggleSortMenu(event)" title="Ordenar"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M11 5h10M11 12h7M11 19h4M4 5v14M2 17l2 2 2-2"/></svg><span class="top-label">Ordenar</span></button><div class="sort-menu" id="sortMenu"></div>
<button class="bi" id="topUploadBtn" onclick="showUpload()" title="Subir" style="display:none"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 15v4a2 2 0 01-2 2H5a2 2 0 01-2-2v-4M17 8l-5-5-5 5M12 3v12"/></svg></button>
<button class="bi" id="topFolderBtn" onclick="showNewFolder()" title="Nueva carpeta" style="display:none"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M22 19a2 2 0 01-2 2H4a2 2 0 01-2-2V5a2 2 0 012-2h5l2 3h9a2 2 0 012 2zM12 11v6M9 14h6"/></svg></button>
<div class="vt" id="mainViewToggle"><button class="vb active" id="gvBtn" onclick="setView('grid')"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="3" width="7" height="7"/><rect x="14" y="3" width="7" height="7"/><rect x="14" y="14" width="7" height="7"/><rect x="3" y="14" width="7" height="7"/></svg></button><button class="vb" id="lvBtn" onclick="setView('list')"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01"/></svg></button></div>
<button class="bi" id="detailsBtn" onclick="toggleDetailsPanel()" title="Detalles"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M4 4h16v16H4z"/><path d="M15 4v16"/></svg><span class="top-label">Detalles</span></button>
<button class="bi" id="themeBtn" onclick="toggleTheme()" title="Tema"></button>
</div>
</div>
<div class="content">
<div class="page active" id="page-files"><div class="tbar"><h2 id="ftitle">Mis archivos</h2></div><div class="bc" id="bc"></div><div id="fc"></div></div>
<div class="page" id="page-starred"><div class="tbar"><h2>Destacados</h2></div><div id="sc"></div></div>
<div class="page" id="page-shares"><div class="tbar"><h2>Links compartidos</h2></div><div id="shc"></div></div>
<div class="page" id="page-trash">
<div class="tbar"><h2>Papelera</h2>
<button class="btn bd" onclick="emptyTrash()">Vaciar papelera</button>
</div>
<div id="tc"></div>
</div>
<div class="ctxbar" id="trashSelBar"><span class="cnt" id="trashSelCount">0 seleccionados</span><button onclick="trashSelAll(TS._last||[])"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="15" height="15"><path d="M9 11l3 3L22 4"/><path d="M21 12v7a2 2 0 01-2 2H5a2 2 0 01-2-2V5a2 2 0 012-2h11"/></svg> Todo</button><div class="div"></div><button onclick="bulkTrashRestore()" style="color:var(--success)"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="15" height="15"><path d="M3 12a9 9 0 109-9M3 3v9h9"/></svg> Restaurar</button><button class="danger" onclick="bulkTrashDelete()"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="15" height="15"><path d="M3 6h18M19 6l-1 14a2 2 0 01-2 2H8a2 2 0 01-2-2L5 6"/></svg> Eliminar</button><div class="div"></div><button onclick="TS.sel.clear();updateTrashBar()">✕ Cancelar</button></div>
<div class="page" id="page-search"><div class="tbar"><h2>Resultados</h2></div><div id="src"></div></div>
<div class="page" id="page-largest"><div id="largestC"></div></div>
<div class="page" id="page-settings"><div class="tbar"><h2>Ajustes</h2></div><div id="stc"></div></div>
<?php if($isAdmin):?><div class="page" id="page-admin"><div class="tbar"><h2>Panel de administración</h2></div><div id="ac"></div></div><?php endif;?>
</div>
</main>
<aside class="details-panel" id="detailsPanel" aria-hidden="true"><div class="dp-head"><h3>Detalles</h3><button type="button" onclick="closeDetailsPanel()">×</button></div><div class="dp-body" id="detailsPanelBody"><div class="dp-empty">Selecciona un elemento para ver sus detalles.</div></div></aside>
<div class="toasts" id="toasts"></div>
<div class="mo" id="mUpload"><div class="md"><h3>Subir archivos</h3><div class="uz" id="dz"><div class="ui">📂</div><p>Arrastra aquí o <strong>haz clic</strong></p><p style="font-size:11px;color:var(--muted2);margin-top:4px">Máximo 10GB por archivo</p><input type="file" id="fi" multiple onchange="handleFiles(this.files)"></div><div id="ul"></div><div class="ma"><button class="btn bs" onclick="closeModal('mUpload')">Cerrar</button></div></div></div>
<div class="mo" id="mFolder"><div class="md"><h3>Nueva carpeta</h3><div class="mf"><label>Nombre</label><input type="text" id="fn" placeholder="Mi carpeta" onkeydown="if(event.key==='Enter')mkFolder()"></div><div class="ma"><button class="btn bs" onclick="closeModal('mFolder')">Cancelar</button><button class="btn bp" onclick="mkFolder()">Crear</button></div></div></div>
<div class="mo" id="mShare"><div class="md"><h3 id="shareTitle">Compartir archivo</h3><p style="font-size:13px;color:var(--muted);line-height:1.5;margin-bottom:14px">Cualquiera con el enlace puede descargar. Usa contraseña, caducidad o límite de descargas si quieres protegerlo.</p><div class="mf"><label>Contraseña (opcional)</label><input type="password" id="spw" placeholder="Sin contraseña" autocomplete="new-password"></div><div class="mf"><label>Expira el (opcional)</label><input type="datetime-local" id="sex"></div><div class="mf"><label>Máx. descargas (opcional)</label><input type="number" id="smd" placeholder="Sin límite" min="1"></div><div id="sres" style="display:none"><label style="font-size:10px;color:var(--muted);text-transform:uppercase;letter-spacing:.7px">Link generado</label><div style="display:flex;gap:8px;align-items:stretch;margin-top:6px"><div class="su" id="surl" style="flex:1;margin:0"></div><button class="btn bp" onclick="copyShare()" style="white-space:nowrap">Copiar</button></div><div id="emailRow" style="display:none;margin-top:14px"><label style="font-size:10px;color:var(--muted);text-transform:uppercase;letter-spacing:.7px">Enviar por email</label><div style="display:flex;gap:8px;align-items:stretch;margin-top:6px"><input type="email" id="semail" placeholder="destinatario@correo.com" style="flex:1;background:var(--surface2);border:1px solid var(--border);border-radius:10px;padding:10px 12px;color:var(--text);font-size:13px;outline:none"><button class="btn bs" id="sendEmailBtn" onclick="sendShareEmail()" style="white-space:nowrap">Enviar</button></div></div></div><div class="ma"><button class="btn bs" onclick="closeModal('mShare')">Cerrar</button><button class="btn bp" id="shBtn" onclick="mkShare()">Crear link</button></div></div></div>
<div class="mo" id="mRename"><div class="md"><h3>Renombrar</h3><div class="mf"><label>Nuevo nombre</label><input type="text" id="ri" onkeydown="if(event.key==='Enter')doRename()"></div><div class="ma"><button class="btn bs" onclick="closeModal('mRename')">Cancelar</button><button class="btn bp" onclick="doRename()">Renombrar</button></div></div></div>
<div class="mo" id="mMove"><div class="md"><h3>Mover a...</h3><div class="foldertree" id="folderTree"></div><div class="ma"><button class="btn bs" onclick="closeModal('mMove')">Cancelar</button><button class="btn bp" onclick="doMove()">Mover aquí</button></div></div></div>
<div class="mo" id="mConfirm"><div class="md"><h3 id="cfTitle">Confirmar</h3><p id="cfMsg" style="font-size:14px;color:var(--muted);line-height:1.6;margin-bottom:4px"></p><div class="ma"><button class="btn bs" onclick="closeModal('mConfirm')">Cancelar</button><button class="btn" id="cfBtn" onclick="cfAccept()">Aceptar</button></div></div></div>
<div class="mo" id="mConflict"><div class="md"><h3>Ya existe</h3><p id="cflMsg" style="font-size:14px;color:var(--muted);line-height:1.6;margin-bottom:8px"></p><div class="ma" style="flex-wrap:wrap"><button class="btn bs" onclick="conflictResolve('cancel')">Cancelar</button><button class="btn bs" onclick="conflictResolve('rename')">Mantener ambos</button><button class="btn bp" onclick="conflictResolve('replace')">Reemplazar</button></div></div></div>
<div class="mo" id="mNewUser"><div class="md"><h3>Nuevo usuario</h3><div class="mf"><label>Usuario</label><input type="text" id="nu-u"></div><div class="mf"><label>Email</label><input type="email" id="nu-e"></div><div class="mf"><label>Nombre</label><input type="text" id="nu-n"></div><div class="mf"><label>Contraseña</label><input type="password" id="nu-p"></div><div class="mf"><label>Rol</label><select id="nu-r"><option value="user">Usuario</option><option value="admin">Admin</option></select></div><div class="mf"><label>Cuota (GB)</label><input type="number" id="nu-q" value="10" min="1"></div><div class="ma"><button class="btn bs" onclick="closeModal('mNewUser')">Cancelar</button><button class="btn bp" onclick="createUser()">Crear</button></div></div></div>
<div class="ctx" id="ctx" style="display:none"></div>
<div class="viewer" id="viewer"><div class="viewer-top"><span class="vtitle" id="vTitle"></span><button class="vbtn" onclick="viewerDownload()" title="Descargar">⬇</button><button class="vbtn" onclick="closeViewer()" title="Cerrar">✕</button></div><div class="viewer-body" id="vBody"></div></div>
<div class="ctxbar" id="ctxbar"><button onclick="bulkShare()"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M4 12v7a1 1 0 001 1h14a1 1 0 001-1v-7"/><path d="M16 6l-4-4-4 4"/><path d="M12 2v13"/></svg> Compartir</button><button onclick="bulkCopyLink()"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M10 13a5 5 0 007 0l3-3a5 5 0 00-7-7l-1 1"/><path d="M14 11a5 5 0 00-7 0l-3 3a5 5 0 007 7l1-1"/></svg> Copiar link</button><button onclick="bulkDownload()"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 3v12"/><path d="M7 10l5 5 5-5"/><path d="M5 21h14"/></svg> Descargar</button><button onclick="bulkStar()">☆ Destacar</button><button onclick="bulkMove()">➜ Mover</button><button class="danger" onclick="bulkTrash()"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M3 6h18"/><path d="M19 6l-1 14a2 2 0 01-2 2H8a2 2 0 01-2-2L5 6"/><path d="M10 11v6M14 11v6"/></svg> Papelera</button><span class="ctx-spacer"></span><button class="ctx-close" onclick="clearSelection()">×</button><span class="cnt" id="selCount">0 seleccionado</span></div>
<!-- Panel de progreso de subida -->
<div id="uploadPanel"><div class="uph"><span class="upstatus" id="uploadStatusIcon">⟳</span><span id="uploadTitle">Uploading items</span><button class="upexpand" title="<?=($language==='en'?'View details':'Ver detalle')?>" onclick="document.getElementById('uploadPanel').classList.toggle('expanded')">↗</button><button class="upclose" onclick="document.getElementById('uploadPanel').classList.remove('show')">✕</button></div><div class="upprogress"><div id="uploadMainFill"></div></div><div class="uplist" id="uplist"></div></div>
VIEWEOF
echo " [app.php cabecera+HTML escrito]"
pct exec "$CT_ID" -- bash -c "cat >> /var/www/vault/src/views/app.php" << 'VIEWEOF'
<script>
/* ══ ESTADO GLOBAL ══ */
let CURRENT_LANG=document.documentElement.getAttribute('lang')||'es';
const S={page:'files',fid:null,view:'list',sortKey:'name',sortDir:'asc',shareTarget:null,renameTarget:null,st:null,currentList:[],viewerIdx:-1,moveIds:[],cfAccept:null,cflRename:null,cflReplace:null,selected:new Set(),moveTarget:null,viewerCurrent:null};

/* ══ API ══ */
async function api(m,p,b){const o={method:m,headers:{}};if(b&&!(b instanceof FormData)){o.headers['Content-Type']='application/json';o.body=JSON.stringify(b);}else if(b)o.body=b;try{const r=await fetch('/api/'+p,o);const txt=await r.text();let d;try{d=JSON.parse(txt);}catch(e){return{ok:false,message:'Respuesta no válida'+(txt?': '+txt.slice(0,120):'')};}return d;}catch(e){return{ok:false,message:'Error de conexión'};}}

/* ══ TOASTS ══ */
function toast(msg,type='info',dur=3500){const ic={success:'✓',error:'✕',info:'ℹ'};const el=document.createElement('div');el.className=`toast ${type}`;el.innerHTML=`<span>${ic[type]||'ℹ'}</span><span>${msg}</span>`;document.getElementById('toasts').appendChild(el);setTimeout(()=>{el.style.opacity='0';el.style.transform='translateY(20px)';el.style.transition='all .3s';setTimeout(()=>el.remove(),300);},dur);}
function closeShareToasts(){document.querySelectorAll('.share-toast').forEach(t=>t.remove());}
function showLinkCopiedToast(url,item){closeShareToasts();const el=document.createElement('div');el.className='share-toast';el.innerHTML=`<span class="st-ico">✓</span><div><div class="st-title">${T('Link copiado')}</div></div><div class="st-actions"><button class="st-settings" type="button">⚙ ${T('Settings')}</button><button class="st-close" type="button">×</button></div><div class="st-sub">${T('Cualquiera con el enlace puede descargar')}</div>`;document.getElementById('toasts').appendChild(el);el.querySelector('.st-close').onclick=()=>el.remove();el.querySelector('.st-settings').onclick=()=>{el.remove();openShareSettingsFromItem(item,url);};setTimeout(()=>{if(el.isConnected){el.style.opacity='0';el.style.transform='translateY(12px)';el.style.transition='all .25s';setTimeout(()=>el.remove(),260);}},9000);}

/* ══ SIDEBAR MÓVIL ══ */
function openSidebar(){document.getElementById('sidebar').classList.add('open');document.getElementById('sideOverlay').classList.add('show');}
function closeSidebar(){document.getElementById('sidebar').classList.remove('open');document.getElementById('sideOverlay').classList.remove('show');}
function toggleCreateMenu(e){if(e)e.stopPropagation();document.getElementById('createMenu')?.classList.toggle('show');}
function closeCreateMenu(){document.getElementById('createMenu')?.classList.remove('show');}
function showFolderUpload(){document.getElementById('folderUploadInput')?.click();}
document.addEventListener('click',e=>{if(!e.target.closest('.od-create-wrap'))closeCreateMenu();});

/* ══ NAVEGACIÓN ══ */
function syncTopbar(){
  const topUpload=document.getElementById('topUploadBtn');
  const topFolder=document.getElementById('topFolderBtn');
  const mainToggle=document.getElementById('mainViewToggle');
  const filePages=['files','starred','search','trash'];
  const canCreate=false;
  if(topUpload)topUpload.style.display='none';
  if(topFolder)topFolder.style.display='none';
  if(mainToggle)mainToggle.style.display=filePages.includes(S.page)?'flex':'none';
  document.getElementById('gvBtn')?.classList.toggle('active',(S.page==='trash'?TS.view:S.view)==='grid');
  document.getElementById('lvBtn')?.classList.toggle('active',(S.page==='trash'?TS.view:S.view)==='list');
}
function hideSelectionBars(){
  document.getElementById('ctxbar')?.classList.remove('show');
  document.getElementById('trashSelBar')?.classList.remove('show');
  document.body.classList.remove('selmode');
  document.body.classList.remove('trashselmode');
}
function showPage(n){
  document.querySelectorAll('.page').forEach(p=>p.classList.remove('active'));
  document.querySelectorAll('.ni').forEach(x=>x.classList.remove('active'));
  document.getElementById('page-'+n)?.classList.add('active');
  document.querySelector(`[data-page="${n}"]`)?.classList.add('active');
  S.page=n;
  clearSelection();
  TS.sel?.clear();
  hideSelectionBars();
  syncTopbar();
  if(n==='files')loadFiles();
  if(n==='starred')loadStarred();
  if(n==='shares')loadShares();
  if(n==='trash')loadTrash();
  if(n==='largest')loadLargest();
  if(n==='admin')loadAdmin();
  if(n==='settings')loadSettings();
}

/* ══ ARCHIVOS ══ */
async function loadFiles(fid){clearSelection();if(fid!==undefined)S.fid=fid??null;const url='files'+(S.fid?`?folder=${S.fid}`:'');const d=await api('GET',url);if(!d.ok)return toast(d.error||'Error','error');renderBC(d.breadcrumb||[]);S.currentList=d.files||[];renderFiles(d.files||[],'fc');document.getElementById('ftitle').textContent=S.fid&&d.breadcrumb?.length?d.breadcrumb[d.breadcrumb.length-1].name:T('Mis archivos');applyLanguage(CURRENT_LANG);}
function toggleSortMenu(e){if(e)e.stopPropagation();const m=document.getElementById('sortMenu');if(!m)return;renderSortMenu();m.classList.toggle('open');}
function renderSortMenu(){const m=document.getElementById('sortMenu');if(!m)return;const opts=[['name','Nombre'],['modified','Modificado'],['owner','Modificado por'],['size','Tamaño'],['shared','Compartido'],['activity','Actividad']];m.innerHTML=opts.map(o=>`<div class="sort-mi ${S.sortKey===o[0]?'active':''}" onclick="setSort('${o[0]}')"><span>${T(o[1])}</span><span class="sort-dir">${S.sortKey===o[0]?(S.sortDir==='asc'?T('Asc'):T('Desc')):''}</span></div>`).join('');}
function setSort(key){if(S.sortKey===key)S.sortDir=S.sortDir==='asc'?'desc':'asc';else{S.sortKey=key;S.sortDir='asc';}document.getElementById('sortMenu')?.classList.remove('open');reloadCurrent();}
document.addEventListener('click',e=>{if(!e.target.closest('#sortBtn')&&!e.target.closest('#sortMenu'))document.getElementById('sortMenu')?.classList.remove('open');});
function reloadCurrent(){if(S.page==='files')loadFiles();else if(S.page==='largest')loadLargest();else if(S.page==='starred')loadStarred();else if(S.page==='shares')loadShares();else if(S.page==='trash')loadTrash();else if(S.page==='admin')loadAdmin();}
function renderBC(c){const el=document.getElementById('bc');let h=`<span onclick="loadFiles(null)">${T('Inicio')}</span>`;c.forEach(cr=>{h+=`<span class="sep">›</span><span onclick="loadFiles(${cr.id})">${H(cr.name)}</span>`;});el.innerHTML=h;}

function openLargestFiles(){S.sortKey='size';S.sortDir='desc';showPage('largest');}
async function loadLargest(){
  clearSelection();
  const el=document.getElementById('largestC');
  if(el)el.innerHTML=`<div class="empty"><div class="ei">⏳</div><h3>${T('Cargando archivos...')}</h3></div>`;
  const d=await api('GET','files/largest?limit=100');
  if(!d.ok)return toast(d.error||d.message||'Error','error');
  S.currentList=d.files||[];
  renderLargest(d.files||[]);
  applyLanguage(CURRENT_LANG);
}
function goToLocation(fid){showPage('files');setTimeout(()=>loadFiles(fid||null),0);}
function renderLargest(files){
  const el=document.getElementById('largestC');if(!el)return;
  files=applySort(files);
  const intro=`<div class="largest-help"><strong>${T('Archivos más grandes en Vault')}</strong><span class="sep"></span><span>${T('Para liberar espacio, descarga y elimina archivos que no necesites, y vacía la papelera.')}</span> <a onclick="showPage('trash')">${T('Papelera de reciclaje')}</a></div>`;
  if(!files.length){el.innerHTML=intro+`<div class="empty"><div class="ei">📄</div><h3>${T('No hay archivos')}</h3><p>${T('Sube archivos para ver aquí los de mayor tamaño.')}</p></div>`;return;}
  const head=`<div class="flh"><div class="hsel"><button class="selectAllCircle" onclick="event.stopPropagation();selectAllToggle()" title="${T('Seleccionar todo')}"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3"><path d="M5 12l5 5L20 6"/></svg></button></div><div class="sort" onclick="setSort('name')">${T('Nombre')}</div><div class="sort" onclick="setSort('owner')">${T('Modificado por')}</div><div class="sort" onclick="setSort('modified')">${T('Modificado')}</div><div class="sort" onclick="setSort('size')">${T('Tamaño')}</div><div class="sort rloc">${T('Ubicación')}</div></div>`;
  el.innerHTML=intro+`<div class="fl largest-list">${head}${files.map(f=>largestRow(f)).join('')}</div>`;
  applySelectionUI();
}
function largestRow(f){
  const chk='<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3"><path d="M5 12l5 5L20 6"/></svg>';
  const ico=mIco(f.mime_type||'');
  const owner=H(f.owner_name||f.owner_username||T('Usuario'));
  const loc=H(f.location||T('Mis archivos'));
  const fid=(f.location_folder_id===null||f.location_folder_id===undefined)?'null':parseInt(f.location_folder_id);
  return `<div class="fr" data-id="${f.id}" data-type="file" data-name="${H(f.name)}" onclick="cardClick(event,${f.id},'file','${esc(f.name)}','${f.mime_type||''}')" oncontextmenu="showCtx(event,${f.id},'file','${esc(f.name)}','${f.mime_type||''}')"><div class="rsel" onclick="event.stopPropagation();toggleSelect(${f.id})">${chk}</div><div class="rn"><span class="fileico">${ico}</span><span>${H(f.name)}${f.is_starred?' ⭐':''}</span></div><div class="rmod">${owner}</div><div class="rd">${fmtD(f.updated_at||f.created_at)}</div><div class="rs">${szH(f.size)}</div><div class="rloc"><span class="loc-link" title="${loc}" onclick="event.stopPropagation();goToLocation(${fid})">${loc}</span></div></div>`;
}
function folderSizeVal(f){return f.type==='folder'?parseInt(f.folder_size||0):parseInt(f.size||0);}function folderItemCount(f){return parseInt(f.item_count||0);}function fileActivity(f){return parseInt(f.share_count||0)>0?T('Enlace activo'):'';}function fileShared(f){return parseInt(f.share_count||0)>0?T('Compartido'):T('Privado');}
function applySort(list){const arr=[...(list||[])];const dir=S.sortDir==='desc'?-1:1;const key=S.sortKey||'name';arr.sort((a,b)=>{if(a.type!==b.type&&key==='name')return a.type==='folder'?-1:1;let av,bv;if(key==='modified'){av=new Date(a.updated_at||a.created_at||0).getTime();bv=new Date(b.updated_at||b.created_at||0).getTime();}else if(key==='owner'){av=(a.owner_name||a.owner_username||'').toLowerCase();bv=(b.owner_name||b.owner_username||'').toLowerCase();}else if(key==='size'){av=folderSizeVal(a);bv=folderSizeVal(b);}else if(key==='shared'){av=fileShared(a);bv=fileShared(b);}else if(key==='activity'){av=fileActivity(a);bv=fileActivity(b);}else{av=(a.name||'').toLowerCase();bv=(b.name||'').toLowerCase();}if(av<bv)return -1*dir;if(av>bv)return 1*dir;return (a.name||'').localeCompare(b.name||'');});return arr;}
function renderFiles(files,cid){const el=document.getElementById(cid);files=applySort(files);if(!files.length){el.innerHTML=`<div class="empty"><div class="ei">📂</div><h3>${T('Carpeta vacía')}</h3><p>${T('Sube archivos o crea una carpeta')}</p></div>`;return;}if(S.view==='grid'){el.innerHTML=`<div class="fg">${files.map(f=>fCard(f)).join('')}</div>`;}else{const head=`<div class="flh"><div class="hsel"><button class="selectAllCircle" onclick="event.stopPropagation();selectAllToggle()" title="${T('Seleccionar todo')}"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3"><path d="M5 12l5 5L20 6"/></svg></button></div><div class="sort" onclick="setSort('name')">${T('Nombre')}</div><div class="sort" onclick="setSort('modified')">${T('Modificado')}</div><div class="sort" onclick="setSort('owner')">${T('Modificado por')}</div><div class="sort" onclick="setSort('size')">${T('Tamaño')}</div><div class="sort" onclick="setSort('shared')">${T('Compartido')}</div><div class="sort" onclick="setSort('activity')">${T('Actividad')}</div></div>`;el.innerHTML=`<div class="fl">${head}${files.map(f=>fRow(f)).join('')}</div>`;}applySelectionUI();initInternalDrag();applyLanguage(CURRENT_LANG);}

/* ══ TARJETAS ══ */
function fCard(f){const ic=f.type==='folder'?'📁':mIco(f.mime_type);const th=f.type==='file'&&f.thumbnail?`/api/thumb/${f.id}`:null;const chk='<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3"><path d="M5 12l5 5L20 6"/></svg>';return`<div class="fc" data-id="${f.id}" data-type="${f.type}" data-name="${H(f.name)}" onclick="cardClick(event,${f.id},'${f.type}','${esc(f.name)}','${f.mime_type||''}')" oncontextmenu="showCtx(event,${f.id},'${f.type}','${esc(f.name)}','${f.mime_type||''}')"><div class="selcheck" onclick="event.stopPropagation();toggleSelect(${f.id})">${chk}</div><div class="ft">${th?`<img src="${th}" loading="lazy">`:`<span>${ic}</span>`}${f.is_starred?'<span style="position:absolute;top:6px;right:6px;font-size:11px">⭐</span>':''}</div><div class="fi-b"><div class="fn" title="${H(f.name)}">${H(f.name)}</div><div class="fm">${f.type==='folder'?szH(f.folder_size||0):szH(f.size)}</div></div><div class="fa"><button class="fab" onclick="event.stopPropagation();starFile(${f.id})" title="${T('Destacar')}">⭐</button><button class="fab" onclick="event.stopPropagation();showShare(${f.id},'${esc(f.name)}','${f.type}')" title="${T('Compartir')}">🔗</button><button class="fab" onclick="event.stopPropagation();moveOne(${f.id})" title="${T('Mover')}">↪</button><button class="fab" onclick="event.stopPropagation();trashIt(${f.id})" title="${T('Papelera')}">🗑</button></div></div>`;}
function fRow(f){const chk='<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3"><path d="M5 12l5 5L20 6"/></svg>';const ico=f.type==='folder'?'📁':mIco(f.mime_type);const owner=H(f.owner_name||f.owner_username||T('Usuario'));const shared=fileShared(f);const size=f.type==='folder'?szH(f.folder_size||0):szH(f.size);const activity=fileActivity(f);return`<div class="fr" data-id="${f.id}" data-type="${f.type}" data-name="${H(f.name)}" onclick="cardClick(event,${f.id},'${f.type}','${esc(f.name)}','${f.mime_type||''}')" oncontextmenu="showCtx(event,${f.id},'${f.type}','${esc(f.name)}','${f.mime_type||''}')"><div class="rsel" onclick="event.stopPropagation();toggleSelect(${f.id})">${chk}</div><div class="rn"><span class="fileico">${ico}</span><span>${H(f.name)}${f.is_starred?' ⭐':''}</span></div><div class="rd">${fmtD(f.updated_at||f.created_at)}</div><div class="rmod">${owner}</div><div class="rs">${size}</div><div class="rshare">${shared}</div><div class="ract">${activity}</div><div class="ra"><button class="fab" onclick="event.stopPropagation();showShare(${f.id},'${esc(f.name)}','${f.type}')">🔗</button><button class="fab" onclick="event.stopPropagation();moveOne(${f.id})">↪</button><button class="fab" onclick="event.stopPropagation();trashIt(${f.id})">🗑</button></div></div>`;}

/* ══ SELECCIÓN ══ */
function cardClick(e,id,type,name,mime){if(S.selected.size>0){toggleSelect(id);return;}openItem(id,type,name,mime);}
function toggleSelect(id){if(S.selected.has(id))S.selected.delete(id);else S.selected.add(id);applySelectionUI();}
function applySelectionUI(){const container=document.querySelector('.page.active');if(container)container.querySelectorAll('.fc:not(.tc-item),.fr:not(.tc-item)').forEach(el=>{const id=parseInt(el.dataset.id);const on=S.selected.has(id);el.classList.toggle('sel',on);const c=el.querySelector('.selcheck,.rsel');if(c)c.classList.toggle('on',on);});const active=S.selected.size>0&&S.page!=='trash';document.body.classList.toggle('selmode',active);const bar=document.getElementById('ctxbar');if(bar){if(active){bar.classList.add('show');document.getElementById('selCount').textContent=S.selected.size+' '+(S.selected.size===1?T('seleccionado'):T('seleccionados'));}else bar.classList.remove('show');}if(document.getElementById('detailsPanel')?.classList.contains('open')){const ids=[...S.selected];if(ids.length===1){const it=(S.currentList||[]).find(x=>parseInt(x.id)===parseInt(ids[0]));if(it)openDetailsPanel(it);else closeDetailsPanel();}else if(ids.length===0){closeDetailsPanel();}else{document.getElementById('detailsPanelBody').innerHTML=`<div class="dp-empty">${T('Selecciona un único elemento para ver sus detalles.')}</div>`;}}const allBtn=container?container.querySelector('.selectAllCircle'):null;if(allBtn){const ids=[...container.querySelectorAll('.fc:not(.tc-item),.fr:not(.tc-item)')].map(el=>parseInt(el.dataset.id)).filter(Boolean);allBtn.classList.toggle('on',ids.length>0&&ids.every(i=>S.selected.has(i)));}}
function clearSelection(){S.selected.clear();closeDetailsPanel();applySelectionUI();}
function selectAllToggle(){const container=document.querySelector('.page.active');if(!container)return;const ids=[...container.querySelectorAll('.fc,.fr')].map(el=>parseInt(el.dataset.id));const allSel=ids.length>0&&ids.every(i=>S.selected.has(i));if(allSel)S.selected.clear();else ids.forEach(i=>S.selected.add(i));applySelectionUI();}
function getSelectedItems(){const container=document.querySelector('.page.active');const out=[];if(container)container.querySelectorAll('.fc,.fr').forEach(el=>{const id=parseInt(el.dataset.id);if(S.selected.has(id))out.push({id,type:el.dataset.type,name:el.dataset.name});});return out;}

/* ══ ACCIONES BULK ══ */
async function bulkStar(){const ids=[...S.selected];const d=await api('POST','bulk/star',{ids});if(d.ok){toast(T('Destacados'),'success');clearSelection();reloadCurrent();}else toast(d.message||'Error','error');}
async function bulkTrash(){const ids=[...S.selected];vaultConfirm(T('Mover a papelera'),T('¿Mover {n} elemento(s) a la papelera?').replace('{n}',ids.length),T('Mover'),async()=>{const d=await api('POST','bulk/trash',{ids});if(d.ok){toast(T('Movidos a papelera'),'success');clearSelection();reloadCurrent();}else toast(d.message||'Error','error');});}
function bulkDownload(){const ids=[...S.selected];if(!ids.length)return;if(ids.length===1){const it=getSelectedItems()[0];const a=document.createElement('a');a.href='/api/download/'+ids[0];if(it&&it.type==='file')a.download=it.name;a.click();clearSelection();return;}const a=document.createElement('a');a.href='/api/bulk-download/?ids='+ids.join(',');a.click();clearSelection();}
function bulkMove(){S.moveIds=[...S.selected];openMoveModal();}
function bulkShare(){const items=getSelectedItems();if(items.length!==1){toast(T('Selecciona solo un elemento para compartir'),'info');return;}showShare(items[0].id,items[0].name,items[0].type);}
async function bulkCopyLink(){const items=getSelectedItems();if(items.length!==1){toast(T('Selecciona solo un elemento para copiar link'),'info');return;}const item=items[0];const d=await api('POST','shares',{file_id:item.id,password:null,expires_at:null,max_downloads:null});if(!d.ok)return toast(d.message||T('Error creando link'),'error');const url=d.url||window.location.origin+'/s/'+d.token;item.share_id=d.id;item.share_url=url;item.share_token=d.token;S.shareTarget={id:item.id,name:item.name,type:item.type,shareId:d.id,url,token:d.token};navigator.clipboard.writeText(url).then(()=>showLinkCopiedToast(url,item),()=>showLinkCopiedToast(url,item));}
function moveOne(id){S.moveIds=[id];openMoveModal();}

/* ══ ABRIR ELEMENTO ══ */
function openItem(id,type,name,mime){if(type==='folder'){loadFiles(id);}else{openViewer(id,name,mime||'');}}

/* ══ ACCIONES INDIVIDUALES ══ */
async function starFile(id){const d=await api('POST','files/'+id+'/star');if(d.ok){reloadCurrent();}else toast(d.message||'Error','error');}
function trashIt(id){vaultConfirm(T('Mover a papelera'),T('¿Mover este elemento a la papelera?'),T('Mover'),async()=>{const d=await api('DELETE','files/'+id);if(d.ok){toast(T('Movido a papelera'),'success');reloadCurrent();}else toast(d.message||'Error','error');});}
function showRename(id,name){S.renameTarget=id;const i=document.getElementById('ri');i.value=name;document.getElementById('mRename').classList.add('open');setTimeout(()=>{i.focus();i.select();},80);}
async function doRename(){const name=document.getElementById('ri').value.trim();if(!name)return;const d=await api('PATCH','files/'+S.renameTarget+'/rename',{name});if(d.ok){toast(T('Renombrado'),'success');closeModal('mRename');reloadCurrent();}else toast(d.message||'Error','error');}

/* ══ NUEVA CARPETA ══ */
function showNewFolder(){document.getElementById('fn').value='';document.getElementById('mFolder').classList.add('open');setTimeout(()=>document.getElementById('fn').focus(),80);}
async function mkFolder(){const name=document.getElementById('fn').value.trim()||T('Nueva carpeta');const d=await api('POST','folders',{name,parent_id:S.fid});if(d.ok){toast(T('Carpeta creada'),'success');closeModal('mFolder');loadFiles();}else toast(d.message||'Error','error');}

/* ══ SUBIDA DE ARCHIVOS ══ */
function showUpload(){document.getElementById('fileUploadInput')?.click();}
function currentFolderLabel(){const title=document.getElementById('ftitle')?.textContent?.trim();return title||T('Mis archivos');}
function pluralItems(n){return n===1?('1 '+T('item')):(n+' '+T('items'));}
function setUploadMainProgress(done,total){const fill=document.getElementById('uploadMainFill');if(fill)fill.style.width=(total?Math.min(100,Math.round(done/total*100)):0)+'%';}
function setUploadSummary(state,total,targetName){
  const panel=document.getElementById('uploadPanel');
  const title=document.getElementById('uploadTitle');
  const icon=document.getElementById('uploadStatusIcon');
  if(!panel||!title||!icon)return;
  panel.classList.remove('done','err','running');
  if(state==='done'){panel.classList.add('done');icon.textContent='✓';title.innerHTML=`${T('Uploaded')} ${pluralItems(total)} ${T('to')} <span class="updest">${H(targetName)}</span>`;setUploadMainProgress(total,total);}
  else if(state==='err'){panel.classList.add('err');icon.textContent='!';title.textContent=`${T('Error uploading')} ${pluralItems(total)}`;}
  else{panel.classList.add('running');icon.textContent='⟳';title.textContent=`${T('Uploading')} ${pluralItems(total)}`;setUploadMainProgress(0,total);}
}
function handleFiles(files){
  if(!files||!files.length)return;
  closeModal('mUpload');
  const panel=document.getElementById('uploadPanel');
  const list=document.getElementById('uplist');
  list.innerHTML='';
  panel.classList.add('show');
  const total=files.length;
  const targetFid=S.fid||null;
  const targetName=currentFolderLabel();
  let done=0;let failed=0;
  setUploadSummary('running',total,targetName);
  function onFileDone(ok=true){done++;if(!ok)failed++;setUploadMainProgress(done,total);if(done>=total){setUploadSummary(failed?'err':'done',total,targetName);setTimeout(()=>{if(!failed){}},2200);}}
  [...files].forEach(f=>{
    const id='up_'+Date.now()+'_'+Math.random().toString(36).slice(2);
    const item=document.createElement('div');item.className='upitem';item.id=id;
    const displayName=H(f.webkitRelativePath||f.name);
    item.innerHTML=`<div class="upname"><span class="upstate">${T('Uploading')}</span> <strong>${displayName}</strong> to <span class="updest">${H(targetName)}</span></div><div class="uprow"><div class="upbar"><div class="upfill" id="fill_${id}" style="width:0%"></div></div><div class="uppct" id="pct_${id}">0%</div></div>`;
    list.appendChild(item);
    uploadOne(f,id,onFileDone,targetFid,targetName,f.webkitRelativePath||'');
  });
}
async function uploadOne(file,itemId,onDone,targetFid,targetName,relativePath){
const CHUNK=5*1024*1024;
const fill=document.getElementById('fill_'+itemId);
const pct=document.getElementById('pct_'+itemId);
const item=document.getElementById(itemId);
function setP(p){if(fill)fill.style.width=p+'%';if(pct)pct.textContent=Math.round(p)+'%';}
function markDone(){if(item){item.classList.add('done');const st=item.querySelector('.upstate');if(st)st.textContent=T('Uploaded');setP(100);}if(S.page==='files'&&(S.fid||null)===(targetFid||null))loadFiles(targetFid||null);if(typeof onDone==='function')onDone(true);}
function markErr(msg){if(item)item.classList.add('err');toast(msg,'error');if(typeof onDone==='function')onDone(false);}
if(file.size<=CHUNK){
  const fd=new FormData();fd.append('file',file);if(targetFid)fd.append('folder_id',targetFid);if(relativePath)fd.append('relative_path',relativePath);
  await new Promise(res=>{const xhr=new XMLHttpRequest();xhr.upload.onprogress=e=>{if(e.lengthComputable)setP(e.loaded/e.total*100);};xhr.onload=()=>{if(xhr.status===200){markDone();}else{markErr(T('Error subiendo')+' '+file.name);}res();};xhr.onerror=()=>{markErr(T('Error subiendo')+' '+file.name);res();};xhr.open('POST','/api/upload');xhr.send(fd);});
  return;
}
const total=Math.ceil(file.size/CHUNK);
const uploadId=(crypto.randomUUID?crypto.randomUUID():Date.now().toString(36)+Math.random().toString(36).slice(2));
let ok=true;
for(let i=0;i<total&&ok;i++){
  const start=i*CHUNK;const chunk=file.slice(start,Math.min(start+CHUNK,file.size));
  const fd=new FormData();fd.append('upload_id',uploadId);fd.append('chunk_index',i);fd.append('total_chunks',total);fd.append('file_name',file.name);fd.append('file_size',file.size);if(targetFid)fd.append('folder_id',targetFid);fd.append('chunk',chunk);
  let tries=0;let sent=false;
  while(tries<3&&!sent){
    try{
      const r=await fetch('/api/upload-chunk',{method:'POST',body:fd,credentials:'same-origin'});
      const d=await r.json();
      if(d.ok)sent=true;else{tries++;await new Promise(r=>setTimeout(r,800));}
    }catch(e){tries++;await new Promise(r=>setTimeout(r,800));}
  }
  if(!sent){markErr(T('Error subiendo')+' '+file.name+' (chunk '+i+')');ok=false;break;}
  setP((i+1)/total*95);
}
if(!ok)return;
try{
  const r=await fetch('/api/upload-complete',{method:'POST',credentials:'same-origin',headers:{'Content-Type':'application/json'},body:JSON.stringify({upload_id:uploadId,file_name:file.name,file_size:file.size,total_chunks:total,folder_id:targetFid||null,relative_path:relativePath||''})});
  const d=await r.json();
  if(d.ok){markDone();return;}
  else{markErr(T('Error completando')+' '+file.name+': '+(d.message||''));}
}catch(e){markErr(T('Error completando')+' '+file.name);}
}

/* ══ COMPARTIR ══ */
function resetShareModal(){document.getElementById('spw').value='';document.getElementById('sex').value='';document.getElementById('smd').value='';document.getElementById('sres').style.display='none';document.getElementById('shBtn').style.display='';document.getElementById('shBtn').textContent=T('Crear link');document.getElementById('semail').value='';}
function showShare(id,name,type){S.shareTarget={id,name,type};resetShareModal();document.getElementById('shareTitle').textContent=type==='folder'?T('Compartir carpeta'):T('Compartir archivo');document.getElementById('mShare').classList.add('open');}
function openShareSettingsFromItem(item,url){S.shareTarget={id:item.id,name:item.name,type:item.type,shareId:item.share_id,url};resetShareModal();document.getElementById('shareTitle').textContent=T('Settings del enlace');document.getElementById('surl').textContent=url;document.getElementById('sres').style.display='block';document.getElementById('shBtn').style.display='';document.getElementById('shBtn').textContent=T('Guardar settings');const emailRow=document.getElementById('emailRow');if(emailRow)emailRow.style.display='block';document.getElementById('mShare').classList.add('open');}
async function mkShare(){const payload={file_id:S.shareTarget.id,password:document.getElementById('spw').value||null,expires_at:document.getElementById('sex').value||null,max_downloads:parseInt(document.getElementById('smd').value)||null};const route=S.shareTarget.shareId?'shares/'+S.shareTarget.shareId:'shares';const method=S.shareTarget.shareId?'PATCH':'POST';const d=await api(method,route,payload);if(!d.ok)return toast(d.message||'Error','error');const url=d.url||window.location.origin+'/s/'+d.token;S.shareTarget.shareId=d.id;S.shareTarget.url=url;S.shareTarget.token=d.token;document.getElementById('surl').textContent=url;document.getElementById('sres').style.display='block';document.getElementById('shBtn').textContent=T('Guardar settings');const emailRow=document.getElementById('emailRow');if(emailRow)emailRow.style.display=d.smtp?'block':'none';document.getElementById('semail').value='';toast(method==='PATCH'?T('Settings guardados'):T('Link creado'),'success');const mshare=document.getElementById('mShare');if(mshare){const md=mshare.querySelector('.md');if(md)setTimeout(()=>md.scrollTop=md.scrollHeight,50);}}
function copyShare(){const url=document.getElementById('surl').textContent;navigator.clipboard.writeText(url).then(()=>toast(T('Link copiado'),'success'));}
async function sendShareEmail(){const btn=document.getElementById('sendEmailBtn');btn.disabled=true;const email=document.getElementById('semail').value.trim();const url=document.getElementById('surl').textContent;if(!email){btn.disabled=false;return toast(T('Introduce un email'),'error');}const d=await api('POST','shares/email',{email,url,filename:S.shareTarget?.name||'',is_folder:S.shareTarget?.type==='folder'});btn.disabled=false;if(d.ok)toast(T('Email enviado'),'success');else toast(d.message||T('Error al enviar'),'error');}

/* ══ VISOR ══ */
function openViewer(id,name,mime){S.viewerIdx=S.currentList.findIndex(f=>f.id===id);renderViewer(id,name,mime);document.getElementById('viewer').classList.add('open');}
function renderViewer(id,name,mime){document.getElementById('vTitle').textContent=name;S.viewerCurrent={id,name,mime};const body=document.getElementById('vBody');const url='/api/view/'+id;let inner='';if(mime.startsWith('image/')){inner=`<img src="${url}" alt="${H(name)}">`;}else if(mime.startsWith('video/')){inner=`<video src="${url}" controls autoplay style="max-width:90%;max-height:90%"></video>`;}else if(mime.startsWith('audio/')){inner=`<div style="text-align:center"><div style="font-size:64px;margin-bottom:20px">🎵</div><audio src="${url}" controls autoplay></audio></div>`;}else if(mime==='application/pdf'){inner=`<iframe src="${url}"></iframe>`;}else if(mime.startsWith('text/')||mime.includes('json')||mime.includes('xml')){inner=`<iframe src="${url}" style="background:#fff"></iframe>`;}else{inner=`<div class="noprev"><div class="npi">${mIco(mime)}</div><h3 style="font-family:'Sora';margin-bottom:8px">${H(name)}</h3><p>${T('Este tipo de archivo no se puede previsualizar')}</p><button class="btn bp" style="margin-top:16px" onclick="viewerDownload()">⬇ ${T('Descargar')}</button></div>`;}
const viewable=S.currentList.filter(f=>f.type==='file'&&(f.mime_type||'').match(/^(image|video|audio)\//)||f.mime_type==='application/pdf');let nav='';if(viewable.length>1){nav=`<button class="viewer-nav prev" onclick="viewerNav(-1)">‹</button><button class="viewer-nav next" onclick="viewerNav(1)">›</button>`;}body.innerHTML=inner+nav;}
function viewerNav(dir){const viewable=S.currentList.filter(f=>f.type==='file');if(!viewable.length)return;let idx=viewable.findIndex(f=>f.id===S.viewerCurrent?.id);idx=(idx+dir+viewable.length)%viewable.length;const f=viewable[idx];renderViewer(f.id,f.name,f.mime_type||'');}
function viewerDownload(){if(S.viewerCurrent){const a=document.createElement('a');a.href='/api/download/'+S.viewerCurrent.id;a.download=S.viewerCurrent.name;a.click();}}
function closeViewer(){document.getElementById('viewer').classList.remove('open');document.getElementById('vBody').innerHTML='';}

/* ══ MENÚ CONTEXTUAL ══ */
function showCtx(e,id,type,name,mime){e.preventDefault();hideCtx();const m=document.getElementById('ctx');const items=[{ico:'✏️',label:T('Renombrar'),fn:`showRename(${id},'${esc(name)}')`},{ico:'⭐',label:T('Destacar'),fn:`starFile(${id})`},{ico:'🔗',label:T('Compartir'),fn:`showShare(${id},'${esc(name)}','${type}')`},{ico:'↪',label:T('Mover'),fn:`moveOne(${id})`},{ico:'⬇️',label:T('Descargar'),fn:`(function(){const a=document.createElement('a');a.href='/api/download/${id}';a.download='${esc(name)}';a.click();})()`},{sep:true},{ico:'🗑',label:T('Mover a papelera'),fn:`trashIt(${id})`,danger:true}];m.innerHTML=items.map(it=>it.sep?`<div class="cxs"></div>`:`<div class="cxi${it.danger?' danger':''}" onclick="hideCtx();${it.fn}">${it.ico} ${it.label}</div>`).join('');m.style.display='block';const vw=window.innerWidth,vh=window.innerHeight;let x=e.clientX,y=e.clientY;setTimeout(()=>{if(x+m.offsetWidth>vw-10)x=vw-m.offsetWidth-10;if(y+m.offsetHeight>vh-10)y=vh-m.offsetHeight-10;m.style.left=x+'px';m.style.top=y+'px';},0);}
function hideCtx(){const m=document.getElementById('ctx');m.style.display='none';}
document.addEventListener('click',e=>{if(!e.target.closest('#ctx'))hideCtx();});

/* ══ MODAL MOVER ══ */
async function openMoveModal(){const d=await api('GET','folders');const tree=document.getElementById('folderTree');S.moveTarget=null;let h=`<div class="ftrow" data-fid="" onclick="pickFolder(this,null)"><span class="ico">🏠</span> ${T('Inicio')} (${T('raíz')})</div>`;const folders=(d.folders||[]).filter(f=>!S.moveIds.includes(f.id));const byParent={};folders.forEach(f=>{(byParent[f.parent_id||'root']=byParent[f.parent_id||'root']||[]).push(f);});function build(parent,depth){const list=byParent[parent||'root']||[];list.forEach(f=>{h+=`<div class="ftrow" data-fid="${f.id}" onclick="pickFolder(this,${f.id})"><span style="width:${depth*16}px;display:inline-block"></span><span class="ico">📁</span> ${H(f.name)}</div>`;build(f.id,depth+1);});}build('root',0);tree.innerHTML=h;document.getElementById('mMove').classList.add('open');}
function pickFolder(el,fid){document.querySelectorAll('#folderTree .ftrow').forEach(r=>r.classList.remove('on'));el.classList.add('on');S.moveTarget=fid;}
async function doMove(conflict){const ids=S.moveIds||[];if(!ids.length)return;const d=await api('POST','bulk/move',{ids,parent_id:S.moveTarget,conflict:conflict||'error'});if(d.ok){toast(T('Movido'),'success');closeModal('mMove');clearSelection();reloadCurrent();}else if((d.message||'').includes('DUPLICATE')){conflictModal(()=>doMove('rename'),()=>doMove('replace'));}else toast(d.message||'Error','error');}

/* ══ MODALES GENÉRICOS ══ */
function vaultConfirm(title,msg,btnText,onAccept,danger){document.getElementById('cfTitle').textContent=title;document.getElementById('cfMsg').textContent=msg;const b=document.getElementById('cfBtn');b.textContent=btnText||T('Aceptar');b.className='btn '+(danger?'bd':'bp');S.cfAccept=onAccept;document.getElementById('mConfirm').classList.add('open');}
function cfAccept(){closeModal('mConfirm');if(S.cfAccept)S.cfAccept();}
function conflictModal(onRename,onReplace){S.cflRename=onRename;S.cflReplace=onReplace;document.getElementById('cflMsg').textContent=T('Ya existe un elemento con ese nombre en el destino. ¿Qué quieres hacer?');document.getElementById('mConflict').classList.add('open');}
function conflictResolve(action){closeModal('mConflict');if(action==='rename'&&S.cflRename)S.cflRename();else if(action==='replace'&&S.cflReplace)S.cflReplace();}
function closeModal(id){document.getElementById(id).classList.remove('open');}
document.querySelectorAll('.mo').forEach(m=>{m.addEventListener('click',e=>{if(e.target===m)m.classList.remove('open');});});

/* ══ OTRAS PÁGINAS ══ */
async function loadStarred(){const d=await api('GET','files/starred');const el=document.getElementById('sc');if(!d.ok||!d.files.length){el.innerHTML=`<div class="empty"><div class="ei">⭐</div><h3>${T('Sin destacados')}</h3></div>`;applyLanguage(CURRENT_LANG);return;}S.currentList=d.files;const files=applySort(d.files);el.innerHTML=`<div class="fg">${files.map(f=>fCard(f)).join('')}</div>`;initInternalDrag();applyLanguage(CURRENT_LANG);}
async function loadShares(){const d=await api('GET','shares');const el=document.getElementById('shc');if(!d.ok||!d.shares.length){el.innerHTML=`<div class="empty"><div class="ei">🔗</div><h3>${T('Sin links compartidos')}</h3></div>`;applyLanguage(CURRENT_LANG);return;}el.innerHTML=`<table><tr><th>${T('Archivo')}</th><th>${T('Link')}</th><th>${T('Descargas')}</th><th>${T('Expira')}</th><th></th></tr>${d.shares.map(s=>`<tr><td>${mIco(s.mime_type)} ${H(s.name)}</td><td><span class="su" style="display:inline-block" onclick="copyTok('${s.token}')">/s/${s.token.slice(0,12)}…</span></td><td>${s.downloads}${s.max_downloads?'/'+s.max_downloads:''}</td><td style="font-size:11px;color:var(--muted)">${s.expires_at?fmtD(s.expires_at):'—'}</td><td><button class="btn bd" style="padding:5px 11px;font-size:11px" onclick="delShare(${s.id})">${T('Eliminar')}</button></td></tr>`).join('')}</table>`;applyLanguage(CURRENT_LANG);}
function copyTok(t){navigator.clipboard.writeText(window.location.origin+'/s/'+t).then(()=>toast(T('Link copiado'),'success'));}
async function delShare(id){const d=await api('DELETE','shares/'+id);if(d.ok){toast('Link eliminado','success');loadShares();}else toast('Error','error');}
// ── Papelera: estado de selección propio ──
const TS={sel:new Set(),view:'grid'};
function setTrashView(v){
  TS.view=v;
  syncTopbar();
  loadTrash();
}
function trashToggleSel(id){if(TS.sel.has(id))TS.sel.delete(id);else TS.sel.add(id);updateTrashBar();}
function trashSelAll(items){const allOn=items.every(f=>TS.sel.has(f.id));TS.sel.clear();if(!allOn)items.forEach(f=>TS.sel.add(f.id));updateTrashBar();}
function updateTrashHeaderSelect(){const c=document.getElementById('tc');const b=c?c.querySelector('.selectAllCircle'):null;if(!b)return;const ids=[...c.querySelectorAll('.tc-item')].map(el=>parseInt(el.dataset.id)).filter(Boolean);b.classList.toggle('on',ids.length>0&&ids.every(i=>TS.sel.has(i)));}
function updateTrashBar(){
  const bar=document.getElementById('trashSelBar');
  const cnt=document.getElementById('trashSelCount');
  document.body.classList.toggle('trashselmode',TS.sel.size>0);
  if(bar)bar.classList.toggle('show',TS.sel.size>0);
  if(cnt)cnt.textContent=TS.sel.size+(TS.sel.size===1?' seleccionado':' seleccionados');
  // Actualizar visuales de selección
  document.querySelectorAll('.tc-item').forEach(el=>{
    const id=parseInt(el.dataset.id);
    el.classList.toggle('sel',TS.sel.has(id));
    const sc=el.querySelector('.tc-sel');
    if(sc)sc.classList.toggle('on',TS.sel.has(id));
  });
  updateTrashHeaderSelect();
}
async function loadTrash(){
  TS.sel.clear();updateTrashBar();
  const d=await api('GET','trash');
  const el=document.getElementById('tc');
  if(!d.ok||!d.files.length){el.innerHTML=`<div class="empty"><div class="ei">🗑</div><h3>Papelera vacía</h3></div>`;return;}
  const files=d.files;TS._last=files;
  const chk='<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3"><path d="M5 12l5 5L20 6"/></svg>';
  const restBtn=(id)=>`<button class="fab tc-restore" onclick="event.stopPropagation();restoreIt(${id})" title="Restaurar" style="background:rgba(52,211,153,.15);color:var(--success)">↩</button>`;
  const delBtn=(id)=>`<button class="fab tc-del" onclick="event.stopPropagation();delIt(${id})" title="Eliminar definitivo" style="background:rgba(255,107,107,.12);color:var(--danger)">✕</button>`;
  if(TS.view==='grid'){
    el.innerHTML=`<div class="fg">${files.map(f=>{
      const ic=f.type==='folder'?'📁':mIco(f.mime_type);
      const th=f.type==='file'&&f.thumbnail?`/api/thumb/${f.id}`:null;
      return`<div class="fc tc-item" data-id="${f.id}" onclick="trashToggleSel(${f.id})">
        <div class="selcheck tc-sel" onclick="event.stopPropagation();trashToggleSel(${f.id})">${chk}</div>
        <div class="ft">${th?`<img src="${th}" loading="lazy">`:`<span>${ic}</span>`}</div>
        <div class="fi-b"><div class="fn" title="${H(f.name)}">${H(f.name)}</div><div class="fm">${f.type==='folder'?szH(f.folder_size||0):szH(f.size)}</div></div>
        <div class="fa" style="display:flex">${restBtn(f.id)}${delBtn(f.id)}</div>
      </div>`;
    }).join('')}</div>`;
  }else{
    const head=`<div class="flh"><div class="hsel"><button class="selectAllCircle" onclick="event.stopPropagation();trashSelAll(TS._last||[]);updateTrashHeaderSelect()" title="Seleccionar todo"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3"><path d="M5 12l5 5L20 6"/></svg></button></div><div class="sort">Nombre</div><div class="sort">Eliminado</div><div class="sort">Modificado por</div><div class="sort">Tamaño</div><div>Estado</div><div>Acciones</div></div>`;
    el.innerHTML=`<div class="fl">${head}${files.map(f=>{
      const ico=f.type==='folder'?'📁':mIco(f.mime_type);
      const owner=H(f.owner_name||f.owner_username||'Usuario');
      const size=f.type==='folder'?((f.item_count!==null&&f.item_count!==undefined)?(parseInt(f.item_count)==1?'1 elemento':parseInt(f.item_count||0)+' elementos'):'Carpeta'):szH(f.size);
      return`<div class="fr tc-item" data-id="${f.id}" onclick="trashToggleSel(${f.id})">
        <div class="rsel tc-sel" onclick="event.stopPropagation();trashToggleSel(${f.id})">${chk}</div>
        <div class="rn"><span class="fileico">${ico}</span><span>${H(f.name)}</span></div>
        <div class="rd">${fmtD(f.trashed_at)}</div>
        <div class="rmod">${owner}</div>
        <div class="rs">${size}</div>
        <div class="rshare">En papelera</div>
        <div class="ract" style="gap:6px">${restBtn(f.id)}${delBtn(f.id)}</div>
      </div>`;}).join('')}</div>`;
  }
  updateTrashBar();
}
async function restoreIt(id){const d=await api('POST','trash/'+id);if(d.ok){toast('Restaurado','success');loadTrash();}else toast(d.error||d.message||'Error','error');}
async function bulkTrashRestore(){
  const ids=[...TS.sel];if(!ids.length)return;
  vaultConfirm(T('Restaurar elementos'),T('¿Restaurar {n} elemento(s)?').replace('{n}',ids.length),T('Restaurar'),async()=>{
    let ok=0;for(const id of ids){const d=await api('POST','trash/'+id);if(d.ok)ok++;}
    toast(ok+' elemento(s) restaurado(s)','success');TS.sel.clear();loadTrash();
  });
}
async function bulkTrashDelete(){
  const ids=[...TS.sel];if(!ids.length)return;
  vaultConfirm(T('Eliminar definitivamente'),T('Se eliminarán {n} elemento(s). No se puede deshacer.').replace('{n}',ids.length),T('Eliminar'),async()=>{
    let ok=0;for(const id of ids){const d=await api('DELETE','trash/'+id);if(d.ok)ok++;}
    toast(ok+' elemento(s) eliminado(s)','success');TS.sel.clear();loadTrash();
  },true);
}
function delIt(id){vaultConfirm(T('Eliminar definitivamente'),T('Esta acción no se puede deshacer. ¿Eliminar permanentemente?'),T('Eliminar'),async()=>{const d=await api('DELETE','trash/'+id);if(d.ok){toast(T('Eliminado'),'info');loadTrash();}},true);}
function emptyTrash(){vaultConfirm(T('Vaciar papelera'),T('Se eliminarán definitivamente todos los elementos de la papelera. ¿Continuar?'),T('Vaciar'),async()=>{const d=await api('DELETE','trash');if(d.ok){toast(T('Papelera vaciada'),'success');TS.sel.clear();loadTrash();}},true);}

/* ══ BÚSQUEDA ══ */
function debSearch(q){clearTimeout(S.st);document.getElementById('clrBtn').classList.toggle('show',!!q.trim());if(!q.trim()){if(S.page==='search')showPage('files');return;}S.st=setTimeout(()=>doSearch(q),350);}
function clearSearch(){document.getElementById('searchInput').value='';document.getElementById('clrBtn').classList.remove('show');if(S.page==='search')showPage('files');}
async function doSearch(q){document.querySelectorAll('.page').forEach(p=>p.classList.remove('active'));document.getElementById('page-search').classList.add('active');S.page='search';const d=await api('GET','search?q='+encodeURIComponent(q));const el=document.getElementById('src');if(!d.ok||!d.files.length){el.innerHTML=`<div class="empty"><div class="ei">🔍</div><h3>Sin resultados</h3></div>`;return;}S.currentList=d.files;const files=applySort(d.files);el.innerHTML=`<div class="fg">${files.map(f=>fCard(f)).join('')}</div>`;initInternalDrag();}

/* ══ ADMIN ══ */
async function loadAdmin(){
  const el=document.getElementById('ac');
  if(!el)return;
  const [sd,ud]=await Promise.all([api('GET','admin/stats'),api('GET','admin/users')]);
  if(!sd.ok||!ud.ok){el.innerHTML='<div class="empty"><h3>Sin permisos</h3><p>No se pudo cargar el panel de administración.</p></div>';return;}
  const st=sd.stats||{},users=ud.users||[];
  const svg={users:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M16 21v-2a4 4 0 00-4-4H6a4 4 0 00-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M22 21v-2a4 4 0 00-3-3.87"/><path d="M16 3.13a4 4 0 010 7.75"/></svg>',files:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M14 2H6a2 2 0 00-2 2v16a2 2 0 002 2h12a2 2 0 002-2V8z"/><path d="M14 2v6h6"/></svg>',storage:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><ellipse cx="12" cy="5" rx="9" ry="3"/><path d="M3 5v14c0 1.7 4 3 9 3s9-1.3 9-3V5"/><path d="M3 12c0 1.7 4 3 9 3s9-1.3 9-3"/></svg>',links:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M10 13a5 5 0 007 0l3-3a5 5 0 00-7-7l-1 1"/><path d="M14 11a5 5 0 00-7 0l-3 3a5 5 0 007 7l1-1"/></svg>'};
  const rows=users.map(u=>{const quota=parseInt(u.storage_quota||0),used=parseInt(u.storage_used||0);const pct=quota?Math.min(100,Math.round(used/quota*100)):0;const initial=H((u.display_name||u.username||'?').trim().charAt(0).toUpperCase());const avatar=u.avatar?`<img src="/api/avatar/${u.id}?v=${Date.now()}" alt="avatar">`:initial;return `<tr><td><div class="admin-user"><div class="admin-avatar">${avatar}</div><div><div class="admin-name">${H(u.display_name||u.username)}</div><div class="admin-sub">${H(u.username)}</div></div></div></td><td class="adminmail" style="font-size:12px">${H(u.email)}</td><td><span class="rb ${u.role==='admin'?'rba':'rbu'}">${u.role}</span></td><td><div class="quota-wrap"><div class="quota-line"><span class="admin-sub">${szH(used)} /</span><input type="number" id="q_${u.id}" value="${Math.round(quota/1073741824)}" min="1" style="width:64px"><span class="admin-sub">GB</span><button class="icon-btn" onclick="saveQuota(${u.id})" title="Guardar cuota">✓</button></div><div class="quota-bar"><div class="quota-fill" style="width:${pct}%"></div></div></div></td><td class="adminlogin" style="font-size:12px;color:var(--muted)">${u.last_login?fmtD(u.last_login):'Nunca'}</td><td><div class="admin-actions"><button class="icon-btn" onclick="adminKillSession(${u.id},'${esc(u.display_name||u.username)}')" title="Cerrar sesión del usuario">⏻</button><button class="icon-btn danger" onclick="delUser(${u.id})" title="Eliminar"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M3 6h18"/><path d="M19 6l-1 14a2 2 0 01-2 2H8a2 2 0 01-2-2L5 6"/><path d="M10 11v6M14 11v6"/></svg></button></div></td></tr>`;}).join('');
  el.innerHTML=`<div class="admin-shell"><div class="admin-hero"><div><p style="font-size:13px;color:var(--muted);margin-top:0">Usuarios, cuotas, enlaces compartidos, actividad y configuración de Vault.</p></div><button class="btn bp" onclick="document.getElementById('mNewUser').classList.add('open')">+ Nuevo usuario</button></div><div class="admin-tabs"><button class="admin-tab active" data-admin-tab="resumen" onclick="adminShowTab('resumen')">Resumen</button><button class="admin-tab" data-admin-tab="compartidos" onclick="adminShowTab('compartidos')">Compartidos</button><button class="admin-tab" data-admin-tab="actividad" onclick="adminShowTab('actividad')">Actividad</button><button class="admin-tab" data-admin-tab="sistema" onclick="adminShowTab('sistema')">Sistema</button></div><div class="admin-panel active" id="admin-panel-resumen"><div class="sgr admin-kpis"><div class="stc"><div class="sic">${svg.users}</div><div class="sl">USUARIOS</div><div class="sv">${st.users||0}</div></div><div class="stc"><div class="sic">${svg.files}</div><div class="sl">ARCHIVOS</div><div class="sv">${st.files||0}</div></div><div class="stc"><div class="sic">${svg.storage}</div><div class="sl">ALMACENAMIENTO</div><div class="sv" style="font-size:21px">${szH(st.total_size||0)}</div></div><div class="stc"><div class="sic">${svg.links}</div><div class="sl">LINKS ACTIVOS</div><div class="sv">${st.shares||0}</div></div></div><div class="admin-sec-title"><h3>Usuarios</h3></div><div class="admin-table-wrap"><table class="admin-table"><tr><th>Usuario</th><th class="adminmail">Email</th><th>Rol</th><th>Cuota</th><th class="adminlogin">Último acceso</th><th>Acciones</th></tr>${rows}</table></div></div><div class="admin-panel" id="admin-panel-compartidos"><div class="admin-empty">Cargando enlaces compartidos...</div></div><div class="admin-panel" id="admin-panel-actividad"><div class="admin-empty">Cargando actividad...</div></div><div class="admin-panel" id="admin-panel-sistema"><div class="admin-empty">Cargando sistema...</div></div></div>`;
  document.querySelectorAll('#admin-panel-sistema input,#admin-panel-sistema select').forEach(i=>{if(i.id!=='sys_smtp_test')i.addEventListener('input',markSystemDirty);});applyLanguage(CURRENT_LANG);
}

function adminShowTab(tab){
  document.querySelectorAll('.admin-tab').forEach(b=>b.classList.toggle('active',b.dataset.adminTab===tab));
  document.querySelectorAll('.admin-panel').forEach(p=>p.classList.remove('active'));
  document.getElementById('admin-panel-'+tab)?.classList.add('active');
  if(tab==='compartidos')loadAdminShares();
  if(tab==='actividad')loadAdminActivity();
  if(tab==='sistema')loadAdminSystem();setTimeout(()=>applyLanguage(CURRENT_LANG),0);
}
async function loadAdminShares(){
  const el=document.getElementById('admin-panel-compartidos');if(!el)return;
  const d=await api('GET','admin/shares');
  if(!d.ok){el.innerHTML='<div class="admin-empty">No se pudieron cargar los compartidos.</div>';applyLanguage(CURRENT_LANG);return;}
  const rows=d.shares||[];
  if(!rows.length){el.innerHTML='<div class="admin-sec-title"><h3>Compartidos</h3><span class="admin-muted">Todos los usuarios</span></div><div class="admin-empty">No hay enlaces compartidos activos.</div>';applyLanguage(CURRENT_LANG);return;}
  const html=rows.map(s=>{const expired=s.expires_at&&new Date(String(s.expires_at).replace(' ','T')).getTime()<Date.now();const size=s.type==='folder'?szH(s.folder_size||0):szH(s.size||0);return `<tr><td><div class="admin-name">${H(s.name)}</div><div class="admin-sub">${s.type==='folder'?'Carpeta':'Archivo'} · ${size} · ${s.is_trashed?'En papelera':'Activo'}</div></td><td><div class="admin-name">${H(s.owner_name||s.owner_username||'Usuario')}</div><div class="admin-sub">${H(s.owner_email||'')}</div></td><td>${s.has_password?'<span class="admin-pill ok">Con contraseña</span>':'<span class="admin-pill warn">Sin contraseña</span>'}</td><td>${s.expires_at?(expired?'<span class="admin-pill bad">Expirado</span> ':'')+fmtD(s.expires_at):'<span class="admin-muted">Sin caducidad</span>'}</td><td>${parseInt(s.downloads||0)}${s.max_downloads?' / '+parseInt(s.max_downloads):''}</td><td><div class="admin-actions"><button class="icon-btn" onclick="adminCopyShare('${esc(s.url)}')" title="Copiar link">🔗</button><button class="icon-btn" onclick="adminOpenShare('${esc(s.url)}')" title="Abrir">↗</button><button class="icon-btn danger" onclick="adminRevokeShare(${s.id})" title="Revocar">🗑</button></div></td></tr>`;}).join('');
  el.innerHTML=`<div class="admin-sec-title"><h3>Compartidos</h3><span class="admin-muted">${rows.length} enlace(s) de todos los usuarios</span></div><div class="admin-table-wrap"><table class="admin-table"><tr><th>Elemento</th><th>Propietario</th><th>Seguridad</th><th>Expira</th><th>Descargas</th><th></th></tr>${html}</table></div>`;applyLanguage(CURRENT_LANG);
}
function adminCopyShare(url){navigator.clipboard.writeText(url).then(()=>toast(T('Link copiado'),'success'),()=>toast('No se pudo copiar','error'));}
function adminOpenShare(url){window.open(url,'_blank','noopener');}
function adminRevokeShare(id){vaultConfirm(T('Revocar enlace'),T('El enlace dejará de funcionar inmediatamente. ¿Continuar?'),T('Revocar'),async()=>{const d=await api('DELETE','admin/shares/'+id);if(d.ok){toast(T('Enlace revocado'),'success');loadAdminShares();loadAdmin();setTimeout(()=>adminShowTab('compartidos'),50);}else toast(d.message||'Error','error');},true);}
async function loadAdminActivity(){
  const el=document.getElementById('admin-panel-actividad');if(!el)return;
  const d=await api('GET','admin/activity');
  if(!d.ok){el.innerHTML=`<div class="admin-empty">${T('No se pudo cargar la actividad.')}</div>`;return;}
  const rows=d.activity||[];
  if(!rows.length){el.innerHTML=`<div class="admin-sec-title"><h3>${T('Actividad')}</h3></div><div class="admin-empty">${T('Todavía no hay actividad registrada.')}</div>`;return;}
  const labels={login:T('Inicio de sesión'),logout:T('Cierre de sesión'),login_failed:T('Login fallido'),admin_force_logout:T('Cierre forzado'),admin_system_update:T('Sistema'),upload:T('Subida'),move:T('Movido'),share:T('Compartido'),trash:T('Papelera'),restore:T('Restaurado'),delete:T('Eliminado')};
  const detailFor=a=>{if(a.action==='login')return T('Acceso desde')+' '+(a.ip||T('IP no disponible'));if(a.action==='logout')return T('Cerrada por el usuario');return a.target||T('No disponible');};
  const html=rows.map(a=>`<tr><td>${fmtD(a.created_at)}</td><td><div class="admin-name">${H(a.display_name||a.username||T('Sistema'))}</div><div class="admin-sub">${H(a.email||'')}</div></td><td><span class="admin-pill">${H(labels[a.action]||a.action)}</span></td><td>${H(detailFor(a))}</td><td class="admin-muted">${H(a.ip||'')}</td></tr>`).join('');
  el.innerHTML=`<div class="admin-sec-title"><h3>${T('Actividad')}</h3><span class="admin-muted">${T('Últimos')} ${rows.length} ${T('eventos')}</span></div><div class="admin-table-wrap"><table class="admin-table"><tr><th>${T('Fecha')}</th><th>${T('Usuario')}</th><th>${T('Acción')}</th><th>${T('Detalle')}</th><th>IP</th></tr>${html}</table></div>`;applyLanguage(CURRENT_LANG);
}
function timezoneOptions(current){const zones=['Europe/Madrid','Atlantic/Canary','America/Havana','America/Bogota','America/New_York','America/Mexico_City','America/Santo_Domingo','America/Caracas','America/Lima','America/Santiago','America/Argentina/Buenos_Aires','UTC'];return zones.map(z=>`<option value="${z}" ${z===current?'selected':''}>${z}</option>`).join('');}
let systemDirty=false;
function markSystemDirty(){systemDirty=true;}
async function loadAdminSystem(){
  const el=document.getElementById('admin-panel-sistema');if(!el)return;
  const d=await api('GET','admin/system');
  if(!d.ok){el.innerHTML='<div class="admin-empty">No se pudo cargar el sistema.</div>';return;}
  const x=d.system||{};const checked=v=>v?'checked':'';
  el.innerHTML=`<div class="admin-system-head"><div><h3>Sistema</h3><p>Configuración operativa de Vault</p></div></div>
  <div class="system-form-grid system-mockup">
    <div class="system-column">
      <section class="system-section"><h4>General</h4>
        <div class="mf"><label>Nombre de la app</label><input id="sys_app_name" value="${H(x.app_name||'Vault')}"></div>
        <div class="mf"><label>URL pública</label><input id="sys_app_url" placeholder="https://cloud.yansy.es" value="${H(x.app_url||'')}"></div>
        <div class="mf"><label>Tamaño máximo de subida (GB)</label><input id="sys_max_upload" type="number" min="1" value="${Math.round((parseInt(x.max_upload_size||10737418240))/1073741824)}"></div>
        <div class="mf"><label>Zona horaria</label><select id="sys_timezone">${timezoneOptions(x.timezone||'Europe/Madrid')}</select></div>
      </section>
      <section class="system-section"><h4>Enlaces compartidos</h4>
        <label class="switchrow"><span><strong>Requerir contraseña por defecto</strong><small>Todos los enlaces nuevos requerirán contraseña.</small></span><input type="checkbox" id="sys_share_require" ${checked(x.share_require_password)}></label>
        <div class="mf"><label>Caducidad por defecto (días, 0 = sin caducidad)</label><input id="sys_share_expiry" type="number" min="0" value="${parseInt(x.share_default_expiry_days||0)}"></div>
        <div class="mf"><label>Máximo de descargas por defecto (0 = sin límite)</label><input id="sys_share_max" type="number" min="0" value="${parseInt(x.share_default_max_downloads||0)}"></div>
      </section>
    </div>
    <div class="system-column">
      <section class="system-section"><div class="system-card-title"><h4>SMTP</h4><label class="inline-check"><span>Activar SMTP</span><input type="checkbox" id="sys_smtp_enabled" ${checked(x.smtp_enabled)}></label></div>
        <div class="mf"><label>Servidor</label><input id="sys_smtp_host" value="${H(x.smtp_host||'')}"></div>
        <div class="system-two"><div class="mf"><label>Puerto</label><input id="sys_smtp_port" value="${H(x.smtp_port||'465')}"></div><div class="mf"><label>Seguridad</label><select id="sys_smtp_security"><option value="ssl" ${x.smtp_security==='ssl'?'selected':''}>SSL/TLS</option><option value="tls" ${x.smtp_security==='tls'?'selected':''}>STARTTLS</option><option value="none" ${x.smtp_security==='none'?'selected':''}>Sin cifrado</option></select></div></div>
        <div class="mf"><label>Usuario</label><input id="sys_smtp_user" value="${H(x.smtp_user||'')}"></div>
        <div class="mf"><label>Contraseña</label><input id="sys_smtp_pass" type="password" placeholder="Dejar vacío para mantener la actual"></div>
        <div class="system-help">La contraseña solo cambia al pulsar Guardar SMTP. Enviar prueba no guarda cambios.</div>
        <div class="mf"><label>Remitente</label><input id="sys_smtp_from" value="${H(x.smtp_from||'')}"></div>
        <div class="mf"><label>Email de prueba</label><input id="sys_smtp_test" placeholder="destinatario@correo.com"></div>
        <div class="system-actions"><button class="btn bp" onclick="adminSaveSystem('smtp')">Guardar SMTP</button><button class="btn bs" onclick="adminTestSmtp()">Enviar prueba</button></div>
      </section>
      <section class="system-section"><h4>Papelera y seguridad</h4>
        <label class="switchrow"><span><strong>Purga automática de papelera</strong><small>Elimina automáticamente archivos tras el periodo indicado.</small></span><input type="checkbox" id="sys_trash_auto" ${checked(x.trash_auto_purge)}></label>
        <div class="mf"><label>Retención papelera (días)</label><select id="sys_trash_days"><option value="30" ${parseInt(x.trash_retention_days||30)===30?'selected':''}>30 días</option><option value="60" ${parseInt(x.trash_retention_days||30)===60?'selected':''}>60 días</option><option value="90" ${parseInt(x.trash_retention_days||30)===90?'selected':''}>90 días</option></select></div>
        <label class="switchrow"><span><strong>Forzar 2FA para administradores</strong><small>Recomendado para proteger el panel admin.</small></span><input type="checkbox" id="sys_force_admin_2fa" ${checked(x.force_admin_2fa)}></label>
        <div class="mf"><label>Duración de sesión (días)</label><input id="sys_session_days" type="number" min="1" value="${Math.round((parseInt(x.session_lifetime||604800))/86400)}"></div>
      </section>
    </div>
  </div><div class="system-savebar"><button class="btn bp" onclick="saveAdminSystem()">Guardar configuración</button></div>`;
  document.querySelectorAll('#admin-panel-sistema input,#admin-panel-sistema select').forEach(i=>{if(i.id!=='sys_smtp_test')i.addEventListener('input',markSystemDirty);});applyLanguage(CURRENT_LANG);
}
async function saveAdminSystem(scope='all'){
  const payload={app_name:val('sys_app_name'),app_url:val('sys_app_url'),max_upload_size:(parseInt(val('sys_max_upload'))||10)*1073741824,timezone:val('sys_timezone')||'Europe/Madrid',smtp_enabled:chk('sys_smtp_enabled'),smtp_host:val('sys_smtp_host'),smtp_port:val('sys_smtp_port'),smtp_security:val('sys_smtp_security'),smtp_user:val('sys_smtp_user'),smtp_from:val('sys_smtp_from'),share_require_password:chk('sys_share_require'),share_default_expiry_days:parseInt(val('sys_share_expiry'))||0,share_default_max_downloads:parseInt(val('sys_share_max'))||0,trash_auto_purge:chk('sys_trash_auto'),trash_retention_days:parseInt(val('sys_trash_days'))||30,force_admin_2fa:chk('sys_force_admin_2fa'),session_lifetime:(parseInt(val('sys_session_days'))||7)*86400};
  const pass=val('sys_smtp_pass');if(pass)payload.smtp_pass=pass;
  const d=await api('PATCH','admin/system',payload);if(d.ok){systemDirty=false;const sp=document.getElementById('sys_smtp_pass');if(sp)sp.value='';toast(scope==='smtp'?'SMTP guardado':'Configuración guardada','success');}else toast(d.message||'Error guardando sistema','error');
}
function adminSaveSystem(scope='all'){return saveAdminSystem(scope);}
async function adminTestSmtp(){if(systemDirty)return toast('Guarda la configuración SMTP antes de enviar una prueba','error');const email=val('sys_smtp_test');if(!email)return toast('Introduce email de prueba','error');const d=await api('POST','admin/system-test-smtp',{email});if(d.ok)toast('Correo de prueba enviado','success');else toast(d.message||'No se pudo enviar','error');}
function val(id){return document.getElementById(id)?.value||'';}function chk(id){return !!document.getElementById(id)?.checked;}
async function saveQuota(id){const gb=parseInt(document.getElementById('q_'+id).value)||1;const d=await api('PATCH','admin/users/'+id,{storage_quota:gb*1073741824});if(d.ok)toast('Cuota actualizada','success');else toast(d.message||'Error','error');}
async function createUser(){const d=await api('POST','admin/users',{username:document.getElementById('nu-u').value,email:document.getElementById('nu-e').value,display_name:document.getElementById('nu-n').value,password:document.getElementById('nu-p').value,role:document.getElementById('nu-r').value,storage_quota:(parseInt(document.getElementById('nu-q').value)||10)*1073741824});if(d.ok){toast('Usuario creado','success');closeModal('mNewUser');loadAdmin();}else toast(d.message||d.error||'Error','error');}
function delUser(id){vaultConfirm(T('Eliminar usuario'),T('Se eliminará el usuario y todos sus archivos. ¿Continuar?'),T('Eliminar'),async()=>{const d=await api('DELETE','admin/users/'+id);if(d.ok){toast(T('Usuario eliminado'),'success');loadAdmin();}else toast(d.message||'Error','error');},true);}
function adminKillSession(id,name){vaultConfirm(T('Cerrar sesión'),T('Se cerrará la sesión activa de {name}. El usuario tendrá que iniciar sesión otra vez.').replace('{name}',name),T('Cerrar sesión'),async()=>{const d=await api('POST','admin/session/'+id);if(d.ok){toast(T('Sesión cerrada'),'success');adminShowTab('actividad');}else toast(d.message||'Error','error');},true);}

/* ══ PANEL DE DETALLES ══ */
function toggleDetailsPanel(){
  const p=document.getElementById('detailsPanel');
  if(!p)return;
  if(p.classList.contains('open')){closeDetailsPanel();return;}
  openDetailsPanel();
}
function closeDetailsPanel(){document.getElementById('detailsPanel')?.classList.remove('open');}
function openDetailsPanel(item){
  const panel=document.getElementById('detailsPanel'),body=document.getElementById('detailsPanelBody');
  if(!panel||!body)return;
  let it=item||null;
  if(!it){
    const selected=getSelectedItems();
    if(selected.length===1){
      it=(S.currentList||[]).find(x=>parseInt(x.id)===parseInt(selected[0].id))||selected[0];
    }
  }
  if(!it){body.innerHTML=`<div class="dp-empty">${T('Selecciona un elemento para ver sus detalles.')}</div>`;panel.classList.add('open');return;}
  const icon=it.type==='folder'?'📁':mIco(it.mime_type||'');
  const type=it.type==='folder'?'Carpeta':'Archivo';
  const size=it.type==='folder'?szH(it.folder_size||0):szH(it.size||0);const itemCount=it.type==='folder'?parseInt(it.item_count||0):null;
  const owner=H(it.owner_name||it.owner_username||T('Usuario'));
  const shared=parseInt(it.share_count||0)>0?T('Compartido'):T('Privado');
  body.innerHTML=`<div class="dp-icon">${icon}</div><div class="dp-name">${H(it.name||T('Elemento'))}</div><div class="dp-type">${T(type)}</div><div class="dp-row"><div class="k">${T('Tamaño')}</div><div class="v">${size}</div></div>${itemCount!==null?`<div class="dp-row"><div class="k">${T('Elementos')}</div><div class="v">${itemCount}</div></div>`:''}<div class="dp-row"><div class="k">${T('Modificado')}</div><div class="v">${it.updated_at?fmtD(it.updated_at):T('No disponible')}</div></div><div class="dp-row"><div class="k">${T('Creado')}</div><div class="v">${it.created_at?fmtD(it.created_at):T('No disponible')}</div></div><div class="dp-row"><div class="k">${T('Modificado por')}</div><div class="v">${owner}</div></div><div class="dp-row"><div class="k">${T('Estado')}</div><div class="v">${shared}</div></div><div class="dp-row"><div class="k">${T('Tipo MIME')}</div><div class="v">${H(it.mime_type||T('No disponible'))}</div></div><div class="dp-actions"><button class="btn bs" onclick="showShare(${parseInt(it.id)},'${esc(it.name||T('Elemento'))}','${it.type||'file'}')">${T('Compartir')}</button><button class="btn bs" onclick="moveOne(${parseInt(it.id)})">${T('Mover')}</button><button class="btn bd" onclick="trashIt(${parseInt(it.id)})">${T('Papelera')}</button></div>`;
  panel.classList.add('open');
}

/* ══ AJUSTES ══ */
async function loadSettings(){
  const me=await api('GET','auth/me');
  const u=me.user||{};
  const el=document.getElementById('stc');
  pendingAvatarFile=null;pendingAvatarDelete=false;
  const av=u.avatar?`<img src="/api/avatar/${u.id}?v=${Date.now()}" alt="avatar">`:H((u.display_name||u.username||'?').trim().charAt(0).toUpperCase());
  el.innerHTML=`<div class="setg"><div class="sc"><h3>Perfil</h3>
    <div class="profile-avatar-edit"><div class="profile-photo" id="profilePhoto">${av}</div><div>
      <input type="file" id="avatarFile" accept="image/jpeg,image/png,image/webp" style="display:none" onchange="previewAvatar()">
      <div class="profile-actions"><button class="btn bs" onclick="document.getElementById('avatarFile').click()">Cambiar foto</button><button class="btn bd" onclick="markAvatarDelete()">Quitar</button></div>
      <div class="admin-sub" style="margin-top:6px">JPG, PNG o WEBP. Máximo 2 MB.</div>
      <div class="avatar-pending-note" id="avatarPendingNote"></div>
    </div></div>
    <div class="mf"><label>Nombre visible</label><input type="text" id="st-n" value="${H(u.display_name||'')}"></div>
    <div class="mf"><label>Email</label><input type="email" id="st-e" value="${H(u.email||'')}"></div>
    <div class="pref-row"><div class="mf"><label>Tema</label><select id="st-theme" onchange="previewThemeSetting()"><option value="light" ${(u.theme||'light')==='light'?'selected':''}>Claro</option><option value="dark" ${(u.theme||'light')==='dark'?'selected':''}>Oscuro</option></select></div><div class="mf"><label>Idioma</label><select id="st-lang" onchange="previewLanguageSetting()"><option value="es" ${(u.language||'es')==='es'?'selected':''}>Español</option><option value="en" ${(u.language||'es')==='en'?'selected':''}>English</option></select></div></div>
    <button class="btn bp" onclick="saveProfile()" style="margin-top:14px">Guardar perfil</button>
  </div><div class="sc"><h3>Cambiar contraseña</h3><div class="mf"><label>Actual</label><input type="password" id="st-cp"></div><div class="mf"><label>Nueva</label><input type="password" id="st-np"></div><div class="mf"><label>Confirmar</label><input type="password" id="st-pp"></div><button class="btn bp" onclick="chgPass()">Cambiar</button></div><div class="sc full"><div style="display:flex;align-items:center;gap:10px;margin-bottom:14px"><h3 style="margin:0">Autenticación en dos pasos (2FA)</h3><span class="ts ${u.totp_enabled?'ton':'toff'}">${u.totp_enabled?'Activo':'Inactivo'}</span></div><p style="font-size:13px;color:var(--muted);margin-bottom:16px;line-height:1.6">${u.totp_enabled?'El 2FA está activo. Necesitarás un código de tu app autenticadora en cada inicio de sesión.':'Añade una capa extra de seguridad. Compatible con Google Authenticator, Authy, Bitwarden, 1Password.'}</p><div id="ta">${u.totp_enabled?`<div class="mf" style="max-width:280px"><label>Confirma tu contraseña para desactivar</label><input type="password" id="dp"></div><button class="btn bd" onclick="disableTotp()">Desactivar 2FA</button>`:`<button class="btn bp" onclick="startTotp()">Activar 2FA</button>`}</div></div></div>`;
  applyLanguage(CURRENT_LANG);
}
function previewAvatar(){
  const inp=document.getElementById('avatarFile');if(!inp.files||!inp.files[0])return;
  const f=inp.files[0];
  if(f.size>2*1024*1024){toast('La imagen no puede superar 2 MB','error');inp.value='';return;}
  if(!['image/jpeg','image/png','image/webp'].includes(f.type)){toast('Formato no válido. Usa JPG, PNG o WEBP','error');inp.value='';return;}
  pendingAvatarFile=f;pendingAvatarDelete=false;
  const photo=document.getElementById('profilePhoto');
  const note=document.getElementById('avatarPendingNote');
  const url=URL.createObjectURL(f);
  photo.innerHTML=`<img src="${url}" alt="avatar preview">`;
  if(note)note.textContent='Foto pendiente. Pulsa Guardar perfil para aplicar el cambio.';
}
function markAvatarDelete(){
  pendingAvatarFile=null;pendingAvatarDelete=true;
  const name=(document.getElementById('st-n')?.value||'<?=h($userName)?>'||'?').trim();
  document.getElementById('profilePhoto').textContent=(name.charAt(0)||'?').toUpperCase();
  const note=document.getElementById('avatarPendingNote');if(note)note.textContent='Foto pendiente de quitar. Pulsa Guardar perfil para aplicar el cambio.';
}
async function uploadPendingAvatar(){
  if(!pendingAvatarFile)return {ok:true};
  const fd=new FormData();fd.append('avatar',pendingAvatarFile);
  const r=await fetch('/api/user/avatar',{method:'POST',body:fd});
  return await r.json();
}
async function deletePendingAvatar(){
  if(!pendingAvatarDelete)return {ok:true};
  return await api('DELETE','user/avatar');
}
function previewThemeSetting(){const t=document.getElementById('st-theme')?.value||'light';document.documentElement.setAttribute('data-theme',t);setThemeIcon(t);}
function previewLanguageSetting(){const l=document.getElementById('st-lang')?.value||'es';CURRENT_LANG=l;document.documentElement.setAttribute('lang',l);applyLanguage(l);}
async function startTotp(){
  const d=await api('GET','user/totp-setup');
  if(!d.ok)return toast(d.error||d.message||'Error generando 2FA','error');
  const ta=document.getElementById('ta');ta.innerHTML='';
  const wrap=document.createElement('div');wrap.style.cssText='display:flex;gap:24px;align-items:flex-start;flex-wrap:wrap';
  wrap.innerHTML=`<div><p style="font-size:12px;color:var(--muted);margin-bottom:10px">1. Escanea con tu app</p><img src="${d.qr}" style="border-radius:12px;border:3px solid var(--border);display:block;width:200px;height:200px"><details style="margin-top:8px"><summary style="font-size:11px;color:var(--muted);cursor:pointer">Ver clave manual</summary><code style="font-size:11px;background:var(--surface2);padding:6px 9px;border-radius:7px;display:block;margin-top:5px;letter-spacing:2px;word-break:break-all">${d.secret}</code></details></div><div style="flex:1;min-width:230px"><p style="font-size:12px;color:var(--muted);margin-bottom:10px">2. Introduce el código de 6 dígitos</p><div class="mf"><input type="tel" autocomplete="one-time-code" inputmode="numeric" maxlength="6" placeholder="000000" style="font-size:22px;font-family:monospace;letter-spacing:8px;text-align:center;width:100%"></div><button class="btn bp" style="width:100%;margin-bottom:8px">Activar 2FA</button><button class="btn bs" style="width:100%">Cancelar</button></div>`;
  ta.appendChild(wrap);
  const inp=wrap.querySelector('input[type="tel"]');const btnOk=wrap.querySelectorAll('button')[0];const btnCancel=wrap.querySelectorAll('button')[1];
  inp.addEventListener('input',()=>{inp.value=inp.value.replace(/\D/g,'').slice(0,6);});
  inp.addEventListener('keydown',e=>{if(e.key==='Enter')doEnable();});
  btnOk.addEventListener('click',doEnable);btnCancel.addEventListener('click',()=>loadSettings());
  setTimeout(()=>inp.focus(),80);
  async function doEnable(){
    const code=String(inp.value||'').replace(/\D/g,'').trim();
    if(code.length!==6){toast('Introduce los 6 dígitos','error');inp.focus();return;}
    btnOk.disabled=true;btnOk.textContent='Activando...';
    const r=await api('POST','user/totp-enable',{code});
    if(!r.ok){btnOk.disabled=false;btnOk.textContent='Activar 2FA';toast(r.message||'Código incorrecto','error');inp.value='';inp.focus();return;}
    const codes=r.backup_codes||[];
    ta.innerHTML=`<div style="background:rgba(52,211,153,.08);border:1px solid rgba(52,211,153,.3);border-radius:12px;padding:18px;max-width:520px"><h4 style="color:var(--success);margin-bottom:8px">✓ 2FA activado correctamente</h4><p style="font-size:13px;color:var(--muted);margin-bottom:12px;line-height:1.6"><strong style="color:var(--text)">Guarda estos códigos de recuperación.</strong> Cada uno se usa una sola vez.</p><div style="display:grid;grid-template-columns:1fr 1fr;gap:6px;margin-bottom:12px">${codes.map(c=>`<code style="background:var(--surface2);padding:7px 10px;border-radius:7px;font-size:13px;border:1px solid var(--border)">${c}</code>`).join('')}</div><button class="btn bs" id="_totpCopy">Copiar todos</button></div><button class="btn bs" onclick="loadSettings()" style="margin-top:10px">Volver</button>`;
    const cp=document.getElementById('_totpCopy');if(cp)cp.onclick=()=>navigator.clipboard.writeText(codes.join('\n')).then(()=>toast('Copiados','success'));
    toast('2FA activado','success');
  }
}
function enableTotp(){}

async function disableTotp(){const pass=document.getElementById('dp').value;if(!pass)return toast('Introduce tu contraseña','error');const d=await api('POST','user/totp-disable',{password:pass});if(d.ok){toast('2FA desactivado','info');loadSettings();}else toast(d.message||'Contraseña incorrecta','error');}
async function saveProfile(){
  const payload={display_name:document.getElementById('st-n').value,email:document.getElementById('st-e').value,theme:document.getElementById('st-theme')?.value||document.documentElement.getAttribute('data-theme')||'light',language:document.getElementById('st-lang')?.value||CURRENT_LANG||'es'};
  const d=await api('POST','user/profile',payload);
  if(!d.ok){toast(d.error||'Error guardando perfil','error');return;}
  if(pendingAvatarDelete){const del=await deletePendingAvatar();if(!del.ok){toast(del.message||'No se pudo quitar la foto','error');return;}}
  if(pendingAvatarFile){const up=await uploadPendingAvatar();if(!up.ok){toast(up.message||up.error||'No se pudo subir la foto','error');return;}}
  pendingAvatarFile=null;pendingAvatarDelete=false;CURRENT_LANG=payload.language;document.documentElement.setAttribute('lang',CURRENT_LANG);document.documentElement.setAttribute('data-theme',payload.theme);setThemeIcon(payload.theme);applyLanguage(CURRENT_LANG);toast('Perfil guardado','success');
  const me=await api('GET','auth/me');const u=me.user||{};const sideAv=document.querySelector('.ur .av');if(sideAv){sideAv.innerHTML=u.avatar?`<img src="/api/avatar/${u.id}?v=${Date.now()}" style="width:100%;height:100%;object-fit:cover;border-radius:50%" alt="avatar">`:H((u.display_name||u.username||'?').trim().charAt(0).toUpperCase());}
  const un=document.querySelector('.ur .un');if(un)un.textContent=u.display_name||u.username||'';
  loadSettings();
}
async function chgPass(){const c=document.getElementById('st-cp').value,n=document.getElementById('st-np').value,p=document.getElementById('st-pp').value;if(n!==p)return toast('Las contraseñas no coinciden','error');if(n.length<8)return toast('Mínimo 8 caracteres','error');const d=await api('POST','user/password',{current:c,new:n});if(d.ok){toast('Contraseña cambiada','success');['st-cp','st-np','st-pp'].forEach(i=>document.getElementById(i).value='');}else toast(d.message||'Error','error');}

/* ══ TEMA ══ */
async function toggleTheme(){
  const cur=document.documentElement.getAttribute('data-theme')||'light';
  const next=cur==='dark'?'light':'dark';
  document.documentElement.setAttribute('data-theme',next);
  setThemeIcon(next);
  const sel=document.getElementById('st-theme');if(sel)sel.value=next;
  await api('POST','user/theme',{theme:next});
}
function setThemeIcon(t){const b=document.getElementById('themeBtn');if(!b)return;b.innerHTML=t==='dark'?'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="17" height="17"><path d="M21 12.8A9 9 0 1111.2 3 7 7 0 0021 12.8z"/></svg>':'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="17" height="17"><circle cx="12" cy="12" r="5"/><path d="M12 1v2M12 21v2M4.2 4.2l1.4 1.4M18.4 18.4l1.4 1.4M1 12h2M21 12h2M4.2 19.8l1.4-1.4M18.4 5.6l1.4-1.4"/></svg>';}
const I18N={
 es:{create:'Crear o subir',folder:'Carpeta',uploadFiles:'Subir archivos',uploadFolder:'Subir carpeta',home:'Home',myFiles:'Mis archivos',favorites:'Favoritos',shared:'Compartidos',trash:'Papelera de reciclaje',admin:'Panel admin',settings:'Ajustes',search:'Buscar archivos...',sort:'Ordenar',details:'Detalles',filesTitle:'Mis archivos',profileSaved:'Perfil guardado'},
 en:{create:'Create or upload',folder:'Folder',uploadFiles:'Upload files',uploadFolder:'Upload folder',home:'Home',myFiles:'My files',favorites:'Favorites',shared:'Shared',trash:'Recycle bin',admin:'Admin panel',settings:'Settings',search:'Search files...',sort:'Sort',details:'Details',filesTitle:'My files',profileSaved:'Profile saved'}
};
const TR_ES_EN={
'Ajustes':'Settings','Perfil':'Profile','Cambiar contraseña':'Change password','Autenticación en dos pasos (2FA)':'Two-step verification (2FA)','Cambiar foto':'Change photo','Quitar':'Remove','Guardar perfil':'Save profile','Nombre visible':'Display name','Email':'Email','Tema':'Theme','Idioma':'Language','Claro':'Light','Oscuro':'Dark','Actual':'Current','Nueva':'New','Confirmar':'Confirm','Cambiar':'Change','Activar 2FA':'Enable 2FA','Desactivar 2FA':'Disable 2FA','Inactivo':'Inactive','Activo':'Active',
'Mis archivos':'My files','Inicio':'Home','Nombre':'Name','Modificado':'Modified','Modificado por':'Modified by','Tamaño':'Size','Compartido':'Shared','Actividad':'Activity','Privado':'Private','Enlace activo':'Active link','Carpeta vacía':'Empty folder','Sube archivos o crea una carpeta':'Upload files or create a folder','Sin resultados':'No results','Papelera vacía':'Recycle bin is empty','En papelera':'In recycle bin','Eliminado':'Deleted','Restaurado':'Restored','Acciones':'Actions','Estado':'Status','Elementos':'Items','Creado':'Created','Tipo MIME':'MIME type',
'Panel de administración':'Admin panel','Usuarios, cuotas, enlaces compartidos, actividad y configuración de Vault.':'Users, quotas, shared links, activity and Vault configuration.','Resumen':'Overview','Compartidos':'Shared','Sistema':'System','Usuarios':'Users','Archivos':'Files','Almacenamiento':'Storage','Links activos':'Active links','Usuario':'User','Rol':'Role','Cuota':'Quota','Último acceso':'Last access','Últimos':'Last','eventos':'events','Fecha':'Date','Acción':'Action','Detalle':'Detail','Configuración operativa de Vault':'Operational Vault configuration','General':'General','Nombre de la app':'App name','URL pública':'Public URL','Tamaño máximo de subida (GB)':'Maximum upload size (GB)','Zona horaria':'Time zone','SMTP':'SMTP','Activar SMTP':'Enable SMTP','Servidor':'Server','Puerto':'Port','Seguridad':'Security','Contraseña':'Password','Remitente':'Sender','Email de prueba':'Test email','Guardar SMTP':'Save SMTP','Enviar prueba':'Send test','Enlaces compartidos':'Shared links','Requerir contraseña por defecto':'Require password by default','Caducidad por defecto (días, 0 = sin caducidad)':'Default expiry (days, 0 = no expiry)','Máximo de descargas por defecto (0 = sin límite)':'Default max downloads (0 = unlimited)','Papelera y seguridad':'Recycle bin and security','Purga automática de papelera':'Automatic recycle bin purge','Retención papelera (días)':'Recycle bin retention (days)','Forzar 2FA para administradores':'Force 2FA for admins','Duración de sesión (días)':'Session duration (days)','Guardar configuración':'Save settings',
'Compartir':'Share','Copiar link':'Copy link','Descargar':'Download','Destacar':'Favorite','Mover':'Move','Papelera':'Recycle bin','Ordenar':'Sort','Detalles':'Details','seleccionado':'selected','seleccionados':'selected','Seleccionar todo':'Select all',
'Link copiado':'Link copied','Cualquiera con el enlace puede descargar':'Anyone with the link can download','Configuración del sistema actualizada':'System configuration updated','Inicio de sesión':'Sign-in','Cierre de sesión':'Sign-out','Cierre forzado':'Forced sign-out','Acceso desde':'Access from','Cerrada por el usuario':'Signed out by user','No disponible':'Not available','Nunca':'Never','No se pudo cargar el sistema.':'Could not load system.','No se pudo cargar la actividad.':'Could not load activity.','Todavía no hay actividad registrada.':'No activity has been recorded yet.',
'La contraseña solo cambia al pulsar Guardar SMTP. Enviar prueba no guarda cambios.':'The password only changes when you click Save SMTP. Send test does not save changes.','Dejar vacío para mantener la actual':'Leave empty to keep current password','destinatario@correo.com':'recipient@example.com','Sin cifrado':'No encryption','30 días':'30 days','60 días':'60 days','90 días':'90 days','Asc':'Asc','Desc':'Desc',
'JPG, PNG o WEBP. Máximo 2 MB.':'JPG, PNG or WEBP. Maximum 2 MB.','Foto pendiente. Pulsa Guardar perfil para aplicar el cambio.':'Photo pending. Click Save profile to apply the change.','Foto pendiente de quitar. Pulsa Guardar perfil para aplicar el cambio.':'Photo removal pending. Click Save profile to apply the change.','Añade una capa extra de seguridad. Compatible con Google Authenticator, Authy, Bitwarden, 1Password.':'Add an extra layer of security. Compatible with Google Authenticator, Authy, Bitwarden, 1Password.','Cancelar':'Cancel','Crear':'Create','Nueva carpeta':'New folder','Mi carpeta':'My folder','Nuevo usuario':'New user','Eliminar':'Delete','Aceptar':'OK','Settings':'Settings','Ver detalle':'View details','Sin destacados':'No favorites','Sin links compartidos':'No shared links','Archivo':'File','Link':'Link','Expira':'Expires','Restaurar elementos':'Restore items','¿Restaurar {n} elemento(s)?':'Restore {n} item(s)?','Restaurar':'Restore','Eliminar definitivamente':'Delete permanently','Se eliminarán {n} elemento(s). No se puede deshacer.':'{n} item(s) will be deleted. This cannot be undone.','Esta acción no se puede deshacer. ¿Eliminar permanentemente?':'This action cannot be undone. Delete permanently?','Vaciar papelera':'Empty recycle bin','Se eliminarán definitivamente todos los elementos de la papelera. ¿Continuar?':'All items in the recycle bin will be permanently deleted. Continue?','Vaciar':'Empty','Papelera vaciada':'Recycle bin emptied','Revocar enlace':'Revoke link','El enlace dejará de funcionar inmediatamente. ¿Continuar?':'The link will stop working immediately. Continue?','Revocar':'Revoke','Enlace revocado':'Link revoked','Eliminar usuario':'Delete user','Se eliminará el usuario y todos sus archivos. ¿Continuar?':'The user and all their files will be deleted. Continue?','Usuario eliminado':'User deleted','Cerrar sesión':'Sign out','Se cerrará la sesión activa de {name}. El usuario tendrá que iniciar sesión otra vez.':'The active session for {name} will be closed. The user will have to sign in again.','Sesión cerrada':'Session closed','Movidos a papelera':'Moved to recycle bin','Movido a papelera':'Moved to recycle bin','¿Mover {n} elemento(s) a la papelera?':'Move {n} item(s) to the recycle bin?','¿Mover este elemento a la papelera?':'Move this item to the recycle bin?','Selecciona un único elemento para ver sus detalles.':'Select a single item to see details.','Elemento':'Item','file':'File','folder':'Folder','Renombrar':'Rename','Español':'Spanish','English':'English','Contraseña cambiada':'Password changed','Las contraseñas no coinciden':'Passwords do not match','Mínimo 8 caracteres':'Minimum 8 characters','Perfil guardado':'Profile saved','No se pudo quitar la foto':'Could not remove photo','No se pudo subir la foto':'Could not upload photo','Subiendo':'Uploading','Subido':'Uploaded','Uploading items':'Uploading items','Mover a papelera':'Move to recycle bin','Selecciona un elemento para ver sus detalles.':'Select an item to see details.','Login fallido':'Failed login','Subida':'Upload','Movido':'Moved','IP no disponible':'IP not available','Destacados':'Favorited','Selecciona solo un elemento para compartir':'Select only one item to share','Selecciona solo un elemento para copiar link':'Select only one item to copy link','Error creando link':'Error creating link','Renombrado':'Renamed','Carpeta creada':'Folder created','item':'item','items':'items','Uploaded':'Uploaded','to':'to','Error uploading':'Error uploading','Uploading':'Uploading','Error subiendo':'Error uploading','Error completando':'Error completing','Crear link':'Create link','Compartir carpeta':'Share folder','Compartir archivo':'Share file','Settings del enlace':'Link settings','Guardar settings':'Save settings','Settings guardados':'Settings saved','Link creado':'Link created','Introduce un email':'Enter an email','Email enviado':'Email sent','Error al enviar':'Error sending','Este tipo de archivo no se puede previsualizar':'This file type cannot be previewed','raíz':'root','Ya existe un elemento con ese nombre en el destino. ¿Qué quieres hacer?':'An item with that name already exists in the destination. What do you want to do?','Enviar por email':'Send by email','Link generado':'Generated link','Contraseña (opcional)':'Password (optional)','Expira el (opcional)':'Expires on (optional)','Máx. descargas (opcional)':'Max downloads (optional)','Sin contraseña':'No password','Sin límite':'No limit','Enviar':'Send','Cerrar':'Close','Cambiar nombre':'Rename','Nuevo nombre':'New name','Resolver conflicto':'Resolve conflict','Renombrar automáticamente':'Rename automatically','Reemplazar':'Replace','Mover elementos':'Move items','Selecciona carpeta destino':'Select destination folder','Mover aquí':'Move here','Código de verificación':'Verification code','Introduce tu contraseña':'Enter your password','Contraseña incorrecta':'Incorrect password','2FA desactivado':'2FA disabled','1. Escanea con tu app':'1. Scan with your app','Ver clave manual':'View manual key','2. Introduce el código de 6 dígitos':'2. Enter the 6-digit code',
'Archivos más grandes en Vault':'Largest files in your Vault','Para liberar espacio, descarga y elimina archivos que no necesites, y vacía la papelera.':'To free up space, download and delete files you do not need, and empty your recycle bin.','Ubicación':'Location','Papelera de reciclaje':'Recycle bin','No hay archivos':'No files','Sube archivos para ver aquí los de mayor tamaño.':'Upload files to see the largest ones here.','Ver archivos más grandes':'View largest files','Cargando archivos...':'Loading files...'
};
const TR_EN_ES=Object.fromEntries(Object.entries(TR_ES_EN).map(([k,v])=>[v,k]));
function T(k){const lang=(CURRENT_LANG==='en')?'en':'es';if(lang==='en')return TR_ES_EN[k]||k;return TR_EN_ES[k]||k;}
function setTextForSelector(sel,txt){const e=document.querySelector(sel);if(!e)return;let done=false;e.childNodes.forEach(n=>{if(n.nodeType===3&&n.textContent.trim()){n.textContent=' '+txt;done=true;}});if(!done){const lab=e.querySelector('.top-label');if(lab)lab.textContent=txt;}}
function translateExactText(lang){
  const map=lang==='en'?TR_ES_EN:TR_EN_ES;
  const skip=new Set(['SCRIPT','STYLE','INPUT','TEXTAREA','SELECT','OPTION','CODE','PRE']);
  const walker=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT,{acceptNode(node){const p=node.parentElement;if(!p||skip.has(p.tagName))return NodeFilter.FILTER_REJECT;return node.nodeValue.trim()?NodeFilter.FILTER_ACCEPT:NodeFilter.FILTER_REJECT;}});
  let n;while(n=walker.nextNode()){
    const raw=n.nodeValue, trimmed=raw.trim();let rep=map[trimmed];
    if(!rep){rep=trimmed.replace(/\bseleccionado\b/g,lang==='en'?'selected':'seleccionado').replace(/\bseleccionados\b/g,lang==='en'?'selected':'seleccionados');if(rep===trimmed)rep=null;}
    if(rep)n.nodeValue=raw.replace(trimmed,rep);
  }
  document.querySelectorAll('[placeholder]').forEach(el=>{const p=el.getAttribute('placeholder');if(map[p])el.setAttribute('placeholder',map[p]);});
  document.querySelectorAll('[title]').forEach(el=>{const p=el.getAttribute('title');if(map[p])el.setAttribute('title',map[p]);});
  document.querySelectorAll('option').forEach(o=>{const tx=o.textContent.trim();if(map[tx])o.textContent=map[tx];});
}
function applyLanguage(lang){lang=(lang==='en')?'en':'es';CURRENT_LANG=lang;document.documentElement.setAttribute('lang',lang);const t=I18N[lang];setTextForSelector('.od-create',t.create);const mi=[...document.querySelectorAll('.od-menu .od-mi span:last-child')];if(mi[0])mi[0].textContent=t.folder;if(mi[1])mi[1].textContent=t.uploadFiles;if(mi[2])mi[2].textContent=t.uploadFolder;const nav={home:t.home,files:t.myFiles,starred:t.favorites,shares:t.shared,trash:t.trash,admin:t.admin,settings:t.settings};Object.entries(nav).forEach(([k,v])=>setTextForSelector(`.ni[data-page="${k}"]`,v));const s=document.getElementById('searchInput');if(s)s.placeholder=t.search;setTextForSelector('#sortBtn',t.sort);setTextForSelector('#detailsBtn',t.details);const ft=document.getElementById('ftitle');if(ft)ft.textContent=t.filesTitle;const st=document.querySelector('.od-storage-title');const sx=document.querySelector('.od-storage-text');if(st&&sx){const used=sx.dataset.used||'',quota=sx.dataset.quota||'',pct=sx.dataset.pct||'0';st.textContent=lang==='en'?'Storage':'Almacenamiento';sx.innerHTML=lang==='en'?`<span class="od-storage-used-link" onclick="openLargestFiles()" title="View largest files">${used}</span> <span class="od-storage-rest">used of ${quota} (${pct}%)</span>`:`<span class="od-storage-used-link" onclick="openLargestFiles()" title="Ver archivos más grandes">${used}</span> <span class="od-storage-rest">usados de ${quota} (${pct}%)</span>`;}translateExactText(lang);}


async function logout(){await api('POST','auth/logout');window.location.href='/';}

/* ══ HELPERS ══ */
function H(s){return String(s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');}
function esc(s){return String(s||'').replace(/\\/g,'\\\\').replace(/'/g,"\\'").replace(/"/g,'&quot;');}
function szH(b){b=parseInt(b)||0;const u=['B','KB','MB','GB','TB'];let i=0;while(b>=1024&&i<4){b/=1024;i++;}return b.toFixed(i?1:0)+' '+u[i];}
function fmtD(s){if(!s)return'—';return new Date(s.replace(' ','T')).toLocaleDateString((CURRENT_LANG==='en')?'en-GB':'es-ES',{day:'2-digit',month:'short',year:'numeric'});}
function mIco(m){if(!m)return'📄';if(m.startsWith('image/'))return'🖼️';if(m.startsWith('video/'))return'🎬';if(m.startsWith('audio/'))return'🎵';if(m==='application/pdf')return'📕';if(m.includes('zip')||m.includes('rar')||m.includes('7z'))return'📦';if(m.includes('word')||m.includes('document'))return'📝';if(m.includes('sheet')||m.includes('excel'))return'📊';if(m.includes('presentation'))return'📽️';if(m.startsWith('text/')||m.includes('json'))return'📃';return'📄';}
function setView(v){
  if(S.page==='trash'){
    TS.view=v;
    syncTopbar();
    loadTrash();
    return;
  }
  S.view=v;
  syncTopbar();
  reloadCurrent();
}

/* ══════════════════════════════════════════════════════════════
   DRAG & DROP EXTERNO (subir archivos desde el PC)
   Separado 100% del drag interno con pointer events
   ══════════════════════════════════════════════════════════════ */
// Drag externo gestionado por vault-global-drop.js
// Estas funciones se mantienen por compatibilidad con la tecla Escape
function showDropOverlay(){}
function hideDropOverlay(){document.body.classList.remove('vault-drag-global');}

/* ══ TECLADO ══ */
document.addEventListener('keydown',e=>{
  if(e.key==='Escape'){
    hideDropOverlay();
    if(S.selected.size)clearSelection();
    closeViewer();
    hideCtx();
  }
});
// Exponer funciones necesarias para los módulos JS externos
window.loadFiles=loadFiles;
window.loadTrash=loadTrash;
window.toast=toast;
window.__vaultBulkSel=S.selected;
window.bulkSelectedIds=()=>[...S.selected];
window.bulkClear=clearSelection;
window.bulkUpdate=applySelectionUI;
window.handleFiles=handleFiles;

/* ══ INIT ══ */
window.addEventListener('load',()=>{
  const si=document.getElementById('searchInput');
  if(si){si.value='';document.getElementById('clrBtn').classList.remove('show');}
});
setTimeout(()=>{
  const si=document.getElementById('searchInput');
  if(si&&si.value){si.value='';document.getElementById('clrBtn').classList.remove('show');}
},150);
setThemeIcon(document.documentElement.getAttribute('data-theme')||'light');
applyLanguage(document.documentElement.getAttribute('lang')||'es');
// Limpiar barras al iniciar
document.getElementById('ctxbar')?.classList.remove('show');
document.getElementById('trashSelBar')?.classList.remove('show');
syncTopbar();
loadFiles();
</script>
<script src="/assets/vault-global-drop.js?v=1"></script>
<script src="/assets/vault-pointer-folder-drag.js?v=1"></script>

</body></html>
VIEWEOF
msg_ok "Interfaz principal desplegada"
msg_info "Desplegando move.php y módulos JS"

pct exec "$CT_ID" -- bash -c "mkdir -p /var/www/vault/public/assets"

pct exec "$CT_ID" -- bash -c "cat > /var/www/vault/public/move.php" << 'PHPEOF'
<?php
require_once __DIR__.'/../config/config.php';
require_once __DIR__.'/../src/bootstrap.php';
header('Content-Type: application/json');
header('X-Content-Type-Options: nosniff');
try {
    $user=Auth::requireAuth();$db=Database::getInstance();
    if($_SERVER['REQUEST_METHOD']==='GET'){
        echo json_encode(['ok'=>true,'folders'=>$db->fetchAll("SELECT id,name,parent_id FROM files WHERE user_id=? AND type='folder' AND is_trashed=0 ORDER BY name ASC",[$user['id']])]);exit;
    }
    if($_SERVER['REQUEST_METHOD']!=='POST')throw new ValidationException('Método no válido');
    $body=json_decode(file_get_contents('php://input'),true)?:[];
    $ids=array_values(array_unique(array_filter(array_map('intval',$body['ids']??[]),fn($v)=>$v>0)));
    if(!$ids)throw new ValidationException('No se recibieron elementos para mover');
    $target=$body['parent_id']??null;
    if($target===''||$target===0||$target==='0')$target=null;
    if($target!==null){$target=(int)$target;$folder=$db->fetch("SELECT id FROM files WHERE id=? AND user_id=? AND type='folder' AND is_trashed=0",[$target,$user['id']]);if(!$folder)throw new ValidationException('Carpeta destino no válida');}
    $conflict=$body['conflict']??'error';
    $moved=0;$failed=0;$duplicates=[];$messages=[];
    foreach($ids as $id){
        try{vault_move_item($db,(int)$user['id'],(int)$id,$target,$conflict);$moved++;}
        catch(ValidationException $e){if(str_starts_with($e->getMessage(),'DUPLICATE_NAME:'))$duplicates[]=(int)$id;else{$failed++;$messages[]=$e->getMessage();}}
        catch(Throwable $e){$failed++;$messages[]=$e->getMessage();}
    }
    echo json_encode(['ok'=>true,'moved'=>$moved,'failed'=>$failed,'duplicates'=>$duplicates,'message'=>$messages?implode(' | ',array_unique($messages)):'']);exit;
}catch(AuthException $e){http_response_code(401);echo json_encode(['ok'=>false,'message'=>$e->getMessage()]);}
catch(ValidationException $e){http_response_code(422);echo json_encode(['ok'=>false,'message'=>$e->getMessage()]);}
catch(Throwable $e){http_response_code(500);error_log('[Vault move.php] '.$e->getMessage());echo json_encode(['ok'=>false,'message'=>'Error interno']);}

function vault_move_item(Database $db,int $uid,int $id,$parentId,string $conflict):void{
    $item=$db->fetch("SELECT * FROM files WHERE id=? AND user_id=? AND is_trashed=0",[$id,$uid]);
    if(!$item)throw new ValidationException('Elemento no encontrado');
    if($parentId!==null&&$item['type']==='folder'){
        if((int)$item['id']===(int)$parentId)throw new ValidationException('No puedes mover una carpeta dentro de sí misma');
        $cursor=(int)$parentId;
        while($cursor){$p=$db->fetch("SELECT id,parent_id FROM files WHERE id=? AND user_id=? AND type='folder'",[$cursor,$uid]);if(!$p)break;if((int)$p['id']===(int)$item['id'])throw new ValidationException('No puedes mover una carpeta dentro de una subcarpeta propia');$cursor=$p['parent_id']?(int)$p['parent_id']:null;}
    }
    $newName=$item['name'];$dup=vault_find_dup($db,$uid,$parentId,$newName,$id);
    if($dup){if($conflict==='rename')$newName=vault_unique_name($db,$uid,$parentId,$newName,$id);elseif($conflict==='replace')vault_delete_item($db,$uid,(int)$dup['id']);else throw new ValidationException('DUPLICATE_NAME: Ya existe un elemento con ese nombre en el destino');}
    $db->execute("UPDATE files SET parent_id=?,name=?,original_name=? WHERE id=? AND user_id=?",[$parentId,$newName,$newName,$id,$uid]);
    $db->execute("INSERT INTO activity_log (user_id,action,target,ip) VALUES (?,?,?,?)",[$uid,'move',$newName,$_SERVER['REMOTE_ADDR']??'']);
}
function vault_find_dup(Database $db,int $uid,$parentId,string $name,int $excludeId):?array{
    return $parentId===null?$db->fetch("SELECT * FROM files WHERE user_id=? AND parent_id IS NULL AND name=? AND id<>? AND is_trashed=0",[$uid,$name,$excludeId]):$db->fetch("SELECT * FROM files WHERE user_id=? AND parent_id=? AND name=? AND id<>? AND is_trashed=0",[$uid,$parentId,$name,$excludeId]);
}
function vault_unique_name(Database $db,int $uid,$parentId,string $name,int $excludeId):string{
    $base=$name;$ext='';$dot=strrpos($name,'.');if($dot!==false){$base=substr($name,0,$dot);$ext=substr($name,$dot);}
    $i=2;do{$cand=$base.' ('.$i.')'.$ext;$dup=vault_find_dup($db,$uid,$parentId,$cand,$excludeId);$i++;}while($dup);return $cand;
}
function vault_delete_item(Database $db,int $uid,int $id):void{
    $item=$db->fetch("SELECT * FROM files WHERE id=? AND user_id=?",[$id,$uid]);if(!$item)return;
    if($item['type']==='folder'){foreach($db->fetchAll("SELECT id FROM files WHERE parent_id=? AND user_id=?",[$id,$uid])as $c)vault_delete_item($db,$uid,(int)$c['id']);}
    else{$p=STORAGE_PATH.'/'.$item['path'];if(!empty($item['path'])&&file_exists($p))@unlink($p);if(!empty($item['thumbnail'])){$t=THUMB_PATH.'/'.$item['thumbnail'];if(file_exists($t))@unlink($t);}$db->execute("UPDATE users SET storage_used=GREATEST(0,storage_used-?) WHERE id=?",[(int)$item['size'],$uid]);}
    $db->execute("DELETE FROM files WHERE id=? AND user_id=?",[$id,$uid]);
}
PHPEOF

msg_info "Desplegando módulo drag externo (subida desde PC)"
pct exec "$CT_ID" -- bash -c "cat > /var/www/vault/public/assets/vault-global-drop.js" << 'JSEOF'
(function(){
"use strict";
if(window.__vaultGlobalDropReady)return;
window.__vaultGlobalDropReady=true;
var dragDepth=0;
function isFileDrag(e){if(!e||!e.dataTransfer)return false;var t=Array.prototype.slice.call(e.dataTransfer.types||[]);return t.indexOf("Files")>=0;}
function ensureStyle(){if(document.getElementById("vault-global-drop-style"))return;var s=document.createElement("style");s.id="vault-global-drop-style";s.textContent="body.vault-drag-global::after{content:\"Suelta los archivos para subirlos\";position:fixed;inset:0;z-index:9998;display:grid;place-items:center;background:rgba(15,10,30,.55);color:#fff;font-family:Sora,Inter,system-ui,sans-serif;font-size:24px;font-weight:800;pointer-events:none;backdrop-filter:blur(4px)}body.vault-drag-global::before{content:\"\";position:fixed;inset:34px;z-index:9999;border:3px dashed rgba(255,255,255,.72);border-radius:28px;pointer-events:none}";document.head.appendChild(s);}
function show(){ensureStyle();document.body.classList.add("vault-drag-global");}
function hide(){dragDepth=0;document.body.classList.remove("vault-drag-global");}
window.addEventListener("dragenter",function(e){if(!isFileDrag(e))return;e.preventDefault();e.stopPropagation();dragDepth++;show();},false);
window.addEventListener("dragover",function(e){if(!isFileDrag(e))return;e.preventDefault();e.stopPropagation();if(e.dataTransfer)e.dataTransfer.dropEffect="copy";show();},false);
window.addEventListener("dragleave",function(e){if(!isFileDrag(e))return;e.preventDefault();e.stopPropagation();dragDepth=Math.max(0,dragDepth-1);if(dragDepth===0)document.body.classList.remove("vault-drag-global");},false);
window.addEventListener("drop",function(e){if(!isFileDrag(e))return;e.preventDefault();e.stopPropagation();hide();var files=e.dataTransfer&&e.dataTransfer.files?e.dataTransfer.files:null;if(!files||files.length===0)return;if(typeof window.handleFiles!=="function")return;window.handleFiles(files);},false);
window.addEventListener("blur",hide,false);
document.addEventListener("keydown",function(e){if(e.key==="Escape")hide();},false);
})();
JSEOF

msg_info "Desplegando módulo drag interno (mover tarjetas sobre carpetas)"
pct exec "$CT_ID" -- bash -c "cat > /var/www/vault/public/assets/vault-pointer-folder-drag.js" << 'JSEOF'
(function(){
"use strict";
var state=null;var suppressNextClick=false;
function qs(s){return document.querySelector(s);}
function qsa(s){return Array.prototype.slice.call(document.querySelectorAll(s));}
function toastSafe(m,t){if(typeof window.toast==="function")window.toast(m,t||"success");else console.log("[Vault]",m);}
function selectedIds(){if(typeof window.bulkSelectedIds==="function")return window.bulkSelectedIds().map(function(x){return parseInt(x,10);}).filter(Boolean);if(window.__vaultBulkSel instanceof Set)return Array.from(window.__vaultBulkSel).map(function(x){return parseInt(x,10);}).filter(Boolean);return[];}
function clearSel(){if(typeof window.bulkClear==="function")window.bulkClear();else if(window.__vaultBulkSel instanceof Set)window.__vaultBulkSel.clear();if(typeof window.bulkUpdate==="function")window.bulkUpdate();}
function cleanVisuals(){document.body.classList.remove("vault-pointer-dragging");qsa(".vault-pointer-drop-target").forEach(function(el){el.classList.remove("vault-pointer-drop-target");});var g=qs("#vaultPointerMoveGhost");if(g)g.remove();}
function cardId(c){return c?parseInt(c.getAttribute("data-id")||"0",10):0;}
function isFolderCard(c){if(!c)return false;return c.getAttribute("data-type")==="folder"||/\bcarpeta\b/i.test(c.innerText||"");}
function isInteractive(el){return!!(el&&el.closest&&el.closest("button,.fab,.selcheck,.rsel,a,input,select,textarea"));}
function ensureStyle(){if(qs("#vault-pfsd-style"))return;var s=document.createElement("style");s.id="vault-pfsd-style";s.textContent=".fc,.fr,.fc img,.fr img{-webkit-user-drag:none!important;user-drag:none!important}body.vault-pointer-dragging{user-select:none!important;cursor:grabbing!important}#vaultPointerMoveGhost{position:fixed;z-index:100002;pointer-events:none;padding:10px 14px;border-radius:14px;background:linear-gradient(135deg,#6d5dfc,#d946a0);color:#fff;font-family:Inter,system-ui,sans-serif;font-weight:900;box-shadow:0 16px 40px rgba(31,25,51,.30);transform:translate(14px,14px)}.fc.vault-pointer-drop-target{outline:3px dashed rgba(109,93,252,.92)!important;outline-offset:-7px!important;box-shadow:0 20px 54px rgba(109,93,252,.30)!important;transform:translateY(-3px)!important}.fc.vault-pointer-drop-target::after{content:\"Mover aquí\";position:absolute;left:12px;right:12px;bottom:12px;z-index:95;background:linear-gradient(135deg,#6d5dfc,#d946a0);color:white;border-radius:12px;padding:9px 10px;text-align:center;font-weight:900;pointer-events:none}";document.head.appendChild(s);}
function conflictModal(count){ensureStyle();return new Promise(function(resolve){var o=qs("#vaultPFDConflict");if(!o){o=document.createElement("div");o.id="vaultPFDConflict";o.style.cssText="position:fixed;inset:0;z-index:100003;display:none;align-items:center;justify-content:center;background:rgba(31,25,51,.42);backdrop-filter:blur(5px)";o.innerHTML='<div style="width:500px;max-width:calc(100vw - 36px);background:#fff;border-radius:20px;box-shadow:0 24px 80px rgba(31,25,51,.26);padding:24px;font-family:Inter,system-ui,sans-serif;color:#1f1933"><div style="font-size:32px;margin-bottom:10px">⚠️</div><h3 style="font-size:18px;font-weight:900;margin:0 0 8px">Ya existe un elemento con ese nombre</h3><p id="vaultPFDConflictText" style="font-size:14px;color:#625a7f;margin:0 0 20px;line-height:1.5"></p><div style="display:flex;justify-content:flex-end;gap:10px;flex-wrap:wrap"><button id="vaultPFDCancel" style="border:1px solid rgba(109,93,252,.2);border-radius:12px;padding:10px 14px;background:#f4f1ff;color:#5543b7;font-weight:800;cursor:pointer">Cancelar</button><button id="vaultPFDRename" style="border:none;border-radius:12px;padding:10px 14px;background:linear-gradient(135deg,#6d5dfc,#8b5cf6);color:#fff;font-weight:800;cursor:pointer">Mantener ambos</button><button id="vaultPFDReplace" style="border:none;border-radius:12px;padding:10px 14px;background:linear-gradient(135deg,#f43f8f,#d946a0);color:#fff;font-weight:800;cursor:pointer">Reemplazar</button></div></div>';document.body.appendChild(o);}
qs("#vaultPFDConflictText").textContent=count===1?"En la carpeta destino ya existe un elemento con el mismo nombre.":"Algunos elementos ya existen en la carpeta destino.";
function close(v){o.style.display="none";qs("#vaultPFDCancel").onclick=null;qs("#vaultPFDRename").onclick=null;qs("#vaultPFDReplace").onclick=null;o.onclick=null;document.onkeydown=null;resolve(v);}
qs("#vaultPFDCancel").onclick=function(){close("cancel");};qs("#vaultPFDRename").onclick=function(){close("rename");};qs("#vaultPFDReplace").onclick=function(){close("replace");};
o.onclick=function(e){if(e.target===o)close("cancel");};document.onkeydown=function(e){if(e.key==="Escape")close("cancel");};
o.style.display="flex";setTimeout(function(){qs("#vaultPFDRename").focus();},50);});}
async function doMove(ids,targetId,conflict){cleanVisuals();var r=await fetch("/move.php",{method:"POST",credentials:"same-origin",headers:{"Content-Type":"application/json"},body:JSON.stringify({ids:ids,parent_id:targetId,conflict:conflict||"error"})});var d=await r.json();if(!d.ok){toastSafe(d.message||"No se pudo mover","error");return;}if(d.duplicates&&d.duplicates.length&&(!conflict||conflict==="error")){var dec=await conflictModal(d.duplicates.length);if(dec==="rename"||dec==="replace"){await doMove(d.duplicates,targetId,dec);return;}if(d.moved>0)toastSafe(d.moved+" movido(s). Los duplicados se cancelaron.","error");}else{if(d.moved>0&&d.failed===0)toastSafe(d.moved+" elemento(s) movido(s)","success");else if(d.moved>0)toastSafe(d.moved+" movido(s), "+d.failed+" con error","error");else toastSafe(d.message||"No se pudo mover","error");}clearSel();if(typeof window.loadFiles==="function")window.loadFiles();}
function ghost(count,x,y){var g=qs("#vaultPointerMoveGhost");if(!g){g=document.createElement("div");g.id="vaultPointerMoveGhost";document.body.appendChild(g);}g.textContent=count+" elemento"+(count===1?"":"s");g.style.left=x+"px";g.style.top=y+"px";}
function folderAt(x,y){var g=qs("#vaultPointerMoveGhost");if(g)g.style.display="none";var el=document.elementFromPoint(x,y);if(g)g.style.display="";if(!el)return null;var c=el.closest(".fc[data-id]");if(!c||!isFolderCard(c))return null;return c;}
function beginDrag(e,card){var id=cardId(card);if(!id)return;var sel=selectedIds();var ids=sel.indexOf(id)>=0?sel:[id];state={pointerId:e.pointerId,card:card,id:id,ids:ids,startX:e.clientX,startY:e.clientY,active:false};}
async function finishDrag(x,y){if(!state)return;var cur=state;state=null;if(!cur.active){cleanVisuals();return;}var target=folderAt(x,y);cleanVisuals();if(!target)return;var targetId=cardId(target);if(!targetId)return;if(cur.ids.indexOf(targetId)>=0){toastSafe("No puedes mover una carpeta dentro de sí misma","error");return;}await doMove(cur.ids,targetId,"error");}
function boot(){ensureStyle();cleanVisuals();
document.addEventListener("dragstart",function(e){if(e.target&&e.target.closest&&e.target.closest(".fc,.fr")){e.preventDefault();e.stopPropagation();cleanVisuals();return false;}},true);
document.addEventListener("pointerdown",function(e){if(e.button!==0)return;if(isInteractive(e.target))return;var card=e.target.closest&&e.target.closest(".fc[data-id]");if(!card)return;beginDrag(e,card);},true);
document.addEventListener("pointermove",function(e){if(!state)return;var dx=Math.abs(e.clientX-state.startX),dy=Math.abs(e.clientY-state.startY);if(!state.active&&(dx>10||dy>10)){state.active=true;suppressNextClick=true;document.body.classList.add("vault-pointer-dragging");ghost(state.ids.length,e.clientX,e.clientY);}if(!state.active)return;e.preventDefault();e.stopPropagation();var g=qs("#vaultPointerMoveGhost");if(g){g.style.left=e.clientX+"px";g.style.top=e.clientY+"px";}qsa(".vault-pointer-drop-target").forEach(function(el){el.classList.remove("vault-pointer-drop-target");});var t=folderAt(e.clientX,e.clientY);if(t)t.classList.add("vault-pointer-drop-target");},true);
document.addEventListener("pointerup",function(e){if(!state)return;e.preventDefault();e.stopPropagation();finishDrag(e.clientX,e.clientY);},true);
document.addEventListener("click",function(e){if(!suppressNextClick)return;e.preventDefault();e.stopPropagation();suppressNextClick=false;},true);
window.addEventListener("blur",function(){state=null;cleanVisuals();},true);
document.addEventListener("keydown",function(e){if(e.key==="Escape"){state=null;cleanVisuals();}},true);
setInterval(function(){qsa(".fc,.fr,.fc img,.fr img").forEach(function(el){el.setAttribute("draggable","false");});},700);}
if(document.readyState==="loading")document.addEventListener("DOMContentLoaded",boot);else boot();
})();
JSEOF

msg_ok "Módulos JS desplegados (drag externo, drag interno)"
pct exec "$CT_ID" -- bash -c "
chown -R www-data:www-data /var/www/vault
find /var/www/vault -type d -exec chmod 755 {} \;
find /var/www/vault -type f -exec chmod 644 {} \;
chmod 750 /var/www/vault/config
chmod 640 /var/www/vault/config/config.php
chmod -R 775 /var/www/vault/storage /var/www/vault/logs
chmod -R 775 /var/www/vault/storage/tmp_chunks
systemctl restart apache2
" || msg_error "Falló la configuración final"

if pct exec "$CT_ID" -- bash -c "systemctl is-active apache2" 2>/dev/null | grep -q active; then
  msg_ok "Apache activo y funcionando"
else
  msg_error "Apache no se inició correctamente"
fi

# Script de Cloudflare Tunnel
msg_info "Instalando script de Cloudflare Tunnel"
pct exec "$CT_ID" -- bash -c "cat > /root/setup-cloudflare-tunnel.sh" << 'TUNNELEOF'
#!/bin/bash
set -e
echo '=== Vault — Cloudflare Tunnel ==='
echo 'Instalando cloudflared...'
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' | tee /etc/apt/sources.list.d/cloudflared.list
apt-get update -qq && apt-get install -y -qq cloudflared
echo 'Autenticando con Cloudflare (abre la URL que aparezca)...'
cloudflared tunnel login
read -rp 'Nombre del tunnel [vault]: ' TN; TN=${TN:-vault}
cloudflared tunnel create "$TN"
TID=$(cloudflared tunnel list | grep "$TN" | awk '{print $1}')
read -rp 'Subdominio (ej: cloud): ' SUB; SUB=${SUB:-cloud}
read -rp 'Dominio (ej: midominio.com): ' DOM
mkdir -p /etc/cloudflared
cat > /etc/cloudflared/config.yml << CFGEOF
tunnel: $TID
credentials-file: /root/.cloudflared/$TID.json
ingress:
  - hostname: $SUB.$DOM
    service: http://localhost:80
  - service: http_status:404
CFGEOF
cloudflared tunnel route dns "$TN" "$SUB.$DOM"
cloudflared service install
systemctl enable cloudflared && systemctl start cloudflared
echo ""
echo "Tunnel activo. Accede a: https://$SUB.$DOM"
TUNNELEOF
pct exec "$CT_ID" -- chmod +x /root/setup-cloudflare-tunnel.sh
msg_ok "Script de Cloudflare Tunnel instalado"

# IP final
sleep 2
CT_IP_FINAL=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}')

# Guardar credenciales
pct exec "$CT_ID" -- bash -c "cat > /root/vault-credentials.txt << CREDEOF
Vault — Credenciales
====================
URL local:   http://${CT_IP_FINAL}
Admin user:  ${ADMIN_USER}
Admin pass:  ${ADMIN_PASS}
Admin email: ${ADMIN_EMAIL}
====================
Cloudflare Tunnel: bash /root/setup-cloudflare-tunnel.sh
CREDEOF
chmod 600 /root/vault-credentials.txt"

# Resumen final
clear
echo -e "${BL}"
cat << 'BANNER'
   __      __    _ _
   \ \    / /_ _| | |_
    \ \/\/ / _` | |  _|
     \_/\_/\__,_|_|\__|

BANNER
echo -e "${CL}"
echo -e " ${CM} ${GN}Vault instalado correctamente${CL}"
echo -e " ${BL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}\n"
echo -e "  ${YW}Acceso local:${CL}    http://${CT_IP_FINAL}"
echo -e "  ${YW}LXC:${CL}             #${CT_ID} (${CT_HOSTNAME})"
echo -e "  ${YW}Admin:${CL}           ${ADMIN_USER} / ${ADMIN_PASS}"
echo ""
echo -e "  ${YW}Acceso externo (HTTPS con dominio propio):${CL}"
echo -e "    pct exec ${CT_ID} -- bash /root/setup-cloudflare-tunnel.sh"
echo ""
echo -e "  ${YW}Entrar al contenedor:${CL}  pct exec ${CT_ID} -- bash"
echo -e "  ${YW}Credenciales guardadas:${CL} /root/vault-credentials.txt (dentro del LXC)"
echo -e "\n ${BL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}\n"
