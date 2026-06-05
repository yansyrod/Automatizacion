# Vault — Cloud Storage personal para Proxmox VE

Vault es un helper script para Proxmox VE que crea automáticamente un contenedor LXC Debian 12 e instala una nube personal con interfaz web, almacenamiento de archivos, usuarios, 2FA, visor de archivos, streaming y soporte SMTP opcional.

El proyecto está pensado para montarlo rápido en un home server, especialmente detrás de Cloudflare Tunnel, sin tener que instalar manualmente Apache, PHP, MariaDB ni la aplicación.

## Instalación rápida

Ejecutar directamente desde el host de Proxmox VE:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/yansyrod/Automatizacion/main/install-vault.sh)"
```

## Qué instala

- Contenedor LXC Debian 12 en Proxmox VE.
- Apache 2.
- PHP 8.2 con extensiones necesarias.
- MariaDB.
- Vault como aplicación web en `/var/www/vault`.
- Sistema de usuarios con administrador inicial.
- Autenticación con soporte 2FA/TOTP.
- Gestor de archivos y carpetas.
- Papelera.
- Favoritos.
- Compartición de archivos mediante enlaces.
- Envío de enlaces por correo si se configura SMTP.
- Miniaturas para imágenes.
- Streaming de vídeo/audio con soporte Range.
- Configuración compatible con uso detrás de Cloudflare Tunnel.

## Requisitos

- Proxmox VE.
- Ejecutar el script desde el host de Proxmox, no dentro de una VM ni dentro de otro contenedor.
- Conectividad a Internet desde el host y desde el contenedor.
- Storage compatible con `rootdir` para crear el LXC.
- Storage con soporte `vztmpl` para descargar o usar el template Debian 12.

## Modos de instalación

El instalador permite dos modos:

### Modo rápido

Usa valores por defecto:

- CT ID: siguiente ID libre detectado por Proxmox.
- Hostname: `vault`.
- CPU: 2 cores.
- RAM: 2048 MB.
- Disco: 20 GB.
- Red: DHCP.
- Storage: primer storage disponible compatible.

### Modo avanzado

Permite personalizar:

- ID del contenedor.
- Hostname.
- CPU.
- RAM.
- Tamaño de disco.
- Storage del contenedor.
- Storage del template.
- Bridge de red.
- IP DHCP o IP fija.
- Gateway.

## Datos que pide el instalador

Durante la instalación se solicitan:

- Nombre visible de la app.
- Usuario administrador.
- Contraseña del administrador.
- Email del administrador.
- Configuración SMTP opcional.

La contraseña interna del contenedor y la contraseña de base de datos se generan automáticamente.

## SMTP opcional

El instalador puede configurar SMTP para enviar enlaces compartidos por correo.

Soporta:

- SSL/TLS, normalmente puerto 465.
- STARTTLS, normalmente puerto 587.
- Sin cifrado, no recomendado.

Si no configuras SMTP, Vault seguirá funcionando, pero no enviará correos.

## Después de instalar

Al finalizar, entra por navegador a la IP asignada al contenedor.

Si usas Cloudflare Tunnel, apunta el túnel hacia el servicio HTTP del contenedor.

Ejemplo:

```text
http://IP_DEL_CONTENEDOR:80
```

## Validar el script antes de ejecutarlo

Puedes descargarlo y validar sintaxis Bash antes de lanzarlo:

```bash
curl -fsSL https://raw.githubusercontent.com/yansyrod/Automatizacion/main/install-vault.sh -o install-vault.sh
bash -n install-vault.sh
bash install-vault.sh
```

## Seguridad

- El script debe ejecutarse como administrador en el host Proxmox.
- Revisa siempre el contenido antes de ejecutar scripts remotos con `curl | bash`.
- La app está pensada para estar detrás de HTTPS, por ejemplo mediante Cloudflare Tunnel o reverse proxy.
- La cookie de sesión no se marca como `Secure` porque el diseño contempla TLS terminado en Cloudflare o proxy externo y HTTP interno hacia el contenedor.

## Autor

- Yansy Rodriguez
- Assisted by ChatGPT

## Licencia

MIT
