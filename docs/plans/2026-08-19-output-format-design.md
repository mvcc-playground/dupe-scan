# Design: saida humana e JSONL

## Decisao

O terminal interativo usa `text` por padrao. Redirecionamentos e `--output` usam `jsonl` por padrao. `--format text` e `--format jsonl` permitem escolher explicitamente.

## Formato text

O relatorio sera organizado em secoes de duplicatas, colisoes, erros e resumo. Cada caminho sera impresso uma vez como texto legivel e, quando o terminal suportar, como hyperlink OSC-8 `file:///...`. O conteudo continua seguro para terminais sem suporte porque o caminho tambem aparece literalmente.

## Formato jsonl

O contrato atual permanece: um objeto JSON valido por linha, UTF-8, com `schema_version` e `event`. Isso preserva processamento incremental com jq, PowerShell e outras ferramentas NDJSON.

## Validacao

- parser de argumentos para os dois formatos;
- teste do reporter text com caminhos e grupos;
- teste de que JSONL continua parseavel linha a linha;
- smoke test em terminal e redirecionamento.
