# ipa-r2-automation

Repositório público de **orquestração da publicação da IPA Library**. Ele contém os workflows do GitHub Actions, a source pública do Feather, o catálogo de tweaks e a integração de arquivamento no TeraBox.

A lógica sensível de armazenamento e geração da source fica em `ipa-r2-core`.

> **Estado atual:** o backend operacional documentado aqui ainda é Cloudflare R2. A migração para Google Drive está em planejamento/validação e não deve ser tratada como implantada até a troca efetiva do pipeline.

## Arquitetura atual

```text
Telegram / IPA Storage
        ↓
ipa-r2-automation
        ├── checkout ipa-r2-core
        ├── checkout ipa-shared-config-core
        ↓
IPA to R2
        ├── upload Cloudflare R2
        ├── gera artifact para TeraBox
        ├── dispara Feather Source
        └── dispara Relatório Diário
                 ↓
       Feather/feather.json
                 ↓
              Feather

IPA to R2 concluído
        ↓
TeraBox Archive
        ↓
arquivo histórico no TeraBox
```

## Estrutura do repositório

| Caminho | Função |
| --- | --- |
| `.github/workflows/ipa-to-r2.yml` | Workflow principal que executa o pipeline IPA → R2 usando o Core privado. |
| `.github/workflows/feather-source.yml` | Atualiza/sincroniza `Feather/feather.json` e aplica metadados de pacote do Injector. |
| `.github/workflows/terabox-archive.yml` | Arquiva no TeraBox o artifact produzido após um `IPA to R2` bem-sucedido. |
| `.github/workflows/terabox-session-test.yml` | Valida se a sessão persistida do TeraBox ainda está utilizável. |
| `.github/workflows/relatorio-diario.yml` | Gera e salva relatórios operacionais do Core privado. |
| `.github/workflows/tweak-catalog.yml` | Regenera `Feather/tweaks.json` quando a source muda. |
| `.github/workflows/healthcheck.yml` | Healthcheck simples do runner desta automação. |
| `.github/scripts/feather_package_metadata.py` | Recupera os metadados de pacote/tweak enviados pelo Injector e injeta-os no URL da versão correta no Feather. |
| `.github/scripts/update_tweak_catalog.py` | Gera/atualiza o catálogo público de tweaks com base na source e em fallbacks estáticos. |
| `scripts/terabox_upload.js` | Cliente de upload para o TeraBox; cria diretórios e envia o IPA usando a sessão restaurada. |
| `Feather/feather.json` | Source principal da **IPA Library** consumida pelo Feather. |
| `Feather/tweaks.json` | Catálogo público de tweaks/pacotes associado aos apps da source. |
| `Feather/icons/repo.png` | Ícone da source IPA Library. |
| `Feather/icons/.gitkeep` | Mantém a pasta de ícones versionada mesmo se não houver outros arquivos. |
| `README.md` | Esta documentação. |

## Workflow `ipa-to-r2.yml`

Nome do workflow: **IPA to R2**.

Esse nome também é usado como gatilho pelo workflow de arquivamento no TeraBox. Renomeá-lo sem atualizar `terabox-archive.yml` quebra o encadeamento.

### Entradas

- `telegram_message_id`: mensagem temporária usada pelo bot para progresso.
- `callback_url`: endpoint de callback do Worker que iniciou a ação.

### Fluxo

1. Faz checkout de `ipa-r2-core`.
2. Faz checkout de `ipa-shared-config-core`.
3. Instala dependências.
4. Executa o script privado de IPA → R2.
5. Publica o artifact preparado para o TeraBox.
6. Notifica o Worker/bot sobre a conclusão.

O código de upload não vive neste YAML; ele é carregado do Core privado.

## Workflow `feather-source.yml`

Responsável pela source pública `Feather/feather.json`.

Modos/entradas importantes:

- `sync_only`: sincroniza apenas remoções com o R2.
- `silent`: evita mensagem própria de confirmação no Telegram.
- `rebuild_all`: reconstrói/atualiza metadados de todos os apps.
- demais inputs transportam nome, Bundle ID, versão, build, App Store ID e chave do objeto R2 em atualizações incrementais.

### Etapas principais

1. Checkout deste repositório.
2. Checkout de `ipa-r2-core`.
3. Checkout de `ipa-shared-config-core`.
4. Executa `scripts/feather_source.py`.
5. Executa `.github/scripts/feather_package_metadata.py`.
6. Salva mudanças em `Feather/feather.json`.
7. Envia confirmação ao Telegram, salvo modo silencioso.

### Comportamento atual importante

A implementação atual do Core foi criada quando o R2 mantinha **apenas uma versão por app**. Por isso, antes da migração para histórico multi-versão, qualquer alteração nessa lógica deve ser testada com cuidado para não perder entradas antigas do array `versions[]`.

## `.github/scripts/feather_package_metadata.py`

Recupera da mensagem do Injector metadados transportados por uma URL invisível no host lógico `feather.invalid`.

Entre os campos suportados estão:

- Bundle ID;
- versão do app;
- nome do pacote;
- versão do pacote;
- `packageRevision`;
- label do pacote.

Depois adiciona esses dados como query parameters ao `downloadURL` do Feather.

Isso permite que o fork do Feather detecte uma nova revisão de tweak mesmo quando a versão do aplicativo é a mesma.

## `.github/scripts/update_tweak_catalog.py`

Lê `Feather/feather.json` e gera `Feather/tweaks.json`.

Prioridade:

1. metadados vindos do Injector/source;
2. fallback estático para IPAs que já chegam pré-patchados e não têm identidade gerada pelo Injector.

Os fallbacks estáticos existem apenas para manter o catálogo completo; quando os metadados reais estão presentes, eles têm prioridade.

## Workflow `tweak-catalog.yml`

Pode ser executado:

- manualmente;
- após conclusão de `Feather Source`;
- após mudanças relevantes no próprio repositório.

Ele roda `update_tweak_catalog.py` e commita `Feather/tweaks.json` apenas quando houver alteração.

## Workflow `terabox-archive.yml`

É executado automaticamente após:

```yaml
workflow_run:
  workflows: ["IPA to R2"]
```

Somente continua quando o workflow anterior terminou com sucesso.

### Função

- baixa o artifact temporário produzido no pipeline principal;
- lê `metadata.json`;
- restaura a sessão do TeraBox;
- valida a sessão;
- envia o IPA para o diretório remoto calculado;
- informa o resultado no Telegram;
- remove o artifact do GitHub depois de upload confirmado.

O TeraBox é tratado como **arquivo histórico independente** do storage ativo.

## `scripts/terabox_upload.js`

Usa `terabox-upload-tool`.

Principais responsabilidades:

- validar variáveis obrigatórias;
- criar a hierarquia remota quando necessário;
- listar/verificar diretórios;
- fazer upload do arquivo;
- retornar erro real quando a operação não puder ser confirmada.

Nenhuma sessão deve ser gravada no arquivo. A sessão é restaurada a partir de secret do workflow.

## Workflow `terabox-session-test.yml`

Teste isolado para confirmar que a sessão salva ainda autentica no TeraBox sem precisar executar todo o pipeline de IPA.

Útil antes de mudanças no mecanismo de arquivamento.

## Workflow `relatorio-diario.yml`

Executa `scripts/relatorio_diario.py` do Core privado e salva relatórios de operação.

Possui controle de concorrência para evitar duas escritas simultâneas no Core.

## Workflow `healthcheck.yml`

Job mínimo usado pelo Worker/bot para saber se o runner do serviço está acessível. Não testa R2 em profundidade; testa a disponibilidade do GitHub Actions desta camada.

## `Feather/feather.json`

É a source pública principal da IPA Library.

Cada app contém, entre outros:

- `name`;
- `bundleIdentifier`;
- `developerName`;
- `iconURL`;
- descrição;
- screenshots;
- `versions[]`;
- versão/data/tamanho/URL atuais.

### Regra

O conteúdo é **gerado/atualizado pelo workflow**, não deve ser mantido manualmente como rotina.

Mudanças manuais podem ser sobrescritas pelo próximo `Feather Source`.

## `Feather/tweaks.json`

Catálogo consumido pelo fork do Feather para relacionar os apps da IPA Library aos respectivos tweaks/pacotes e revisões.

É derivado da source e deve ser regenerado pelo workflow.

## Repositórios relacionados

- `Lucas25Pedrosa/ipa-r2-core` — lógica privada de R2/Feather/relatórios.
- `Lucas25Pedrosa/ipa-shared-config-core` — cadastro e configuração compartilhada.
- `Lucas25Pedrosa/ipa-tweak-bot` — Injector público.
- `Lucas25Pedrosa/Bot-Injector-Core` — Core privado do Injector.
- `Lucas25Pedrosa/appstore-telegram-monitor` — orquestra o monitor e interage com a source em comandos como `/del`.

## Segredos e permissões

Os workflows usam secrets para categorias como:

- token de acesso ao Core privado;
- token de acesso ao shared config;
- credenciais R2/S3;
- Telegram;
- Azure Translator;
- sessão TeraBox.

Nunca gravar valores reais no repositório ou em artifacts persistentes.

## Regras de manutenção

1. Não renomear `IPA to R2` sem atualizar o gatilho do TeraBox.
2. Não apagar o artifact do TeraBox antes de confirmação do upload.
3. Não editar `Feather/feather.json` manualmente como solução permanente.
4. Toda alteração no formato da source deve preservar compatibilidade com o Feather.
5. Mudanças no backend de armazenamento precisam atualizar também o Core, Feather, `/del`, `/uso` e `/status`.
6. Durante migrações, manter rollback disponível antes de remover o storage anterior.
