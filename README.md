# Zabbix Unified Installer

[![Validate installer](https://github.com/denysg001/zabbix-unified-installer/actions/workflows/validate.yml/badge.svg)](https://github.com/denysg001/zabbix-unified-installer/actions/workflows/validate.yml)

Instalador unificado e resiliente para Zabbix Database, Server e Proxy, com fluxo interativo, instalacao limpa, diagnostico integrado e exports para suporte.

## O Que Ele Faz

- Instala Zabbix Database com PostgreSQL e TimescaleDB opcional.
- Instala Zabbix Server com frontend, Nginx, PHP-FPM e schema PostgreSQL.
- Instala Zabbix Proxy com SQLite e Agent 2 opcional.
- Mantem compatibilidade com Ubuntu e Debian suportados pelo script.
- Entrega certificado final com credenciais completas.
- Gera resumo plain, JSON estruturado e pacote unico de suporte.

## Requisitos

Sistema operacional:

- Ubuntu suportado pelo instalador;
- Debian suportado pelo instalador.

Arquitetura:

- `amd64`;
- `arm64`.

Hardware recomendado:

- minimo pratico: 2 GB RAM, 2 vCPU;
- recomendado para Server/Database: 4 GB+ RAM;
- disco livre recomendado: 2 GB+ antes da instalacao.

Permissoes:

- execucao com `root`/`sudo` para instalar, limpar, diagnosticar logs protegidos e gerar bundle em `/root`;
- acesso externo HTTPS aos repositorios Zabbix, PostgreSQL/PGDG e TimescaleDB quando aplicavel.

## Instalacao Rapida

Latest, a partir do branch `main`:

```bash
curl -fsSL -o AUTOMACAO-ZBX-UNIFIED.sh \
  https://raw.githubusercontent.com/denysg001/zabbix-unified-installer/main/AUTOMACAO-ZBX-UNIFIED.sh
chmod +x AUTOMACAO-ZBX-UNIFIED.sh
sudo ./AUTOMACAO-ZBX-UNIFIED.sh
```

Versao fixa, reproduzivel por tag:

```bash
curl -fsSL -o AUTOMACAO-ZBX-UNIFIED.sh \
  https://raw.githubusercontent.com/denysg001/zabbix-unified-installer/v5.5/AUTOMACAO-ZBX-UNIFIED.sh
chmod +x AUTOMACAO-ZBX-UNIFIED.sh
sudo ./AUTOMACAO-ZBX-UNIFIED.sh
```

Via clone:

```bash
git clone https://github.com/denysg001/zabbix-unified-installer.git
cd zabbix-unified-installer
sudo ./AUTOMACAO-ZBX-UNIFIED.sh
```

## Modos Diretos

```bash
sudo ./AUTOMACAO-ZBX-UNIFIED.sh db
sudo ./AUTOMACAO-ZBX-UNIFIED.sh server
sudo ./AUTOMACAO-ZBX-UNIFIED.sh proxy
```

Validar o proprio instalador sem instalar nada:

```bash
./AUTOMACAO-ZBX-UNIFIED.sh --self-test
```

Diagnostico pos-instalacao:

```bash
sudo ./AUTOMACAO-ZBX-UNIFIED.sh server --doctor-export
```

Pacote unico para suporte:

```bash
sudo ./AUTOMACAO-ZBX-UNIFIED.sh --collect-support-bundle
```

O pacote sera salvo em `/root/zabbix_support_bundle_YYYYMMDD_HHMMSS.tar.gz` e pode conter credenciais, PSKs e outros dados sensiveis.

## Features Em Destaque

- **Doctor integrado:** diagnostico por componente, com export para `/root/zabbix_doctor_report.txt`.
- **Wipe controlado:** limpeza de instalacoes anteriores dentro do escopo escolhido.
- **Deteccao de OS:** Ubuntu/Debian, codename, arquitetura, RAM e CPU.
- **Auto-tuning:** sugestoes de tuning para PostgreSQL e fallback seguro para TimescaleDB.
- **TimescaleDB opcional:** falha de TimescaleDB nao deve quebrar instalacao base.
- **Agent 2 funcional:** opcional nos componentes aplicaveis.
- **Exports de suporte:** resumo colorido, plain text, JSON e bundle `.tar.gz`.
- **Erro estruturado:** falhas fatais em `/root/zabbix_install_error.json`.
- **CI no GitHub:** `bash -n` e ShellCheck em cada push/PR.

## Screenshots

Prints e GIFs reais do terminal podem ser adicionados em `docs/assets/`.

Sugestoes de capturas:

- menu inicial com banner;
- barra de progresso durante instalacao;
- certificado final;
- tela do Doctor;
- bundle de suporte gerado.

## Arquivos Importantes No Host Instalado

Se der erro fatal, abra primeiro:

```bash
cat /root/zabbix_install_error.json
```

Quando a instalacao terminar, confira:

```bash
cat /root/zabbix_install_summary_plain.txt
cat /root/zabbix_install_summary.json
```

Quando rodar o Doctor exportado:

```bash
cat /root/zabbix_doctor_report.txt
```

Quando quiser enviar tudo em um unico arquivo para analise:

```bash
sudo ./AUTOMACAO-ZBX-UNIFIED.sh --collect-support-bundle
```

## Fonte Da Verdade

O arquivo principal e:

```text
AUTOMACAO-ZBX-UNIFIED.sh
```

Este e o unico arquivo que deve receber desenvolvimento normal.

Nao ha necessidade de manter copias do script dentro do repositorio para versionar releases. Versoes oficiais devem ser recuperadas por tags Git e GitHub Releases.

## Latest Vs Versao Fixa

Use `main` quando quiser a versao mais recente em desenvolvimento:

```text
https://raw.githubusercontent.com/denysg001/zabbix-unified-installer/main/AUTOMACAO-ZBX-UNIFIED.sh
```

Use uma tag quando quiser uma versao fixa e reproduzivel:

```text
https://raw.githubusercontent.com/denysg001/zabbix-unified-installer/v5.5/AUTOMACAO-ZBX-UNIFIED.sh
```

Regra operacional:

- `main`: pode receber correcoes novas.
- `vX.Y`: nao muda depois de publicada.

## Politica De Versionamento

O versionamento oficial acontece por:

- commits no Git;
- tags, como `v5.4`, `v5.5`;
- GitHub Releases.

Para publicar uma versao estavel:

1. Atualizar `INSTALLER_VERSION` dentro de `AUTOMACAO-ZBX-UNIFIED.sh`.
2. Atualizar `CHANGELOG.md`.
3. Validar com:

```bash
bash -n AUTOMACAO-ZBX-UNIFIED.sh
```

4. Criar commit.
5. Criar tag, por exemplo:

```bash
git tag v5.5
```

6. Publicar a tag no GitHub.
7. Criar um GitHub Release para a tag.

Regras:

- Nao sobrescrever release antiga.
- Nao alterar tag ja publicada.
- Nao duplicar logica entre arquivos.
- Nao usar copias em `releases/` como fonte de versoes; a fonte oficial e sempre `AUTOMACAO-ZBX-UNIFIED.sh` na tag desejada.

## Releases Publicadas

- `v5.5`: primeira versao estavel recomendada, estabilizada apos testes reais de Database, Server e Proxy em Ubuntu/LXC.

Observacao: `v5.4` existiu como publicacao inicial do repositorio, mas nao e recomendada como versao final.

## Licenca

Este projeto esta disponivel sob a licenca MIT. Veja [LICENSE](LICENSE).

O instalador nao redistribui os softwares que instala; Zabbix, PostgreSQL,
TimescaleDB, Nginx, PHP, SQLite, OpenSSL e demais pacotes continuam sujeitos as
suas proprias licencas. Veja [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
