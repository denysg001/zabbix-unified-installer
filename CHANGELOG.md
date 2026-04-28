# Changelog

Todas as versoes oficiais deste projeto sao publicadas por tag Git e GitHub Release.

## main - v5.5-dev

- Adicionado modo `--collect-support-bundle`, que gera um pacote `.tar.gz` em `/root` com resumo da instalacao, erro estruturado, Doctor, logs limitados, status de servicos, portas, pacotes e configuracoes relacionadas.

## v5.4 - 2026-04-28

Primeira versao oficial publicada no repositorio `denysg001/zabbix-unified-installer`.

Baseada no instalador unificado `v5.4`, com:

- arquivo principal `AUTOMACAO-ZBX-UNIFIED.sh`;
- versionamento oficial por tag Git e GitHub Release;
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
