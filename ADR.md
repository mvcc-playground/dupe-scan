# ADR-0001: Runtime concorrente e pipeline incremental

- **Status:** Aceito
- **Data:** 2026-08-19
- **Decisão:** Adotar ZIO como runtime de concorrência e I/O da aplicação, mantendo `std.Io` como contrato das bibliotecas e adapters.

## Implementacao registrada (2026-08-19)

- O executavel inicializa `zio.Runtime` e passa `runtime.io()` para adapters e progresso.
- ZIO esta fixado no commit `1e9b15be900d6865479ea9d04705476f177a2e1f`; o lock/hash fica em `build.zig.zon`.
- `pipeline.scanIncremental` usa `std.Io.Queue` com capacidade 256 para transportar metadados e erros com backpressure. A enumeracao e a amostragem podem avancar em paralelo.
- `pipeline.scan` permanece batch para testes e integracoes existentes, reduzindo risco enquanto hash/grouper incremental ainda sao medidos.
- Validacao realizada: `zig build test --summary all` (24/24) e `zig build -Doptimize=ReleaseSafe`.

Proximas etapas: medir tempo ate primeira amostra/hash; migrar hash e grouper para filas adicionais somente se o benchmark ReleaseFast justificar; depois otimizar conversoes UTF-16/UTF-8 no Windows.

## Correcao de paralelismo (2026-08-19)

O primeiro ajuste de `--workers` tinha uma falha: a politica ainda reservava no maximo dois leitores por volume fixo, entao valores 12 e 120 produziam o mesmo plano. A politica agora distribui leitores adicionais em round-robin entre volumes fixos e limita valores explicitos a 32 leitores para evitar tempestade de seeks, memoria e handles. Volumes removiveis/remotos continuam com um leitor.

O texto `Hashing 16/N` e um marco de progresso, nao uma barreira: cada worker continua processando itens enquanto o contador e atualizado a cada 16 conclusoes. A fila ZIO continua limitada; a documentacao do projeto confirma que `std.Io`/queues sao a abstracao de concorrencia usada pelo runtime ([ZIO](https://github.com/lalinsky/zio)).

## Workers automáticos (2026-08-19)

Quando `--workers` não é informado, o scheduler consulta rapidamente a quantidade de CPUs lógicas e sugere `2x CPU`, com mínimo de 4 e máximo de 32 leitores. O limite de 32, combinado com buffers de 256 KiB por leitor e fila limitada, evita crescimento sem controle de memória. O usuário ainda pode fornecer `--workers N` para substituir a sugestão.

Essa escolha é deliberadamente conservadora para discos: mais threads não garantem mais velocidade quando o gargalo é I/O. O plano efetivo continua aparecendo no `scan_summary.worker_plan`, permitindo medir e ajustar por máquina.

## Saida legivel e contrato NDJSON (2026-08-19)

O contrato de dados permanece JSONL/NDJSON valido em UTF-8: um objeto por linha para automacao. Para leitura humana, o terminal interativo escolhe `text` automaticamente; `--format text` e `--format jsonl` permitem escolha explicita. O formato texto separa duplicatas, colisoes, erros e resumo, calcula throughput e emite hyperlinks OSC-8 `file:///...` quando o terminal suporta, mantendo o caminho literal como fallback.

Redirecionamentos e `--output` continuam JSONL por padrao para nao misturar diagnostico/progresso com dados. A especificacao NDJSON exige UTF-8 e um valor JSON valido por linha ([ndjson-spec](https://github.com/ndjson/ndjson-spec)); essa decisao preserva streaming e validacao com ferramentas comuns.

## Relatorio text com arquivos e pastas (2026-08-19)

No formato humano, cada membro continua sendo exibido como `FILE`, com nome, tamanho e caminho clicavel. Em seguida, o reporter lista as pastas pai como `FOLDER`, removendo repeticoes dentro do mesmo grupo. Assim, arquivos continuam verificaveis individualmente e a pasta pode ser aberta para uma acao manual; nenhuma exclusao automatica e feita.

## Arquivos vazios (2026-08-19)

Arquivos de tamanho zero foram removidos da etapa de candidatos. O conteudo vazio e identico por definicao, gerando grupos ruidosos com `.gitkeep`, arquivos temporarios e marcadores de cache. Eles continuam enumerados e nao sao apagados; apenas deixam de ser amostrados, hasheados e reportados como duplicatas.

## Contexto

O `dupe-scan` já usa `std.Io` nos adapters, mas o pipeline ainda é uma sequência de barreiras:

1. enumera todos os arquivos;
2. constrói todos os buckets por tamanho;
3. amostra todos os candidatos;
4. calcula todos os hashes completos;
5. agrupa e só então produz o resultado.

Esse desenho é correto, porém aumenta o pico de memória e impede que a amostragem e o hashing comecem enquanto a enumeração ainda está recebendo dados. O hashing atual usa `std.Thread.spawn` e monta o plano de volumes apenas depois que todos os candidatos são conhecidos.

## Alternativas consideradas

### ZIO

Escolhido. Fornece fibers, structured concurrency, cancellation, timeouts, channels e execução single-thread ou multi-thread, mantendo a aplicação escrita contra `std.Io`. Isso permite que o núcleo continue independente do runtime e que o executável escolha a implementação de I/O adequada ao Windows.

### libxev

Excelente opção low-level e com alocações de runtime reduzidas, mas sua arquitetura não implementa `std.Io`. Adotá-lo agora criaria uma segunda abstração concorrente e aumentaria o custo de integração entre o núcleo existente e os adapters.

### ForkUnion / Loom

São interessantes para CPU-bound e fork/join, mas o scanner é predominantemente I/O-bound. ForkUnion ainda adicionaria um core C++/NUMA; Loom resolveria paralelismo de CPU, não o fluxo de I/O entre etapas.

### `std.Thread` e `std.Io` sem runtime adicional

É o menor risco imediato e continua sendo o fallback de compatibilidade. Não resolve, sozinho, a necessidade de canais, backpressure, cancellation e execução incremental entre as fases.

## Decisão

Usaremos ZIO como runtime do executável, mas manteremos as interfaces públicas do domínio e dos adapters baseadas em `std.Io`. O pipeline será dividido em estágios com canais limitados:

```text
enumeradores -> índice de tamanho -> amostradores -> hashers por volume -> grouper -> relatório
       metadata       sample jobs          hash jobs            resultados
```

O índice de tamanho começa a trabalhar assim que recebe o segundo arquivo de um tamanho. Um arquivo ainda pode ser amostrado antes de existir um par, mas nenhum arquivo será considerado duplicado sem hash completo. Os canais terão capacidade fixa para impor backpressure e manter a máquina responsiva.

O grouper continuará emitindo o JSONL final de forma determinística após o fechamento dos canais. O progresso poderá ser incremental durante toda a execução, sem mudar o contrato dos eventos finais.

O scheduler continuará limitado por volume: leitores de volumes fixos podem receber dois slots por padrão; removível, remoto e desconhecido recebem um. ZIO fornecerá fibers e cancellation, mas não será usado para multiplicar leitores indiscriminadamente nem para misturar filas de discos diferentes.

## Consequências

### Positivas

- Menor tempo até a primeira amostra e o primeiro hash.
- Menor quantidade de trabalho pendente em cada etapa.
- Backpressure explícito e memória previsível.
- Cancellation e shutdown estruturados quando um root falhar ou o usuário interromper.
- Biblioteca continua reutilizável por qualquer implementação de `std.Io`.

### Negativas e riscos

- Introdução de uma dependência/runtime novo que precisa ser fixado e validado contra Zig 0.16.0.
- O índice de tamanho e o grouper terão estado concorrente mais complexo.
- A saída final precisa esperar o fechamento dos canais, mesmo que o trabalho interno seja incremental.
- Integração prematura pode piorar throughput em discos lentos; toda mudança será aceita somente após benchmark ReleaseFast no mesmo dataset.

## Regras de segurança

- Nenhum estágio ganha APIs de deleção, movimento, renomeação ou escrita nos arquivos de entrada.
- Reparse points, symlinks e junctions continuam sendo rejeitados antes da recursão.
- Erros de arquivo são mensagens recuperáveis e fecham apenas o item afetado.
- Canais são limitados; uma raiz ou disco lento não pode provocar crescimento ilimitado de memória.
- O progresso permanece em `stderr`; JSONL e `--output` não recebem mensagens de diagnóstico.

## Plano incremental

1. Medir a implementação atual em ReleaseFast e registrar tempo até primeiro resultado útil, arquivos/s, bytes/s, leitores efetivos e pico aproximado de memória.
2. Fazer um spike isolado de compatibilidade ZIO + Zig 0.16.0, sem trocar o scanner ainda; validar `std.Io`, channels, cancellation e structured concurrency no Windows.
3. Extrair contratos de mensagens e ownership (`Metadata`, `SampleJob`, `SampleResult`, `HashJob`, `HashResult`) sem mudar o resultado final.
4. Implementar canais limitados e um índice de tamanho single-owner; quando um tamanho atingir dois itens, publicar trabalho de amostragem imediatamente.
5. Implementar amostradores e hashers como estágios concorrentes; preservar o scheduler por volume e adicionar fechamento explícito de canais.
6. Adaptar o grouper para consumir resultados à medida que chegam, mantendo a emissão JSONL determinística no encerramento.
7. Otimizar o caminho Windows medido: manter caminhos operacionais em UTF-16, reduzir conversões/joins por entrada e reutilizar buffers por worker.
8. Adicionar cancellation, timeout por root, tratamento de canal cheio e encerramento limpo em erro/interrupção.
9. Comparar batch versus staged em datasets pequenos, muitos arquivos, arquivos grandes, árvores profundas, múltiplos volumes, falhas de permissão e arquivos que desaparecem.
10. Promover staged a padrão somente se mantiver resultados idênticos, segurança intacta e melhorar tempo total ou tempo até primeiro trabalho útil sem aumentar o pico de memória além do limite documentado.
