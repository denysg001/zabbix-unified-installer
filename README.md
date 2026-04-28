# Zabbix Unified Installer

Instalador Bash unico para Zabbix Database, Server e Proxy, com suporte a Ubuntu/Debian, PostgreSQL, TimescaleDB opcional e Agent 2.

## Arquivo principal

Use e edite sempre este arquivo:

```bash
./AUTOMACAO-ZBX-UNIFIED.sh
```

O historico de alteracoes deve ficar no Git/GitHub. Versoes publicadas ficam em tags, por exemplo `v5.4`.

## Como executar

```bash
sudo ./AUTOMACAO-ZBX-UNIFIED.sh
```

Modos diretos:

```bash
sudo ./AUTOMACAO-ZBX-UNIFIED.sh db
sudo ./AUTOMACAO-ZBX-UNIFIED.sh server
sudo ./AUTOMACAO-ZBX-UNIFIED.sh proxy
```

Diagnostico:

```bash
sudo ./AUTOMACAO-ZBX-UNIFIED.sh server --doctor-export
```

## Arquivos importantes no host instalado

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

## Releases

A pasta `releases/` guarda copias congeladas das versoes publicadas. O desenvolvimento normal deve acontecer no arquivo principal `AUTOMACAO-ZBX-UNIFIED.sh`.

Versao inicial deste repositorio:

- `v5.4`

