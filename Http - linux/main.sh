#!/bin/bash
# =================================================
# SISTEMA ADMIN SERVIDORES LINUX
# =================================================
clear

PUERTOS_USADOS=()

# ── FIX RED: Forzar IPv4 y eliminar ruta incorrecta ───────────
if [ ! -f /etc/apt/apt.conf.d/99force-ipv4 ]; then
    echo 'Acquire::ForceIPv4 "true";' | sudo tee /etc/apt/apt.conf.d/99force-ipv4 > /dev/null
fi
sudo ip route del default via 1.1.1.1 dev ens34 2>/dev/null || true

apt_update() {
    sudo apt-get update -y \
        -o Acquire::ForceIPv4=true \
        -o Acquire::http::Timeout=15 \
        2>&1 | grep -E "^(Err|E:)" || true
}

# ── FUNCIONES ───────────────────────────────────

validar_puerto(){
    while true; do
        read -p "Ingrese puerto: " PUERTO
        if ! [[ $PUERTO =~ ^[0-9]+$ ]]; then
            echo "Puerto invalido"
            continue
        fi
        if [ $PUERTO -lt 1 ] || [ $PUERTO -gt 65535 ]; then
            echo "Puerto fuera de rango (1-65535)"
            continue
        fi
        local DUPLICADO=false
        for p in "${PUERTOS_USADOS[@]}"; do
            if [ "$p" == "$PUERTO" ]; then
                echo "Ese puerto ya está en uso en el script"
                DUPLICADO=true
                break
            fi
        done
        $DUPLICADO && continue

        if sudo lsof -i :$PUERTO &>/dev/null; then
            echo "Puerto $PUERTO ya está en uso por otro proceso, elige otro"
            continue
        fi
        PUERTOS_USADOS+=($PUERTO)
        break
    done
}

crear_usuario(){
    local USUARIO=$1
    if id "$USUARIO" &>/dev/null; then
        echo "Usuario $USUARIO ya existe"
    else
        sudo useradd -r -s /usr/sbin/nologin $USUARIO
        echo "Usuario $USUARIO creado"
    fi
}

mostrar_versiones(){
    local PAQUETE=$1
    mapfile -t versiones < <(apt-cache madison $PAQUETE 2>/dev/null | awk '{print $3}' | sort -u)
    if [ ${#versiones[@]} -eq 0 ]; then
        echo "No hay versiones disponibles para $PAQUETE"
        echo "Ejecute: sudo apt update"
        return 1
    fi
    echo "Versiones disponibles de $PAQUETE:"
    for i in "${!versiones[@]}"; do
        echo "$((i+1))) ${versiones[$i]}"
    done
    while true; do
        read -p "Seleccione numero de version: " op
        if [[ ! $op =~ ^[0-9]+$ ]] || [ $op -lt 1 ] || [ $op -gt ${#versiones[@]} ]; then
            echo "Opcion invalida"
        else
            VERSION=${versiones[$((op-1))]}
            break
        fi
    done
}

configurar_firewall(){
    if command -v ufw &>/dev/null; then
        sudo ufw delete allow $PUERTO/tcp 2>/dev/null
        sudo ufw allow $PUERTO/tcp > /dev/null
        echo "Regla de firewall agregada para puerto $PUERTO"
    else
        echo "ufw no disponible, omitiendo firewall"
    fi
}

crear_index(){
    local SERVICIO=$1
    local VER=$2
    sudo mkdir -p /var/www/$SERVICIO
    sudo bash -c "cat > /var/www/$SERVICIO/index.html" << EOF
<html>
<head><title>$SERVICIO</title></head>
<body>
<h1>Servidor $SERVICIO funcionando</h1>
<p>Version: $VER</p>
<p>Puerto: $PUERTO</p>
</body>
</html>
EOF
}

detectar_instalacion(){
    local PAQUETE=$1
    local INSTALADO
    INSTALADO=$(dpkg -l 2>/dev/null | grep "^ii" | grep "$PAQUETE" | awk '{print $2,$3}' | head -n1)
    if [ -n "$INSTALADO" ]; then
        echo "$INSTALADO"
        return 0
    else
        return 1
    fi
}

# ── INSTALACIÓN Y ACTUALIZACIÓN ─────────────────

instalar_apache(){
    echo "Actualizando repositorios..."
    apt_update

    INST=$(detectar_instalacion apache2)
    if [ $? -eq 0 ]; then
        echo "Apache ya está instalado: $INST"
        read -p "Desea reinstalar/actualizar Apache? (s/n): " R
        [[ $R != [sS] ]] && return
    fi

    mostrar_versiones apache2 || return 1
    validar_puerto
    crear_usuario apache

    echo "Instalando Apache2..."
    if ! sudo apt-get install -y apache2 apache2-bin apache2-utils apache2-data; then
        echo "ERROR: Fallo la instalacion de Apache."
        return 1
    fi

    # FIX: Escribir ports.conf desde cero (evita acumulacion de puertos con sed)
    sudo bash -c "cat > /etc/apache2/ports.conf" << EOF
# Generado por admin_servidores.sh
Listen $PUERTO

<IfModule ssl_module>
        Listen 443
</IfModule>
<IfModule mod_gnutls.c>
        Listen 443
</IfModule>
EOF

    # FIX: Escribir 000-default.conf desde cero (evita VirtualHost corrupto)
    sudo a2ensite 000-default.conf 2>/dev/null || true
    sudo bash -c "cat > /etc/apache2/sites-enabled/000-default.conf" << EOF
<VirtualHost *:$PUERTO>
        ServerAdmin webmaster@localhost
        DocumentRoot /var/www/html
        ErrorLog \${APACHE_LOG_DIR}/error.log
        CustomLog \${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
EOF

    # FIX: Agregar ServerName para evitar warning
    if ! grep -q "ServerName" /etc/apache2/apache2.conf; then
        echo "ServerName localhost" | sudo tee -a /etc/apache2/apache2.conf > /dev/null
    fi

    sudo rm -rf /var/www/html/*
    crear_index apache "$VERSION"
    sudo cp /var/www/apache/index.html /var/www/html/index.html

    if sudo apache2ctl configtest 2>&1 | grep -q "Syntax OK"; then
        sudo systemctl daemon-reload
        sudo systemctl enable apache2
        sudo systemctl restart apache2
        configurar_firewall
        echo "✓ Apache instalado y corriendo en puerto $PUERTO"
        echo "  Accede en: http://$(hostname -I | awk '{print $1}'):$PUERTO"
    else
        echo "ERROR: Configuracion invalida."
        sudo apache2ctl configtest
        return 1
    fi
}

instalar_nginx(){
    echo "Actualizando repositorios..."
    apt_update

    INST=$(detectar_instalacion nginx)
    if [ $? -eq 0 ]; then
        echo "Nginx ya está instalado: $INST"
        read -p "Desea reinstalar/actualizar Nginx? (s/n): " R
        [[ $R != [sS] ]] && return
    fi

    mostrar_versiones nginx || return 1
    validar_puerto
    crear_usuario www-data

    echo "Instalando Nginx..."
    if ! sudo apt-get install -y nginx; then
        echo "ERROR: Fallo la instalacion de Nginx."
        return 1
    fi

    NGINX_CONF=""
    [ -f /etc/nginx/sites-enabled/default ]  && NGINX_CONF="/etc/nginx/sites-enabled/default"
    [ -z "$NGINX_CONF" ] && [ -f /etc/nginx/conf.d/default.conf ] && NGINX_CONF="/etc/nginx/conf.d/default.conf"

    if [ -n "$NGINX_CONF" ]; then
        sudo sed -i "s/listen 80 default_server;/listen $PUERTO default_server;/g" $NGINX_CONF
        sudo sed -i "s/listen \[::\]:80 default_server;/listen [::]:$PUERTO default_server;/g" $NGINX_CONF
    fi

    sudo rm -f /var/www/html/index.nginx-debian.html
    crear_index nginx "$VERSION"
    sudo cp /var/www/nginx/index.html /var/www/html/index.html

    if sudo nginx -t 2>&1 | grep -q "successful"; then
        sudo systemctl daemon-reload
        sudo systemctl enable nginx
        sudo systemctl restart nginx
        configurar_firewall
        echo "✓ Nginx instalado y corriendo en puerto $PUERTO"
    else
        echo "ERROR: Configuracion invalida."
        sudo nginx -t
        return 1
    fi
}

instalar_tomcat(){
    echo "Actualizando repositorios..."
    apt_update

    mapfile -t tomcats < <(apt-cache search tomcat 2>/dev/null | grep '^tomcat' | grep -E 'tomcat[0-9]+' | awk '{print $1}')
    if [ ${#tomcats[@]} -eq 0 ]; then
        echo "No hay versiones de Tomcat disponibles"
        return 1
    fi

    echo "Versiones disponibles de Tomcat:"
    for i in "${!tomcats[@]}"; do
        echo "$((i+1))) ${tomcats[$i]}"
    done

    while true; do
        read -p "Seleccione numero de version: " op
        if [[ ! $op =~ ^[0-9]+$ ]] || [ $op -lt 1 ] || [ $op -gt ${#tomcats[@]} ]; then
            echo "Opcion invalida"
        else
            TOMCAT_PAQUETE=${tomcats[$((op-1))]}
            break
        fi
    done

    VERSION=$(apt-cache policy $TOMCAT_PAQUETE 2>/dev/null | grep Candidate | awk '{print $2}')
    validar_puerto
    crear_usuario tomcat

    echo "Instalando $TOMCAT_PAQUETE..."
    if ! sudo apt-get install -y $TOMCAT_PAQUETE; then
        echo "ERROR: Fallo la instalacion de Tomcat."
        return 1
    fi

    # Buscar server.xml
    SERVER_XML="/etc/$TOMCAT_PAQUETE/server.xml"
    [ ! -f "$SERVER_XML" ] && \
        SERVER_XML=$(find /etc /opt /usr -name "server.xml" 2>/dev/null | grep -i tomcat | head -1)

    if [ -n "$SERVER_XML" ] && [ -f "$SERVER_XML" ]; then
        sudo sed -i "s/port=\"8080\"/port=\"$PUERTO\"/g" "$SERVER_XML"
        echo "Puerto configurado en $SERVER_XML"
    else
        echo "ADVERTENCIA: No se encontró server.xml"
    fi

    sudo systemctl daemon-reload
    sudo systemctl enable $TOMCAT_PAQUETE
    sudo systemctl restart $TOMCAT_PAQUETE

    if systemctl is-active --quiet $TOMCAT_PAQUETE; then
        configurar_firewall
        echo "✓ Tomcat instalado y corriendo en puerto $PUERTO"
    else
        echo "ERROR: Tomcat no inicio. Revisa: sudo journalctl -xe"
        return 1
    fi
}

# ── DESINSTALACIÓN ──────────────────────────────

desinstalar_servidor(){
    echo "SERVIDORES INSTALADOS:"
    echo "1) Apache"
    echo "2) Nginx"
    echo "3) Tomcat"
    echo "4) Cancelar"
    read -p "Seleccione servidor a desinstalar: " op
    case $op in
        1)
            if ! detectar_instalacion apache2 > /dev/null; then
                echo "Apache no está instalado"; return
            fi
            APACHE_PAQUETES=$(dpkg -l 2>/dev/null | grep apache2 | awk '{print $2}' | tr '\n' ' ')
            sudo systemctl stop apache2 2>/dev/null || true
            sudo apt-get remove --purge $APACHE_PAQUETES -y
            sudo apt-get autoremove -y
            echo "✓ Apache eliminado"
            ;;
        2)
            if ! detectar_instalacion nginx > /dev/null; then
                echo "Nginx no está instalado"; return
            fi
            NGINX_PAQUETES=$(dpkg -l 2>/dev/null | grep nginx | awk '{print $2}' | tr '\n' ' ')
            sudo systemctl stop nginx 2>/dev/null || true
            sudo apt-get remove --purge $NGINX_PAQUETES -y
            sudo apt-get autoremove -y
            echo "✓ Nginx eliminado"
            ;;
        3)
            TOMCAT_SVC=$(systemctl list-units --type=service 2>/dev/null | grep tomcat | awk '{print $1}' | head -1)
            TOMCAT_PAQUETES=$(dpkg -l 2>/dev/null | grep tomcat | awk '{print $2}' | tr '\n' ' ')
            if [ -z "$TOMCAT_PAQUETES" ]; then
                echo "Tomcat no está instalado"; return
            fi
            [ -n "$TOMCAT_SVC" ] && sudo systemctl stop $TOMCAT_SVC 2>/dev/null || true
            sudo apt-get remove --purge $TOMCAT_PAQUETES -y
            sudo apt-get autoremove -y
            echo "✓ Tomcat eliminado"
            ;;
        4) echo "Operacion cancelada" ;;
        *) echo "Opcion invalida" ;;
    esac
}

# ── MENU PRINCIPAL ───────────────────────────────

while true; do
    echo "==============================="
    echo "   SISTEMA ADMIN SERVIDORES"
    echo "==============================="
    echo "1) Instalar/Actualizar Apache"
    echo "2) Instalar/Actualizar Nginx"
    echo "3) Instalar/Actualizar Tomcat"
    echo "4) Desinstalar servidor"
    echo "5) Salir"
    echo "==============================="
    read -p "Seleccione opcion: " op
    case $op in
        1) instalar_apache ;;
        2) instalar_nginx ;;
        3) instalar_tomcat ;;
        4) desinstalar_servidor ;;
        5) exit 0 ;;
        *) echo "Opcion invalida" ;;
    esac
done