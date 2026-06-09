#!/bin/bash

set -euo pipefail

# ============================================================
# Configura Impressoras Corporativas
# ============================================================

if [[ $EUID -ne 0 ]]; then
    echo "Execute com sudo."
    exit 1
fi

BROTHER_DRIVER_URL="https://github.com/alclogti/samba-ad/releases/download/brother-MFCL6912DW-v1.0/mfcl6912dwpdrv-4.0.3-2.i386.deb"
BROTHER_DRIVER_DEB="/tmp/mfcl6912dwpdrv-4.0.3-2.i386.deb"

# ============================================================
# Dependências
# ============================================================

apt-get update

apt-get install -y \
    cups \
    wget

systemctl enable cups >/dev/null 2>&1
systemctl start cups

# ============================================================
# Habilita arquitetura i386 (idempotente)
# ============================================================

if ! dpkg --print-foreign-architectures | grep -qx "i386"; then
    echo "Habilitando arquitetura i386..."
    dpkg --add-architecture i386
    apt-get update
fi

# ============================================================
# Instala driver Brother se necessário
# ============================================================

if ! lpinfo -m | grep -q "brother-MFCL6912DW-cups-en.ppd"; then

    echo "Driver Brother não encontrado."
    echo "Baixando driver..."

    wget -q --show-progress \
        -O "$BROTHER_DRIVER_DEB" \
        "$BROTHER_DRIVER_URL"

    echo "Instalando driver..."

    dpkg -i "$BROTHER_DRIVER_DEB" || true

    apt-get install -f -y

    echo "Driver Brother instalado."

else
    echo "Driver Brother já instalado."
fi

# ============================================================
# Configura impressora
# ============================================================

configure_printer() {

    local NAME="$1"
    local IP="$2"
    local PPD="$3"
    local DESCRIPTION="$4"
    local LOCATION="$5"

    echo
    echo "Configurando ${NAME}..."

    if ! timeout 3 bash -c "</dev/tcp/${IP}/9100" 2>/dev/null; then
        echo "ERRO: ${NAME} não responde em ${IP}:9100"
        return 1
    fi

    lpadmin \
        -p "${NAME}" \
        -E \
        -v "socket://${IP}:9100" \
        -m "${PPD}"

    lpadmin \
        -p "${NAME}" \
        -D "${DESCRIPTION}" \
        -L "${LOCATION}"

    cupsenable "${NAME}"
    cupsaccept "${NAME}"

    echo "OK: ${NAME}"
}

# ============================================================
# Impressoras
# ============================================================

configure_printer \
    "Impressora-Estoque" \
    "192.168.154.109" \
    "brother-MFCL6912DW-cups-en.ppd" \
    "Brother MFC-L6912DW - Estoque" \
    "Estoque"

# ============================================================
# Impressora padrão
# ============================================================

lpoptions -d Impressora-Estoque

# ============================================================
# Compartilhamento
# ============================================================

cupsctl --share-printers

# ============================================================
# Resumo
# ============================================================

echo
echo "======================================"
echo "IMPRESSORAS CONFIGURADAS"
echo "======================================"

lpstat -p

echo
echo "======================================"
echo "DISPOSITIVOS"
echo "======================================"

lpstat -v

echo
echo "Configuração concluída com sucesso."