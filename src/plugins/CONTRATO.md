# Contrato de Plugins

Plugins vivem em `src/plugins/<nome>.sh` e são chamados por `src/main.sh` quando o operador usa `--plugin=<nome>` ou `--plugin <nome>`.

Cada plugin deve implementar estas funções obrigatórias:

- `plugin_nome()`
- `plugin_descricao()`
- `plugin_verificar_prerequisitos()`
- `plugin_instalar()`

Regras:

- O plugin deve ser idempotente: executar mais de uma vez não pode quebrar uma instalação existente nem duplicar configuração sem necessidade.
- O plugin deve validar pré-requisitos antes de alterar o sistema.
- O plugin deve usar os helpers compartilhados do instalador quando estiverem disponíveis.
- O plugin não deve mascarar credenciais no certificado final, mas deve mascarar credenciais em logs operacionais.
- O plugin deve retornar erro claro quando não puder continuar.
