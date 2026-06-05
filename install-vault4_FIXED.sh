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
define('APP_VERSION', '2.0.0');
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
  theme ENUM('dark','light') DEFAULT 'dark',
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
SQLEOF
mysql vault < /tmp/schema.sql
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

pct exec "$CT_ID" -- bash -c "cat > /var/www/vault/src/auth/Auth.php" << 'PHPEOF'
<?php
class Auth {
    public static function check():bool{return isset($_SESSION['user_id'])&&!empty($_SESSION['user_id'])&&empty($_SESSION['totp_pending']);}
    public static function user():?array{if(!self::check())return null;return Database::getInstance()->fetch("SELECT id,username,email,display_name,role,storage_quota,storage_used,totp_enabled,theme FROM users WHERE id=? AND active=1",[$_SESSION['user_id']]);}
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
    private static function finalizeLogin(array $u):void{session_regenerate_id(true);$_SESSION['user_id']=$u['id'];$_SESSION['user_role']=$u['role'];$db=Database::getInstance();$db->execute("UPDATE users SET last_login=NOW() WHERE id=?",[$u['id']]);$db->execute("INSERT INTO activity_log (user_id,action,ip) VALUES (?,?,?)",[$u['id'],'login',$_SERVER['REMOTE_ADDR']??'']);}
    public static function logout():void{if(self::check()){Database::getInstance()->execute("INSERT INTO activity_log (user_id,action,ip) VALUES (?,?,?)",[$_SESSION['user_id'],'logout',$_SERVER['REMOTE_ADDR']??'']);}$_SESSION=[];session_destroy();}
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
    public static function isConfigured():bool{
        return defined('SMTP_HOST') && SMTP_HOST !== '';
    }
    public static function send(string $to,string $subject,string $htmlBody,string $textBody=''):bool{
        if(!self::isConfigured())return false;
        $from=SMTP_FROM?:SMTP_USER;
        $appName=defined('APP_NAME')?APP_NAME:'Vault';
        if($textBody==='')$textBody=trim(strip_tags(str_replace(['<br>','</p>','</div>'],"\n",$htmlBody)));
        $eol="\r\n";
        $boundary='vault_'.md5(uniqid((string)mt_rand(),true));
        $domain=substr(strrchr($from,'@'),1)?:'localhost';
        $headers ='From: '.self::encodeHeader($appName).' <'.$from.'>'.$eol;
        $headers.='Reply-To: '.$from.$eol;
        $headers.='Return-Path: '.$from.$eol;
        $headers.='Message-ID: <'.$boundary.'@'.$domain.'>'.$eol;
        $headers.='Date: '.date('r').$eol;
        $headers.='X-Mailer: '.$appName.$eol;
        $headers.='MIME-Version: 1.0'.$eol;
        $headers.='Content-Type: multipart/alternative; boundary="'.$boundary.'"'.$eol;
        $body ='--'.$boundary.$eol;
        $body.='Content-Type: text/plain; charset=UTF-8'.$eol;
        $body.='Content-Transfer-Encoding: 8bit'.$eol.$eol;
        $body.=$textBody.$eol.$eol;
        $body.='--'.$boundary.$eol;
        $body.='Content-Type: text/html; charset=UTF-8'.$eol;
        $body.='Content-Transfer-Encoding: 8bit'.$eol.$eol;
        $body.=$htmlBody.$eol.$eol;
        $body.='--'.$boundary.'--'.$eol;
        return @mail($to,self::encodeHeader($subject),$body,$headers,'-f'.$from);
    }
    private static function encodeHeader(string $s):string{
        return preg_match('/[\x80-\xff]/',$s)?'=?UTF-8?B?'.base64_encode($s).'?=':$s;
    }
    public static function sendShare(string $to,string $sender,string $url,string $filename,bool $isFolder=false):bool{
        $appName=defined('APP_NAME')?APP_NAME:'Vault';
        $u=htmlspecialchars($url,ENT_QUOTES);
        $n=htmlspecialchars($filename,ENT_QUOTES);
        $s=htmlspecialchars($sender,ENT_QUOTES);
        $tipo=$isFolder?'una carpeta':'un archivo';
        $subject=$sender.' ha compartido '.$tipo.' contigo';
        $textBody="Hola,\n\n".$sender.' ha compartido '.$tipo.' contigo a traves de '.$appName.': "'.$filename."\".\n\nPuedes acceder desde este enlace:\n".$url."\n\nSi no esperabas este mensaje, puedes ignorarlo.\n\n-- \n".$appName;
        $html='<!DOCTYPE html><html lang="es"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>'
            .'<body style="margin:0;padding:0;background:#f4f3fb;font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif">'
            .'<div style="max-width:520px;margin:0 auto;padding:32px 20px">'
            .'<div style="text-align:center;margin-bottom:24px"><span style="font-size:20px;font-weight:bold;color:#6366f1">'.htmlspecialchars($appName).'</span></div>'
            .'<div style="background:#ffffff;border:1px solid #e6e4f0;border-radius:16px;padding:32px">'
            .'<p style="font-size:16px;line-height:1.6;color:#1a1530;margin:0 0 20px">Hola,</p>'
            .'<p style="font-size:16px;line-height:1.6;color:#1a1530;margin:0 0 24px"><strong>'.$s.'</strong> ha compartido '.$tipo.' contigo: <strong>'.$n.'</strong></p>'
            .'<div style="text-align:center;margin:28px 0"><a href="'.$u.'" style="display:inline-block;background:#6366f1;color:#ffffff;text-decoration:none;padding:13px 30px;border-radius:10px;font-weight:bold;font-size:15px">Ver '.($isFolder?'carpeta':'archivo').'</a></div>'
            .'<p style="font-size:13px;color:#6b6489;line-height:1.6;margin:24px 0 0">Si el boton no funciona, copia y pega este enlace en tu navegador:<br><a href="'.$u.'" style="color:#6366f1;word-break:break-all">'.$u.'</a></p>'
            .'</div>'
            .'<p style="font-size:12px;color:#9d97b5;text-align:center;margin:20px 0 0">Si no esperabas este mensaje, puedes ignorarlo con seguridad.</p>'
            .'</div></body></html>';
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
        $sql="SELECT id,name,type,mime_type,size,thumbnail,is_starred,created_at,updated_at FROM files WHERE user_id=? AND is_trashed=0 AND ".($pid?"parent_id=?":"parent_id IS NULL")." ORDER BY type='folder' DESC, name ASC";
        return $this->db->fetchAll($sql,$pid?[$uid,$pid]:[$uid]);
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
        return $this->db->fetch("SELECT * FROM files WHERE id=? AND user_id=? AND is_trashed=0",[$id,$uid]);
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
    public function search(int $uid,string $q):array{return $this->db->fetchAll("SELECT id,name,type,mime_type,size,thumbnail,created_at FROM files WHERE user_id=? AND is_trashed=0 AND name LIKE ? ORDER BY type DESC,name ASC LIMIT 50",[$uid,"%$q%"]);}
    public function createShare(int $uid,int $fid,?string $pass,?string $exp,?int $maxdl):string{
        $f=$this->db->fetch("SELECT id FROM files WHERE id=? AND user_id=? AND is_trashed=0",[$fid,$uid]);if(!$f)throw new NotFoundException('No encontrado');
        $tok=bin2hex(random_bytes(16));$hp=$pass?password_hash($pass,PASSWORD_BCRYPT):null;
        $this->db->execute("INSERT INTO shares (file_id,user_id,token,password,expires_at,max_downloads) VALUES (?,?,?,?,?,?)",[$fid,$uid,$tok,$hp,$exp,$maxdl]);
        return $tok;
    }
    public function getShares(int $uid):array{return $this->db->fetchAll("SELECT s.*,f.name,f.type,f.size FROM shares s JOIN files f ON s.file_id=f.id WHERE s.user_id=? ORDER BY s.created_at DESC",[$uid]);}
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
        if($m==='GET'&&$a==='starred'){$f=Database::getInstance()->fetchAll("SELECT id,name,type,mime_type,size,thumbnail,created_at FROM files WHERE user_id=? AND is_starred=1 AND is_trashed=0 ORDER BY name",[$u['id']]);echo json_encode(['ok'=>true,'files'=>$f]);}
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
        if(empty($_FILES['file']))throw new ValidationException('No se recibió archivo');
        $pid=isset($_POST['folder_id'])&&$_POST['folder_id']!==''?(int)$_POST['folder_id']:null;
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
        elseif($m==='POST'){$d=$this->json();$tok=$fm->createShare($u['id'],(int)($d['file_id']??0),$d['password']??null,$d['expires_at']??null,isset($d['max_downloads'])&&$d['max_downloads']?(int)$d['max_downloads']:null);echo json_encode(['ok'=>true,'token'=>$tok,'url'=>self::baseUrl().'/s/'.$tok,'smtp'=>Mailer::isConfigured()]);}
        elseif($m==='DELETE'&&$id){$fm->deleteShare($u['id'],$id);echo json_encode(['ok'=>true]);}
        else throw new NotFoundException('Acción inválida');
    }
    private static function baseUrl():string{
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
        if($m==='GET'){echo json_encode(['ok'=>true,'files'=>$db->fetchAll("SELECT id,name,type,mime_type,size,trashed_at FROM files WHERE user_id=? AND is_trashed=1 ORDER BY trashed_at DESC",[$u['id']])]);}
        elseif($m==='POST'&&$id){$fm->restore($u['id'],$id);echo json_encode(['ok'=>true]);}
        elseif($m==='DELETE'&&$id){$fm->delete($u['id'],$id);echo json_encode(['ok'=>true]);}
        elseif($m==='DELETE'&&!$id){foreach($db->fetchAll("SELECT id FROM files WHERE user_id=? AND is_trashed=1",[$u['id']]) as $it)$fm->delete($u['id'],$it['id']);echo json_encode(['ok'=>true]);}
        else throw new NotFoundException('Acción inválida');
    }
    private function user(string $m,string $a):void{
        $u=Auth::requireAuth();$db=Database::getInstance();
        if($m==='POST'&&$a==='password'){$d=$this->json();$c=$db->fetch("SELECT password FROM users WHERE id=?",[$u['id']]);if(!password_verify($d['current']??'',$c['password']))throw new ValidationException('Contraseña actual incorrecta');$db->execute("UPDATE users SET password=? WHERE id=?",[password_hash($d['new']??'',PASSWORD_BCRYPT,['cost'=>12]),$u['id']]);echo json_encode(['ok'=>true]);}
        elseif($m==='POST'&&$a==='profile'){$d=$this->json();$db->execute("UPDATE users SET display_name=?,email=? WHERE id=?",[$d['display_name']??$u['display_name'],$d['email']??$u['email'],$u['id']]);echo json_encode(['ok'=>true]);}
        elseif($m==='POST'&&$a==='theme'){$d=$this->json();$t=($d['theme']??'dark')==='light'?'light':'dark';$db->execute("UPDATE users SET theme=? WHERE id=?",[$t,$u['id']]);echo json_encode(['ok'=>true,'theme'=>$t]);}
        elseif($m==='GET'&&$a==='totp-setup'){$s=Auth::totpGenerateSecret();$_SESSION['totp_setup_secret']=$s;echo json_encode(['ok'=>true,'secret'=>$s,'qr'=>Auth::totpQrUrl($s,$u['username'],APP_NAME)]);}
        elseif($m==='POST'&&$a==='totp-enable'){$d=$this->json();$s=$_SESSION['totp_setup_secret']??null;if(!$s)throw new ValidationException('Sesión de configuración expirada. Recarga la página e inténtalo de nuevo.');if(!Auth::totpVerify($s,$d['code']??''))throw new ValidationException('Código incorrecto. Verifica que la hora de tu teléfono esté sincronizada.');$bp=Auth::generateBackupCodes();$db->execute("UPDATE users SET totp_secret=?,totp_enabled=1,totp_backup=? WHERE id=?",[$s,json_encode(array_map(fn($c)=>hash('sha256',$c),$bp)),$u['id']]);unset($_SESSION['totp_setup_secret']);echo json_encode(['ok'=>true,'backup_codes'=>$bp]);}
        elseif($m==='POST'&&$a==='totp-disable'){$d=$this->json();$c=$db->fetch("SELECT password FROM users WHERE id=?",[$u['id']]);if(!password_verify($d['password']??'',$c['password']))throw new ValidationException('Contraseña incorrecta');$db->execute("UPDATE users SET totp_secret=NULL,totp_enabled=0,totp_backup=NULL WHERE id=?",[$u['id']]);echo json_encode(['ok'=>true]);}
        else throw new NotFoundException('Acción inválida');
    }
    private function admin(string $m,string $a,?int $id):void{
        Auth::requireAdmin();$db=Database::getInstance();
        if($a==='users'&&$m==='GET'){echo json_encode(['ok'=>true,'users'=>$db->fetchAll("SELECT id,username,email,display_name,role,storage_quota,storage_used,active,last_login,created_at FROM users ORDER BY created_at DESC")]);}
        elseif($a==='users'&&$m==='POST'){$d=$this->json();$h=password_hash($d['password']??'changeme',PASSWORD_BCRYPT,['cost'=>12]);$nid=$db->execute("INSERT INTO users (username,email,password,display_name,role,storage_quota) VALUES (?,?,?,?,?,?)",[$d['username'],$d['email'],$h,$d['display_name']??$d['username'],$d['role']??'user',(int)($d['storage_quota']??10737418240)]);@mkdir(STORAGE_PATH."/$nid",0750,true);echo json_encode(['ok'=>true,'id'=>$nid]);}
        elseif($a==='users'&&$m==='DELETE'&&$id){$me=Auth::user();if($id===$me['id'])throw new ValidationException('No puedes eliminar tu propio usuario');$db->execute("DELETE FROM users WHERE id=?",[$id]);echo json_encode(['ok'=>true]);}
        elseif($a==='users'&&$m==='PATCH'&&$id){$d=$this->json();
            // Editar cuota y/o rol
            if(isset($d['storage_quota'])){$db->execute("UPDATE users SET storage_quota=? WHERE id=?",[(int)$d['storage_quota'],$id]);}
            if(isset($d['role'])&&in_array($d['role'],['admin','user'])){$db->execute("UPDATE users SET role=? WHERE id=?",[$d['role'],$id]);}
            echo json_encode(['ok'=>true]);}
        elseif($a==='stats'&&$m==='GET'){echo json_encode(['ok'=>true,'stats'=>['users'=>$db->fetch("SELECT COUNT(*) c FROM users")['c'],'files'=>$db->fetch("SELECT COUNT(*) c FROM files WHERE type='file' AND is_trashed=0")['c'],'total_size'=>$db->fetch("SELECT COALESCE(SUM(storage_used),0) s FROM users")['s'],'shares'=>$db->fetch("SELECT COUNT(*) c FROM shares")['c']]]);}
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
    if(!$uid||$total<1||$fsize<1)throw new ValidationException('Parámetros inválidos');
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
    $tn=null;if(str_starts_with($mime,'image/')&&function_exists('imagecreatefromstring')){$fmo=new FileManager();$tn=$fmo->makeThumb($finalPath,$u['id'],$sn);}
    $fid=$db->execute('INSERT INTO files (user_id,parent_id,name,original_name,type,mime_type,size,path,thumbnail) VALUES (?,?,?,?,?,?,?,?,?)',[$u['id'],$pid,$sname,$fname,'file',$mime,$realSize,$rp,$tn]);
    $db->execute('UPDATE users SET storage_used=storage_used+? WHERE id=?',[$realSize,$u['id']]);
    for($i=0;$i<$total;$i++){@unlink($dir.'/chunk_'.str_pad((string)$i,6,'0',STR_PAD_LEFT));}@rmdir($dir);
    $tmpBase=CHUNK_TMP_PATH.'/'.$u['id'];
    if(is_dir($tmpBase))foreach(scandir($tmpBase)as $entry){if($entry==='.'||$entry==='..')continue;$d2=$tmpBase.'/'.$entry;if(is_dir($d2)&&filemtime($d2)<time()-86400){$fs2=glob($d2.'/*');if($fs2)foreach($fs2 as $f2)@unlink($f2);@rmdir($d2);}}
    echo json_encode(['ok'=>true,'id'=>$fid,'name'=>$sname,'size'=>$realSize,'mime_type'=>$mime]);
}
    private function json():array{return json_decode(file_get_contents('php://input'),true)??[];}
}
PHPEOF
msg_ok "Enrutador API desplegado"
msg_info "Creando puntos de entrada"

pct exec "$CT_ID" -- bash -c "
cat > /var/www/vault/public/index.php << 'PHPEOF'
<?php
require_once __DIR__.'/../config/config.php';
require_once __DIR__.'/../src/bootstrap.php';
if(!empty(\$_SESSION['totp_pending'])&&empty(\$_SESSION['user_id'])){require __DIR__.'/../src/views/totp.php';exit;}
if(!Auth::check()){require __DIR__.'/../src/views/login.php';exit;}
\$user=Auth::user();
require __DIR__.'/../src/views/app.php';
PHPEOF

cat > /var/www/vault/public/api.php << 'PHPEOF'
<?php
require_once __DIR__.'/../config/config.php';
require_once __DIR__.'/../src/bootstrap.php';
\$route=\$_GET['route']??'';
\$method=\$_SERVER['REQUEST_METHOD'];
// Las rutas de streaming/descarga NO envían JSON header
\$isStream=preg_match('#^(view|download|thumb|bulk-download|upload-chunk|upload-complete)/?#',\$route);
if(!\$isStream)header('Content-Type: application/json');
header('X-Content-Type-Options: nosniff');
try{(new Router())->dispatch(\$method,\$route);}
catch(AuthException \$e){http_response_code(401);echo json_encode(['ok'=>false,'error'=>'No autorizado','message'=>\$e->getMessage()]);}
catch(NotFoundException \$e){http_response_code(404);echo json_encode(['ok'=>false,'error'=>'No encontrado','message'=>\$e->getMessage()]);}
catch(ValidationException \$e){http_response_code(422);echo json_encode(['ok'=>false,'error'=>'Validación','message'=>\$e->getMessage()]);}
catch(Throwable \$e){http_response_code(500);error_log('[Vault] '.\$e->getMessage());echo json_encode(['ok'=>false,'error'=>'Error interno']);}
PHPEOF

cat > /var/www/vault/public/share.php << 'PHPEOF'
<?php
require_once __DIR__.'/../config/config.php';
require_once __DIR__.'/../src/bootstrap.php';
\$token=\$_GET['token']??'';
if(!\$token){http_response_code(404);die('Link no válido');}
\$db=Database::getInstance();
\$share=\$db->fetch('SELECT s.*,f.name,f.type,f.size,f.mime_type,f.path,u.display_name as owner_name FROM shares s JOIN files f ON s.file_id=f.id JOIN users u ON s.user_id=u.id WHERE s.token=? AND f.is_trashed=0',[\$token]);
if(!\$share){http_response_code(404);die('Link no válido o expirado');}
if(\$share['expires_at']&&strtotime(\$share['expires_at'])<time()){http_response_code(410);die('Link expirado');}
if(\$share['max_downloads']&&\$share['downloads']>=\$share['max_downloads']){http_response_code(410);die('Límite de descargas alcanzado');}
// Autenticación: sin contraseña = acceso directo; con contraseña = validar y recordar en sesión
\$sessionKey='share_auth_'.\$token;
\$authenticated=!\$share['password'];
if(\$share['password']){
    if(!empty(\$_SESSION[\$sessionKey])){\$authenticated=true;}
    elseif(isset(\$_POST['share_pass'])){
        if(password_verify(\$_POST['share_pass'],\$share['password'])){\$authenticated=true;\$_SESSION[\$sessionKey]=true;}
        else{\$passError=true;}
    }
}
// Descarga / streaming (solo si está autenticado)
if(\$authenticated&&isset(\$_GET['dl'])){
    if(empty(\$_GET['preview'])){\$db->execute('UPDATE shares SET downloads=downloads+1 WHERE token=?',[\$token]);}
    if(\$share['type']==='folder'){
        // Carpeta compartida -> servir como ZIP
        \$fm=new FileManager();
        \$zipPath=\$fm->zipFolder(\$share['user_id'],\$share['file_id'],\$share['name']);
        \$zipName=preg_replace('/[\/\\\\\\\\:*?\"<>|]/','_',\$share['name']).'.zip';
        header('Content-Type: application/zip');
        header('Content-Disposition: attachment; filename=\"'.rawurlencode(\$zipName).'\"');
        header('Content-Length: '.filesize(\$zipPath));
        readfile(\$zipPath);@unlink(\$zipPath);exit;
    }
    \$fp=STORAGE_PATH.'/'.\$share['path'];
    if(!file_exists(\$fp)){http_response_code(404);die('Archivo no encontrado');}
    \$inline=!empty(\$_GET['preview']);
    FileManager::streamFile(\$fp,\$share['mime_type']?:'application/octet-stream',\$inline);
}
require __DIR__.'/../src/views/share.php';
PHPEOF

cat > /var/www/vault/public/.htaccess << 'HTEOF'
RewriteEngine On
RewriteBase /
RewriteCond %{REQUEST_FILENAME} -f [OR]
RewriteCond %{REQUEST_FILENAME} -d
RewriteRule ^ - [L]
RewriteRule ^api/(.*)\$ api.php?route=\$1 [L,QSA]
RewriteRule ^s/([a-zA-Z0-9]+)\$ share.php?token=\$1 [L,QSA]
RewriteRule ^ index.php [L]
Options -Indexes
Header always set X-Content-Type-Options nosniff
Header always set X-Frame-Options SAMEORIGIN
HTEOF
" || msg_error "Falló la creación de puntos de entrada"
msg_ok "Puntos de entrada creados"
msg_info "Desplegando vistas (login, 2FA, compartir)"

pct exec "$CT_ID" -- bash -c "cat > /var/www/vault/src/views/login.php" << 'VIEWEOF'
<?php $appName=APP_NAME;?><!DOCTYPE html><html lang="es"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title><?=h($appName)?> — Acceder</title><style>
@import url('https://fonts.googleapis.com/css2?family=Sora:wght@400;600;700;800&family=Inter:wght@300;400;500;600&display=swap');
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Inter',sans-serif;background:#0f0a1e;color:#ECEAF5;min-height:100vh;display:flex;align-items:center;justify-content:center;overflow:hidden;padding:20px}
.bg{position:fixed;inset:0;z-index:0;overflow:hidden}
.orb{position:absolute;border-radius:50%;filter:blur(90px);opacity:.5;animation:float 12s ease-in-out infinite}
.o1{width:600px;height:600px;background:radial-gradient(circle,#6366f1,transparent 70%);top:-150px;left:-100px}
.o2{width:500px;height:500px;background:radial-gradient(circle,#ec4899,transparent 70%);bottom:-120px;right:-80px;animation-delay:-4s}
.o3{width:400px;height:400px;background:radial-gradient(circle,#8b5cf6,transparent 70%);top:40%;left:50%;transform:translate(-50%,-50%);animation-delay:-8s}
@keyframes float{0%,100%{transform:translateY(0) scale(1)}50%{transform:translateY(-40px) scale(1.08)}}
.card{position:relative;z-index:2;width:100%;max-width:410px;background:rgba(22,18,40,.7);border:1px solid rgba(255,255,255,.1);border-radius:26px;padding:46px 40px;box-shadow:0 40px 100px rgba(0,0,0,.6),inset 0 1px 0 rgba(255,255,255,.08);backdrop-filter:blur(20px)}
.brand{text-align:center;margin-bottom:36px}
.shield-logo{width:68px;height:68px;margin:0 auto 18px;position:relative}
.shield-glow{position:absolute;inset:-8px;background:linear-gradient(135deg,#6366f1,#ec4899);border-radius:20px;filter:blur(16px);opacity:.55;animation:pulse 3s ease-in-out infinite}
@keyframes pulse{0%,100%{opacity:.45;transform:scale(1)}50%{opacity:.7;transform:scale(1.05)}}
.shield-icon{position:relative;width:68px;height:68px;background:linear-gradient(135deg,#6366f1,#ec4899);border-radius:19px;display:flex;align-items:center;justify-content:center;box-shadow:0 8px 28px rgba(99,102,241,.45)}
.brand h1{font-family:'Sora',sans-serif;font-size:27px;font-weight:800;letter-spacing:-.5px;background:linear-gradient(135deg,#c7d2fe,#fbcfe8);-webkit-background-clip:text;-webkit-text-fill-color:transparent;margin-bottom:5px}
.brand p{color:#9d97b5;font-size:13px}
.field{margin-bottom:18px}
.field label{display:block;font-size:11px;font-weight:600;color:#9d97b5;text-transform:uppercase;letter-spacing:.9px;margin-bottom:8px}
.iw{position:relative}
.iw .ico{position:absolute;left:15px;top:50%;transform:translateY(-50%);color:#6b6489;width:17px;height:17px}
.field input{width:100%;background:rgba(255,255,255,.05);border:1px solid rgba(255,255,255,.1);border-radius:13px;padding:14px 16px 14px 44px;color:#ECEAF5;font-family:'Inter',sans-serif;font-size:14px;outline:none;transition:all .2s}
.field input::placeholder{color:#6b6489}
.field input:focus{border-color:#8b5cf6;box-shadow:0 0 0 3px rgba(139,92,246,.18);background:rgba(255,255,255,.07)}
.btn{width:100%;background:linear-gradient(135deg,#6366f1,#ec4899);color:#fff;border:none;border-radius:13px;padding:15px;font-family:'Sora',sans-serif;font-size:15px;font-weight:700;cursor:pointer;margin-top:10px;transition:all .2s;box-shadow:0 6px 24px rgba(99,102,241,.4)}
.btn:hover{transform:translateY(-2px);box-shadow:0 10px 32px rgba(99,102,241,.55)}
.btn:disabled{opacity:.5;cursor:not-allowed;transform:none}
.error{background:rgba(255,107,107,.12);border:1px solid rgba(255,107,107,.3);border-radius:11px;padding:12px 14px;color:#ff9b9b;font-size:13px;margin-bottom:18px;display:none}
.error.show{display:block}
.foot{text-align:center;margin-top:24px;font-size:12px;color:#6b6489}
.foot .secure{display:inline-flex;align-items:center;gap:5px;color:#8b5cf6}
.sp{display:none;width:18px;height:18px;border:2px solid rgba(255,255,255,.3);border-top-color:#fff;border-radius:50%;animation:spin .7s linear infinite;margin:0 auto}
@keyframes spin{to{transform:rotate(360deg)}}
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
@import url('https://fonts.googleapis.com/css2?family=Sora:wght@700;800&family=Inter:wght@400;500&display=swap');
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Inter',sans-serif;background:#0f0a1e;color:#ECEAF5;min-height:100vh;display:flex;align-items:center;justify-content:center}
.bg{position:fixed;inset:0;z-index:0;overflow:hidden}.orb{position:absolute;border-radius:50%;filter:blur(90px);opacity:.5;animation:float 12s ease-in-out infinite}
.o1{width:600px;height:600px;background:radial-gradient(circle,#6366f1,transparent 70%);top:-150px;left:-100px}.o2{width:500px;height:500px;background:radial-gradient(circle,#ec4899,transparent 70%);bottom:-120px;right:-80px;animation-delay:-4s}
@keyframes float{0%,100%{transform:translateY(0)}50%{transform:translateY(-40px)}}
.card{position:relative;z-index:2;width:100%;max-width:400px;background:rgba(22,18,40,.7);border:1px solid rgba(255,255,255,.1);border-radius:26px;padding:44px 36px;box-shadow:0 40px 100px rgba(0,0,0,.6);backdrop-filter:blur(20px);text-align:center}
.sh{font-size:50px;margin-bottom:16px;animation:pulse 2s ease-in-out infinite}@keyframes pulse{0%,100%{transform:scale(1)}50%{transform:scale(1.06)}}
h1{font-family:'Sora',sans-serif;font-size:22px;font-weight:800;margin-bottom:8px}.sub{font-size:13px;color:#9d97b5;margin-bottom:32px;line-height:1.6}
.inputs{display:flex;gap:10px;justify-content:center;margin-bottom:24px}
.box{width:44px;height:54px;background:rgba(255,255,255,.05);border:2px solid rgba(255,255,255,.12);border-radius:12px;color:#fff;font-size:22px;font-weight:700;font-family:'Sora',sans-serif;text-align:center;outline:none;transition:all .2s}
.box:focus{border-color:#8b5cf6;transform:scale(1.05)}.box.filled{border-color:rgba(139,92,246,.5)}
.btn{width:100%;background:linear-gradient(135deg,#6366f1,#ec4899);color:#fff;border:none;border-radius:13px;padding:14px;font-family:'Sora',sans-serif;font-size:15px;font-weight:700;cursor:pointer;transition:all .2s;box-shadow:0 6px 24px rgba(99,102,241,.4)}
.btn:hover{transform:translateY(-2px)}.btn:disabled{opacity:.5}
.err{color:#ff9b9b;font-size:13px;margin-bottom:12px;min-height:20px}
.back{font-size:12px;color:#9d97b5;margin-top:20px;cursor:pointer}.back:hover{color:#fff}
</style></head><body>
<div class="bg"><div class="orb o1"></div><div class="orb o2"></div></div>
<div class="card"><div class="sh">🛡️</div><h1>Verificación en dos pasos</h1><p class="sub">Código de 6 dígitos de tu app autenticadora</p>
<div class="err" id="err"></div>
<div class="inputs" id="inp"><input type="tel" maxlength="1" class="box" inputmode="numeric"><input type="tel" maxlength="1" class="box" inputmode="numeric"><input type="tel" maxlength="1" class="box" inputmode="numeric"><input type="tel" maxlength="1" class="box" inputmode="numeric"><input type="tel" maxlength="1" class="box" inputmode="numeric"><input type="tel" maxlength="1" class="box" inputmode="numeric"></div>
<button class="btn" id="btn" onclick="go()" disabled>Verificar</button>
<div class="back" onclick="window.location.href='/'">← Volver</div>
</div>
<script>
const boxes=document.querySelectorAll('.box');boxes.forEach((b,i)=>{b.addEventListener('input',e=>{const v=e.target.value.replace(/\D/g,'');e.target.value=v?v[0]:'';e.target.classList.toggle('filled',!!v);if(v&&i<boxes.length-1)boxes[i+1].focus();chk();});b.addEventListener('keydown',e=>{if(e.key==='Backspace'&&!b.value&&i>0){boxes[i-1].focus();boxes[i-1].value='';boxes[i-1].classList.remove('filled');chk();}if(e.key==='Enter')go();});b.addEventListener('paste',e=>{e.preventDefault();const t=(e.clipboardData||window.clipboardData).getData('text').replace(/\D/g,'').slice(0,6);[...t].forEach((c,j)=>{if(boxes[j]){boxes[j].value=c;boxes[j].classList.add('filled');}});chk();if(t.length===6)go();});});boxes[0].focus();
function chk(){document.getElementById('btn').disabled=![...boxes].every(b=>b.value);}
async function go(){const btn=document.getElementById('btn');const code=[...boxes].map(b=>b.value).join('');btn.disabled=true;try{const r=await fetch('/api/auth/totp-verify',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({code})});const d=await r.json();if(d.ok){window.location.href='/';}else{document.getElementById('err').textContent=d.message||'Código incorrecto';boxes.forEach(b=>{b.value='';b.classList.remove('filled');});boxes[0].focus();btn.disabled=true;}}catch(e){document.getElementById('err').textContent='Error de conexión';btn.disabled=false;}}
</script></body></html>
VIEWEOF

pct exec "$CT_ID" -- bash -c "cat > /var/www/vault/src/views/share.php" << 'VIEWEOF'
<?php $appName=APP_NAME;function mie($m){if(!$m)return'📄';if(str_starts_with($m,'image/'))return'🖼️';if(str_starts_with($m,'video/'))return'🎬';if(str_starts_with($m,'audio/'))return'🎵';if($m==='application/pdf')return'📕';if(str_contains($m,'zip')||str_contains($m,'rar'))return'📦';return'📄';}?><!DOCTYPE html><html lang="es"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title><?=h($appName)?> — Archivo compartido</title><style>
@import url('https://fonts.googleapis.com/css2?family=Sora:wght@700;800&family=Inter:wght@400;500&display=swap');
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Inter',sans-serif;background:#0f0a1e;color:#ECEAF5;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:24px;overflow:hidden}
.bg{position:fixed;inset:0;z-index:0;overflow:hidden}.orb{position:absolute;border-radius:50%;filter:blur(90px);opacity:.45;animation:float 12s ease-in-out infinite}
.o1{width:500px;height:500px;background:radial-gradient(circle,#6366f1,transparent 70%);top:-120px;left:-80px}.o2{width:400px;height:400px;background:radial-gradient(circle,#ec4899,transparent 70%);bottom:-100px;right:-60px;animation-delay:-4s}
@keyframes float{0%,100%{transform:translateY(0)}50%{transform:translateY(-30px)}}
.card{position:relative;z-index:2;background:rgba(22,18,40,.7);border:1px solid rgba(255,255,255,.1);border-radius:26px;padding:42px;width:100%;max-width:440px;text-align:center;backdrop-filter:blur(20px);box-shadow:0 40px 100px rgba(0,0,0,.6)}
.logo{display:inline-flex;align-items:center;gap:8px;font-family:'Sora',sans-serif;font-weight:800;font-size:16px;color:#c7d2fe;margin-bottom:28px}
.logo svg{width:24px;height:24px}
.fi{font-size:64px;margin-bottom:14px}
.fn{font-family:'Sora',sans-serif;font-size:20px;font-weight:700;margin-bottom:6px;word-break:break-word}
.meta{font-size:13px;color:#9d97b5;margin-bottom:8px}.own{font-size:12px;color:#9d97b5;margin-bottom:24px}
.btn{display:inline-flex;align-items:center;gap:8px;background:linear-gradient(135deg,#6366f1,#ec4899);color:#fff;border:none;border-radius:13px;padding:14px 28px;font-family:'Sora',sans-serif;font-size:15px;font-weight:700;cursor:pointer;text-decoration:none;box-shadow:0 6px 24px rgba(99,102,241,.4);transition:all .2s}
.btn:hover{transform:translateY(-2px)}
.pi{width:100%;background:rgba(255,255,255,.05);border:1px solid rgba(255,255,255,.12);border-radius:11px;padding:12px;color:#fff;font-size:14px;outline:none;margin-bottom:12px;text-align:center}
.pi:focus{border-color:#8b5cf6}.err{color:#ff9b9b;font-size:13px;margin-bottom:12px}
.media-preview{margin-bottom:20px;border-radius:14px;overflow:hidden;max-height:280px}
.media-preview img,.media-preview video{width:100%;max-height:280px;object-fit:contain;border-radius:14px;background:#000}
</style></head><body>
<div class="bg"><div class="orb o1"></div><div class="orb o2"></div></div>
<div class="card">
<div class="logo"><svg viewBox="0 0 24 24" fill="none"><path d="M12 3 L19 6 V11 C19 15.5 16 19 12 21 C8 19 5 15.5 5 11 V6 Z" stroke="#a5b4fc" stroke-width="2" stroke-linejoin="round"/><path d="M9 11.5 l2 2 l4-4.5" stroke="#a5b4fc" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg> <?=h($appName)?></div>
<?php if(!$authenticated):?>
<div class="fi">🔒</div><div class="fn">Archivo protegido</div><div class="meta">Este archivo requiere contraseña</div>
<form method="POST"><?php if(isset($passError)):?><div class="err">Contraseña incorrecta</div><?php endif;?><input type="password" name="share_pass" class="pi" placeholder="••••••••" autofocus><button type="submit" class="btn">🔓 Acceder</button></form>
<?php else:
$mime=$share['mime_type']??'';
$isFolder=$share['type']==='folder';
$isImg=!$isFolder&&str_starts_with($mime,'image/');$isVid=!$isFolder&&str_starts_with($mime,'video/');?>
<?php if($isFolder):?><div class="fi">📁</div>
<?php elseif($isImg):?><div class="media-preview"><img src="?token=<?=h($token)?>&dl=1&preview=1" alt=""></div>
<?php elseif($isVid):?><div class="media-preview"><video controls src="?token=<?=h($token)?>&dl=1&preview=1"></video></div>
<?php else:?><div class="fi"><?=mie($mime)?></div><?php endif;?>
<div class="fn"><?=h($share['name'])?></div>
<div class="meta"><?=$share['type']==='file'?size_human($share['size']):'Carpeta'?></div>
<div class="own">Compartido por <strong><?=h($share['owner_name'])?></strong></div>
<?php if($share['allow_download']):?><a href="?token=<?=h($token)?>&dl=1" class="btn" download><?=$isFolder?'⬇️ Descargar (ZIP)':'⬇️ Descargar'?></a><?php endif;?>
<?php if($share['max_downloads']):?><p style="font-size:11px;color:#9d97b5;margin-top:12px"><?=$share['downloads']?> / <?=$share['max_downloads']?> descargas</p><?php endif;?>
<?php endif;?>
</div></body></html>
VIEWEOF
msg_ok "Vistas de login, 2FA y compartir desplegadas"
msg_info "Desplegando interfaz principal"

msg_info "Desplegando interfaz principal"

pct exec "$CT_ID" -- bash -c "cat > /var/www/vault/src/views/app.php" << 'VIEWEOF'
<?php
$appName=APP_NAME;$userName=$user['display_name']?:$user['username'];
$isAdmin=$user['role']==='admin';$quota=$user['storage_quota'];$used=$user['storage_used'];
$usedPct=$quota>0?min(100,round($used/$quota*100,1)):0;
$theme=$user['theme']??'dark';
?><!DOCTYPE html><html lang="es" data-theme="<?=h($theme)?>"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title><?=h($appName)?></title><style>
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
</style></head>
<body>
<!-- Overlay para cerrar sidebar en móvil -->
<div id="sideOverlay" onclick="closeSidebar()"></div>
<!-- Ghost de drag interno -->
<div id="dragGhost"></div>
<aside class="sidebar" id="sidebar">
<div class="sh"><div class="brand"><div class="logo"><svg width="22" height="22" viewBox="0 0 24 24" fill="none"><path d="M12 3 L19 6 V11 C19 15.5 16 19 12 21 C8 19 5 15.5 5 11 V6 Z" stroke="#fff" stroke-width="2" stroke-linejoin="round"/><path d="M9 11.5 l2 2 l4-4.5" stroke="#fff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg></div><span class="name"><?=h($appName)?></span></div></div>
<nav class="nav">
<div class="ns">Mis archivos</div>
<div class="ni active" onclick="showPage('files');closeSidebar()" data-page="files"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M3 9l9-7 9 7v11a2 2 0 01-2 2H5a2 2 0 01-2-2z"/></svg> Inicio</div>
<div class="ni" onclick="showPage('starred');closeSidebar()" data-page="starred"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 2l3 7h7l-5.5 4 2 7L12 16l-6.5 4 2-7L2 9h7z"/></svg> Destacados</div>
<div class="ni" onclick="showPage('shares');closeSidebar()" data-page="shares"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M10 13a5 5 0 007 0l3-3a5 5 0 00-7-7l-1 1"/><path d="M14 11a5 5 0 00-7 0l-3 3a5 5 0 007 7l1-1"/></svg> Compartidos</div>
<div class="ni" onclick="showPage('trash');closeSidebar()" data-page="trash"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M3 6h18M19 6l-1 14a2 2 0 01-2 2H8a2 2 0 01-2-2L5 6m3 0V4a2 2 0 012-2h4a2 2 0 012 2v2"/></svg> Papelera</div>
<?php if($isAdmin):?><div class="ns">Administración</div>
<div class="ni" onclick="showPage('admin');closeSidebar()" data-page="admin"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="3"/><path d="M19 12a7 7 0 00-.1-1l2-1.5-2-3.5-2.4 1a7 7 0 00-1.7-1L14.5 2h-5l-.3 2.5a7 7 0 00-1.7 1l-2.4-1-2 3.5 2 1.5a7 7 0 000 2l-2 1.5 2 3.5 2.4-1a7 7 0 001.7 1l.3 2.5h5l.3-2.5a7 7 0 001.7-1l2.4 1 2-3.5-2-1.5a7 7 0 00.1-1z"/></svg> Panel admin</div><?php endif;?>
<div class="ns">Cuenta</div>
<div class="ni" onclick="showPage('settings');closeSidebar()" data-page="settings"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="8" r="4"/><path d="M4 21v-1a6 6 0 016-6h4a6 6 0 016 6v1"/></svg> Ajustes</div>
</nav>
<div class="sf">
<div class="ql"><span><?=size_human($used)?> usados</span><span><?=size_human($quota)?></span></div>
<div class="qb"><div class="qf" style="width:<?=$usedPct?>%"></div></div>
<div class="ur"><div class="av"><?=strtoupper(substr($userName,0,1))?></div><span class="un"><?=h($userName)?></span><button class="lb" onclick="logout()" title="Salir">⤶</button></div>
</div>
</aside>
<main class="main">
<div class="topbar">
<button class="hbtn" id="hbtn" onclick="openSidebar()" title="Menú"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M3 12h18M3 6h18M3 18h18"/></svg></button>
<div class="sw"><svg class="si" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="11" cy="11" r="8"/><path d="M21 21l-4-4"/></svg><input type="search" id="searchInput" name="vault_search" placeholder="Buscar archivos..." autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false" oninput="debSearch(this.value)"><button class="clr" id="clrBtn" onclick="clearSearch()"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M18 6L6 18M6 6l12 12"/></svg></button></div>
<div class="tr">
<button class="bi" id="topUploadBtn" onclick="showUpload()" title="Subir"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 15v4a2 2 0 01-2 2H5a2 2 0 01-2-2v-4M17 8l-5-5-5 5M12 3v12"/></svg></button>
<button class="bi" id="topFolderBtn" onclick="showNewFolder()" title="Nueva carpeta"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M22 19a2 2 0 01-2 2H4a2 2 0 01-2-2V5a2 2 0 012-2h5l2 3h9a2 2 0 012 2zM12 11v6M9 14h6"/></svg></button>
<div class="vt" id="mainViewToggle"><button class="vb active" id="gvBtn" onclick="setView('grid')"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="3" width="7" height="7"/><rect x="14" y="3" width="7" height="7"/><rect x="14" y="14" width="7" height="7"/><rect x="3" y="14" width="7" height="7"/></svg></button><button class="vb" id="lvBtn" onclick="setView('list')"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01"/></svg></button></div>
<button class="bi" id="themeBtn" onclick="toggleTheme()"></button>
<button class="bi" onclick="showPage('settings')" title="Ajustes"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="3"/><path d="M19 12a7 7 0 00-.1-1l2-1.5-2-3.5-2.4 1a7 7 0 00-1.7-1L14.5 2h-5l-.3 2.5a7 7 0 00-1.7 1l-2.4-1-2 3.5 2 1.5a7 7 0 000 2l-2 1.5 2 3.5 2.4-1a7 7 0 001.7 1l.3 2.5h5l.3-2.5a7 7 0 001.7-1l2.4 1 2-3.5-2-1.5a7 7 0 00.1-1z"/></svg></button>
</div>
</div>
<div class="content">
<div class="page active" id="page-files"><div class="tbar"><h2 id="ftitle">Mis archivos</h2><button class="btn bs" onclick="showNewFolder()">Nueva carpeta</button><button class="btn bp" onclick="showUpload()">Subir</button></div><div class="bc" id="bc"></div><div id="fc"></div></div>
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
<div class="page" id="page-settings"><div class="tbar"><h2>Ajustes</h2></div><div id="stc"></div></div>
<?php if($isAdmin):?><div class="page" id="page-admin"><div class="tbar"><h2>Panel de administración</h2></div><div id="ac"></div></div><?php endif;?>
</div>
</main>
<div class="toasts" id="toasts"></div>
<div class="mo" id="mUpload"><div class="md"><h3>Subir archivos</h3><div class="uz" id="dz"><div class="ui">📂</div><p>Arrastra aquí o <strong>haz clic</strong></p><p style="font-size:11px;color:var(--muted2);margin-top:4px">Máximo 10GB por archivo</p><input type="file" id="fi" multiple onchange="handleFiles(this.files)"></div><div id="ul"></div><div class="ma"><button class="btn bs" onclick="closeModal('mUpload')">Cerrar</button></div></div></div>
<div class="mo" id="mFolder"><div class="md"><h3>Nueva carpeta</h3><div class="mf"><label>Nombre</label><input type="text" id="fn" placeholder="Mi carpeta" onkeydown="if(event.key==='Enter')mkFolder()"></div><div class="ma"><button class="btn bs" onclick="closeModal('mFolder')">Cancelar</button><button class="btn bp" onclick="mkFolder()">Crear</button></div></div></div>
<div class="mo" id="mShare"><div class="md"><h3>Compartir archivo</h3><div class="mf"><label>Contraseña (opcional)</label><input type="password" id="spw" placeholder="Sin contraseña" autocomplete="new-password"></div><div class="mf"><label>Expira el (opcional)</label><input type="datetime-local" id="sex"></div><div class="mf"><label>Máx. descargas (opcional)</label><input type="number" id="smd" placeholder="Sin límite" min="1"></div><div id="sres" style="display:none"><label style="font-size:10px;color:var(--muted);text-transform:uppercase;letter-spacing:.7px">Link generado</label><div style="display:flex;gap:8px;align-items:stretch;margin-top:6px"><div class="su" id="surl" style="flex:1;margin:0"></div><button class="btn bp" onclick="copyShare()" style="white-space:nowrap">Copiar</button></div><div id="emailRow" style="display:none;margin-top:14px"><label style="font-size:10px;color:var(--muted);text-transform:uppercase;letter-spacing:.7px">Enviar por email</label><div style="display:flex;gap:8px;align-items:stretch;margin-top:6px"><input type="email" id="semail" placeholder="destinatario@correo.com" style="flex:1;background:var(--surface2);border:1px solid var(--border);border-radius:10px;padding:10px 12px;color:var(--text);font-size:13px;outline:none"><button class="btn bs" id="sendEmailBtn" onclick="sendShareEmail()" style="white-space:nowrap">Enviar</button></div></div></div><div class="ma"><button class="btn bs" onclick="closeModal('mShare')">Cerrar</button><button class="btn bp" id="shBtn" onclick="mkShare()">Crear link</button></div></div></div>
<div class="mo" id="mRename"><div class="md"><h3>Renombrar</h3><div class="mf"><label>Nuevo nombre</label><input type="text" id="ri" onkeydown="if(event.key==='Enter')doRename()"></div><div class="ma"><button class="btn bs" onclick="closeModal('mRename')">Cancelar</button><button class="btn bp" onclick="doRename()">Renombrar</button></div></div></div>
<div class="mo" id="mMove"><div class="md"><h3>Mover a...</h3><div class="foldertree" id="folderTree"></div><div class="ma"><button class="btn bs" onclick="closeModal('mMove')">Cancelar</button><button class="btn bp" onclick="doMove()">Mover aquí</button></div></div></div>
<div class="mo" id="mConfirm"><div class="md"><h3 id="cfTitle">Confirmar</h3><p id="cfMsg" style="font-size:14px;color:var(--muted);line-height:1.6;margin-bottom:4px"></p><div class="ma"><button class="btn bs" onclick="closeModal('mConfirm')">Cancelar</button><button class="btn" id="cfBtn" onclick="cfAccept()">Aceptar</button></div></div></div>
<div class="mo" id="mConflict"><div class="md"><h3>Ya existe</h3><p id="cflMsg" style="font-size:14px;color:var(--muted);line-height:1.6;margin-bottom:8px"></p><div class="ma" style="flex-wrap:wrap"><button class="btn bs" onclick="conflictResolve('cancel')">Cancelar</button><button class="btn bs" onclick="conflictResolve('rename')">Mantener ambos</button><button class="btn bp" onclick="conflictResolve('replace')">Reemplazar</button></div></div></div>
<div class="mo" id="mNewUser"><div class="md"><h3>Nuevo usuario</h3><div class="mf"><label>Usuario</label><input type="text" id="nu-u"></div><div class="mf"><label>Email</label><input type="email" id="nu-e"></div><div class="mf"><label>Nombre</label><input type="text" id="nu-n"></div><div class="mf"><label>Contraseña</label><input type="password" id="nu-p"></div><div class="mf"><label>Rol</label><select id="nu-r"><option value="user">Usuario</option><option value="admin">Admin</option></select></div><div class="mf"><label>Cuota (GB)</label><input type="number" id="nu-q" value="10" min="1"></div><div class="ma"><button class="btn bs" onclick="closeModal('mNewUser')">Cancelar</button><button class="btn bp" onclick="createUser()">Crear</button></div></div></div>
<div class="ctx" id="ctx" style="display:none"></div>
<div class="viewer" id="viewer"><div class="viewer-top"><span class="vtitle" id="vTitle"></span><button class="vbtn" onclick="viewerDownload()" title="Descargar">⬇</button><button class="vbtn" onclick="closeViewer()" title="Cerrar">✕</button></div><div class="viewer-body" id="vBody"></div></div>
<div class="ctxbar" id="ctxbar"><span class="cnt" id="selCount">0 seleccionados</span><button onclick="selectAllToggle()"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M9 11l3 3L22 4"/><path d="M21 12v7a2 2 0 01-2 2H5a2 2 0 01-2-2V5a2 2 0 012-2h11"/></svg> Todo</button><div class="div"></div><button onclick="bulkDownload()"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 15v4a2 2 0 01-2 2H5a2 2 0 01-2-2v-4M7 10l5 5 5-5M12 15V3"/></svg> Descargar</button><button onclick="bulkStar()"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 2l3 7h7l-5.5 4 2 7L12 16l-6.5 4 2-7L2 9h7z"/></svg> Destacar</button><button onclick="bulkMove()"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M5 12h14M12 5l7 7-7 7"/></svg> Mover</button><button class="danger" onclick="bulkTrash()"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M3 6h18M19 6l-1 14a2 2 0 01-2 2H8a2 2 0 01-2-2L5 6"/></svg> Papelera</button><div class="div"></div><button onclick="clearSelection()">✕ Cancelar</button></div>
<!-- Panel de progreso de subida -->
<div id="uploadPanel"><div class="uph"><span>Subiendo archivos</span><button class="upclose" onclick="document.getElementById('uploadPanel').classList.remove('show')">✕</button></div><div class="uplist" id="uplist"></div></div>
VIEWEOF
echo " [app.php cabecera+HTML escrito]"
pct exec "$CT_ID" -- bash -c "cat >> /var/www/vault/src/views/app.php" << 'VIEWEOF'
<script>
/* ══ ESTADO GLOBAL ══ */
const S={page:'files',fid:null,view:'grid',shareTarget:null,renameTarget:null,st:null,currentList:[],viewerIdx:-1,moveIds:[],cfAccept:null,cflRename:null,cflReplace:null,selected:new Set(),moveTarget:null,viewerCurrent:null};

/* ══ API ══ */
async function api(m,p,b){const o={method:m,headers:{}};if(b&&!(b instanceof FormData)){o.headers['Content-Type']='application/json';o.body=JSON.stringify(b);}else if(b)o.body=b;try{const r=await fetch('/api/'+p,o);const txt=await r.text();let d;try{d=JSON.parse(txt);}catch(e){return{ok:false,message:'Respuesta no válida'+(txt?': '+txt.slice(0,120):'')};}return d;}catch(e){return{ok:false,message:'Error de conexión'};}}

/* ══ TOASTS ══ */
function toast(msg,type='info',dur=3500){const ic={success:'✓',error:'✕',info:'ℹ'};const el=document.createElement('div');el.className=`toast ${type}`;el.innerHTML=`<span>${ic[type]||'ℹ'}</span><span>${msg}</span>`;document.getElementById('toasts').appendChild(el);setTimeout(()=>{el.style.opacity='0';el.style.transform='translateY(20px)';el.style.transition='all .3s';setTimeout(()=>el.remove(),300);},dur);}

/* ══ SIDEBAR MÓVIL ══ */
function openSidebar(){document.getElementById('sidebar').classList.add('open');document.getElementById('sideOverlay').classList.add('show');}
function closeSidebar(){document.getElementById('sidebar').classList.remove('open');document.getElementById('sideOverlay').classList.remove('show');}

/* ══ NAVEGACIÓN ══ */
function syncTopbar(){
  const topUpload=document.getElementById('topUploadBtn');
  const topFolder=document.getElementById('topFolderBtn');
  const mainToggle=document.getElementById('mainViewToggle');
  const filePages=['files','starred','search','trash'];
  const canCreate=S.page==='files';
  if(topUpload)topUpload.style.display=canCreate?'inline-flex':'none';
  if(topFolder)topFolder.style.display=canCreate?'inline-flex':'none';
  if(mainToggle)mainToggle.style.display=filePages.includes(S.page)?'flex':'none';
  document.getElementById('gvBtn')?.classList.toggle('active',(S.page==='trash'?TS.view:S.view)==='grid');
  document.getElementById('lvBtn')?.classList.toggle('active',(S.page==='trash'?TS.view:S.view)==='list');
}
function hideSelectionBars(){
  document.getElementById('ctxbar')?.classList.remove('show');
  document.getElementById('trashSelBar')?.classList.remove('show');
  document.body.classList.remove('selmode');
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
  if(n==='admin')loadAdmin();
  if(n==='settings')loadSettings();
}

/* ══ ARCHIVOS ══ */
async function loadFiles(fid){clearSelection();if(fid!==undefined)S.fid=fid??null;const url='files'+(S.fid?`?folder=${S.fid}`:'');const d=await api('GET',url);if(!d.ok)return toast(d.error||'Error','error');renderBC(d.breadcrumb||[]);S.currentList=d.files||[];renderFiles(d.files||[],'fc');document.getElementById('ftitle').textContent=S.fid&&d.breadcrumb?.length?d.breadcrumb[d.breadcrumb.length-1].name:'Mis archivos';}
function reloadCurrent(){if(S.page==='files')loadFiles();else if(S.page==='starred')loadStarred();else if(S.page==='trash')loadTrash();}
function renderBC(c){const el=document.getElementById('bc');let h=`<span onclick="loadFiles(null)">Inicio</span>`;c.forEach(cr=>{h+=`<span class="sep">›</span><span onclick="loadFiles(${cr.id})">${H(cr.name)}</span>`;});el.innerHTML=h;}
function renderFiles(files,cid){const el=document.getElementById(cid);if(!files.length){el.innerHTML=`<div class="empty"><div class="ei">📂</div><h3>Carpeta vacía</h3><p>Sube archivos o crea una carpeta</p></div>`;return;}if(S.view==='grid'){el.innerHTML=`<div class="fg">${files.map(f=>fCard(f)).join('')}</div>`;}else{el.innerHTML=`<div class="fl">${files.map(f=>fRow(f)).join('')}</div>`;}applySelectionUI();initInternalDrag();}

/* ══ TARJETAS ══ */
function fCard(f){const ic=f.type==='folder'?'📁':mIco(f.mime_type);const th=f.type==='file'&&f.thumbnail?`/api/thumb/${f.id}`:null;const chk='<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3"><path d="M5 12l5 5L20 6"/></svg>';return`<div class="fc" data-id="${f.id}" data-type="${f.type}" data-name="${H(f.name)}" onclick="cardClick(event,${f.id},'${f.type}','${esc(f.name)}','${f.mime_type||''}')" oncontextmenu="showCtx(event,${f.id},'${f.type}','${esc(f.name)}','${f.mime_type||''}')"><div class="selcheck" onclick="event.stopPropagation();toggleSelect(${f.id})">${chk}</div><div class="ft">${th?`<img src="${th}" loading="lazy">`:`<span>${ic}</span>`}${f.is_starred?'<span style="position:absolute;top:6px;right:6px;font-size:11px">⭐</span>':''}</div><div class="fi-b"><div class="fn" title="${H(f.name)}">${H(f.name)}</div><div class="fm">${f.type==='folder'?'Carpeta':szH(f.size)}</div></div><div class="fa"><button class="fab" onclick="event.stopPropagation();starFile(${f.id})" title="Destacar">⭐</button><button class="fab" onclick="event.stopPropagation();showShare(${f.id},'${esc(f.name)}','${f.type}')" title="Compartir">🔗</button><button class="fab" onclick="event.stopPropagation();moveOne(${f.id})" title="Mover">↪</button><button class="fab" onclick="event.stopPropagation();trashIt(${f.id})" title="Papelera">🗑</button></div></div>`;}
function fRow(f){const chk='<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3"><path d="M5 12l5 5L20 6"/></svg>';return`<div class="fr" data-id="${f.id}" data-type="${f.type}" data-name="${H(f.name)}" onclick="cardClick(event,${f.id},'${f.type}','${esc(f.name)}','${f.mime_type||''}')" oncontextmenu="showCtx(event,${f.id},'${f.type}','${esc(f.name)}','${f.mime_type||''}')"><div class="rsel" onclick="event.stopPropagation();toggleSelect(${f.id})">${chk}</div><div class="ri">${f.type==='folder'?'📁':mIco(f.mime_type)}</div><div class="rn">${H(f.name)}${f.is_starred?' ⭐':''}</div><div class="rs">${f.type==='folder'?'—':szH(f.size)}</div><div class="rd">${fmtD(f.updated_at||f.created_at)}</div><div class="ra"><button class="fab" onclick="event.stopPropagation();showShare(${f.id},'${esc(f.name)}','${f.type}')">🔗</button><button class="fab" onclick="event.stopPropagation();moveOne(${f.id})">↪</button><button class="fab" onclick="event.stopPropagation();trashIt(${f.id})">🗑</button></div></div>`;}

/* ══ SELECCIÓN ══ */
function cardClick(e,id,type,name,mime){if(S.selected.size>0){toggleSelect(id);return;}openItem(id,type,name,mime);}
function toggleSelect(id){if(S.selected.has(id))S.selected.delete(id);else S.selected.add(id);applySelectionUI();}
function applySelectionUI(){const container=document.querySelector('.page.active');if(container)container.querySelectorAll('.fc:not(.tc-item),.fr:not(.tc-item)').forEach(el=>{const id=parseInt(el.dataset.id);const on=S.selected.has(id);el.classList.toggle('sel',on);const c=el.querySelector('.selcheck,.rsel');if(c)c.classList.toggle('on',on);});const active=S.selected.size>0&&S.page!=='trash';document.body.classList.toggle('selmode',active);const bar=document.getElementById('ctxbar');if(!bar)return;if(active){bar.classList.add('show');document.getElementById('selCount').textContent=S.selected.size+(S.selected.size===1?' seleccionado':' seleccionados');}else bar.classList.remove('show');}
function clearSelection(){S.selected.clear();applySelectionUI();}
function selectAllToggle(){const container=document.querySelector('.page.active');if(!container)return;const ids=[...container.querySelectorAll('.fc,.fr')].map(el=>parseInt(el.dataset.id));const allSel=ids.length>0&&ids.every(i=>S.selected.has(i));if(allSel)S.selected.clear();else ids.forEach(i=>S.selected.add(i));applySelectionUI();}
function getSelectedItems(){const container=document.querySelector('.page.active');const out=[];if(container)container.querySelectorAll('.fc,.fr').forEach(el=>{const id=parseInt(el.dataset.id);if(S.selected.has(id))out.push({id,type:el.dataset.type,name:el.dataset.name});});return out;}

/* ══ ACCIONES BULK ══ */
async function bulkStar(){const ids=[...S.selected];const d=await api('POST','bulk/star',{ids});if(d.ok){toast('Destacados','success');clearSelection();reloadCurrent();}else toast(d.message||'Error','error');}
async function bulkTrash(){const ids=[...S.selected];vaultConfirm('Mover a papelera',`¿Mover ${ids.length} elemento(s) a la papelera?`,'Mover',async()=>{const d=await api('POST','bulk/trash',{ids});if(d.ok){toast('Movidos a papelera','success');clearSelection();reloadCurrent();}else toast(d.message||'Error','error');});}
function bulkDownload(){const ids=[...S.selected];if(!ids.length)return;if(ids.length===1){const it=getSelectedItems()[0];const a=document.createElement('a');a.href='/api/download/'+ids[0];if(it&&it.type==='file')a.download=it.name;a.click();clearSelection();return;}const a=document.createElement('a');a.href='/api/bulk-download/?ids='+ids.join(',');a.click();clearSelection();}
function bulkMove(){S.moveIds=[...S.selected];openMoveModal();}
function moveOne(id){S.moveIds=[id];openMoveModal();}

/* ══ ABRIR ELEMENTO ══ */
function openItem(id,type,name,mime){if(type==='folder'){loadFiles(id);}else{openViewer(id,name,mime||'');}}

/* ══ ACCIONES INDIVIDUALES ══ */
async function starFile(id){const d=await api('POST','files/'+id+'/star');if(d.ok){reloadCurrent();}else toast(d.message||'Error','error');}
function trashIt(id){vaultConfirm('Mover a papelera','¿Mover este elemento a la papelera?','Mover',async()=>{const d=await api('DELETE','files/'+id);if(d.ok){toast('Movido a papelera','success');reloadCurrent();}else toast(d.message||'Error','error');});}
function showRename(id,name){S.renameTarget=id;const i=document.getElementById('ri');i.value=name;document.getElementById('mRename').classList.add('open');setTimeout(()=>{i.focus();i.select();},80);}
async function doRename(){const name=document.getElementById('ri').value.trim();if(!name)return;const d=await api('PATCH','files/'+S.renameTarget+'/rename',{name});if(d.ok){toast('Renombrado','success');closeModal('mRename');reloadCurrent();}else toast(d.message||'Error','error');}

/* ══ NUEVA CARPETA ══ */
function showNewFolder(){document.getElementById('fn').value='';document.getElementById('mFolder').classList.add('open');setTimeout(()=>document.getElementById('fn').focus(),80);}
async function mkFolder(){const name=document.getElementById('fn').value.trim()||'Nueva carpeta';const d=await api('POST','folders',{name,parent_id:S.fid});if(d.ok){toast('Carpeta creada','success');closeModal('mFolder');loadFiles();}else toast(d.message||'Error','error');}

/* ══ SUBIDA DE ARCHIVOS ══ */
function showUpload(){document.getElementById('mUpload').classList.add('open');}
function handleFiles(files){
  if(!files||!files.length)return;
  closeModal('mUpload');
  const panel=document.getElementById('uploadPanel');
  const list=document.getElementById('uplist');
  panel.classList.add('show');
  const total=files.length;
  let done=0;
  function onFileDone(){done++;if(done>=total){setTimeout(()=>{panel.classList.remove('show');list.innerHTML='';},2200);}}
  [...files].forEach(f=>{
    const id='up_'+Date.now()+'_'+Math.random().toString(36).slice(2);
    const item=document.createElement('div');item.className='upitem';item.id=id;
    item.innerHTML=`<div class="upname">${H(f.name)}</div><div class="uprow"><div class="upbar"><div class="upfill" id="fill_${id}" style="width:0%"></div></div><div class="uppct" id="pct_${id}">0%</div></div>`;
    list.appendChild(item);
    uploadOne(f,id,onFileDone);
  });
}
async function uploadOne(file,itemId,onDone){
const CHUNK=5*1024*1024;
const fill=document.getElementById('fill_'+itemId);
const pct=document.getElementById('pct_'+itemId);
const item=document.getElementById(itemId);
function setP(p){if(fill)fill.style.width=p+'%';if(pct)pct.textContent=Math.round(p)+'%';}
if(file.size<=CHUNK){
  const fd=new FormData();fd.append('file',file);if(S.fid)fd.append('folder_id',S.fid);
  await new Promise(res=>{const xhr=new XMLHttpRequest();xhr.upload.onprogress=e=>{if(e.lengthComputable)setP(e.loaded/e.total*100);};xhr.onload=()=>{if(xhr.status===200){if(item)item.classList.add('done');}else{if(item)item.classList.add('err');toast('Error subiendo '+file.name,'error');}res();};xhr.onerror=()=>{if(item)item.classList.add('err');res();};xhr.open('POST','/api/upload');xhr.send(fd);});
  reloadCurrent();if(typeof onDone==='function')onDone();return;
}
const total=Math.ceil(file.size/CHUNK);
const uploadId=(crypto.randomUUID?crypto.randomUUID():Date.now().toString(36)+Math.random().toString(36).slice(2));
let ok=true;
for(let i=0;i<total&&ok;i++){
  const start=i*CHUNK;const chunk=file.slice(start,Math.min(start+CHUNK,file.size));
  const fd=new FormData();fd.append('upload_id',uploadId);fd.append('chunk_index',i);fd.append('total_chunks',total);fd.append('file_name',file.name);fd.append('file_size',file.size);if(S.fid)fd.append('folder_id',S.fid);fd.append('chunk',chunk);
  let tries=0;let sent=false;
  while(tries<3&&!sent){
    try{
      const r=await fetch('/api/upload-chunk',{method:'POST',body:fd,credentials:'same-origin'});
      const d=await r.json();
      if(d.ok)sent=true;else{tries++;await new Promise(r=>setTimeout(r,800));}
    }catch(e){tries++;await new Promise(r=>setTimeout(r,800));}
  }
  if(!sent){if(item)item.classList.add('err');toast('Error subiendo '+file.name+' (chunk '+i+')','error');ok=false;break;}
  setP((i+1)/total*95);
}
if(!ok)return;
try{
  const r=await fetch('/api/upload-complete',{method:'POST',credentials:'same-origin',headers:{'Content-Type':'application/json'},body:JSON.stringify({upload_id:uploadId,file_name:file.name,file_size:file.size,total_chunks:total,folder_id:S.fid||null})});
  const d=await r.json();
  if(d.ok){setP(100);if(item)item.classList.add('done');reloadCurrent();if(typeof onDone==='function')onDone();return;}
  else{if(item)item.classList.add('err');toast('Error completando '+file.name+': '+(d.message||''),'error');}
}catch(e){if(item)item.classList.add('err');toast('Error completando '+file.name,'error');}
  if(typeof onDone==='function')onDone();
}

/* ══ COMPARTIR ══ */
function showShare(id,name,type){S.shareTarget={id,name,type};document.getElementById('spw').value='';document.getElementById('sex').value='';document.getElementById('smd').value='';document.getElementById('sres').style.display='none';document.getElementById('shBtn').style.display='';document.getElementById('semail').value='';document.getElementById('mShare').classList.add('open');}
async function mkShare(){const d=await api('POST','shares',{file_id:S.shareTarget.id,password:document.getElementById('spw').value||null,expires_at:document.getElementById('sex').value||null,max_downloads:parseInt(document.getElementById('smd').value)||null});if(!d.ok)return toast(d.message||'Error','error');const url=d.url||window.location.origin+'/s/'+d.token;document.getElementById('surl').textContent=url;document.getElementById('sres').style.display='block';document.getElementById('shBtn').style.display='none';const emailRow=document.getElementById('emailRow');if(emailRow)emailRow.style.display=d.smtp?'block':'none';document.getElementById('semail').value='';toast('Link creado','success');const mshare=document.getElementById('mShare');if(mshare){const md=mshare.querySelector('.md');if(md)setTimeout(()=>md.scrollTop=md.scrollHeight,50);}}
function copyShare(){const url=document.getElementById('surl').textContent;navigator.clipboard.writeText(url).then(()=>toast('Link copiado','success'));}
async function sendShareEmail(){const btn=document.getElementById('sendEmailBtn');btn.disabled=true;const email=document.getElementById('semail').value.trim();const url=document.getElementById('surl').textContent;if(!email)return toast('Introduce un email','error');const d=await api('POST','shares/email',{email,url,filename:S.shareTarget?.name||'',is_folder:S.shareTarget?.type==='folder'});btn.disabled=false;if(d.ok)toast('Email enviado','success');else toast(d.message||'Error al enviar','error');}

/* ══ VISOR ══ */
function openViewer(id,name,mime){S.viewerIdx=S.currentList.findIndex(f=>f.id===id);renderViewer(id,name,mime);document.getElementById('viewer').classList.add('open');}
function renderViewer(id,name,mime){document.getElementById('vTitle').textContent=name;S.viewerCurrent={id,name,mime};const body=document.getElementById('vBody');const url='/api/view/'+id;let inner='';if(mime.startsWith('image/')){inner=`<img src="${url}" alt="${H(name)}">`;}else if(mime.startsWith('video/')){inner=`<video src="${url}" controls autoplay style="max-width:90%;max-height:90%"></video>`;}else if(mime.startsWith('audio/')){inner=`<div style="text-align:center"><div style="font-size:64px;margin-bottom:20px">🎵</div><audio src="${url}" controls autoplay></audio></div>`;}else if(mime==='application/pdf'){inner=`<iframe src="${url}"></iframe>`;}else if(mime.startsWith('text/')||mime.includes('json')||mime.includes('xml')){inner=`<iframe src="${url}" style="background:#fff"></iframe>`;}else{inner=`<div class="noprev"><div class="npi">${mIco(mime)}</div><h3 style="font-family:'Sora';margin-bottom:8px">${H(name)}</h3><p>Este tipo de archivo no se puede previsualizar</p><button class="btn bp" style="margin-top:16px" onclick="viewerDownload()">⬇ Descargar</button></div>`;}
const viewable=S.currentList.filter(f=>f.type==='file'&&(f.mime_type||'').match(/^(image|video|audio)\//)||f.mime_type==='application/pdf');let nav='';if(viewable.length>1){nav=`<button class="viewer-nav prev" onclick="viewerNav(-1)">‹</button><button class="viewer-nav next" onclick="viewerNav(1)">›</button>`;}body.innerHTML=inner+nav;}
function viewerNav(dir){const viewable=S.currentList.filter(f=>f.type==='file');if(!viewable.length)return;let idx=viewable.findIndex(f=>f.id===S.viewerCurrent?.id);idx=(idx+dir+viewable.length)%viewable.length;const f=viewable[idx];renderViewer(f.id,f.name,f.mime_type||'');}
function viewerDownload(){if(S.viewerCurrent){const a=document.createElement('a');a.href='/api/download/'+S.viewerCurrent.id;a.download=S.viewerCurrent.name;a.click();}}
function closeViewer(){document.getElementById('viewer').classList.remove('open');document.getElementById('vBody').innerHTML='';}

/* ══ MENÚ CONTEXTUAL ══ */
function showCtx(e,id,type,name,mime){e.preventDefault();hideCtx();const m=document.getElementById('ctx');const items=[{ico:'✏️',label:'Renombrar',fn:`showRename(${id},'${esc(name)}')`},{ico:'⭐',label:'Destacar',fn:`starFile(${id})`},{ico:'🔗',label:'Compartir',fn:`showShare(${id},'${esc(name)}','${type}')`},{ico:'↪',label:'Mover',fn:`moveOne(${id})`},{ico:'⬇️',label:'Descargar',fn:`(function(){const a=document.createElement('a');a.href='/api/download/${id}';a.download='${esc(name)}';a.click();})()`},{sep:true},{ico:'🗑',label:'Mover a papelera',fn:`trashIt(${id})`,danger:true}];m.innerHTML=items.map(it=>it.sep?`<div class="cxs"></div>`:`<div class="cxi${it.danger?' danger':''}" onclick="hideCtx();${it.fn}">${it.ico} ${it.label}</div>`).join('');m.style.display='block';const vw=window.innerWidth,vh=window.innerHeight;let x=e.clientX,y=e.clientY;setTimeout(()=>{if(x+m.offsetWidth>vw-10)x=vw-m.offsetWidth-10;if(y+m.offsetHeight>vh-10)y=vh-m.offsetHeight-10;m.style.left=x+'px';m.style.top=y+'px';},0);}
function hideCtx(){const m=document.getElementById('ctx');m.style.display='none';}
document.addEventListener('click',e=>{if(!e.target.closest('#ctx'))hideCtx();});

/* ══ MODAL MOVER ══ */
async function openMoveModal(){const d=await api('GET','folders');const tree=document.getElementById('folderTree');S.moveTarget=null;let h=`<div class="ftrow" data-fid="" onclick="pickFolder(this,null)"><span class="ico">🏠</span> Inicio (raíz)</div>`;const folders=(d.folders||[]).filter(f=>!S.moveIds.includes(f.id));const byParent={};folders.forEach(f=>{(byParent[f.parent_id||'root']=byParent[f.parent_id||'root']||[]).push(f);});function build(parent,depth){const list=byParent[parent||'root']||[];list.forEach(f=>{h+=`<div class="ftrow" data-fid="${f.id}" onclick="pickFolder(this,${f.id})"><span style="width:${depth*16}px;display:inline-block"></span><span class="ico">📁</span> ${H(f.name)}</div>`;build(f.id,depth+1);});}build('root',0);tree.innerHTML=h;document.getElementById('mMove').classList.add('open');}
function pickFolder(el,fid){document.querySelectorAll('#folderTree .ftrow').forEach(r=>r.classList.remove('on'));el.classList.add('on');S.moveTarget=fid;}
async function doMove(conflict){const ids=S.moveIds||[];if(!ids.length)return;const d=await api('POST','bulk/move',{ids,parent_id:S.moveTarget,conflict:conflict||'error'});if(d.ok){toast('Movido','success');closeModal('mMove');clearSelection();reloadCurrent();}else if((d.message||'').includes('DUPLICATE')){conflictModal(()=>doMove('rename'),()=>doMove('replace'));}else toast(d.message||'Error','error');}

/* ══ MODALES GENÉRICOS ══ */
function vaultConfirm(title,msg,btnText,onAccept,danger){document.getElementById('cfTitle').textContent=title;document.getElementById('cfMsg').textContent=msg;const b=document.getElementById('cfBtn');b.textContent=btnText||'Aceptar';b.className='btn '+(danger?'bd':'bp');S.cfAccept=onAccept;document.getElementById('mConfirm').classList.add('open');}
function cfAccept(){closeModal('mConfirm');if(S.cfAccept)S.cfAccept();}
function conflictModal(onRename,onReplace){S.cflRename=onRename;S.cflReplace=onReplace;document.getElementById('cflMsg').textContent='Ya existe un elemento con ese nombre en el destino. ¿Qué quieres hacer?';document.getElementById('mConflict').classList.add('open');}
function conflictResolve(action){closeModal('mConflict');if(action==='rename'&&S.cflRename)S.cflRename();else if(action==='replace'&&S.cflReplace)S.cflReplace();}
function closeModal(id){document.getElementById(id).classList.remove('open');}
document.querySelectorAll('.mo').forEach(m=>{m.addEventListener('click',e=>{if(e.target===m)m.classList.remove('open');});});

/* ══ OTRAS PÁGINAS ══ */
async function loadStarred(){const d=await api('GET','files/starred');const el=document.getElementById('sc');if(!d.ok||!d.files.length){el.innerHTML=`<div class="empty"><div class="ei">⭐</div><h3>Sin destacados</h3></div>`;return;}S.currentList=d.files;el.innerHTML=`<div class="fg">${d.files.map(f=>fCard(f)).join('')}</div>`;initInternalDrag();}
async function loadShares(){const d=await api('GET','shares');const el=document.getElementById('shc');if(!d.ok||!d.shares.length){el.innerHTML=`<div class="empty"><div class="ei">🔗</div><h3>Sin links compartidos</h3></div>`;return;}el.innerHTML=`<table><tr><th>Archivo</th><th>Link</th><th>Descargas</th><th>Expira</th><th></th></tr>${d.shares.map(s=>`<tr><td>${mIco(s.mime_type)} ${H(s.name)}</td><td><span class="su" style="display:inline-block" onclick="copyTok('${s.token}')">/s/${s.token.slice(0,12)}…</span></td><td>${s.downloads}${s.max_downloads?'/'+s.max_downloads:''}</td><td style="font-size:11px;color:var(--muted)">${s.expires_at?fmtD(s.expires_at):'—'}</td><td><button class="btn bd" style="padding:5px 11px;font-size:11px" onclick="delShare(${s.id})">Eliminar</button></td></tr>`).join('')}</table>`;}
function copyTok(t){navigator.clipboard.writeText(window.location.origin+'/s/'+t).then(()=>toast('Link copiado','success'));}
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
function updateTrashBar(){
  const bar=document.getElementById('trashSelBar');
  const cnt=document.getElementById('trashSelCount');
  if(bar)bar.classList.toggle('show',TS.sel.size>0);
  if(cnt)cnt.textContent=TS.sel.size+(TS.sel.size===1?' seleccionado':' seleccionados');
  // Actualizar visuales de selección
  document.querySelectorAll('.tc-item').forEach(el=>{
    const id=parseInt(el.dataset.id);
    el.classList.toggle('sel',TS.sel.has(id));
    const sc=el.querySelector('.tc-sel');
    if(sc)sc.classList.toggle('on',TS.sel.has(id));
  });
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
        <div class="fi-b"><div class="fn" title="${H(f.name)}">${H(f.name)}</div><div class="fm">${f.type==='folder'?'Carpeta':szH(f.size)}</div></div>
        <div class="fa" style="display:flex">${restBtn(f.id)}${delBtn(f.id)}</div>
      </div>`;
    }).join('')}</div>`;
  }else{
    el.innerHTML=`<div class="fl">${files.map(f=>`
      <div class="fr tc-item" data-id="${f.id}" onclick="trashToggleSel(${f.id})">
        <div class="rsel tc-sel" onclick="event.stopPropagation();trashToggleSel(${f.id})">${chk}</div>
        <div class="ri">${f.type==='folder'?'📁':mIco(f.mime_type)}</div>
        <div class="rn">${H(f.name)}</div>
        <div class="rs">${f.type==='file'?szH(f.size):'—'}</div>
        <div class="rd">${fmtD(f.trashed_at)}</div>
        <div class="ra" style="display:flex">${restBtn(f.id)}${delBtn(f.id)}</div>
      </div>`).join('')}</div>`;
  }
  updateTrashBar();
}
async function restoreIt(id){const d=await api('POST','trash/'+id);if(d.ok){toast('Restaurado','success');loadTrash();}else toast(d.error||d.message||'Error','error');}
async function bulkTrashRestore(){
  const ids=[...TS.sel];if(!ids.length)return;
  vaultConfirm('Restaurar elementos','¿Restaurar '+ids.length+' elemento(s)?','Restaurar',async()=>{
    let ok=0;for(const id of ids){const d=await api('POST','trash/'+id);if(d.ok)ok++;}
    toast(ok+' elemento(s) restaurado(s)','success');TS.sel.clear();loadTrash();
  });
}
async function bulkTrashDelete(){
  const ids=[...TS.sel];if(!ids.length)return;
  vaultConfirm('Eliminar definitivamente','Se eliminarán '+ids.length+' elemento(s). No se puede deshacer.','Eliminar',async()=>{
    let ok=0;for(const id of ids){const d=await api('DELETE','trash/'+id);if(d.ok)ok++;}
    toast(ok+' elemento(s) eliminado(s)','success');TS.sel.clear();loadTrash();
  },true);
}
function delIt(id){vaultConfirm('Eliminar definitivamente','Esta acción no se puede deshacer. ¿Eliminar permanentemente?','Eliminar',async()=>{const d=await api('DELETE','trash/'+id);if(d.ok){toast('Eliminado','info');loadTrash();}},true);}
function emptyTrash(){vaultConfirm('Vaciar papelera','Se eliminarán definitivamente todos los elementos de la papelera. ¿Continuar?','Vaciar',async()=>{const d=await api('DELETE','trash');if(d.ok){toast('Papelera vaciada','success');TS.sel.clear();loadTrash();}},true);}

/* ══ BÚSQUEDA ══ */
function debSearch(q){clearTimeout(S.st);document.getElementById('clrBtn').classList.toggle('show',!!q.trim());if(!q.trim()){if(S.page==='search')showPage('files');return;}S.st=setTimeout(()=>doSearch(q),350);}
function clearSearch(){document.getElementById('searchInput').value='';document.getElementById('clrBtn').classList.remove('show');if(S.page==='search')showPage('files');}
async function doSearch(q){document.querySelectorAll('.page').forEach(p=>p.classList.remove('active'));document.getElementById('page-search').classList.add('active');S.page='search';const d=await api('GET','search?q='+encodeURIComponent(q));const el=document.getElementById('src');if(!d.ok||!d.files.length){el.innerHTML=`<div class="empty"><div class="ei">🔍</div><h3>Sin resultados</h3></div>`;return;}S.currentList=d.files;el.innerHTML=`<div class="fg">${d.files.map(f=>fCard(f)).join('')}</div>`;initInternalDrag();}

/* ══ ADMIN ══ */
async function loadAdmin(){const[sd,ud]=await Promise.all([api('GET','admin/stats'),api('GET','admin/users')]);const el=document.getElementById('ac');const s=sd.stats||{};el.innerHTML=`<div class="sgr"><div class="stc"><div class="sic">👥</div><div class="sl">Usuarios</div><div class="sv">${s.users||0}</div></div><div class="stc"><div class="sic">📄</div><div class="sl">Archivos</div><div class="sv">${s.files||0}</div></div><div class="stc"><div class="sic">💾</div><div class="sl">Almacenamiento</div><div class="sv" style="font-size:19px">${szH(s.total_size||0)}</div></div><div class="stc"><div class="sic">🔗</div><div class="sl">Links activos</div><div class="sv">${s.shares||0}</div></div></div><div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:12px"><h3 style="font-family:'Sora';font-weight:700">Usuarios</h3><button class="btn bp" onclick="document.getElementById('mNewUser').classList.add('open')">+ Nuevo usuario</button></div><table><tr><th>Usuario</th><th class="adminmail">Email</th><th>Rol</th><th>Cuota</th><th class="adminlogin">Último acceso</th><th></th></tr>${(ud.users||[]).map(u=>`<tr><td><strong>${H(u.username)}</strong>${u.display_name&&u.display_name!==u.username?`<br><span style="font-size:11px;color:var(--muted)">${H(u.display_name)}</span>`:''}</td><td class="adminmail" style="font-size:12px">${H(u.email)}</td><td><span class="rb ${u.role==='admin'?'rba':'rbu'}">${u.role}</span></td><td><div class="qedit"><span style="font-size:11px;color:var(--muted)">${szH(u.storage_used)}/</span><input type="number" id="q_${u.id}" value="${Math.round(u.storage_quota/1073741824)}" min="1"><span class="un2">GB</span><button class="qsave" onclick="saveQuota(${u.id})" title="Guardar cuota">✓</button></div></td><td class="adminlogin" style="font-size:11px;color:var(--muted)">${u.last_login?fmtD(u.last_login):'Nunca'}</td><td><button class="btn bd" style="padding:5px 11px;font-size:11px" onclick="delUser(${u.id})">Eliminar</button></td></tr>`).join('')}</table>`;}
async function saveQuota(id){const gb=parseInt(document.getElementById('q_'+id).value)||1;const d=await api('PATCH','admin/users/'+id,{storage_quota:gb*1073741824});if(d.ok)toast('Cuota actualizada','success');else toast(d.message||'Error','error');}
async function createUser(){const d=await api('POST','admin/users',{username:document.getElementById('nu-u').value,email:document.getElementById('nu-e').value,display_name:document.getElementById('nu-n').value,password:document.getElementById('nu-p').value,role:document.getElementById('nu-r').value,storage_quota:(parseInt(document.getElementById('nu-q').value)||10)*1073741824});if(d.ok){toast('Usuario creado','success');closeModal('mNewUser');loadAdmin();}else toast(d.message||d.error||'Error','error');}
function delUser(id){vaultConfirm('Eliminar usuario','Se eliminará el usuario y todos sus archivos. ¿Continuar?','Eliminar',async()=>{const d=await api('DELETE','admin/users/'+id);if(d.ok){toast('Usuario eliminado','success');loadAdmin();}else toast(d.message||'Error','error');},true);}

/* ══ AJUSTES ══ */
async function loadSettings(){const me=await api('GET','auth/me');const u=me.user||{};const el=document.getElementById('stc');el.innerHTML=`<div class="setg"><div class="sc"><h3>Perfil</h3><div class="mf"><label>Nombre visible</label><input type="text" id="st-n" value="${H(u.display_name||'')}"></div><div class="mf"><label>Email</label><input type="email" id="st-e" value="${H(u.email||'')}"></div><button class="btn bp" onclick="saveProfile()">Guardar</button></div><div class="sc"><h3>Cambiar contraseña</h3><div class="mf"><label>Actual</label><input type="password" id="st-cp"></div><div class="mf"><label>Nueva</label><input type="password" id="st-np"></div><div class="mf"><label>Confirmar</label><input type="password" id="st-pp"></div><button class="btn bp" onclick="chgPass()">Cambiar</button></div><div class="sc full"><div style="display:flex;align-items:center;gap:10px;margin-bottom:14px"><h3 style="margin:0">Autenticación en dos pasos (2FA)</h3><span class="ts ${u.totp_enabled?'ton':'toff'}">${u.totp_enabled?'Activo':'Inactivo'}</span></div><p style="font-size:13px;color:var(--muted);margin-bottom:16px;line-height:1.6">${u.totp_enabled?'El 2FA está activo. Necesitarás un código de tu app autenticadora en cada inicio de sesión.':'Añade una capa extra de seguridad. Compatible con Google Authenticator, Authy, Bitwarden, 1Password.'}</p><div id="ta">${u.totp_enabled?`<div class="mf" style="max-width:280px"><label>Confirma tu contraseña para desactivar</label><input type="password" id="dp"></div><button class="btn bd" onclick="disableTotp()">Desactivar 2FA</button>`:`<button class="btn bp" onclick="startTotp()">Activar 2FA</button>`}</div></div></div>`;}
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
async function saveProfile(){const d=await api('POST','user/profile',{display_name:document.getElementById('st-n').value,email:document.getElementById('st-e').value});if(d.ok)toast('Guardado','success');else toast(d.error||'Error','error');}
async function chgPass(){const c=document.getElementById('st-cp').value,n=document.getElementById('st-np').value,p=document.getElementById('st-pp').value;if(n!==p)return toast('Las contraseñas no coinciden','error');if(n.length<8)return toast('Mínimo 8 caracteres','error');const d=await api('POST','user/password',{current:c,new:n});if(d.ok){toast('Contraseña cambiada','success');['st-cp','st-np','st-pp'].forEach(i=>document.getElementById(i).value='');}else toast(d.message||'Error','error');}

/* ══ TEMA ══ */
async function toggleTheme(){const cur=document.documentElement.getAttribute('data-theme')||'dark';const next=cur==='dark'?'light':'dark';document.documentElement.setAttribute('data-theme',next);setThemeIcon(next);await api('POST','user/theme',{theme:next});}
function setThemeIcon(t){document.getElementById('themeBtn').innerHTML=t==='dark'?'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="17" height="17"><path d="M21 12.8A9 9 0 1111.2 3 7 7 0 0021 12.8z"/></svg>':'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="17" height="17"><circle cx="12" cy="12" r="5"/><path d="M12 1v2M12 21v2M4.2 4.2l1.4 1.4M18.4 18.4l1.4 1.4M1 12h2M21 12h2M4.2 19.8l1.4-1.4M18.4 5.6l1.4-1.4"/></svg>';}
async function logout(){await api('POST','auth/logout');window.location.href='/';}

/* ══ HELPERS ══ */
function H(s){return String(s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');}
function esc(s){return String(s||'').replace(/\\/g,'\\\\').replace(/'/g,"\\'").replace(/"/g,'&quot;');}
function szH(b){b=parseInt(b)||0;const u=['B','KB','MB','GB','TB'];let i=0;while(b>=1024&&i<4){b/=1024;i++;}return b.toFixed(i?1:0)+' '+u[i];}
function fmtD(s){if(!s)return'—';return new Date(s.replace(' ','T')).toLocaleDateString('es-ES',{day:'2-digit',month:'short',year:'numeric'});}
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
setThemeIcon(document.documentElement.getAttribute('data-theme')||'dark');
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
