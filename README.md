# dupe-scan

Scanner de arquivos duplicados para Windows e outras plataformas. Ele encontra arquivos byte a byte idênticos mesmo quando possuem nomes diferentes e também aponta colisões de mesmo nome/tamanho com conteúdo diferente.

O scanner é estritamente somente-leitura: não apaga, move, renomeia, executa nem altera os arquivos analisados. A única escrita possível é o relatório solicitado explicitamente com `--output`.

## Como executar

O Zig 0.16.0 é definido em `mise.toml`. Com o Zig disponível no PATH:

```text
zig build run -- 'C:\Users\User\Documents'
```

O progresso é obrigatório e sempre aparece no `stderr`, mostrando:

- enumeração de arquivos;
- candidatos por tamanho;
- amostragem;
- hashes completos com barra e `atual/total`;
- agrupamento e resumo final.

O relatório JSONL continua separado no `stdout`:

```text
zig build run -- 'D:\Backup' > resultado.jsonl
```

Para salvar diretamente em um arquivo novo:

```text
zig build run -- 'D:\Backup' --output resultado.jsonl
```

O caminho de `--output` não pode existir: isso evita sobrescrever dados por engano.

## Opções

```text
dupe-scan <raiz>... [--output <arquivo>] [--workers auto|N] [--backend auto|portable|win32]
```

- `--workers auto` aplica limites por volume; `N` define um teto global.
- `--backend auto` seleciona Win32 no Windows e o backend portátil nas demais plataformas.
- `--backend portable` força o backend portátil.
- `--backend win32` exige Windows.
- Não existe opção para desligar o progresso.

## Pipeline

1. Enumera metadados sem seguir links simbólicos, junctions ou reparse points.
2. Agrupa por tamanho exato.
3. Compara amostras do início e do fim do arquivo.
4. Calcula o hash BLAKE3 completo dos candidatos restantes.
5. Emite grupos duplicados, colisões de nome e erros recuperáveis em JSONL.

O scheduler limita leitores simultâneos por volume para evitar sobrecarga em mídias removíveis, remotas ou lentas.

## Desenvolvimento

```text
zig build test --summary all
zig build -Doptimize=ReleaseSafe
```

Os testes cobrem parser, segurança de saída, pipeline, concorrência, adapters Win32/portátil, JSONL e renderização do progresso.
