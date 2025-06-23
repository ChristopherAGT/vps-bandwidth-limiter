#!/bin/bash

# Colores
verde="\e[1;32m"
amarillo="\e[1;33m"
rojo="\e[1;31m"
cyan="\e[1;36m"
neutro="\e[0m"

CONFIG="/etc/limitador-banda.conf"
STATUS="/etc/limitador-banda.status.json"
SCRIPT_APLICADOR="/usr/local/bin/limitar-banda.sh"
LOG="/var/log/limitador-banda.log"
DEST="$HOME/.local/bin/bandwidth-manager"

# Validar root para las operaciones que lo requieran
if [[ $EUID -ne 0 ]]; then
  echo -e "${rojo}❌ Este script debe ejecutarse como root.${neutro}"
  exit 1
fi

# Instalar dependencias jq y tc si no existen
instalar_dependencias() {
  local paquetes="jq iproute2"
  echo -e "${amarillo}🔍 Verificando dependencias necesarias...${neutro}"

  local faltantes=()
  for p in jq tc; do
    if ! command -v $p &>/dev/null; then
      faltantes+=($p)
    fi
  done
  if [[ ${#faltantes[@]} -eq 0 ]]; then
    echo -e "${verde}✔️ jq y tc ya están instalados.${neutro}"
    return
  fi

  if command -v apt &>/dev/null; then
    apt update -y
    apt install -y "${faltantes[@]}"
  elif command -v dnf &>/dev/null; then
    dnf install -y "${faltantes[@]}"
  elif command -v yum &>/dev/null; then
    yum install -y "${faltantes[@]}"
  elif command -v apk &>/dev/null; then
    apk add "${faltantes[@]}"
  else
    echo -e "${rojo}❌ No se detectó gestor de paquetes compatible para instalar jq y tc.${neutro}"
    exit 1
  fi

  echo -e "${verde}✔️ Dependencias instaladas correctamente.${neutro}"
}

# Detectar interfaz de red automáticamente o permitir seleccionar
detectar_interfaz() {
  INTERFAZ=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | head -n1)
  if [[ -z "$INTERFAZ" ]]; then
    echo -e "${amarillo}⚠️ No se detectó automáticamente la interfaz. Seleccione manualmente:${neutro}"
    select opt in $(ls /sys/class/net); do
      INTERFAZ=$opt
      break
    done
  fi
}

# Solicitar límite de Mbps y validar
solicitar_limite() {
  while true; do
    read -p $'\n📥 ¿Cuántos Mbps deseas permitir? (Ej: 15): ' LIMITE
    if [[ "$LIMITE" =~ ^[0-9]+$ && "$LIMITE" -gt 0 ]]; then
      break
    else
      echo -e "${rojo}❌ Valor inválido. Ingresa solo números enteros positivos.${neutro}"
    fi
  done
}

# Aplicar limitador con tc
aplicar_limite() {
  tc qdisc del dev "$INTERFAZ" root 2>/dev/null || true
  tc qdisc add dev "$INTERFAZ" root handle 1: htb default 30
  tc class add dev "$INTERFAZ" parent 1: classid 1:1 htb rate "${LIMITE}mbit" ceil "${LIMITE}mbit"
  tc class add dev "$INTERFAZ" parent 1:1 classid 1:30 htb rate "${LIMITE}mbit" ceil "${LIMITE}mbit"
}

# Guardar configuración
guardar_config() {
  echo "INTERFAZ=$INTERFAZ" > "$CONFIG"
  echo "LIMITE=$LIMITE" >> "$CONFIG"
  echo "{\"interfaz\":\"$INTERFAZ\",\"limite_mbps\":$LIMITE,\"aplicado\":true,\"ultima_aplicacion\":\"$(date -u +"%Y-%m-%d %H:%M:%S UTC")\"}" > "$STATUS"
  echo "$(date) - Aplicado $LIMITE Mbps en $INTERFAZ" >> "$LOG"
}

# Crear script aplicador permanente para reinicios
crear_script_aplicador() {
  cat <<EOF > "$SCRIPT_APLICADOR"
#!/bin/bash
source $CONFIG
tc qdisc del dev \$INTERFAZ root 2>/dev/null || true
tc qdisc add dev \$INTERFAZ root handle 1: htb default 30
tc class add dev \$INTERFAZ parent 1: classid 1:1 htb rate \${LIMITE}mbit ceil \${LIMITE}mbit
tc class add dev \$INTERFAZ parent 1:1 classid 1:30 htb rate \${LIMITE}mbit ceil \${LIMITE}mbit
EOF
  chmod +x "$SCRIPT_APLICADOR"
}

# Agregar script al crontab para aplicarlo al reiniciar
agregar_crontab() {
  (crontab -l 2>/dev/null | grep -v "$SCRIPT_APLICADOR" ; echo "@reboot $SCRIPT_APLICADOR") | crontab -
}

# Eliminar limitación y limpiar archivos
eliminar_limite() {
  if [[ -f "$CONFIG" ]]; then
    source "$CONFIG"
    tc qdisc del dev "$INTERFAZ" root 2>/dev/null || true
    rm -f "$CONFIG" "$STATUS" "$SCRIPT_APLICADOR"
    crontab -l 2>/dev/null | grep -v "$SCRIPT_APLICADOR" | crontab -
    echo -e "${verde}✅ Limitador eliminado completamente.${neutro}"
  else
    echo -e "${amarillo}⚠️ No hay limitación activa para eliminar.${neutro}"
  fi
}

# Aplicar límite temporal (minutos)
aplicar_temporal() {
  while true; do
    read -p "⏳ ¿Cuántos minutos quieres aplicar el límite? (Ej: 60): " MIN
    if [[ "$MIN" =~ ^[0-9]+$ && "$MIN" -gt 0 ]]; then
      break
    else
      echo -e "${rojo}❌ Valor inválido. Ingresa solo números enteros positivos.${neutro}"
    fi
  done
  solicitar_limite
  aplicar_limite
  echo "$(date) - Aplicado temporalmente $LIMITE Mbps por $MIN minutos en $INTERFAZ" >> "$LOG"
  echo -e "${verde}✔️ Límite aplicado por $MIN minutos.${neutro}"
  sleep $((MIN * 60))
  tc qdisc del dev "$INTERFAZ" root 2>/dev/null || true
  echo "$(date) - Límite temporal eliminado" >> "$LOG"
  echo -e "${verde}✔️ Límite temporal finalizado.${neutro}"
}

# Prueba de red (ping google.com)
prueba_red() {
  echo -e "${amarillo}📡 Ping a google.com...${neutro}"
  ping -c 4 google.com
}

# Ver estado actual (mostrar JSON formateado)
ver_estado() {
  echo -e "\n📊 ${cyan}Estado actual:${neutro}"
  if [[ -f "$STATUS" ]]; then
    jq . "$STATUS"
  else
    echo -e "${amarillo}⚠️ No hay configuración activa.${neutro}"
  fi
}

# Ver log de actividad
ver_log() {
  if [[ -f "$LOG" ]]; then
    cat "$LOG"
  else
    echo -e "${amarillo}📂 No hay registros aún.${neutro}"
  fi
}

# Instalar script como comando global
instalar_comando() {
  mkdir -p "$HOME/.local/bin"
  cp "$0" "$DEST"
  chmod +x "$DEST"

  if ! echo "$PATH" | grep -q "$HOME/.local/bin"; then
    local shell_rc
    if [[ -n "$ZSH_VERSION" ]]; then
      shell_rc="$HOME/.zshrc"
    elif [[ -n "$BASH_VERSION" ]]; then
      shell_rc="$HOME/.bashrc"
    else
      shell_rc="$HOME/.profile"
    fi
    echo "export PATH=\$HOME/.local/bin:\$PATH" >> "$shell_rc"
    echo -e "${amarillo}⚠️ Añadido export PATH a $shell_rc.${neutro}"
    echo "Por favor reinicia tu terminal o ejecuta: source $shell_rc"
  fi

  echo -e "${verde}✅ Instalación completada. Usa el comando 'bandwidth-manager'.${neutro}"
}

# Menú principal
menu() {
  while true; do
    echo -e "${cyan}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🚦 GESTOR DE LIMITADOR DE ANCHO DE BANDA"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${neutro}"
    echo "1️⃣ Establecer límite de banda"
    echo "2️⃣ Ver configuración actual"
    echo "3️⃣ Cambiar límite actual"
    echo "4️⃣ Aplicar límite temporal (minutos)"
    echo "5️⃣ Eliminar limitación"
    echo "6️⃣ Ver log de actividad"
    echo "7️⃣ Prueba de red (ping)"
    echo "8️⃣ 🔥 Desinstalar completamente"
    echo "0️⃣ Salir"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    read -p "Seleccione una opción: " OPCION

    case $OPCION in
      1)
        instalar_dependencias
        detectar_interfaz
        solicitar_limite
        aplicar_limite
        guardar_config
        crear_script_aplicador
        agregar_crontab
        echo -e "${verde}✅ Límite aplicado correctamente.${neutro}"
        ;;
      2) ver_estado ;;
      3)
        if [[ ! -f "$CONFIG" ]]; then
          echo -e "${rojo}❌ No hay configuración previa.${neutro}"
          ;;
        else
          source "$CONFIG"
          solicitar_limite
          aplicar_limite
          guardar_config
          echo -e "${verde}✅ Límite actualizado a ${LIMITE} Mbps.${neutro}"
        fi
        ;;
      4)
        detectar_interfaz
        aplicar_temporal
        ;;
      5) eliminar_limite ;;
      6) ver_log ;;
      7) prueba_red ;;
      8)
        read -p "$(echo -e ${rojo}⚠️ Esto eliminará todos los archivos y el comando. ¿Continuar? (s/n): ${neutro})" CONFIRMAR
        if [[ "$CONFIRMAR" == "s" ]]; then
        eliminar_limite
          rm -f "$DEST"
          echo -e "${verde}✅ Comando 'bandwidth-manager' desinstalado.${neutro}"
          echo "Saliendo..."
          exit 0
        else
          echo "Operación cancelada."
        fi
        ;;
      0)
        echo "Saliendo..."
        exit 0
        ;;
      *)
        echo -e "${rojo}❌ Opción inválida. Intenta nuevamente.${neutro}"
        ;;
    esac
    read -p "Presiona ENTER para continuar..."
  done
}

# Auto-instalar si se ejecuta fuera de ~/.local/bin
if [[ "$0" != "$DEST" ]]; then
  instalar_dependencias
  instalar_comando
  exit 0
fi

# Ejecutar menú
menu
