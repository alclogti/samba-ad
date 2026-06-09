#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Script de integração Linux ao Active Directory com compartilhamento SMB
# ==============================================================================
# O objetivo deste script é:
#   1. Instalar os pacotes necessários para autenticação no AD, Kerberos, SSSD e Samba.
#   2. Validar DNS e conectividade com o controlador de domínio.
#   3. Configurar Kerberos de forma idempotente.
#   4. Ingressar a máquina Linux no domínio usando adcli/realmd.
#   5. Habilitar criação automática de diretórios home para usuários do domínio.
#   6. Instalar um script de logon Linux baseado no scriptPath do usuário no AD.
#   7. Configurar o Samba como membro do domínio para autenticar usuários do AD.
#   8. Criar e configurar uma pasta compartilhada SMB com leitura/escrita para Domain Users.
#   9. Criar atalho local na área de trabalho do usuário para o diretório compartilhado.
#  10. Registrar/atualizar o DNS A da máquina no DNS do AD via Kerberos/nsupdate.
#  11. Manter a execução idempotente, evitando duplicidade em arquivos de configuração.
#
# Correções incluídas nesta versão:
#   - Remove a abordagem com atalho smb:// na área de trabalho.
#   - Cria um link simbólico local para /srv/samba/scanner.
#   - Usa REDE\\Domain Users no valid users do Samba.
#   - Força o DC correto em net ads join/testjoin.
#   - Define password server para preferir o DC correto.
#   - Desativa validação PAM no Samba para evitar erro de getpwnam com nome misturado.
#   - Ajusta /etc/hosts para hostname FQDN local.
#   - Registra DNS dinâmico no AD com nsupdate -g usando a conta da máquina.
#   - Gera log específico da criação/validação do atalho local.
# ==============================================================================

# ------------------------------------------------------------------------------
# Dados do domínio Active Directory
# ------------------------------------------------------------------------------
DOMAIN="rede.alclog.com.br"
REALM="REDE.ALCLOG.COM.BR"
AD_IP="192.168.150.3"
AD_NAME="cdmuribeca.rede.alclog.com.br"
BASE_DN="dc=rede,dc=alclog,dc=com,dc=br"

# Nome curto e FQDN esperado da máquina.
HOST_SHORT="$(hostname -s)"
HOST_FQDN="$(echo "${HOST_SHORT}.${DOMAIN}" | tr '[:upper:]' '[:lower:]')"

# ------------------------------------------------------------------------------
# Dados do compartilhamento SMB
# ------------------------------------------------------------------------------
SHARE_NAME="Scanner"
SHARE_PATH="/srv/samba/scanner"
SHARE_URI="smb://${HOST_SHORT}/${SHARE_NAME}"
DOMAIN_USERS_GROUP="domain users@${DOMAIN}"

# Grupo usado nas permissões do Samba.
# Importante:
#   - DOMAIN_USERS_GROUP é o nome resolvido pelo Linux/SSSD e usado no chgrp/setfacl.
#   - SAMBA_DOMAIN_USERS_GROUP é o nome usado pelo Samba/Winbind em valid users.
# O teste prático confirmou funcionamento com:
#   valid users = @"REDE\Domain Users"
SAMBA_DOMAIN_USERS_GROUP="REDE\Domain Users"

# Credenciais administrativas do domínio.
AD_USER="${AD_USER:-}"
AD_PASS="${AD_PASS:-}"

# ------------------------------------------------------------------------------
# Funções simples de saída padronizada
# ------------------------------------------------------------------------------
log() {
  echo "[INFO] $*"
}

warn() {
  echo "[WARN] $*" >&2
}

die() {
  echo "[ERRO] $*" >&2
  exit 1
}

# ------------------------------------------------------------------------------
# O script precisa de privilégios administrativos.
# ------------------------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
  die "Execute como root."
fi

# ------------------------------------------------------------------------------
# Verifica se o realmd já reconhece a máquina como ingressada no domínio.
# ------------------------------------------------------------------------------
realm_is_joined() {
  realm list --name-only 2>/dev/null | grep -Fxiq "$DOMAIN"
}

# ------------------------------------------------------------------------------
# Verifica se o keytab local já possui o principal host/maquina@REALM.
# ------------------------------------------------------------------------------
keytab_has_host_principal() {
  [ -f /etc/krb5.keytab ] && klist -k /etc/krb5.keytab 2>/dev/null | grep -Fqi "host/${HOST_SHORT}@${REALM}"
}

# ------------------------------------------------------------------------------
# Habilita, inicia e reinicia um serviço quando ele existe no sistema.
# ------------------------------------------------------------------------------
ensure_service_running() {
  local svc="$1"

  if systemctl list-unit-files | awk '{print $1}' | grep -Fxq "${svc}.service"; then
    systemctl enable --now "$svc" >/dev/null 2>&1 || true
    systemctl restart "$svc" >/dev/null 2>&1 || true
  fi
}

# ------------------------------------------------------------------------------
# Ajusta uma opção dentro da seção [libdefaults] do /etc/krb5.conf.
# ------------------------------------------------------------------------------
set_krb5_libdefault() {
  local key="$1"
  local value="$2"
  local file="/etc/krb5.conf"

  touch "$file"

  if grep -qi '^\[libdefaults\]' "$file"; then
    if grep -Eqi "^[[:space:]]*${key}[[:space:]]*=" "$file"; then
      sed -i -E "s|^[[:space:]]*${key}[[:space:]]*=.*|    ${key} = ${value}|I" "$file"
    else
      sed -i "/^\[libdefaults\]/a \    ${key} = ${value}" "$file"
    fi
  else
    cat <<EOF >> "$file"

[libdefaults]
    ${key} = ${value}
EOF
  fi
}

# ------------------------------------------------------------------------------
# Ajusta uma opção dentro da seção [global] do /etc/samba/smb.conf.
# ------------------------------------------------------------------------------
set_smb_global_option() {
  local key="$1"
  local value="$2"
  local file="/etc/samba/smb.conf"

  touch "$file"

  if ! grep -qi '^\[global\]' "$file"; then
    sed -i '1i[global]\n' "$file"
  fi

  if awk '
    BEGIN { in_global=0; found=0 }
    /^\[global\]/ { in_global=1; next }
    /^\[/ { in_global=0 }
    in_global && tolower($0) ~ "^[[:space:]]*" tolower(k) "[[:space:]]*=" { found=1 }
    END { exit found ? 0 : 1 }
  ' k="$key" "$file"; then
    awk -v key="$key" -v value="$value" '
      BEGIN { in_global=0; done=0 }
      /^\[global\]/ { in_global=1; print; next }
      /^\[/ { in_global=0 }
      in_global && done == 0 && tolower($0) ~ "^[[:space:]]*" tolower(key) "[[:space:]]*=" {
        print "   " key " = " value
        done=1
        next
      }
      { print }
    ' "$file" > "${file}.tmp"
    mv "${file}.tmp" "$file"
  else
    sed -i "/^\[global\]/a \   ${key} = ${value}" "$file"
  fi
}


# ------------------------------------------------------------------------------
# Garante que o /etc/hosts tenha o FQDN local da máquina.
#
# Isso corrige casos onde:
#   hostname -f
# retorna apenas VM001, em vez de VM001.rede.alclog.com.br.
#
# A linha esperada fica:
#   127.0.1.1 vm001.rede.alclog.com.br VM001
# ------------------------------------------------------------------------------
configure_local_fqdn() {
  log "--- Ajustando FQDN local em /etc/hosts ---"

  local file="/etc/hosts"
  local tmp="${file}.tmp"
  local fqdn="$HOST_FQDN"
  local short="$HOST_SHORT"

  cp "$file" "${file}.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true

  if grep -Eq "^[[:space:]]*127\.0\.1\.1[[:space:]]+" "$file"; then
    awk -v fqdn="$fqdn" -v short="$short" '
      BEGIN { done=0 }
      /^[[:space:]]*127\.0\.1\.1[[:space:]]+/ && done == 0 {
        print "127.0.1.1 " fqdn " " short
        done=1
        next
      }
      { print }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
  else
    printf '127.0.1.1 %s %s\n' "$fqdn" "$short" >> "$file"
  fi

  log "FQDN local esperado: ${fqdn}"
}

# ------------------------------------------------------------------------------
# Remove do smb.conf o bloco do compartilhamento controlado por este script.
# ------------------------------------------------------------------------------
remove_smb_share_block() {
  local share_name="$1"
  local file="/etc/samba/smb.conf"

  [ -f "$file" ] || return 0

  awk -v share="$share_name" '
    BEGIN { skip=0 }
    /^\[/ {
      current=$0
      gsub(/^\[/, "", current)
      gsub(/\]$/, "", current)
      skip=(tolower(current) == tolower(share))
    }
    skip == 0 { print }
  ' "$file" > "${file}.tmp"

  mv "${file}.tmp" "$file"
}

# ------------------------------------------------------------------------------
# Recria o bloco do compartilhamento SMB no smb.conf.
# ------------------------------------------------------------------------------
append_smb_share_block() {
  local file="/etc/samba/smb.conf"

  remove_smb_share_block "$SHARE_NAME"

  cat <<EOF >> "$file"

[${SHARE_NAME}]
   path = ${SHARE_PATH}
   browseable = yes
   read only = no
   writable = yes
   guest ok = no
   valid users = @"${SAMBA_DOMAIN_USERS_GROUP}"
   create mask = 0660
   directory mask = 0770
   inherit permissions = yes
   inherit acls = yes
EOF
}

# ------------------------------------------------------------------------------
# Confirma se o grupo Domain Users está visível para o Linux via NSS/SSSD.
# ------------------------------------------------------------------------------
ensure_domain_group_visible() {
  if getent group "$DOMAIN_USERS_GROUP" >/dev/null 2>&1; then
    return 0
  fi

  warn "Grupo '${DOMAIN_USERS_GROUP}' ainda não foi resolvido pelo NSS/SSSD."
  warn "Verifique se o domínio está ingressado, se o SSSD está ativo e se o nome do grupo no Linux está nesse formato."
  return 1
}

# ------------------------------------------------------------------------------
# Instala todos os pacotes necessários.
# ------------------------------------------------------------------------------
install_base_packages() {
  log "--- 1. Atualizando sistema e instalando pacotes base ---"
  export DEBIAN_FRONTEND=noninteractive

  apt update
  apt install -y \
    ssh \
    curl \
    realmd \
    sssd \
    sssd-ad \
    sssd-tools \
    adcli \
    samba \
    samba-common-bin \
    winbind \
    libnss-winbind \
    krb5-user \
    packagekit \
    smbclient \
    ldap-utils \
    libnss-sss \
    libpam-sss \
    libpam-mkhomedir \
    acl \
    xdg-user-dirs \
    dnsutils \
    netcat-openbsd

  systemctl enable --now ssh
}

# ------------------------------------------------------------------------------
# Instala o Google Chrome via repositório oficial do Google.
# Idempotente: não adiciona chave ou repositório se já existem.
# Em caso de falha na instalação, o script segue (não aborta).
# ------------------------------------------------------------------------------
install_google_chrome() {
  log "--- Instalando Google Chrome (repositório oficial) ---"

  local src="/etc/apt/sources.list.d/google-chrome.sources"
  local legacy_list="/etc/apt/sources.list.d/google-chrome.list"

  # Limpa arquivos antigos antes de qualquer apt update para evitar que uma
  # execução anterior com source inválido quebre a instalação inteira.
  rm -f "$src" "$legacy_list"

  install -dm 755 /etc/apt/keyrings

  local key="/etc/apt/keyrings/google-chrome.asc"
  if [ ! -f "$key" ]; then
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL https://dl.google.com/linux/linux_signing_key.pub -o "$key"
    elif command -v wget >/dev/null 2>&1; then
      wget -qO "$key" https://dl.google.com/linux/linux_signing_key.pub
    else
      apt-get update
      apt-get install -y curl
      curl -fsSL https://dl.google.com/linux/linux_signing_key.pub -o "$key"
    fi

    chmod a+r "$key"
    log "Chave GPG do Google adicionada."
  fi

  cat <<EOF > "$src"
Types: deb
URIs: https://dl.google.com/linux/chrome/deb/
Suites: stable
Components: main
Signed-By: $key
Architectures: amd64
EOF
  log "Repositório do Google Chrome adicionado."

  set +e
  apt-get update
  apt-get install -y google-chrome-stable
  local rc=$?
  set -e

  if [ "$rc" -eq 0 ]; then
    log "Google Chrome instalado com sucesso."
  else
    warn "Não foi possível instalar o Google Chrome. Script seguirá normalmente."
  fi
}

# ------------------------------------------------------------------------------
# Valida pré-requisitos básicos antes de tentar ingressar no domínio.
# ------------------------------------------------------------------------------
check_prereqs() {
  log "--- 2. Validando DNS e conectividade com o AD ---"

  if command -v resolvectl >/dev/null 2>&1; then
    resolvectl status 2>/dev/null | sed 's/^/[DNS] /' || true
  else
    [ -f /etc/resolv.conf ] && sed 's/^/[DNS] /' /etc/resolv.conf || true
  fi

  getent hosts "$AD_NAME" >/dev/null 2>&1 || die "Não foi possível resolver ${AD_NAME}. Verifique o DNS recebido via DHCP."
  nc -z -w 3 "$AD_IP" 389 >/dev/null 2>&1 || die "Não foi possível conectar em ${AD_IP}:389 (LDAP)."
  nc -z -w 3 "$AD_IP" 88 >/dev/null 2>&1 || die "Não foi possível conectar em ${AD_IP}:88 (Kerberos)."

  log "DNS e conectividade com o AD OK."
}

# ------------------------------------------------------------------------------
# Configura parâmetros mínimos do Kerberos.
# ------------------------------------------------------------------------------
configure_krb5() {
  log "--- 3. Ajustando Kerberos (idempotente) ---"

  set_krb5_libdefault "default_realm" "$REALM"
  set_krb5_libdefault "rdns" "false"
}

# ------------------------------------------------------------------------------
# Habilita criação automática de diretório home para usuários do domínio.
# ------------------------------------------------------------------------------
configure_mkhomedir() {
  log "--- 4. Habilitando criação automática de home ---"
  export DEBIAN_FRONTEND=noninteractive
  pam-auth-update --enable mkhomedir >/dev/null
}

# ------------------------------------------------------------------------------
# Instala o script mestre de logon para usuários Linux.
# ------------------------------------------------------------------------------
install_logon_script() {
  log "--- 5. Instalando script mestre de logon ---"

  cat <<EOF > /usr/local/bin/logon_linux.sh
#!/usr/bin/env bash
set -euo pipefail

LOGIN_ONLY=\$(echo "\$USER" | cut -d'@' -f1)
SHORTCUT_LOG="/tmp/logon_shortcut_\${LOGIN_ONLY}.log"

{
    echo "[INFO] Usuário: \$USER"
    echo "[INFO] HOME: \$HOME"
    echo "[INFO] SHARE_URI: ${SHARE_URI}"
    echo "[INFO] Data: \$(date)"
} > "\${SHORTCUT_LOG}" 2>&1

# Localiza a área de trabalho do usuário respeitando o idioma do sistema.
if command -v xdg-user-dir >/dev/null 2>&1; then
    DESKTOP_DIR=\$(xdg-user-dir DESKTOP 2>/dev/null || true)
else
    DESKTOP_DIR=""
fi

if [ -z "\${DESKTOP_DIR}" ] || [ ! -d "\${DESKTOP_DIR}" ]; then
    if [ -d "\$HOME/Área de trabalho" ]; then
        DESKTOP_DIR="\$HOME/Área de trabalho"
    elif [ -d "\$HOME/Desktop" ]; then
        DESKTOP_DIR="\$HOME/Desktop"
    else
        DESKTOP_DIR="\$HOME/Desktop"
        mkdir -p "\${DESKTOP_DIR}"
    fi
fi

echo "[INFO] DESKTOP_DIR: \${DESKTOP_DIR}" >> "\${SHORTCUT_LOG}" 2>&1

# Remove atalhos criados por versões anteriores do script.
rm -f "\${DESKTOP_DIR}/${SHARE_NAME}.desktop" \
      "\${DESKTOP_DIR}/${SHARE_NAME}.url" \
      "\${DESKTOP_DIR}/${SHARE_NAME}.ulr" 2>/dev/null || true

# Cria um atalho local para o diretório real no disco.
# Como a pasta compartilhada fica nesta própria máquina, é mais simples e confiável
# abrir /srv/samba/scanner diretamente, em vez de abrir smb://maquina/Scanner.
SHORTCUT_PATH="\${DESKTOP_DIR}/${SHARE_NAME}"

if [ -L "\${SHORTCUT_PATH}" ]; then
    rm -f "\${SHORTCUT_PATH}"
fi

if [ -e "\${SHORTCUT_PATH}" ] && [ ! -L "\${SHORTCUT_PATH}" ]; then
    echo "[WARN] Já existe um arquivo ou pasta chamado ${SHARE_NAME} em \${DESKTOP_DIR}. Não foi sobrescrito." >> "\${SHORTCUT_LOG}" 2>&1
else
    ln -s "${SHARE_PATH}" "\${SHORTCUT_PATH}"
    echo "[INFO] Link criado: \${SHORTCUT_PATH} -> ${SHARE_PATH}" >> "\${SHORTCUT_LOG}" 2>&1
fi

# Sem ticket Kerberos, não tenta consultar LDAP nem acessar NETLOGON.
klist >/dev/null 2>&1 || exit 0

# Consulta no AD o atributo scriptPath do usuário autenticado.
FULL_VBS_NAME=\$(ldapsearch -LLL -H ldap://${AD_NAME} -N -Y GSSAPI -b "${BASE_DN}" "(sAMAccountName=\${LOGIN_ONLY})" scriptPath 2>/dev/null | awk '/^scriptPath: / {print \$2}')

if [ -n "\${FULL_VBS_NAME}" ]; then
    FULL_VBS_NAME=\$(echo "\${FULL_VBS_NAME}" | tr -d '\r')
    SH_NAME="\${FULL_VBS_NAME%.*}.sh"
    LOCAL_TEMP_SCRIPT="/tmp/\${SH_NAME}"

    smbclient "//${AD_NAME}/netlogon" -k -c "get \${SH_NAME} \${LOCAL_TEMP_SCRIPT}" >/dev/null 2>&1 || exit 0

    if [ -f "\${LOCAL_TEMP_SCRIPT}" ]; then
        sed -i 's/\r\$//' "\${LOCAL_TEMP_SCRIPT}"
        chmod +x "\${LOCAL_TEMP_SCRIPT}"
        bash "\${LOCAL_TEMP_SCRIPT}" > "/tmp/logon_exec_\${LOGIN_ONLY}.log" 2>&1 || true
        rm -f "\${LOCAL_TEMP_SCRIPT}"
    fi
fi
EOF

  chmod +x /usr/local/bin/logon_linux.sh
}

# ------------------------------------------------------------------------------
# Cria um arquivo de autostart para executar o script de logon no ambiente gráfico.
# ------------------------------------------------------------------------------
install_autostart() {
  log "--- 6. Configurando autostart ---"

  cat <<EOF > /etc/xdg/autostart/logon-linux.desktop
[Desktop Entry]
Version=1.0
Type=Application
Name=Samba Logon Script
Comment=Executa script de logon Linux e cria atalhos de rede
Exec=/usr/local/bin/logon_linux.sh
Terminal=false
X-GNOME-Autostart-enabled=true
EOF

  chmod 644 /etc/xdg/autostart/logon-linux.desktop
}

# ------------------------------------------------------------------------------
# Realiza o join no AD usando adcli diretamente contra o DC definido em AD_IP.
# ------------------------------------------------------------------------------
join_with_adcli() {
  log "--- 7. Ingressando com adcli (DC fixo) ---"

  if keytab_has_host_principal; then
    log "Keytab já contém o principal host/${HOST_SHORT}@${REALM}. Pulando adcli join."
    return 0
  fi

  printf '%s' "$AD_PASS" | adcli join \
    --domain="$DOMAIN" \
    --domain-controller="$AD_IP" \
    --login-user="$AD_USER" \
    --stdin-password \
    --verbose

  log "adcli join concluído."
}

# ------------------------------------------------------------------------------
# Registra o domínio no realmd.
# ------------------------------------------------------------------------------
register_with_realm() {
  log "--- 8. Registrando com realmd ---"

  if realm_is_joined; then
    log "realmd já registra o domínio ${DOMAIN}. Pulando."
    ensure_service_running sssd
    return 0
  fi

  local attempt max_attempts=5
  for attempt in $(seq 1 "$max_attempts"); do
    log "Tentativa ${attempt}/${max_attempts} do realm join..."

    if printf '%s' "$AD_PASS" | realm join "$DOMAIN" \
      -U "$AD_USER" \
      --client-software=sssd \
      --membership-software=adcli \
      --verbose; then

      if realm_is_joined; then
        log "realm join concluído."
        ensure_service_running sssd
        return 0
      fi
    fi

    warn "realm join falhou nesta tentativa. Aguardando 3s..."
    sleep 3
  done

  return 1
}

# ------------------------------------------------------------------------------
# Solicita credenciais administrativas do domínio somente quando necessárias.
# ------------------------------------------------------------------------------
ensure_ad_credentials() {
  if [ -z "${AD_USER:-}" ]; then
    read -r -p "Digite o usuário Admin do Domínio (ex: administrador): " AD_USER < /dev/tty
  fi
  [ -n "${AD_USER:-}" ] || die "Usuário do domínio não informado."

  if [ -z "${AD_PASS:-}" ]; then
    read -r -s -p "Digite a senha do usuário ${AD_USER}: " AD_PASS < /dev/tty
    echo
  fi
  [ -n "${AD_PASS:-}" ] || die "Senha do usuário do domínio não informada."
}

# ------------------------------------------------------------------------------
# Verifica se o Samba já possui associação funcional com o domínio.
# ------------------------------------------------------------------------------
samba_domain_is_joined() {
  net ads testjoin -S "$AD_NAME" >/dev/null 2>&1 || net ads testjoin >/dev/null 2>&1
}

# ------------------------------------------------------------------------------
# Configura o Samba como membro do domínio AD.
# ------------------------------------------------------------------------------
configure_samba_domain_member() {
  log "--- Configurando Samba como membro do domínio ---"

  set_smb_global_option "workgroup" "REDE"
  set_smb_global_option "realm" "$REALM"
  set_smb_global_option "security" "ADS"
  set_smb_global_option "kerberos method" "secrets and keytab"

  # Prefere o DC saudável/correto nos fluxos Samba/Winbind.
  # Isso evita que a estação escolha automaticamente um DC antigo/instável via SRV DNS.
  set_smb_global_option "password server" "$AD_NAME"
  set_smb_global_option "server min protocol" "SMB2"
  set_smb_global_option "map to guest" "Never"

  # Evita que o smbd recuse o login depois de o Winbind autenticar a senha.
  # No ambiente testado, o PAM tentava validar nomes em formato misturado, por exemplo:
  #   getpwnam(REDE\bruno.barros@rede.alclog.com.br)
  # O resultado era NT_STATUS_LOGON_FAILURE mesmo com wbinfo -a funcionando.
  set_smb_global_option "obey pam restrictions" "no"
  set_smb_global_option "pam password change" "no"
  set_smb_global_option "winbind use default domain" "yes"
  set_smb_global_option "winbind offline logon" "yes"
  set_smb_global_option "winbind enum users" "no"
  set_smb_global_option "winbind enum groups" "no"
  set_smb_global_option "template shell" "/bin/bash"
  set_smb_global_option "template homedir" "/home/%U"
  set_smb_global_option "idmap config * : backend" "tdb"
  set_smb_global_option "idmap config * : range" "3000-7999"
  set_smb_global_option "idmap config REDE : backend" "rid"
  set_smb_global_option "idmap config REDE : range" "472800000-472899999"

  systemctl enable --now winbind >/dev/null 2>&1 || true
  systemctl restart winbind >/dev/null 2>&1 || true

  if samba_domain_is_joined; then
    log "Samba já está associado ao domínio."
    return 0
  fi

  ensure_ad_credentials

  printf '%s\n' "$AD_PASS" | net ads join -U "$AD_USER" -S "$AD_NAME" >/dev/null

  systemctl restart winbind >/dev/null 2>&1 || true
  systemctl restart smbd >/dev/null 2>&1 || true

  if samba_domain_is_joined; then
    log "Samba associado ao domínio com sucesso."
  else
    die "Samba não conseguiu validar associação com o domínio após net ads join."
  fi
}


# ------------------------------------------------------------------------------
# Registra ou atualiza o registro DNS A da máquina no DNS do AD.
#
# Observação:
#   Em alguns ambientes Samba/Zentyal, nsupdate -g pode exibir:
#     TSIG error with server: tsig verify failure
#   mesmo quando o registro foi efetivamente criado.
#   Por isso a função valida o resultado com "host" após o nsupdate.
# ------------------------------------------------------------------------------
register_dns_record() {
  log "--- Registrando DNS dinâmico da máquina no AD ---"

  local ip_addr
  local host_lower
  local nsupdate_output
  local nsupdate_status

  host_lower="$(echo "$HOST_FQDN" | tr '[:upper:]' '[:lower:]')"
  ip_addr="$(ip -4 route get "$AD_IP" 2>/dev/null | awk '/src/ {for (i=1;i<=NF;i++) if ($i=="src") print $(i+1)}' | head -n1)"

  if [ -z "$ip_addr" ]; then
    ip_addr="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi

  if [ -z "$ip_addr" ]; then
    warn "Não foi possível identificar o IP principal da máquina. DNS não será atualizado."
    return 0
  fi

  log "Registro desejado: ${host_lower} -> ${ip_addr}"

  kdestroy 2>/dev/null || true

  if ! kinit -k "${HOST_SHORT}\$@${REALM}"; then
    warn "Não foi possível obter ticket Kerberos com a conta da máquina."
    warn "Teste manual sugerido: sudo kinit -k '${HOST_SHORT}\$@${REALM}'"
    return 0
  fi

  set +e
  nsupdate_output="$(nsupdate -g 2>&1 <<EOF
server ${AD_IP}
realm ${REALM}
zone ${DOMAIN}
update delete ${host_lower} A
update add ${host_lower} 3600 A ${ip_addr}
send
EOF
)"
  nsupdate_status=$?
  set -e

  if [ -n "$nsupdate_output" ]; then
    echo "$nsupdate_output" | sed 's/^/[NSUPDATE] /'
  fi

  # Alguns ambientes retornam erro TSIG mesmo aplicando o update.
  # A validação final é a consulta DNS.
  if host "$host_lower" "$AD_IP" 2>/dev/null | grep -Fq "$ip_addr"; then
    log "DNS atualizado/validado: ${host_lower} -> ${ip_addr}"
    return 0
  fi

  if [ "$nsupdate_status" -ne 0 ]; then
    warn "nsupdate retornou erro e o registro não foi validado."
  else
    warn "nsupdate não retornou erro, mas o registro não foi validado."
  fi

  warn "Valide manualmente:"
  warn "  host ${host_lower} ${AD_IP}"
  warn "Ou cadastre manualmente no DC:"
  warn "  samba-tool dns add 127.0.0.1 ${DOMAIN} ${HOST_SHORT} A ${ip_addr} -U administrador"

  return 0
}

# ------------------------------------------------------------------------------
# Configura a pasta compartilhada SMB com acesso para Domain Users.
# ------------------------------------------------------------------------------
configure_smb_share() {
  log "--- 9. Configurando compartilhamento SMB idempotente ---"

  mkdir -p "$SHARE_PATH"

  ensure_service_running sssd

  if ensure_domain_group_visible; then
    chgrp "$DOMAIN_USERS_GROUP" "$SHARE_PATH"
    chmod 2777 "$SHARE_PATH"

    setfacl -m "g:${DOMAIN_USERS_GROUP}:rwx" "$SHARE_PATH"
    setfacl -d -m "g:${DOMAIN_USERS_GROUP}:rwx" "$SHARE_PATH"
  else
    warn "A pasta foi criada, mas as ACLs do grupo de domínio não foram aplicadas."
    warn "Após corrigir a resolução do grupo, execute o script novamente."
  fi

  configure_samba_domain_member

  append_smb_share_block

  testparm -s >/dev/null

  systemctl enable --now smbd >/dev/null 2>&1 || true
  systemctl restart smbd

  log "Compartilhamento SMB configurado: //${HOST_SHORT}/${SHARE_NAME}"
}

# ------------------------------------------------------------------------------
# Executa validações finais e exibe informações úteis para diagnóstico.
# ------------------------------------------------------------------------------
validate_result() {
  log "--- 10. Validação final ---"

  ensure_service_running sssd

  if realm_is_joined; then
    log "Domínio presente no realm list:"
    realm list
  else
    warn "realm list ainda não mostra o domínio."
  fi

  if keytab_has_host_principal; then
    log "Keytab contém host/${HOST_SHORT}@${REALM}."
  else
    warn "Keytab não contém o principal esperado."
  fi

  if getent group "$DOMAIN_USERS_GROUP" >/dev/null 2>&1; then
    log "Grupo resolvido: ${DOMAIN_USERS_GROUP}"
  else
    warn "Grupo não resolvido: ${DOMAIN_USERS_GROUP}"
  fi

  if [ -d "$SHARE_PATH" ]; then
    log "Diretório local do compartilhamento existe: ${SHARE_PATH}"
    getfacl "$SHARE_PATH" 2>/dev/null | sed 's/^/[ACL] /' || true
  else
    warn "Diretório local do compartilhamento não existe: ${SHARE_PATH}"
  fi

  if systemctl is-active --quiet smbd; then
    log "Serviço smbd ativo."
  else
    warn "Serviço smbd não está ativo."
  fi

  if systemctl is-active --quiet winbind; then
    log "Serviço winbind ativo."
  else
    warn "Serviço winbind não está ativo."
  fi

  if samba_domain_is_joined; then
    log "Samba validou associação com o domínio."
  else
    warn "Samba ainda não validou associação com o domínio."
  fi

  if net ads info -S "$AD_NAME" >/dev/null 2>&1; then
    log "Consulta ADS no DC correto OK: ${AD_NAME}"
  else
    warn "Falha ao consultar ADS no DC correto: ${AD_NAME}"
  fi

  if wbinfo -D REDE >/dev/null 2>&1; then
    log "Winbind enxerga o domínio REDE."
  else
    warn "Winbind não conseguiu consultar o domínio REDE."
  fi

  if wbinfo -t >/dev/null 2>&1; then
    log "Trust secret validado pelo usuário atual."
  else
    warn "Trust secret não validou sem sudo. Teste manual sugerido: sudo wbinfo -t"
  fi

  if host "$HOST_FQDN" "$AD_IP" >/dev/null 2>&1; then
    log "DNS do AD resolve ${HOST_FQDN}:"
    host "$HOST_FQDN" "$AD_IP" | sed 's/^/[DNS-AD] /' || true
  else
    warn "DNS do AD ainda não resolve ${HOST_FQDN}."
  fi

  if testparm -s >/dev/null; then
    log "Configuração Samba validada com testparm."
    log "Bloco efetivo do compartilhamento Scanner:"
    testparm -s 2>/dev/null | sed -n '/\[Scanner\]/,/^\[/p' | sed 's/^/[SMB] /' || true
  else
    warn "Configuração Samba falhou no testparm."
  fi

  log "Teste manual sugerido no usuário logado:"
  log "  xdg-open ${SHARE_PATH}"
  log "Teste manual sugerido para o compartilhamento:"
  log "  smbclient //localhost/${SHARE_NAME} -U \"REDE\\\\usuario\""
  log "Diretório real compartilhado:"
  log "  ${SHARE_PATH}"
  log "Grupo local autorizado:"
  log "  ${DOMAIN_USERS_GROUP}"
  log "Grupo Samba autorizado:"
  log "  ${SAMBA_DOMAIN_USERS_GROUP}"
  log "Log do atalho por usuário:"
  log "  /tmp/logon_shortcut_USUARIO.log"
}

# ------------------------------------------------------------------------------
# Fluxo principal
# ------------------------------------------------------------------------------
main() {
  install_google_chrome
  install_base_packages
  configure_local_fqdn
  check_prereqs
  configure_krb5
  configure_mkhomedir
  install_logon_script
  install_autostart

  if realm_is_joined && keytab_has_host_principal; then
    log "Máquina já está integrada ao domínio e registrada no realmd."
    ensure_service_running sssd
    configure_smb_share
    register_dns_record
    validate_result
    exit 0
  fi

  ensure_ad_credentials

  join_with_adcli

  if ! register_with_realm; then
    warn "O join com adcli funcionou, mas o registro no realmd falhou."
    warn "Isso é compatível com o problema do DNS/SRV apontando também para o DC ruim."
    warn "Corrija o DC problemático ou remova o SRV incorreto para estabilizar."
  fi

  configure_smb_share
  register_dns_record
  validate_result
  log "Instalação finalizada."
}

main "$@"
