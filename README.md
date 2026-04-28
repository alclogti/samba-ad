# Ubuntu 24.04 no Samba AD - Instalador Automático

Este projeto automatiza a integração do Ubuntu 24.04 com um domínio Samba Active Directory, incluindo a configuração de rede, Kerberos, SSH e scripts de logon automáticos.

## O que este script faz?
- Atualiza o sistema e instala/ativa o **SSH**.
- Configura o **Netplan** para usar o DNS do AD.
- Instala e configura **Realmd, SSSD e Kerberos**.
- Habilita a **criação automática da pasta Home** no primeiro login.
- Configura um **Script de Logon Mestre** que baixa e executa atalhos `.sh` a partir do SYSVOL/NETLOGON do servidor.

## Como usar

Basta rodar o comando abaixo em uma instalação limpa do Ubuntu 24.04:

```sh
wget -O install.sh https://gist.githubusercontent.com/alclogti/419da44fe5d67b91bcd628fc8b83191a/raw/baa04fa4e7b31df42258d812cb6da28efdac7f0a/configuracao.sh && sudo bash install.sh
```
