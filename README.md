# ipa-r2-automation

Repositório público de **orquestração da publicação da IPA Library**. Ele contém os workflows do GitHub Actions, a source pública do Feather, o catálogo de tweaks e a integração de arquivamento no TeraBox.

A lógica sensível de armazenamento e geração da source fica em `ipa-r2-core`.

> **Estado atual:** o armazenamento principal da IPA Library é o **Google Drive**. O Cloudflare R2/Falcon foi retirado do runtime operacional e permanece apenas como legado/congelado e como fonte do workflow manual de migração. Alguns nomes de arquivos, workflows, repositórios e variáveis ainda contêm `R2` por compatibilidade histórica.

## Arquitetura atual

```text
Telegram / IPA Storage
        ↓
ipa-r2-automation
        ├── checkout ipa-r2-core
        ├── checkout ipa-shared-config-core
        ↓
IPA to R2
(nome legado mantido por compatibilidade)
        ↓
Google Drive
        ├── cria/atualiza pasta do app e da versão
        ├── atualiza drive_index.json
        ├── gera artifact para TeraBox
        ├── dispara Feather Source
        └── dispara Relatório Diário
                 ↓
       Feather/feather.json
                 ↓
              Feather

Downloads públicos
        ↓
drive.lucaspedrosa.shop
        ↓
ipa-drive-proxy
        ↓
Google Drive

IPA to R2 concluído
        ↓
TeraBox Archive
        ↓
arquivo histórico independente no TeraBox
```

## Armazenamento

### Google Drive

O Google Drive é o storage principal da IPA Library.

Cada app é controlado em `ipa-shared-config-core/drive_index.json`, usando o App Store ID como chave principal.

Estrutura lógica:

```text
IPA Library/
└── App/
    ├── versão antiga/
    │   └── App_versão.ipa
    └── versão atual/
        └── App_versão.ipa
```

O índice registra, por versão:

- `folder_id`;
- `drive_file_id`;
- `filename`;
- `build`;
- `size`;
- `sha256`.

A versão atual também é indicada por `current_version`.

### Regras de atualização

- Mesma versão + mesmo SHA-256: reutiliza o mesmo arquivo.
- Mesma versão + SHA-256 diferente: atualiza o conteúdo preservando o mesmo `drive_file_id`.
- Nova versão: cria nova pasta/arquivo e preserva as versões anteriores.
- Nenhuma exclusão histórica automática ocorre durante uma atualização normal.

### Download público

Os IPAs continuam privados no Google Drive.

O acesso público é feito por:

```text
https://drive.lucaspedrosa.shop/d/<DRIVE_FILE_ID>/<ARQUIVO.ipa>
```

O domínio é atendido pelo Worker `ipa-drive-proxy`, que:

- autentica no Google Drive;
- faz streaming do arquivo;
- suporta requisições `Range`;
- preserva `Content-Disposition`;
- envia `Cache-Control: no-store`;
- é usado pelo Feather para downloads e retomada.

O mesmo Worker também expõe rotas internas usadas pelo App Store Monitor por **Cloudflare Service Binding**, sem duplicar as credenciais Google no Worker do monitor.

### Cloudflare R2 / Falcon

O Falcon não faz parte do runtime operacional atual.

Ele permanece apenas como:

- armazenamento legado/congelado;
- origem do workflow manual `migrate-r2-to-drive.yml`;
- referência histórica em logs e nomes antigos.

Nenhum fluxo normal de upload, Feather, `/uso`, `/status`, `/del` ou consulta do monitor deve depender do Falcon.

## Estrutura do repositório

| Caminho | Função |
| --- | --- |
| `.github/workflows/ipa-to-r2.yml` | Workflow principal de publicação no Google Drive. O nome `IPA to R2` é legado e foi mantido por compatibilidade com o TeraBox. |
| `.github/workflows/feather-source.yml` | Atualiza/sincroniza `Feather/feather.json` com o `drive_index.json` e aplica metadados de pacote do Injector. |
| `.github/workflows/migrate-r2-to-drive.yml` | Workflow manual de migração do legado R2/Falcon para Google Drive. Não participa do fluxo normal. |
| `.github/workflows/terabox-archive.yml` | Arquiva no TeraBox o artifact produzido após um `IPA to R2` bem-sucedido. |
| `.github/workflows/terabox-session-test.yml` | Valida se a sessão persistida do TeraBox ainda está utilizável. |
| `.github/workflows/relatorio-diario.yml` | Gera e salva relatórios operacionais do Core privado. |
| `.github/workflows/tweak-catalog.yml` | Regenera `Feather/tweaks.json` quando a source muda. |
| `.github/workflows/healthcheck.yml` | Healthcheck simples do runner desta automação. O nome interno ainda pode conter R2 por compatibilidade histórica. |
| `.github/scripts/feather_package_metadata.py` | Recupera metadados de pacote/tweak enviados pelo Injector e aplica-os à versão correta no Feather. |
| `.github/scripts/update_tweak_catalog.py` | Gera/atualiza o catálogo público de tweaks com base na source e em fallbacks estáticos. |
| `scripts/terabox_upload.js` | Cliente de upload para o TeraBox. |
| `Feather/feather.json` | Source principal da **IPA Library** consumida pelo Feather. |
| `Feather/tweaks.json` | Catálogo público de tweaks/pacotes associado aos apps da source. |
| `Feather/icons/repo.png` | Ícone da source IPA Library. |
| `README.md` | Esta documentação. |

## Workflow `ipa-to-r2.yml`

Nome do workflow: **IPA to R2**.

O nome é legado, mas continua intencionalmente preservado porque `terabox-archive.yml` usa esse nome em `workflow_run`.

Renomeá-lo sem atualizar o TeraBox quebra o encadeamento.

### Entradas

- `telegram_message_id`: mensagem temporária usada pelo bot para progresso.
- `callback_url`: endpoint de callback do Worker que iniciou a ação.

### Fluxo

1. Faz checkout de `ipa-r2-core`.
2. Faz checkout de `ipa-shared-config-core`.
3. Instala dependências.
4. Executa `private-core/scripts/ipa_to_r2_by_id.py`.
5. O Core valida o IPA e envia para o Google Drive.
6. Atualiza `drive_index.json` somente após validar o upload.
7. Publica o artifact temporário para o TeraBox.
8. Dispara a atualização do Feather e o relatório.
9. Notifica o Worker/bot sobre a conclusão.

O nome dos scripts `ipa_to_r2.py` e `ipa_to_r2_by_id.py` também é legado. A implementação atual usa Google Drive.

## `drive_index.json`

O arquivo fica em `ipa-shared-config-core` e é a fonte de verdade para os IPAs armazenados no Google Drive.

Exemplo simplificado:

```json
{
  "APP_STORE_ID": {
    "name": "App",
    "bundle_id": "com.exemplo.app",
    "app_folder_id": "DRIVE_FOLDER_ID",
    "current_version": "1.2.3",
    "versions": {
      "1.2.3": {
        "folder_id": "VERSION_FOLDER_ID",
        "drive_file_id": "DRIVE_FILE_ID",
        "filename": "App_1.2.3.ipa",
        "build": "123",
        "size": 123456789,
        "sha256": "..."
      }
    }
  }
}
```

O `drive_file_id` é usado para gerar o link público e para exclusões exatas. Não deve ser feita busca destrutiva por nome de arquivo no Drive.

## Histórico de changelog

O arquivo `ipa-shared-config-core/appstore_release_history.json` preserva os release notes capturados da App Store.

Regras:

- a versão atual continua vindo da API da Apple;
- versões históricas usam o JSON quando necessário;
- release notes em inglês podem ser traduzidos pelo Azure Translator;
- o `/del` remove também a entrada do app nesse histórico.

## Workflow `feather-source.yml`

Responsável pela source pública `Feather/feather.json`.

Modos/entradas importantes:

- `sync_only`: sincroniza remoções usando o estado do `drive_index.json`;
- `silent`: evita mensagem própria de confirmação no Telegram;
- `rebuild_all`: reconstrói/atualiza metadados de todos os apps;
- demais inputs transportam nome, Bundle ID, versão, build e App Store ID para atualizações incrementais.

O input legado `r2_key` pode continuar presente por compatibilidade, mas não representa armazenamento ativo.

### Etapas principais

1. Checkout deste repositório.
2. Checkout de `ipa-r2-core`.
3. Checkout de `ipa-shared-config-core`.
4. Executa `scripts/feather_source.py`.
5. Executa `.github/scripts/feather_package_metadata.py`.
6. Salva mudanças em `Feather/feather.json`.
7. Envia confirmação ao Telegram, salvo modo silencioso.

### Comportamento multi-versão

O Feather preserva o histórico de versões armazenadas no Drive.

Para cada app:

- a versão atual fica em destaque;
- versões anteriores permanecem em `versions[]`;
- cada versão usa seu próprio `drive_file_id`;
- o histórico pode ser usado para downgrade pelo Feather;
- os metadados atuais vêm da Apple;
- os metadados históricos usam `appstore_release_history.json` e dados já preservados na source.

## `.github/scripts/feather_package_metadata.py`

Recupera da mensagem do Injector metadados transportados por uma URL invisível no host lógico `feather.invalid`.

Entre os campos suportados estão:

- Bundle ID;
- versão do app;
- nome do pacote;
- versão do pacote;
- `packageRevision`;
- label do pacote.

Depois adiciona esses dados como query parameters ao `downloadURL` da versão correta no Feather.

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

O TeraBox é tratado como **arquivo histórico independente** do Google Drive.

Uma falha no TeraBox não deve desfazer um upload do Drive já validado.

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

O relatório entende registros novos do Google Drive e mantém compatibilidade de leitura com logs antigos do R2.

Possui controle de concorrência para evitar duas escritas simultâneas no Core.

## Workflow `healthcheck.yml`

Job mínimo usado pelo Worker/bot para saber se o runner do serviço está acessível.

Ele não testa o Google Drive em profundidade. O status real do Drive é consultado pelo `ipa-drive-proxy` e pelo Service Binding usado pelo App Store Monitor.

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

Os `downloadURL` dos IPAs apontam para `drive.lucaspedrosa.shop`.

### Regra

O conteúdo é **gerado/atualizado pelo workflow**, não deve ser mantido manualmente como rotina.

Mudanças manuais podem ser sobrescritas pelo próximo `Feather Source`.

## `Feather/tweaks.json`

Catálogo consumido pelo fork do Feather para relacionar os apps da IPA Library aos respectivos tweaks/pacotes e revisões.

É derivado da source e deve ser regenerado pelo workflow.

## Integração com o App Store Monitor

O App Store Monitor usa o Google Drive sem receber as credenciais OAuth diretamente.

Arquitetura:

```text
appstore-monitor-trigger
        ↓
Service Binding DRIVE_PROXY
        ↓
ipa-drive-proxy
        ↓
Google Drive API
```

Os comandos principais usam:

- `/uso`: consulta a cota do Google Drive pelo proxy;
- `/status`: verifica Drive/proxy;
- `/del`: remove os `drive_file_id` exatos, atualiza `drive_index.json`, remove o histórico de changelog, sincroniza Feather e conclui a remoção do app.

O Falcon não deve ser consultado por esses comandos.

## Workflow `migrate-r2-to-drive.yml`

Esse workflow existe apenas para migração/recuperação manual do legado.

Ele pode usar:

- `R2_ACCESS_KEY_ID`;
- `R2_SECRET_ACCESS_KEY`;
- `R2_ENDPOINT`;
- `R2_BUCKET`;
- credenciais Google.

Como é `workflow_dispatch`, ele não roda automaticamente.

Não deve ser confundido com o pipeline normal de produção.

## Repositórios relacionados

- `Lucas25Pedrosa/ipa-r2-core` — lógica privada de armazenamento, Drive, Feather e relatórios. O nome do repositório é legado.
- `Lucas25Pedrosa/ipa-shared-config-core` — cadastro, `drive_index.json`, histórico de release notes e configuração compartilhada.
- `Lucas25Pedrosa/ipa-tweak-bot` — Injector público.
- `Lucas25Pedrosa/Bot-Injector-Core` — Core privado do Injector.
- `Lucas25Pedrosa/appstore-telegram-monitor` — workflows públicos do monitor.
- `Lucas25Pedrosa/appstore-telegram-core` — Core privado do monitor.

## Segredos e permissões

O fluxo de produção pode usar secrets para categorias como:

- token de acesso ao Core privado;
- token de escrita/leitura do shared config;
- `GOOGLE_CLIENT_ID`;
- `GOOGLE_CLIENT_SECRET`;
- `GOOGLE_REFRESH_TOKEN`;
- `DRIVE_FOLDER_ID`;
- Telegram;
- Azure Translator;
- sessão TeraBox.

O App Store Monitor não precisa duplicar as credenciais Google quando acessa o Drive pelo Service Binding.

As credenciais R2/S3 devem ficar restritas ao workflow manual de migração/legado enquanto ele for mantido.

Nunca gravar valores reais no repositório ou em artifacts persistentes.

## Regras de manutenção

1. Não renomear `IPA to R2` sem atualizar o gatilho do TeraBox.
2. Não tratar nomes contendo `R2` como prova de uso ativo do R2; vários são mantidos apenas por compatibilidade.
3. `drive_index.json` é a fonte de verdade do armazenamento operacional.
4. Não excluir arquivos do Drive por nome quando houver `drive_file_id` disponível.
5. Não apagar o artifact do TeraBox antes da confirmação do upload.
6. Não editar `Feather/feather.json` manualmente como solução permanente.
7. Toda alteração no formato da source deve preservar compatibilidade com o Feather.
8. Mudanças em `/del` devem manter sincronizados Drive, `drive_index.json`, `appstore_release_history.json`, Feather, `apps.json` e emoji.
9. O Falcon não deve voltar ao runtime sem decisão explícita de rollback.
10. Nunca remover versões históricas do Drive em uma atualização normal.
