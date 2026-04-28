# Changelog

Todas as versoes oficiais deste projeto sao publicadas por tag Git e GitHub Release.

## v5.4 - 2026-04-28

Primeira versao oficial publicada no repositorio `denysg001/zabbix-unified-installer`.

Baseada no instalador unificado `v5.4`, com:

- arquivo principal `AUTOMACAO-ZBX-UNIFIED.sh`;
- suporte a Database, Server e Proxy;
- Ubuntu/Debian;
- PostgreSQL;
- TimescaleDB opcional;
- Agent 2;
- certificado final com credenciais completas;
- export JSON;
- arquivo de erro estruturado em `/root/zabbix_install_error.json`;
- Doctor endurecido com timeouts;
- sanitizacao do arquivo plain para uso seguro com `cat`;
- fallback para `timescaledb-tune`;
- tag Git `v5.4`.

