# Zabbix Unified Installer

Instalador Bash unico para Zabbix Database, Server e Proxy.

O objetivo deste repositorio e ser a fonte oficial do instalador, com historico limpo, versoes rastreaveis por Git e releases confiaveis.

## Fonte da Verdade

O arquivo principal e:

```text
AUTOMACAO-ZBX-UNIFIED.sh
```

Este e o unico arquivo que deve receber desenvolvimento normal.

Nao ha necessidade de manter copias do script dentro do repositorio para versionar releases. Versoes oficiais devem ser recuperadas por tags Git e GitHub Releases.

## Latest vs Versao Fixa

Use `main` quando quiser a versao mais recente em desenvolvimento:

```text
https://raw.githubusercontent.com/denysg001/zabbix-unified-installer/main/AUTOMACAO-ZBX-UNIFIED.sh
```

Use uma tag quando quiser uma versao fixa e reproduzivel:

```text
https://raw.githubusercontent.com/denysg001/zabbix-unified-installer/v5.4/AUTOMACAO-ZBX-UNIFIED.sh
```

Regra operacional:

- `main`: pode receber correcoes novas.
- `vX.Y`: nao muda depois de publicada.

## Instalacao via Curl

Latest:

```bash
curl -fsSL -o AUTOMACAO-ZBX-UNIFIED.sh \
  https://raw.githubusercontent.com/denysg001/zabbix-unified-installer/main/AUTOMACAO-ZBX-UNIFIED.sh
chmod +x AUTOMACAO-ZBX-UNIFIED.sh
sudo ./AUTOMACAO-ZBX-UNIFIED.sh
```

Versao fixa:

```bash
curl -fsSL -o AUTOMACAO-ZBX-UNIFIED.sh \
  https://raw.githubusercontent.com/denysg001/zabbix-unified-installer/v5.4/AUTOMACAO-ZBX-UNIFIED.sh
chmod +x AUTOMACAO-ZBX-UNIFIED.sh
sudo ./AUTOMACAO-ZBX-UNIFIED.sh
```

## Modos Diretos

```bash
sudo ./AUTOMACAO-ZBX-UNIFIED.sh db
sudo ./AUTOMACAO-ZBX-UNIFIED.sh server
sudo ./AUTOMACAO-ZBX-UNIFIED.sh proxy
```

Diagnostico:

```bash
sudo ./AUTOMACAO-ZBX-UNIFIED.sh server --doctor-export
```

## Arquivos Importantes no Host Instalado

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

## Politica de Versionamento

O versionamento oficial acontece por:

- commits no Git;
- tags, como `v5.4`, `v5.5`;
- GitHub Releases.

Para publicar uma versao estavel:

1. Atualizar `INSTALLER_VERSION` dentro de `AUTOMACAO-ZBX-UNIFIED.sh`.
2. Atualizar o changelog no script e em `CHANGELOG.md`.
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

- `v5.4`: primeira versao oficial publicada neste repositorio.
