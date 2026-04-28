# Third-Party Notices

Este repositorio contem o instalador `AUTOMACAO-ZBX-UNIFIED.sh`, licenciado
sob MIT conforme o arquivo [LICENSE](LICENSE).

O instalador nao empacota, copia nem redistribui Zabbix, PostgreSQL,
TimescaleDB, Nginx, PHP, SQLite, OpenSSL, curl, wget, nmap, net-snmp ou os
demais pacotes do sistema operacional. Ele instala esses softwares no host de
destino usando repositorios oficiais do fornecedor ou da distribuicao
Ubuntu/Debian.

Cada software instalado continua sujeito aos seus proprios termos de licenca,
copyright, marcas e politicas do fornecedor. Este arquivo e um mapa pratico de
conformidade, nao substitui revisao juridica.

## Resumo pratico

- O codigo deste instalador: MIT.
- Os softwares instalados pelo script: cada um mantem sua propria licenca.
- As dependencias transitivas instaladas pelo APT devem ser auditadas no host
  final, porque podem variar por distribuicao, versao, arquitetura e repositorio.
- Para uso comercial, redistribuicao de imagem pronta, appliance, ISO ou produto
  que inclua os pacotes instalados, revise as licencas dos pacotes efetivamente
  distribuidos.

## Softwares de terceiros instalados ou usados diretamente

| Software / pacote | Uso no instalador | Licenca / aviso principal | Fonte oficial |
| --- | --- | --- | --- |
| Zabbix 7.x (`zabbix-server-pgsql`, `zabbix-proxy-sqlite3`, `zabbix-agent2`, frontend e pacotes relacionados) | Monitoramento, server, proxy, agent e frontend | Zabbix 7.0+ e publicado sob GNU AGPLv3. Versoes anteriores ate 6.4 eram GPLv2. | <https://www.zabbix.com/rn/rn7.4.0> e <https://www.zabbix.com/documentation/7.0/en/manual/introduction/whatsnew700> |
| PostgreSQL / PGDG (`postgresql-*`, `postgresql-client-*`) | Banco de dados | PostgreSQL License, licenca permissiva similar a BSD/MIT. | <https://www.postgresql.org/about/licence/> |
| TimescaleDB (`timescaledb-*`) | Extensao opcional para PostgreSQL | TimescaleDB tem componentes Apache 2.0 e componentes sob Timescale License (TSL), conforme edicao/feature. | <https://www.timescale.com/legal/licenses> e <https://docs.timescale.com/about/latest/timescaledb-editions/> |
| Nginx | Frontend HTTP/HTTPS do Zabbix Server | Licenca BSD de 2 clausulas. | <https://nginx.org/> e <https://nginx.org/en/docs/faq/license_copyright.html> |
| PHP / PHP-FPM e extensoes PHP | Runtime do frontend Zabbix | PHP License / BSD-3-Clause conforme versao e componentes. Arquivos individuais podem ter avisos adicionais. | <https://www.php.net/license/> |
| SQLite (`sqlite3`) | Banco local do Zabbix Proxy SQLite | Dominio publico, conforme declaracao oficial do SQLite. | <https://www.sqlite.org/copyright.html> |
| OpenSSL | TLS, certificados e utilitarios criptograficos | OpenSSL 3.0+ usa Apache License 2.0; versoes anteriores usam licenca dupla OpenSSL/SSLeay. | <https://www.openssl-library.org/source/license/> |
| curl / libcurl | Downloads e testes HTTP(S) | Licenca propria inspirada em MIT/X. | <https://curl.se/docs/copyright.html> |
| GNU Wget | Downloads HTTP(S) | GNU GPL. | <https://www.gnu.org/software/wget/> |
| Bash e utilitarios GNU (`grep`, `sed`, `tar`, `gzip`, coreutils quando aplicavel) | Execucao do script e processamento de texto | Normalmente GNU GPL, conforme pacote instalado pela distribuicao. | <https://www.gnu.org/licenses/> |
| awk (`gawk`, `mawk` ou equivalente da distro) | Processamento de texto | Depende do pacote instalado pela distribuicao. Confirme em `/usr/share/doc/<pacote>/copyright`. | Pacote Ubuntu/Debian instalado no host |
| jq | Leitura/validacao JSON quando disponivel | MIT para o `jq`; documentacao sob CC BY 3.0. | <https://github.com/jqlang/jq> |
| nmap | Ferramenta opcional de diagnostico/rede | Nmap Public Source License (NPSL), baseada na GPLv2 com termos adicionais. | <https://nmap.org/npsl/> |
| Net-SNMP (`snmp`, `snmpd`) | Ferramentas SNMP opcionais | Conjunto de avisos BSD-like e licencas relacionadas. | <https://www.net-snmp.org/about/license.html> |
| fping, traceroute, net-tools e pacotes auxiliares | Diagnostico de rede | Variam por pacote e distribuicao. Confirme no arquivo de copyright do pacote instalado. | `/usr/share/doc/<pacote>/copyright` no host |
| Ubuntu/Debian e dependencias transitivas instaladas via APT | Sistema operacional e bibliotecas | Cada pacote possui sua propria licenca e copyright. | `/usr/share/doc/<pacote>/copyright` no host |

## Como auditar no servidor instalado

No Ubuntu/Debian, a fonte mais confiavel para o pacote realmente instalado e o
arquivo de copyright entregue pelo proprio pacote:

```bash
less /usr/share/doc/zabbix-server-pgsql/copyright
less /usr/share/doc/zabbix-agent2/copyright
less /usr/share/doc/postgresql-17/copyright
less /usr/share/doc/timescaledb-2-postgresql-17/copyright
less /usr/share/doc/nginx/copyright
less /usr/share/doc/php8.3-fpm/copyright
less /usr/share/doc/sqlite3/copyright
less /usr/share/doc/openssl/copyright
less /usr/share/doc/curl/copyright
```

Para listar rapidamente os pacotes mais relevantes e ver se o arquivo de
copyright existe:

```bash
for pkg in \
  zabbix-server-pgsql zabbix-frontend-php zabbix-nginx-conf zabbix-sql-scripts \
  zabbix-proxy-sqlite3 zabbix-agent2 postgresql-17 postgresql-client-17 \
  timescaledb-2-postgresql-17 nginx php8.3-fpm sqlite3 openssl curl wget jq nmap \
  snmp snmpd fping traceroute net-tools; do
  if [ -f "/usr/share/doc/$pkg/copyright" ]; then
    printf '%s\t%s\n' "$pkg" "/usr/share/doc/$pkg/copyright"
  fi
done
```

## Cuidados em uso comercial

O uso interno de um script que instala pacotes oficiais costuma ser diferente de
redistribuir um produto pronto contendo esses pacotes. Antes de distribuir uma
imagem, appliance, ISO, container, instalador empacotado ou servico gerenciado,
revise especialmente:

- obrigacoes da AGPLv3 aplicaveis ao Zabbix 7.x;
- termos da Timescale License quando usar recursos Community/TSL;
- termos do Nmap caso ele seja redistribuido dentro de produto/appliance;
- avisos de copyright e licencas de todas as dependencias transitivas;
- marcas registradas e nomes comerciais dos fornecedores.

## Nota sobre marcas

Zabbix, PostgreSQL, TimescaleDB, Nginx, PHP, SQLite, OpenSSL e os demais nomes
citados pertencem aos seus respectivos proprietarios. Este projeto nao e
afiliado, endossado ou mantido por esses fornecedores.
