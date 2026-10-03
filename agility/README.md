# RustAgility

Cliente RustDesk com marca e servidor proprios. Fork de
[rustdesk/rustdesk](https://github.com/rustdesk/rustdesk), licenca AGPL-3.0
(o codigo-fonte modificado fica publico neste repositorio).

## O que muda em relacao ao RustDesk

| O que | Onde |
|---|---|
| Nome do app `RustAgility` (servico, pasta, `RustAgility.exe`, textos da UI) | `agility/hbb_common.patch` (`APP_NAME`) |
| Servidor `rustdesk.agilitysti.com.br`, Key, API Server e WebSocket ligados por padrao | `agility/hbb_common.patch` (`RENDEZVOUS_SERVERS`, `RS_PUB_KEY`, `DEFAULT_SETTINGS`) |
| Icones (exe, bandeja, interface) | `agility/gen_icons.py` a partir de `agility/logo-source.png` |
| Metadados do .exe (Propriedades) | `flutter/windows/runner/Runner.rc` |
| Build Windows x64 | `.github/workflows/agility-windows.yml` |

Com nome diferente de "RustDesk" o proprio codigo desliga a atualizacao
automatica para o RustDesk oficial (`is_custom_client()`).

O servidor, a Key etc. estao no submodulo `libs/hbb_common` (outro repo). Em
vez de um segundo fork, o workflow aplica `agility/hbb_common.patch` antes de
compilar. Para conferir localmente:

    git -C libs/hbb_common apply --check ../../agility/hbb_common.patch

## Gerar o instalador

GitHub -> Actions -> **RustAgility Windows** -> Run workflow. Leva cerca de
1 h. O resultado fica em Artifacts da execucao:

- `RustAgility-<versao>-x86_64.exe`: instalador/portatil (sempre)
- `RustAgility-<versao>-x86_64.msi`: se o passo do MSI der certo

Sem certificado de assinatura de codigo o Windows mostra o aviso do
SmartScreen ("Mais informacoes" -> "Executar assim mesmo").

## Trocar logo, servidor ou Key

- Logo: substituir `agility/logo-source.png` (PNG quadrado 1024x1024,
  fundo transparente) e rodar `python3 agility/gen_icons.py` (Pillow).
- Servidor/Key: editar `libs/hbb_common/src/config.rs`, regerar o patch com
  `git -C libs/hbb_common diff > agility/hbb_common.patch` e desfazer a
  alteracao no submodulo (`git -C libs/hbb_common checkout -- .`).

## Atualizar com o RustDesk oficial

Sincronizar o fork (Sync fork no GitHub). Conflitos possiveis so nos arquivos
da tabela acima. Se o `hbb_common` mudar a ponto de o patch nao aplicar, o
passo "Apply RustAgility patch" falha logo no inicio do build; refazer o
patch sobre o `config.rs` novo.
