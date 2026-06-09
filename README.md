# Ubuntu 24.04 no Samba AD - Instalador Automático

Este projeto automatiza a integração do Ubuntu 24.04 com um domínio Samba Active Directory, incluindo a configuração de rede, Kerberos, SSH e scripts de logon automáticos.

## O que este script faz?
- Atualiza o sistema e instala/ativa o **SSH**.
- Valida **DNS e conectividade** com o controlador de domínio (LDAP/Kerberos).
- Configura o **Kerberos** (`/etc/krb5.conf`) de forma idempotente.
- Ajusta o **FQDN local** em `/etc/hosts` para resolver o hostname corretamente.
- Ingressa a máquina no domínio via **adcli** e **realmd**.
- Configura o **Samba** como membro do domínio AD (com mapeamento RID, valid users, password server preferencial, etc.).
- Instala um **script de logon mestre** (`/usr/local/bin/logon_linux.sh`) que:
  - Cria um **link simbólico** na área de trabalho para o compartilhamento **Scanner**.
  - Baixa e executa scripts `.sh` adicionais do **NETLOGON** do AD.
- Registra o **script de logon** no autostart do GNOME para ser executado automaticamente após o login do usuário no ambiente gráfico.
- Habilita criação automática de **pasta Home** no primeiro login (mkhomedir).
- Cria e configura uma pasta **compartilhada SMB** (`Scanner` em `/srv/samba/scanner`) com acesso para **Domain Users**.
- Registra/atualiza o registro **DNS A** da máquina no DNS do AD via Kerberos/nsupdate.
- Executa **validações finais** e exibe diagnósticos (realm, keytab, winbind, ACLs, etc.).
- É **idempotente**: pode ser reexecutado várias vezes sem duplicar configurações.

## Como usar

Basta rodar o comando abaixo no **Terminal** de uma instalação limpa do Ubuntu 24.04:

```sh
wget --no-cache -O install.sh "https://raw.githubusercontent.com/alclogti/samba-ad/main/scripts/configurar-dominio.sh?nocache=$(date +%s)" && sudo bash install.sh
```

### Nessa fase, coloque seu usuário e senha de rede

<img width="1273" height="801" alt="image" src="https://github.com/user-attachments/assets/402442ca-e180-4004-9569-4e96860a1f1c" />

### Após conclusão do script, reinicie o Linux:

```sh
sudo reboot
```

## Primeiro Login

<img width="1286" height="806" alt="image" src="https://github.com/user-attachments/assets/2fb78843-bf9c-414a-bcdd-c0e9f1e086dd" />

### Informe o nome.sobrenome@rede.alclog.com.br

<img width="1276" height="801" alt="image" src="https://github.com/user-attachments/assets/316ffa5e-8786-4e54-81e1-c5469f0e2320" />

## Instalar Impressoras

Após o login no domínio, execute o script de instalação das impressoras corporativas:

```sh
wget --no-cache -O instalar-impressoras.sh "https://raw.githubusercontent.com/alclogti/samba-ad/main/scripts/instalar-impressoras.sh?nocache=$(date +%s)" && sudo bash instalar-impressoras.sh
```

O script:
- Instala o CUPS e o driver Brother MFC-L6912DW.
- Configura a impressora **Impressora-Estoque** (`192.168.154.109`) como padrão.
- Ativa o compartilhamento de impressoras via CUPS.

