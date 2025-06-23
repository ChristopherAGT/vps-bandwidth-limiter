#!/bin/bash

# 🎨 Colores
verde="\e[1;32m"
rojo="\e[1;31m"
amarillo="\e[1;33m"
cyan="\e[1;36m"
neutro="\e[0m"

CONFIG="/etc/limitador-banda.conf"
STATUS="/etc/limitador-banda.status.json"
SCRIPT_APLICADOR="/usr/local/bin/limitar-banda.sh"
LOG="/var/log/limitador-banda.log"

# 🔐 Validar root
[[ $EUID -ne 0 ]] && echo -e "${rojo}❌ Este script debe ejecutarse como root.${neutro}" && exit 1

# 📦 Instalar tc si no está
instalar_tc() {
  if ! command -v tc &>/dev/null; then
    echo -e "${amarillo}📦 Instalando tc...${neutro}"
    if command -v apt &>/dev/null; then
      apt update -y && apt install -y iproute2
    elif command -v dnf &>/dev/null; then
      dnf install -y iproute
    elif command -v yum &>/dev/null; then
      yum install -y iproute
    elif command -v apk &>/dev/null; then
      apk add iproute2
    else
      echo -e "${rojo}❌ No se encontró un gestor de paquetes compatible.${neutro}"
      exit 1
    fi
  fi
}

# 📡 Detectar o seleccionar interfaz
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

# 📥 Solicitar límite
solicitar_limite() {
  read -p $'\n📥 ¿Cuántos Mbps deseas permitir? (Ej: 15): ' LIMITE
  if ! [[ "$LIMITE" =~ ^[0-9]+$ ]]; then
    echo -e "${rojo}❌ Valor inválido. Solo se aceptan números enteros.${neutro}"
    exit 1
  fi
}

# 🚦 Aplicar limitador
aplicar_limite() {
  tc qdisc del dev "$INTERFAZ" root 2>/dev/null
  tc qdisc add dev "$INTERFAZ" root handle 1: htb default 30
  tc class add dev "$INTERFAZ" parent 1: classid 1:1 htb rate "${LIMITE}mbit" ceil "${LIMITE}mbit"
  tc class add dev "$INTERFAZ" parent 1:1 classid 1:30 htb rate "${LIMITE}mbit" ceil "${LIMITE}mbit"
}

# 💾 Guardar configuración
guardar_config() {
  echo "INTERFAZ=$INTERFAZ" > "$CONFIG"
  echo "LIMITE=$LIMITE" >> "$CONFIG"
  echo "{\"interfaz\":\"$INTERFAZ\",\"limite_mbps\":$LIMITE,\"aplicado\":true,\"ultima_aplicacion\":\"$(date -u +"%Y-%m-%d %H:%M:%S UTC")\"}" > "$STATUS"
  echo "$(date) - Aplicado $LIMITE Mbps en $INTERFAZ" >> "$LOG"
}

# 📜 Crear script permanente
crear_script_aplicador() {
  cat <<EOF > "$SCRIPT_APLICADOR"
#!/bin/bash
source $CONFIG
tc qdisc del dev \$INTERFAZ root 2>/dev/null
tc qdisc add dev \$INTERFAZ root handle 1: htb default 30
tc class add dev \$INTERFAZ parent 1: classid 1:1 htb rate \${LIMITE}mbit ceil \${LIMITE}mbit
tc class add dev \$INTERFAZ parent 1:1 classid 1:30 htb rate \${LIMITE}mbit ceil \${LIMITE}mbit
EOF
  chmod +x "$SCRIPT_APLICADOR"
}

# 🔁 Agregar a crontab
agregar_crontab() {
  crontab -l 2>/dev/null | grep -q "$SCRIPT_APLICADOR" || (crontab -l 2>/dev/null; echo "@reboot $SCRIPT_APLICADOR") | crontab -
}

# 🧼 Eliminar limitación
eliminar_limite() {
  source "$CONFIG" 2>/dev/null
  tc qdisc del dev "$INTERFAZ" root 2>/dev/null
  rm -f "$CONFIG" "$STATUS" "$SCRIPT_APLICADOR"
  crontab -l 2>/dev/null | grep -v "$SCRIPT_APLICADOR" | crontab -
  echo -e "${verde}✅ Limitador eliminado completamente.${neutro}"
}

# ⏱ Aplicar por tiempo
aplicar_temporal() {
  read -p "⏳ ¿Cuántos minutos quieres aplicar el límite? (Ej: 60): " MIN
  if ! [[ "$MIN" =~ ^[0-9]+$ ]]; then
    echo -e "${rojo}❌ Valor inválido.${neutro}"
    return
  fi
  solicitar_limite
  aplicar_limite
  echo "$(date) - Aplicado temporalmente $LIMITE Mbps por $MIN minutos en $INTERFAZ" >> "$LOG"
  sleep $((MIN * 60))
  tc qdisc del dev "$INTERFAZ" root 2>/dev/null
  echo "$(date) - Límite temporal eliminado" >> "$LOG"
  echo -e "${verde}✔️ Límite temporal finalizado.${neutro}"
}

# 🌐 Prueba de red
prueba_red() {
  echo -e "${amarillo}📡 Ping a google.com...${neutro}"
  ping -c 4 google.com
}

# 📖 Ver estado
ver_estado() {
  echo -e "\n📊 ${cyan}Estado actual:${neutro}"
  [[ -f "$STATUS" ]] && cat "$STATUS" | jq . || echo "⚠️ No hay configuración activa."
}

# 📖 Ver log
ver_log() {
  [[ -f "$LOG" ]] && cat "$LOG" || echo -e "${amarillo}📂 No hay registros aún.${neutro}"
}

# 📋 Menú
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
      instalar_tc
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
      source "$CONFIG" 2>/dev/null || { echo -e "${rojo}❌ No hay configuración previa.${neutro}"; continue; }
      solicitar_limite
      aplicar_limite
      guardar_config
      echo -e "${verde}✅ Límite actualizado a ${LIMITE} Mbps.${neutro}"
      ;;
    4)
      detectar_interfaz
      aplicar_temporal
      ;;
    5)
      eliminar_limite
      ;;
    6)
      ver_log
      ;;
    7)
      prueba_red
      ;;
    8)
      echo -e "${rojo}⚠️ Esto eliminará todos los archivos del limitador. ¿Deseas continuar? (s/n): ${neutro}"
      read CONFIRMAR
      [[ "$CONFIRMAR" == "s" ]] && eliminar_limite && rm -f "$LOG" "$0" && echo -e "${verde}🔥 Script eliminado. Adiós.${neutro}" && exit 0
      ;;
    0) exit 0 ;;
    *) echo -e "${rojo}❌ Opción no válida.${neutro}" ;;
  esac
  echo -e "\nPresiona ENTER para continuar..."
  read
done
}

menu
