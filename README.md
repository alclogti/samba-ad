# Ubuntu 24.04 no Samba AD - Instalador Automático

Este projeto automatiza a integração do Ubuntu 24.04 com um domínio Samba Active Directory, incluindo a configuração de rede, Kerberos, SSH e scripts de logon automáticos.

## O que este script faz?
- Atualiza o sistema e instala/ativa o **SSH**.
- Configura o **Netplan** para usar o DNS do AD.
- Instala e configura **Realmd, SSSD e Kerberos**.
- Habilita a **criação automática da pasta Home** no primeiro login.
- Configura um **Script de Logon Mestre** que baixa e executa atalhos `.sh` a partir do SYSVOL/NETLOGON do servidor.

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

