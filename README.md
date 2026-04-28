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
curl -fsSL https://gist.github.com/alclogti/419da44fe5d67b91bcd628fc8b83191a | sudo bash
```
