## Changelog

Todas as versoes oficiais deste projeto sao publicadas por tag Git e GitHub Release.

**main - apos v5.5**

- Adicionado `THIRD_PARTY_NOTICES.md` com avisos de licencas de terceiros, fontes oficiais e orientacao pratica para auditoria dos pacotes instalados no host.
- README atualizado para separar claramente a licenca MIT do instalador das licencas dos softwares instalados via repositorios oficiais.

**v5.5 - 2026-04-28**

Versao estabilizada apos testes reais em ambientes Ubuntu/LXC para Database, Server e Proxy.

- Adicionado modo `--self-test`, que valida funções internas, comandos essenciais, parsing de configuração, sanitização de texto, escape JSON e detecção básica de ambiente sem instalar nada.
- Adicionado modo `--collect-support-bundle`, que gera um pacote `.tar.gz` em `/root` com resumo da instalacao, erro estruturado, Doctor, logs limitados, status de servicos, portas, pacotes e configuracoes relacionadas.
- Corrigida reinstalação da camada DB quando o pacote PostgreSQL já existe, mas o cluster/configuração `/etc/postgresql/<versao>/main` não existe ou ficou parcial após testes anteriores.
- Reforçada sanitização dos exports plain text para remover ANSI, carriage return e controles de forma consistente em Ubuntu/Debian.
- Protegido `timescaledb-tune` em container/LXC para evitar tuning baseado na RAM do host; o instalador aplica limites seguros pela RAM detectada no container.
- Melhorada espera do PostgreSQL na camada DB usando readiness do cluster, reduzindo falso erro do serviço genérico em ambientes LXC.
- Corrigido falso aviso do Doctor/pós-validação quando `postgresql.service` genérico aparece inativo, mas o cluster PostgreSQL está respondendo.
- Recuperados conffiles do Server (`zabbix_server.conf` e `nginx.conf`) em reinstalações parciais antes de aplicar configuração.
- Ajustada configuração opcional de compressão/columnstore TimescaleDB para não despejar erros críticos no log quando a política não é suportada pela combinação instalada.
- Corrigida contagem de políticas TimescaleDB para diferenciar políticas aplicadas de políticas ignoradas pela versão/configuração atual.
- Recuperados conffiles do Proxy/Agent em reinstalações parciais antes de aplicar configuração.
- Separada ativação de `zabbix-proxy` e `zabbix-agent2`, com diagnóstico do serviço no log quando algum deles falhar.
- Removido uso ativo de `EnableRemoteCommands`/`AllowKey` no Proxy, evitando parâmetros inválidos em versões atuais; `AllowKey` permanece restrito ao Agent 2.
- Garantido `LogFile` no Proxy quando `LogType=file`, evitando falha de inicialização por configuração de log incompleta.
- Corrigido Doctor para não gerar erro fatal quando encontra padrões conhecidos em logs; agora mantém o resultado como aviso.
- README reorganizado como página principal do projeto, com requisitos, instalação rápida, features, screenshots planejados, política de versionamento e licença.
- Adicionada licença MIT.

**v5.4 - 2026-04-28 (historico pre-estavel, nao recomendado)**

Primeira publicacao no repositorio `denysg001/zabbix-unified-installer`, mantida apenas como historico.

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

<details>
<summary><strong>Historico legado anterior ao repositorio GitHub</strong></summary>

```text
  v5.3 — 2026-04-27
        [GERAL] Adicionado --list-supported-os, com matriz clara de sistemas
          suportados, experimentais e indisponíveis.
          (o operador consegue ver rapidamente o que pode instalar).
        [GERAL] Adicionado --repo-check para validação preventiva de
          repositórios/pacotes oficiais por componente.
          (testa Zabbix, PGDG/PostgreSQL, TimescaleDB, PHP/Nginx e dependências
          sem iniciar a instalação).
        [GERAL] Detecção de AlmaLinux/Rocky preparada como OS_FAMILY=rhel,
          com funções abstratas pkg_update/pkg_install/pkg_purge/pkg_is_installed.
          Fluxos RHEL ainda abortam de forma controlada antes de qualquer
          instalação parcial.
          (o script reconhece a família, mas não tenta gambiarra sem suporte
          completo).
        [GERAL] Exportação JSON adicionada em /root/zabbix_install_summary.json
          com chmod 600, mantendo credenciais completas.
          (facilita suporte/automação sem substituir o certificado em texto).
        [GERAL] Bloco de avisos da instalação adicionado ao certificado final.
          (exibe TimescaleDB indisponível, pacotes opcionais pulados e outros
          alertas importantes em um lugar fácil de copiar).
        [DOCTOR] Diagnóstico ampliado com leitura de erros comuns nos logs.
          (procura connection refused, PSK mismatch, TLS handshake, database is
          down e outros sinais frequentes).
------------------------------------------------------------------------------
  v5.2 — 2026-04-27
        [SERVER] Menu de revisão final: numeração duplicada corrigida nas
          seções de BD, frontend, performance e tuning.
          (o operador agora vê um número único para cada linha e pode alterar
          a seção correspondente sem ambiguidade).
        [PROXY] Menu de revisão final: numeração duplicada corrigida em
          Performance Auto e Tuning Avançado.
          (a tela de revisão ficou mais clara antes de iniciar a instalação).
        [DB] Texto da pergunta de atualização mudou de "pacotes do Ubuntu"
          para "pacotes do sistema".
          (a mensagem agora faz sentido tanto em Ubuntu quanto em Debian).
        [GERAL] Adicionada validação direta do índice Packages.gz oficial do
          Zabbix antes de registrar o zabbix-release no APT.
          (se o pacote principal ainda não existir para distro/codename/arch,
          o script aborta antes de alterar os repositórios locais).
------------------------------------------------------------------------------
  v5.1 — 2026-04-27
        [GERAL] Pacotes auxiliares de diagnóstico agora são instalados em dois
          grupos: obrigatórios e opcionais. Pacotes opcionais ausentes no
          repositório da distro, como snmp-mibs-downloader no Debian main,
          geram aviso e não abortam a instalação.
          (o Server/Proxy não falham por causa de uma ferramenta acessória).
        [GERAL] Pré-check e --check agora verificam apt-cache e dpkg, porque
          a v5.0 passou a usar apt-cache policy para validar pacotes.
          (se a base APT estiver incompleta, o operador vê isso antes).
        [SERVER] Dependências base foram separadas por necessidade real:
          software-properties-common só é exigido quando o PPA do PHP for usado
          no Ubuntu; Debian não instala esse pacote sem necessidade.
          (menos pacotes extras em Debian e menos chance de falha desnecessária).
        [DOCTOR] Cabeçalho do Doctor passou a mostrar o sistema real detectado
          em vez de sempre escrever Ubuntu.
          (diagnóstico fica coerente em Debian).
------------------------------------------------------------------------------
  v5.0 — 2026-04-27
        [GERAL] Adicionado suporte oficial a Debian 12 (bookworm) e Debian 13
          (trixie) para Database, Server e Proxy, mantendo Ubuntu como antes.
          Debian 11 foi excluído de propósito porque o pacote zabbix-server-pgsql
          não está publicado nas combinações validadas.
          (o instalador agora aceita Debian moderno sem tentar improvisar em
          versões onde faltam pacotes oficiais).
        [GERAL] Validação central de pacotes por apt-cache policy antes de
          instalar componentes críticos: Zabbix, PostgreSQL/PGDG, PHP, Nginx
          e dependências auxiliares.
          (se o repositório não entregou o pacote, o erro aparece antes de uma
          instalação pela metade).
        [GERAL] URLs do repositório Zabbix agora são montadas por sistema:
          Ubuntu usa caminhos ubuntu; Debian usa caminhos debian oficiais,
          respeitando a diferença entre 7.0, 7.4 e 8.0.
          (evita baixar pacote de repositório da distro errada).
        [DB] TimescaleDB passou a validar packagecloud por família do sistema
          operacional: ubuntu ou debian. Se o pacote compatível não existir,
          continua sem TimescaleDB e registra o aviso como antes.
          (TimescaleDB continua opcional; Zabbix/PostgreSQL não ficam bloqueados).
        [SERVER] PHP nativo por sistema: Ubuntu mantém os valores anteriores;
          Debian 12 usa PHP 8.2 e Debian 13 usa PHP 8.4.
          (não adiciona PPA Ubuntu em Debian e usa o PHP publicado pela distro).
------------------------------------------------------------------------------
  v4.30 — 2026-04-27
        [GERAL] --wipe/--wipe-db: adicionado apt-mark unhold antes de cada
          apt-get purge no modo de limpeza completa — o hold aplicado pela
          v4.28 no final da instalação bloqueava silenciosamente o purge
          dos pacotes Zabbix/Nginx e PostgreSQL/TimescaleDB no wipe,
          deixando pacotes presos sem qualquer aviso.
          (o modo --wipe voltou a remover todos os pacotes corretamente).
        [DB] Menu de revisão: numeração corrigida — as entradas 3/3, 4/4 e
          5/5 passaram a ter números únicos (3 a 8), evitando ambiguidade ao
          escolher qual campo editar. O case foi atualizado em conformidade.
          (selecionar o número de uma secção no menu já não confunde versão
          Zabbix com versão PostgreSQL, nem IPs com credenciais de BD).
        [DB] Pipeline INSTALL_AGENT: adicionado apt-mark unhold zabbix-agent2
          antes do apt-get purge no passo de remoção prévia do Agent 2 —
          o hold aplicado pela v4.28 impedia a remoção correta do agente
          quando se reinstalava com INSTALL_AGENT=1.
          (reinstalar a BD com o Agent 2 já volta a remover a versão anterior
          antes de instalar a nova).
------------------------------------------------------------------------------
  v4.29 — 2026-04-27
        [DB/SERVER/PROXY] CLEAN_INSTALL: adicionado apt-mark unhold antes do
          passo de purge em cada componente — o hold aplicado pela v4.28 no
          final da instalação bloqueava silenciosamente o apt-get purge numa
          reinstalação subsequente com limpeza, deixando pacotes antigos no
          sistema sem qualquer aviso.
          (um segundo CLEAN_INSTALL depois de usar a v4.28 voltou a funcionar
          corretamente, removendo todos os pacotes antes de reinstalar).
        [DB] Pipeline: wait_for_service_active zabbix-agent2 corrigido para
          ser condicional a INSTALL_AGENT — antes corria sempre, mesmo quando
          o Agent 2 não foi instalado, fazendo o script esperar 30 segundos
          inutilmente e registar um aviso de serviço inexistente.
          (a instalação de BD sem Agent 2 já não demora 30 segundos extra
          no final nem mostra aviso de serviço não encontrado).
        [PROXY] m_security(): conflito de PSK Identity entre Proxy e Agent
          substituído por loop de re-pergunta em vez de exit 1 abrupto —
          o operador pode corrigir o nome sem perder todo o questionário.
          (digitar o mesmo nome PSK para o Proxy e para o Agent já não
          mata o instalador; pede para escolher um nome diferente).
------------------------------------------------------------------------------
  v4.28 — 2026-04-27
        [GERAL] warn_previous_installation() no modo --safe: substituída
          confirmação única por loop com CONTINUAR/SAIR/nova tentativa —
          mesmo padrão já aplicado em confirm_execution_summary (v4.24) e
          safe_confirm_cleanup (v4.27).
          (digitar algo errado ao confirmar a presença de instalação anterior
          já não abortava o script inteiro; agora pede para tentar de novo).
        [DB/SERVER/PROXY] Fuso horário detectado automaticamente do sistema
          operacional (timedatectl) e proposto como padrão no questionário —
          antes estava fixo como "America/Sao_Paulo" em 5 lugares no código.
          O operador pode confirmar ou alterar durante o questionário.
          (instalações fora do Brasil já não precisam editar o script para
          acertar o fuso; o valor correto aparece pré-preenchido).
        [DB/SERVER/PROXY] Adicionado passo final "apt-mark hold" para fixar
          as versões instaladas dos pacotes Zabbix e PostgreSQL.
          Zabbix e PostgreSQL não são atualizados automaticamente por
          apt upgrade acidental; para atualizar é preciso fazer
          apt-mark unhold explicitamente.
          (evita que um simples "apt upgrade" em manutenção do SO quebre
          a instalação com uma versão incompatível ou não testada).
------------------------------------------------------------------------------
  v4.27 — 2026-04-27
        [GERAL] safe_confirm_cleanup(): adicionado loop de validação igual ao
          de confirm_execution_summary (v4.24) — digitar errado pede novamente,
          digitar SAIR cancela sem erro.
          (qualquer erro de digitação em "LIMPAR" já não abortava a instalação
          inteira; agora o script pede para tentar de novo).
        [DOCTOR SERVER] Detecção da porta do Nginx movida para antes da
          verificação TCP — o doctor agora lê a porta real do nginx.conf e
          verifica apenas essa porta, em vez de testar 80, 443, 8080 e 8443
          sempre.
          (eliminados falsos avisos "porta não está em escuta" para as 3 portas
          que nunca foram configuradas naquele servidor).
        [GERAL] doctor_psql_with_pgpass(): adicionado trap RETURN para garantir
          remoção do ficheiro temporário com a senha da base de dados em qualquer
          saída — normal, erro ou Ctrl+C.
          (antes, interromper o diagnóstico deixava um ficheiro com a senha
          em /tmp até o próximo reboot).
        [GERAL] on_error(): erros fatais passam a ser escritos também no
          LOG_FILE além do stderr.
          (quem monitoriza o log com "tail -f" agora vê o erro fatal que
          matou a instalação, sem precisar verificar o terminal separadamente).
------------------------------------------------------------------------------
  v4.26 — 2026-04-27
        [GERAL] Changelog de v4.19 a v4.25 reescrito com explicações em
          linguagem simples entre parênteses em todos os itens técnicos
          (qualquer pessoa consegue entender o que mudou em cada versão,
          sem precisar conhecer os comandos por trás).
------------------------------------------------------------------------------
  v4.25 — 2026-04-27
        [DOCTOR DB] Verificação do TimescaleDB corrigida: a query consultava
          a base de dados padrão do sistema ("postgres"), onde a extensão
          nunca está instalada — o TimescaleDB fica na base "zabbix".
          O doctor agora lê o nome correto da base no ficheiro de configuração
          e conecta no lugar certo.
          (o diagnóstico parava de mostrar falso aviso "TimescaleDB não
          encontrado" mesmo quando estava instalado e a funcionar).
------------------------------------------------------------------------------
  v4.24 — 2026-04-27
        [GERAL] Tela de confirmação final ganhou loop de validação: digitar
          qualquer coisa errada mostra a mensagem "Entrada inválida" e pede
          de novo; digitar SAIR cancela sem erro.
          (antes, qualquer erro de digitação abortava a instalação; agora
          o script simplesmente pede para tentar de novo).
------------------------------------------------------------------------------
  v4.23 — 2026-04-27
        [DB/SERVER/PROXY] Corrigida falha em CLEAN_INSTALL onde o repositório
          Zabbix sumia após a limpeza: o script apagava o ficheiro de
          configuração do repositório, mas o sistema de pacotes (dpkg) não
          o recriava ao reinstalar a mesma versão — comportamento padrão
          do dpkg quando o ficheiro foi apagado manualmente. Adicionado
          --force-confmiss para forçar a recriação.
          (a instalação parava com "repositório Zabbix não acessível" logo
          após a limpeza; agora o repositório é sempre recriado corretamente).
------------------------------------------------------------------------------
  v4.22 — 2026-04-27
        [SERVER/DB/PROXY] O ficheiro de configuração do frontend
          (zabbix.conf.php) passou a registar a versão real do instalador
          em vez de sempre mostrar "v4.18" fixo.
          (facilitava identificar qual versão do script gerou aquela
          instalação, sem precisar procurar nos logs).
        [SERVER/DB/PROXY] A barra de progresso passou a contar corretamente
          os passos de sincronização de horário, que só existem em servidores
          físicos e não em containers.
          (a barra não ultrapassa mais 100% em servidores físicos nem
          fica curta em containers LXC).
------------------------------------------------------------------------------
  v4.21 — 2026-04-27
        [DOCTOR PROXY] O diagnóstico do Proxy passou a verificar o Agent 2
          apenas quando ele foi instalado (ficheiro de configuração presente).
          (antes, o diagnóstico mostrava FALHA CRÍTICA toda vez que o Proxy
          foi instalado sem Agent 2, mesmo sendo uma situação válida).
        [DOCTOR PROXY] Adicionada seção "AGENT 2 DO PROXY" no diagnóstico,
          mostrando Hostname, Server e estado do PSK quando o Agent 2 estiver
          instalado (igual ao que já existia no diagnóstico de DB e Server).
          (o operador passa a ver o resumo completo do Agent 2 no Proxy,
          sem precisar verificar manualmente o ficheiro de configuração).
        [GERAL] Removida função interna que nunca era chamada em lugar nenhum
          do script desde versões antigas.
          (limpeza de código sem impacto operacional).
        [GERAL] O comando --check passou a testar se as versões do Zabbix
          (7.0 e 7.4) estão publicadas para o Ubuntu instalado nesta máquina.
          (avisa antes de começar se a combinação Ubuntu + Zabbix escolhida
          ainda não tem pacotes disponíveis no repositório oficial).
------------------------------------------------------------------------------
  v4.20 — 2026-04-27
        [GERAL] O diagnóstico --doctor passou a ter limite de 5 segundos
          para conectar na base de dados.
          (antes, se a base estivesse inacessível, o terminal travava por
          30+ segundos sem nenhuma mensagem; agora falha rapidamente).
        [DOCTOR DB] Adicionada verificação se a extensão TimescaleDB está
          de facto carregada dentro do PostgreSQL.
          (confirmava apenas se o serviço estava ativo; agora confirma
          também se a extensão está registada na base de dados).
        [DOCTOR SERVER] O diagnóstico do Servidor passou a mostrar também
          o estado do Agent 2 quando instalado na mesma máquina.
          (alinhado com o diagnóstico de DB que já fazia isso desde v4.14).
        [PROXY] O resumo antes de instalar o Proxy passou a mostrar o modo
          de operação (ATIVO ou PASSIVO) e o endereço do Servidor.
          (o operador vê as decisões mais importantes antes de confirmar,
          sem precisar rolar o ecrã para trás).
        [GERAL] O diagnóstico de portas em uso passou a detetar corretamente
          portas posicionadas no final da linha de saída do sistema.
          (portas na posição final eram ignoradas com o padrão anterior).
------------------------------------------------------------------------------
  v4.19 — 2026-04-27
        [DB] Senhas com o caractere | (barra vertical) deixaram de corromper
          silenciosamente o ficheiro postgresql.conf.
          (a configuração era gravada com o valor errado sem qualquer erro;
          o serviço arrancava, mas com parâmetro incorreto).
        [SERVER/GERAL] O teste de resposta do frontend passou a aceitar apenas
          códigos HTTP 2xx e 3xx como sucesso.
          (antes, erros como 403 e 503 eram tratados como sucesso porque a
          expressão de validação estava incorreta).
        [GERAL] O modo --debug-services passou a detetar corretamente quando
          um serviço não existe no sistema.
          (o comando usado antes sempre retornava "encontrado", mesmo para
          serviços que nunca foram instalados).
        [GERAL] O aviso de instalação anterior passou a listar os pacotes
          encontrados antes de pedir confirmação.
          (o operador vê exatamente o que será afetado, não apenas "existe
          instalação anterior").
        [GERAL] O modo --debug-services passou a listar todos os serviços
          PHP-FPM presentes, não só o primeiro encontrado.
          (em máquinas com várias versões de PHP instaladas, as versões
          extras ficavam invisíveis no diagnóstico).
------------------------------------------------------------------------------
  v4.18 — 2026-04-27
        [GERAL] Adicionada confirmação explícita CONTINUAR antes do pipeline
          (depois da revisão final, o operador confirma por texto antes de
          qualquer instalação ou limpeza começar).
        [GERAL] Adicionado --safe para exigir confirmação LIMPAR antes de ações
          destrutivas conhecidas (evita limpeza acidental quando o operador quer
          uma camada extra de segurança).
        [GERAL] Adicionado --debug-services para diagnosticar serviços sem
          instalar nada (mostra status, journal, portas e processos relacionados).
        [GERAL] Logs passam a ser espelhados em /var/log/zabbix-install/
          (mantém o log antigo e também cria db.log/server.log/proxy.log/full.log).
        [GERAL] Pré-check mostra se o IP principal parece LAB/REDE PRIVADA ou
          PRODUÇÃO/PÚBLICO (ajuda a perceber risco de exposição antes de abrir
          serviços em rede).
        [GERAL] Pré-check avisa quando encontra instalação anterior no escopo
          Zabbix/PostgreSQL/Nginx (deixa claro que a instalação limpa pode
          remover vestígios antigos).
        [GERAL] Adicionada espera inteligente de serviços críticos por até 30s
          após start/restart (reduz falso erro quando systemd demora alguns
          segundos para marcar o serviço como ativo).
------------------------------------------------------------------------------
  v4.17 — 2026-04-27
        [GERAL] Changelog passa a usar explicações em linguagem mais simples
          entre parênteses após itens técnicos (assim uma pessoa com menos
          experiência consegue entender o efeito prático da mudança).
        [GERAL] Adicionado o bloco "Como ler este changelog" no topo
          (um guia rápido para entender [GERAL], [DB], [SERVER] e [PROXY]).
        [GERAL] Nenhuma lógica de instalação foi alterada nesta versão
          (não muda pacotes, serviços, limpeza, certificados nem credenciais).
------------------------------------------------------------------------------
  v4.16 — 2026-04-27
        [GERAL] Certificado final mantém os arquivos fixos e cria cópias
          históricas por componente/data em /root/zabbix_install_summary_*
          (o operador sempre tem o arquivo mais recente e também um histórico
          para auditoria ou comparação posterior).
        [GERAL] Doctor --export mantém arquivo fixo e cria cópia histórica
          por componente/data em /root/zabbix_doctor_report_*
          (cada diagnóstico exportado fica preservado, sem perder o anterior).
        [GERAL] Certificado final passa a registrar a versão do instalador
          (fica claro qual script gerou aquela instalação).
        [GERAL] Doctor tenta exibir qual versão do instalador gerou o último
          certificado salvo (ajuda a conferir se a máquina foi instalada por
          uma versão antiga ou recente do instalador).
------------------------------------------------------------------------------
  v4.15 — 2026-04-27
        [GERAL] Doctor agora encerra com resumo objetivo: OK, COM AVISOS ou
          FALHA CRÍTICA, contabilizando avisos/falhas durante as verificações
          (o operador consegue saber rapidamente se está tudo bem ou se precisa
          olhar algum ponto antes de liberar a máquina).
        [PROXY] Certificado final destaca o comportamento do modo passivo:
          o Zabbix Server precisa alcançar este Proxy na porta 10051/TCP
          (no proxy passivo, quem inicia a conexão é o servidor).
------------------------------------------------------------------------------
  v4.14 — 2026-04-27
        [GERAL] Adicionado --list-versions para consultar compatibilidade sem
          entrar no instalador (permite ver versões suportadas sem iniciar a
          instalação).
        [GERAL] Doctor ganhou --export, salvando diagnóstico em
          /root/zabbix_doctor_report.txt com chmod 600 (gera um arquivo de
          diagnóstico protegido para copiar ou arquivar).
        [GERAL] Pré-check passa a exibir estado de sincronização do relógio
          quando timedatectl está disponível (ajuda a identificar problemas de
          horário antes que afetem logs, certificados ou comunicação).
        [GERAL] Senhas manuais recebem aviso de senha fraca, sem bloquear
          (o operador é alertado, mas mantém controle da decisão).
        [SERVER] Teste do frontend agora valida resposta HTTP e procura sinais
          da aplicação Zabbix na página local (não basta a porta abrir; o teste
          tenta confirmar que a tela do Zabbix realmente responde).
        [GERAL] Certificado final ganhou bloco com comandos úteis de suporte
          (facilita copiar comandos de diagnóstico logo após a instalação).
------------------------------------------------------------------------------
  v4.13 — 2026-04-27
        [GERAL] Certificado final agora também gera versão limpa sem códigos
          ANSI em /root/zabbix_install_summary_plain.txt, mantendo o arquivo
          colorido original exatamente como visto no terminal.
        [SERVER] Confirmação de schema Zabbix incompatível ficou mais forte:
          para continuar mesmo assim é preciso digitar CONTINUAR.
        [PROXY] Adicionado teste informativo Proxy → Server no modo ativo,
          validando conectividade TCP até a porta 10051 antes do certificado.
------------------------------------------------------------------------------
  v4.12 — 2026-04-27
        [GERAL] Versão criada a partir da v4.11 para finalizar a correção
          interrompida: banner principal passa a exibir v4.12.
        [GERAL] Certificado final de DB, Server e Proxy volta a ser exportado
          automaticamente para /root/zabbix_install_summary.txt com chmod 600.
        [GERAL] Exportação usa o mesmo conteúdo exibido no terminal, mantendo
          credenciais completas, DBPassword e PSKs sem mascaramento.
        [SERVER] Auditoria do certificado final volta a exibir DBPassword
          completo, conforme regra operacional de certificado completo.
------------------------------------------------------------------------------
  v4.11 — 2026-04-27
        [GERAL] TOTAL_STEPS corrigido: os três run_step de
          verify_zabbix_repo_active adicionados no v4.10 não estavam
          contabilizados — Server +1, Proxy +1, DB/Agent2 +1 condicional.
        [GERAL] set_config(): adicionado escape do caractere | no valor
          antes do sed (além de \ e & já existentes), evitando corrupção
          silenciosa de configuração quando a senha contém |.
        [GERAL] post_validate_installation() reescrito para distinguir
          serviços críticos de verificações informativas. Serviços críticos
          com falha mudam o banner de "Perfeita ✔" para "com Avisos ⚠" e
          exibem alerta no topo do certificado, sem bloquear as credenciais.
        [GERAL] check_frontend_http() passa a tentar 3 vezes com 5s de
          intervalo, reduzindo falsos negativos em ambientes lentos ou
          containers onde PHP-FPM demora a aceitar ligações.
        [GERAL] verify_zabbix_repo_active() aceita agora um parâmetro de
          pacote: Server verifica zabbix-server-pgsql, Proxy verifica
          zabbix-proxy-sqlite3, DB/Agent2 mantém zabbix-agent2.
        [GERAL] Banner e zabbix.conf PHP atualizados para v4.11.
------------------------------------------------------------------------------
  v4.10 — 2026-04-27
        [GERAL] Todos os clean install (Server, Proxy, DB, Wipe) passam a
          remover também zabbix*.sources (formato deb822 usado no Zabbix
          7.x/8.x), evitando conflito de entradas duplicadas ou stale no
          apt que impedia o novo repositório de ser indexado.
        [GERAL] Adicionada função verify_zabbix_repo_active() chamada após
          cada "apt-get update" do repositório Zabbix. Verifica via
          apt-cache policy se os pacotes Zabbix estão de facto acessíveis
          e falha imediatamente com diagnóstico claro — em vez de deixar
          o pipeline avançar e falhar num passo tardio (ex: Agent 2).
        [GERAL] Banner principal e zabbix.conf PHP atualizados para v4.10.
------------------------------------------------------------------------------
  v4.9 — 2026-04-27
        [SERVER] Instalação do Zabbix Agent 2 agora faz unhold do pacote
          antes do apt-get install, corrigindo falha silenciosa quando o
          pacote estava marcado como held de uma instalação anterior.
        [GERAL] port_process_info() reescrito: em vez de exibir a linha
          bruta do ss com todos os PIDs, mostra apenas o nome do processo
          e a contagem (ex: nginx — 11 processos), reduzindo a poluição
          visual no pré-check de portas.
------------------------------------------------------------------------------
  v4.8 — 2026-04-27
        [SERVER] calc_server_auto_performance() subdividido em quatro tiers:
          < 4 GB (mínimo), 4–8 GB (baixo), 8–16 GB (médio) e > 16 GB (alto),
          evitando que VMs de 2 GB recebam os mesmos valores de 7 GB.
        [SERVER] HistoryCacheSize e TrendCacheSize passam a ser calculados
          automaticamente por perfil e aplicados sempre no zabbix_server.conf,
          junto com os cinco parâmetros core já existentes (v4.7).
        [SERVER] Removida duplicação em apply_server_config(): os cinco
          parâmetros core não eram mais reescritos quando USE_TUNING=1.
        [SERVER] Banner e revisão final passam a exibir o perfil de
          performance detetado (mínimo/baixo/médio/alto).
        [PROXY] Adicionado calc_proxy_auto_performance() com os mesmos quatro
          tiers do Server. CacheSize, HistoryCacheSize, StartPollers,
          StartPreprocessors e StartDBSyncers agora aplicados sempre,
          independentemente de USE_TUNING.
        [PROXY] Prompts de tuning manual passam a usar os valores
          auto-calculados como ponto de partida, em vez de valores fixos.
        [PROXY] Banner passa a exibir o perfil de performance detetado.
        [PROXY] LOG_FILE renomeado para zabbix_proxy_install_*.log,
          alinhado com a nomenclatura de DB e Server.
        [GERAL] Banner principal atualizado para v4.8.
        [GERAL] run_step(): retry de 3 tentativas agora aplicado apenas
          a comandos apt/dpkg; outros comandos falham imediatamente sem
          sleep, evitando mascarar erros reais e atrasar a instalação.
        [SERVER] Auditoria do certificado final passa a mascarar
          DBPassword (****) para evitar exposição em shoulder-surfing.
        [SERVER] Logrotate corrigido: postrotate usava zabbix_agentd.pid
          em vez de zabbix_agent2.pid — logs do Agent 2 nunca eram
          rotacionados via HUP.
------------------------------------------------------------------------------
  v4.7 — 2026-04-27
        [SERVER] Adicionado ajuste automático de performance baseado em RAM e
          CPU para Zabbix Server, com perfis baixo, médio e alto.
        [SERVER] StartPollers, StartPreprocessors, CacheSize, ValueCacheSize e
          StartDBSyncers agora são calculados dinamicamente e aplicados sempre
          no zabbix_server.conf com valores conservadores.
        [SERVER] Tuning manual continua disponível e passa a usar o perfil
          automático como valor recomendado inicial.
------------------------------------------------------------------------------
  v4.6 — 2026-04-27
        [GERAL] Adicionada execução por parâmetro --mode db|server|proxy,
          preservando menu interativo e atalhos existentes por argumento.
        [GERAL] --mode tem prioridade sobre o menu; valor ausente ou inválido
          agora retorna erro claro.
        [GERAL] Nenhuma alteração na lógica de instalação dos componentes.
------------------------------------------------------------------------------
  v4.5 — 2026-04-27
        [GERAL] Adicionado modo de limpeza completa --wipe para parar serviços
          Zabbix/Nginx/PostgreSQL e remover pacotes/diretórios no escopo do
          instalador, sem criar backup e sem tocar fora de Zabbix/PostgreSQL/Nginx.
        [GERAL] Adicionada flag --wipe-db para incluir remoção de PostgreSQL,
          TimescaleDB, diretórios de dados/configuração e resíduos de repositório.
        [GERAL] Wipe sempre pede confirmação explícita antes de executar.
        [GERAL] Nenhuma alteração na lógica de instalação dos componentes.
------------------------------------------------------------------------------
  v4.4 — 2026-04-27
        [GERAL] Menu inicial tornado explícito com opções Instalar Database,
          Instalar Server, Instalar Proxy e Sair.
        [GERAL] Navegação do menu mantém validação de entrada inválida e
          preserva execução futura por flags/argumentos db, server e proxy.
        [GERAL] Nenhuma alteração na lógica de instalação dos componentes.
------------------------------------------------------------------------------
  v4.3 — 2026-04-27
        [GERAL] Adicionado pré-check antes do pipeline real: root, Ubuntu
          suportado por componente, RAM mínima, disco livre e comandos obrigatórios.
        [GERAL] Adicionada validação preventiva de portas por componente.
          Portas de instalações antigas podem prosseguir; processos não
          relacionados exigem confirmação do operador.
        [GERAL] run_step() agora mostra etapa, comando/função, log e sugestões
          de diagnóstico quando uma falha persiste.
        [DB] Doctor passa a reconhecer Agent 2 instalado na camada de base.
        [GERAL] Mantida decisão operacional: certificado final continua apenas
          na tela, com credenciais completas, sem salvar resumo em arquivo.
------------------------------------------------------------------------------
  v4.2 — 2026-04-27
        [DB] Adicionada opção interativa para instalar e configurar Zabbix
          Agent 2 na própria máquina da base de dados, seguindo a mesma lógica
          dos componentes Server e Proxy.
        [DB] O operador informa a versão Zabbix alvo da instalação; quando
          Agent 2 é habilitado, o repositório segue automaticamente essa versão,
          junto com Server/ServerActive, Hostname, AllowKey opcional e PSK.
        [DB] Revisão final, pipeline, pós-validação e certificado da camada
          de base de dados passam a exibir estado e credenciais do Agent 2.
        [GERAL] Deteção de VERSION_ID/VERSION_CODENAME deixou de depender
          de grep -P, mantendo fallback mais portátil para --simulate/check.
        [GERAL] clear agora é tolerante a ambientes sem TERM, evitando abortar
          testes/simulações não interativas com set -e ativo.
        [DB] Auto-detecção de IP local para listen_addresses agora verifica
          se o comando ip existe antes de executar, preservando fallback '*'.
------------------------------------------------------------------------------
  v4.1 — 2026-04-27
        [GERAL] Changelog v1.0 reescrito com mais contexto histórico,
          documentando a intenção inicial do projeto: instalação limpa,
          interativa e unificada para DB, Server e Proxy, com revisão final
          antes de qualquer alteração destrutiva.
        [GERAL] Nenhuma alteração funcional no pipeline de instalação.
------------------------------------------------------------------------------
  v4.0 — 2026-04-27
        [GERAL] set_config() e set_pg_config(): escapa metacaracteres & e \
          do sed no valor antes de substituir — senhas com esses chars eram
          gravadas erradas nos ficheiros de configuração sem qualquer erro.
        [GERAL] conf_value(): reescrito com awk para não quebrar valores com
          = (base64, tokens), usando index() em vez de -F=.
        [GERAL] auto_repair_apt(): logging protegido por [[ -n LOG_FILE ]]
          para evitar criação de ficheiro vazio em --simulate.
        [GERAL] run_step(): is_apt ativado também quando apt-get/dpkg estão
          dentro de bash -c, para que auto_repair_apt seja chamado em falhas
          de lock nessas invocações.
        [SERVER] import_schema(): idempotência verificada em dbversion em vez
          de hosts — deteta schema parcialmente importado e aborta com erro
          claro em vez de silenciosamente pular o passo.
        [SERVER] m_nginx(): SERVER_NAME validado antes de ser usado no sed —
          valor com espaço ou metacarácter não corromperia mais o nginx.conf.
        [SERVER] m_agent() e [PROXY] m_agent(): AG_SERVER e AG_SERVER_ACTIVE
          validados com validate_zabbix_identity após o read.
        [SERVER] patch_theme_loader(): falha ao encontrar ponto de inserção
          agora emite aviso e continua em vez de abortar a instalação inteira.
        [GERAL] Banner atualizado para v4.0 (regra estabelecida em v2.3).
------------------------------------------------------------------------------
  v3.7 — 2026-04-27
        [GERAL] Refatorado --simulate para reutilizar o pipeline real via
          run_step, evitando duplicação manual de etapas.
        [GERAL] Adicionadas guardas de simulação nos pontos fora de run_step
          que dependem de ficheiros/pacotes criados durante a instalação real.
------------------------------------------------------------------------------
  v3.6 — 2026-04-27
        [GERAL] Adicionado modo --simulate: mantém questionário e revisão
          interativos, mas simula o pipeline calculado sem executar comandos,
          instalar pacotes, remover ficheiros ou alterar serviços.
        [GERAL] --simulate não exige root e não cria lock de instalação.
------------------------------------------------------------------------------
  v3.5 — 2026-04-27
        [GERAL] Adicionado modo --doctor para diagnóstico pós-instalação por
          componente, sem instalar, remover ou alterar configuração.
        [GERAL] Falhas de serviço agora exibem automaticamente últimas linhas
          do journal para acelerar diagnóstico em campo.
        [GERAL] Validação reforçada para hostnames e identidades PSK.
        [GERAL] Mensagens de repositório Zabbix indisponível agora indicam
          causas prováveis e alternativas.
        [SERVER] Pós-validação testa conexão real com a BD usando
          /etc/zabbix/zabbix_server.conf.
        [SERVER] Certificado final ganhou bloco compacto sem cores para copiar
          o acesso ao frontend.
------------------------------------------------------------------------------
  v3.4 — 2026-04-27
        [GERAL] Adicionado modo --dry-run para mostrar o plano destrutivo do
          componente escolhido sem instalar, remover ou alterar ficheiros.
        [GERAL] Validação reforçada de parâmetros numéricos e tamanhos nos
          assistentes de tuning DB, Server e Proxy.
        [SERVER] Pós-validação agora testa resposta HTTP/HTTPS local do
          frontend além de serviços e portas.
------------------------------------------------------------------------------
  v3.3 — 2026-04-27
        [GERAL] auto_repair_apt agora espera até 15s por apt/dpkg antes de
          tentar liberar serviços apt-daily; locks só são removidos quando não
          há processo apt/dpkg vivo.
        [GERAL] Pós-validação automática também chamada ao final dos
          componentes Server e Proxy.
        [SERVER] Corrigido fluxo de atualização: UPDATE_SYSTEM agora executa
          apt-get upgrade e instala ferramentas de rede em passos separados.
        [SERVER] Adicionado python3 às dependências base usadas pelo ajuste
          de SSL/Nginx.
        [SERVER] Valores gravados em .pgpass e zabbix.conf.php agora escapam
          caracteres especiais em senhas manuais.
        [DB] Mensagem de sincronização de repositórios TimescaleDB corrigida
          quando o repositório não está disponível.
        [DB] ALTER DATABASE do TimescaleDB usa identificador SQL escapado.
------------------------------------------------------------------------------
  v3.2 — 2026-04-27
        [GERAL] Corrigido pós-validação automática: cada componente agora
          valida apenas os seus próprios serviços. A instalação DB não tenta
          validar zabbix-server, nginx ou php-fpm.
        [DB] Corrigido erro com set -u: PHP_VER unbound variable ao final
          da instalação da base de dados.
------------------------------------------------------------------------------
  v3.1 — 2026-04-26
        [GERAL] Adicionado lock file por componente para impedir execuções
          simultâneas do instalador e evitar conflito de apt/systemctl.
        [GERAL] Logging estruturado com timestamp para início, sucesso e falha
          de cada etapa registrada no LOG_FILE do componente.
        [GERAL] Pós-validação automática de serviços e portas principais após
          a instalação, com avisos claros para diagnóstico.
        [GERAL] Trap EXIT empilhável para preservar limpeza do lock e do .pgpass
          sem sobrescrever handlers existentes.
------------------------------------------------------------------------------
  v3.0 — 2026-04-26
        [GERAL] Bash strict mode reforçado para set -Eeuo pipefail com trap ERR
          informando linha e comando falhado, sem esconder falhas críticas.
        [GERAL] Adicionado argumento opcional de componente: db, server ou proxy,
          permitindo saltar o menu inicial sem remover o modo interativo.
        [GERAL] Limpeza de instalação anterior mais agressiva: remove também
          ficheiros de repositórios Zabbix/PGDG/TimescaleDB e resíduos em /tmp.
        [GERAL] Ajuda --help atualizada com exemplos de uso e comportamento
          destrutivo de instalação limpa.
------------------------------------------------------------------------------
  v2.9 — 2026-04-26
        [GERAL] Adicionado modo --check para validar ambiente sem instalar,
          sem remover pacotes e sem alterar ficheiros.
        [GERAL] Validação reforçada de IP/CIDR IPv4 nas entradas de pg_hba.conf.
        [GERAL] Checagem preventiva de espaço livre em disco antes do pipeline.
        [GERAL] Validação antecipada de distribuição Ubuntu suportada por ao
          menos um componente antes dos menus interativos.
        [GERAL] Menus de revisão mantêm segredos mascarados por padrão; certificados finais ainda exibem credenciais para uso imediato.
------------------------------------------------------------------------------
  v2.8 — 2026-04-26
        [GERAL] Hardening conservador: validação de identificadores PostgreSQL,
          portas e tamanhos; máscara de segredos nos menus de revisão; validação
          HTTP dos repositórios Zabbix antes do wget; mensagens de upgrade
          ajustadas para refletir apt-get upgrade; avisos reforçados para
          AllowKey=system.run[*].
        [DB] Senhas com aspas simples agora são escapadas antes de comandos SQL.
------------------------------------------------------------------------------
  v2.6 — 2026-04-19
        [SERVER] Fix: apt-get update -qq antes de instalar postgresql-client
          em m_dbconn() — em LXC recém-criado o cache apt está vazio e a
          instalação falhava silenciosamente antes do update do pipeline
        [SERVER] Fix: PHP_VER e NEED_PHP_PPA agora resetados aos valores
          padrão do SO em m_version() antes de aplicar a regra do Zabbix 8.0
          — evita que uma seleção anterior de 8.0 force PHP 8.2 se o
          utilizador voltar a escolher 7.0 ou 7.4 no menu de revisão
------------------------------------------------------------------------------
  v2.5 — 2026-04-19
        [SERVER] Auto-deteção de PostgreSQL e TimescaleDB na BD remota:
          • m_pgver() e m_timescale() removidos do questionário
          • m_dbconn() agora conecta, autentica e deteta automaticamente:
              – versão do PostgreSQL via server_version_num
              – presença e versão do TimescaleDB via pg_extension
              – schema Zabbix existente via dbversion.mandatory
          • Se psql não estiver instalado, instala postgresql-client
            silenciosamente antes da deteção
        [SERVER] Nova tabela de compatibilidade (_show_compat_table):
          • Mostra PostgreSQL, TimescaleDB e Schema Zabbix BD com estado
            visual (✔ / ✖) em relação à versão Zabbix escolhida
          • Deteta conflito de schema (ex: BD com schema 7.4, servidor 8.0)
            e exibe menu interativo com 4 opções de resolução:
              1) Alterar versão Zabbix (volta ao m_version, re-verifica)
              2) Re-inserir dados de conexão (conectar a outra BD)
              3) Continuar mesmo assim (com aviso)
              4) Abortar instalação
          • Menu de revisão final mostra linha de schema a vermelho enquanto
            conflito não for resolvido
        [GERAL] Mapeação de schema Zabbix confirmada em produção:
          • mandatory 7000000–7039999 → schema Zabbix 7.0
          • mandatory 7040000–7050032 → schema Zabbix 7.4
          • mandatory ≥ 7050033       → schema Zabbix 8.0
------------------------------------------------------------------------------
  v2.4 — 2026-04-19
        [DB] max_connections agora é uma questão independente e sempre visível
          no questionário (antes estava enterrada dentro das opções de tuning)
        [DB] Explicação educativa sobre a relação entre upload_max_filesize
          do PHP e o número de conexões simultâneas ao PostgreSQL
        [DB] max_connections removido do bloco de tuning — é sempre aplicado
          independentemente de USE_TUNING=0 ou 1
------------------------------------------------------------------------------
  v2.3 — 2026-04-19
        [GERAL] Corrigido: banner de cada componente mostrava versão antiga
          (ex: "Enterprise Suite v1.5") em vez da versão atual do ficheiro
        [GERAL] Estabelecida regra: ao criar nova versão, atualizar SEMPRE
          tanto o cabeçalho do ficheiro como o echo do banner
------------------------------------------------------------------------------
  v2.2 — 2026-04-19
        [DB] timescaledb-tune: abordagem de deteção LXC revertida (v2.1
          adicionou systemd-detect-virt mas era desnecessário — o problema
          existia também fora de containers)
        [DB] run_tsdb_tune() implementado corretamente: tenta timescaledb-tune,
          se falhar por qualquer motivo usa set_preload_manual() como fallback
          — nunca aborta o run_step(); sempre retorna 0
------------------------------------------------------------------------------
  v2.1 — 2026-04-19
        [DB] TSDB_AVAILABLE: flag de disponibilidade do TimescaleDB por distro
          check_tsdb_repo_availability() testa via curl se o repo packagecloud
          tem pacotes para o codename atual (ex: Ubuntu 26.04 "resolute" não
          tem pacotes TSDB) — se falhar, todos os passos TSDB são ignorados
          graciosamente sem abortar a instalação
------------------------------------------------------------------------------
  v2.0 — 2026-04-19
        [GERAL] Suporte ao Zabbix 8.0 LTS adicionado nos componentes
          Server e Proxy (opção 3 nos menus de versão)
        [GERAL] Suporte ao Ubuntu 26.04 LTS "Resolute Raccoon":
          PHP 8.5 auto-selecionado para Ubuntu 26.04
        [SERVER] check_zbx8_php_compat(): se Zabbix 8.0 escolhido e PHP < 8.2,
          força PHP 8.2 e ativa o PPA ondrej/php automaticamente
        [SERVER] Repo Zabbix 8.0 usa path diferente (/release/ no URL)
------------------------------------------------------------------------------
  v1.9 — 2026-04-19
        [DB] GPG: adicionado --batch --yes ao gpg --dearmor para evitar o
          prompt interativo "File exists. Overwrite? (y/N)" em reinstalações
        [DB] timescaledb-tune: revertida deteção LXC (v1.8); implementado
          run_tsdb_tune() com fallback gracioso — se timescaledb-tune falhar
          por qualquer razão, aplica shared_preload_libraries manualmente
          sem abortar a instalação
------------------------------------------------------------------------------
  v1.8 — 2026-04-19
        [DB/SERVER/PROXY] NTP/timezone condicionais: em ambientes de container
          (LXC, Docker) o relógio é gerido pelo host — timedatectl e
          systemd-timesyncd são ignorados com aviso; usa systemd-detect-virt -c
------------------------------------------------------------------------------
  v1.7 — 2026-04-18 (idêntico ao v1.8 para DB, Server e Proxy)
------------------------------------------------------------------------------
  v1.6 — 2026-04-18
        [GERAL] Segurança: PGPASSWORD substituído por ~/.pgpass em todas as
          chamadas psql (PGPASSWORD era visível em /proc/<pid>/environ e
          bash -x); setup_pgpass() com trap EXIT garante remoção do ficheiro
          mesmo em erro ou Ctrl+C; ficheiro .pgpass pré-existente é guardado
          em mktemp e restaurado no fim
------------------------------------------------------------------------------
  v1.5 — 2026-04-18
        [SERVER] Corrigido crash em configure_nginx() com set -euo pipefail:
          "[[  ! -e symlink ]] && ln -sf" falhava quando o symlink já existia
          (código 1 abortava o set -e). Substituído por "ln -sf" direto.
------------------------------------------------------------------------------
  v1.4 — 2026-04-18
        [GERAL] Corrigido congelamento no CLEAN_INSTALL: systemctl stop podia
          bloquear 90s+; agora timeout 15s por serviço + fallback systemctl kill
          + pkill -9 -x como último recurso. Afetava DB, Server e Proxy.
------------------------------------------------------------------------------
  v1.3 — 2026-04-18
        [SERVER] PHP-FPM: memory_limit 256M, upload configurável no questionário
          (16/32/64/128M ou personalizado), pm.max_children auto por RAM,
          pm.max_requests=200; externalscripts e alertscripts criados;
          logrotate configurado para /var/log/zabbix/
        [DB] Locale pt_BR.UTF-8 adicionado
------------------------------------------------------------------------------
  v1.2 — 2026-04-18
        [DB] listen_addresses: auto-deteta IP primário desta máquina em vez
          de usar '*' (todas as interfaces) — limita exposição da porta 5432
------------------------------------------------------------------------------
  v1.1 — 2026-04-18
        [GERAL] Restauradas descrições explicativas em todos os assistentes
          de tuning: DB (9 params), Server (23 params), Proxy (25 params)
------------------------------------------------------------------------------
  v1.0 — 2026-04-17
        Ideia inicial do projeto: transformar instalações manuais e repetitivas
          de Zabbix em um assistente único, guiado e previsível, capaz de montar
          uma camada completa do ambiente sem depender de anotações soltas,
          comandos copiados manualmente ou decisões tomadas no meio do processo.
        O script nasceu como instalador unificado para três papéis separados:
          BASE DE DADOS, SERVIDOR e PROXY. Cada papel é escolhido no início da
          execução e segue um fluxo independente dentro do mesmo arquivo, para
          reaproveitar funções comuns sem misturar responsabilidades.
        A base de dados foi desenhada para criar uma instalação PostgreSQL limpa,
          opcionalmente com TimescaleDB, já preparada para uso pelo Zabbix:
          remoção de resíduos anteriores, criação de usuário/banco, ajuste de
          pg_hba.conf, configuração de listen_addresses, tuning inicial e emissão
          das credenciais necessárias para o próximo componente.
        A camada de servidor foi pensada para instalar Zabbix Server, frontend,
          Nginx, PHP-FPM e dependências em cima de uma base PostgreSQL já definida,
          importando schema quando necessário, gravando as configurações principais
          e entregando ao operador uma URL funcional de acesso ao frontend.
        A camada de proxy foi incluída para repetir a mesma filosofia em pontos
          remotos: instalação limpa do Zabbix Proxy, banco local quando aplicável,
          Agent 2, PSK e parâmetros suficientes para registrar o proxy no servidor.
        Desde o início, a proposta foi ser interativa: perguntar valores essenciais,
          explicar opções sensíveis, permitir revisão final e só então executar
          o pipeline destrutivo. A instalação limpa é intencional: o operador parte
          de um estado conhecido, apagando vestígios de tentativas anteriores para
          reduzir comportamento imprevisível em laboratório, homologação ou produção.
        A infraestrutura partilhada já concentrava cores, mensagens, validações,
          helpers de sistema e execução por etapas; os componentes ficavam em
          branches case independentes para facilitar evolução sem duplicar o
          esqueleto do instalador.
```

</details>
