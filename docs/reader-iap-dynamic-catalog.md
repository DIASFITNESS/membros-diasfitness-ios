# Catálogo dinâmico Reader IAP — Parte A

Base: `823f8259fb45955cfede99559585ddbc9fb4586a`. Implementação para revisão;
sem merge, build Apple, upload ou publicação. Parte B não implementada.

## Contrato e implementação

- `diasIAP` continua recebendo `{id, op, payload}` e respondendo por
  `window.__diasIAPResolve(id, {ok, data/error})`. Os nomes das operações,
  campos de sucesso, preços localizados e códigos de erro existentes permanecem.
- `getProducts` exige `payload.productIds` como array de strings. Ausente, null,
  escalar, array misto, string vazia, caracteres fora de ASCII letras/dígitos/`._-`,
  ID acima de 100 bytes ou mais de 100 entradas brutas gera `iap_error` com a
  mensagem existente de produto inválido. O limite vale antes da deduplicação.
  Não há normalização de caixa nem remoção de espaços. Duplicados são deduplicados.
- Array vazio retorna `products: []`, sem consultar StoreKit. O fallback anterior
  para três produtos foi removido intencionalmente; o Reader deve enviar os IDs.
- Cada consulta usa `Product.products(for:)` com os IDs recebidos. A resposta é
  filtrada pelos IDs solicitados e ordenada por ID. Produtos desconhecidos ou
  indisponíveis são omitidos, sem metadados/preços fabricados. Erros StoreKit
  continuam chegando como `iap_error`.
- O limite de 100 entradas é por chamada, não por catálogo; catálogos maiores
  podem ser consultados em lotes sem alteração nativa. Não há lista/prefixo de
  cursos no Swift. GAP e qualquer produto futuro com formato válido seguem o
  mesmo caminho. Disponibilidade real depende da Apple, região e configuração.
- `purchase` consulta somente o ID solicitado, valida o formato e exige um
  `Product` de ID exatamente correspondente. Não depende de `getProducts`
  anterior. O sucesso exige verificação StoreKit e produto correspondente na
  transação; retorna o mesmo JWS e transaction ID string. Não concede cursos.
- Não existe cache compartilhado de produtos; respostas de consultas sobrepostas
  permanecem locais à operação, inclusive quando chegam fora de ordem.

## Recuperação e finish

`remember`, `Transaction.updates`, recuperação inicial de `Transaction.unfinished`,
`restore` e `sync` não dependem de produtos consultados nem de lista fixa. As
sequências StoreKit pertencem ao app; resultados não verificados são rejeitados.
`restore`/`sync` unem entitlements atuais e transações não finalizadas por ID,
preservando `signedTransaction`, `transactionId` e `originalTransactionId`.
Somente `sync` chama `AppStore.sync()`.

Nenhum filtro de catálogo ativo é aplicado à recuperação: uma compra antiga pode
precisar de reconciliação mesmo após o produto deixar de ser vendido. O backend
continua sendo a autoridade sobre IDs ativos, usuário proprietário, revogação,
validade e concessão de acesso. Verificação Apple não comprova propriedade da
conta DIASFITNESS. Nenhum callback espontâneo foi adicionado; o Reader precisa
solicitar restauração/sincronização para receber JWS recuperados.

`finish` reserva o transaction ID antes da primeira suspensão, liberando a reserva
com `defer`. Exige encontrar o ID em `Transaction.unfinished` com `.verified`,
mesmo que exista uma transação em memória. Assim um entitlement já finalizado,
reintroduzido em memória por `restore`, não autoriza outra finalização. Um conjunto
em memória também rejeita IDs finalizados nesta instância, inclusive se uma
sequência atrasada ainda expuser o ID. Após reinício, StoreKit é a fonte durável.
A validade do contexto é reavaliada antes da única chamada a `Transaction.finish()`.

**O frontend ainda é responsável por solicitar finish somente após o backend
validar e conceder acesso. O nativo NÃO comprova essa autorização.** Não foi
adicionado endpoint, token, assinatura, autenticação ou novo campo de protocolo.
Não há finalização automática na compra, observer, restauração ou reinício.

## Origem e navegação

Preservados os controles existentes: frame principal, HTTPS, host exato
`reader.diasfitness.com`, porta padrão/443, WKWebView de origem, geração de
navegação e token imutável por documento. O callback revalida origem e documento
no JavaScript e faz uma única tentativa. Perda do callback não finaliza nem
remove a compra; um novo request de recuperação é necessário. Request IDs ativos
continuam deduplicados; reutilização após conclusão continua permitida.

## Verificações executadas

`node tests/reader-iap-callback.test.cjs`: **27/27 passaram** (18 testes executam
JavaScript real extraído do Swift em documentos simulados; 9 são verificações
estáticas do código). Nenhum teste executa Swift, StoreKit ou comunicação backend.

| Cenário solicitado | Evidência disponível nesta entrega | Validação Apple ainda necessária |
| --- | --- | --- |
| Três IDs atuais, GAP, 26 produtos e futuro | Callback real com fixtures; 22 dos 26 IDs são sintéticos. Guardas estáticas de consulta dinâmica | Consulta real, metadados, preço e disponibilidade dos IDs reais |
| Desconhecido/indisponível | Callback com lista vazia; inspeção estática do filtro StoreKit | Retorno parcial/vazio real e falha de rede |
| Payload inválido e duplicados | Guardas estáticas de tipo, contagem, caracteres, tamanho e Set | Executar payload ausente/null/misto, espaços, Unicode, ID de 101 bytes, 101 entradas, duplicados e array vazio na bridge |
| Consultas concorrentes | Callbacks simulados em ordem inversa e ausência estática de cache compartilhado | Consultas StoreKit sobrepostas e compra simultânea a consulta |
| Cancelada, pendente e não verificada | Envelopes de erro simulados; casos e verificação criptográfica checados estaticamente | Cancelamento real, Ask to Buy/aprovação tardia, `.unverified`, erro StoreKit |
| Restore/sync e produtos novos | JWS/IDs grandes sintéticos em callback; sequências e deduplicação checadas estaticamente | Recuperar GAP/futuro após reinício, sem getProducts, inclusive consumível inacabado |
| Já finalizada e finish concorrente | Inspeção estática da origem unfinished e reserva anterior ao await | Duas chamadas com IDs de request distintos antes/durante finish, repetição após conclusão/restore/reinício, ID arbitrário, `.unverified` |
| Origem e callbacks | JS real em documentos simulados, navegação, resolver ausente/exceção, JSON especial; guardas nativas estáticas | WKWebView real, HTTP, domínio semelhante, iframe, porta indevida e término do processo |

`git diff --check` passou. Tree-sitter Swift 0.7.4 / tree-sitter 0.26.0 analisou
`ReaderIAPBridge.swift` sem erros de sintaxe. Isso não é compilação/type checking.
Swift, swiftc, Xcode e SDK Apple estão indisponíveis neste ambiente Linux.

Após autorização específica, compilar com Xcode e dependências existentes em
iOS 15+, executar a matriz em StoreKit Test/Sandbox e confirmar em dispositivo/
TestFlight. O arquivo de teste existente mantém o hash da função `verified` e do
bloco restore/sync; substitui apenas o hash amplo que incluía o helper alterado.
Não há alegação de 26 produtos reais consultados nem de compra Sandbox efetuada.

## Limites e arquivos

Código de produção alterado somente em `ReaderIAPBridge.swift`; testes em
`tests/reader-iap-callback.test.cjs`. Documentação complementar nesta nota, nas
notas históricas e no relatório separado `reader-iap-finish-part-b.md`.

StoreKit 2 e deployment target iOS 15.0 preservados. Nenhuma alteração em domínio
membros, Lovable/backend, banco, usuários, cursos/acessos, checkout, Mercado Pago,
financeiro, produtos Apple, Bundle ID, certificados, assinatura, entitlements,
versão/build number ou Codemagic. O YAML versionado não possui triggers automáticos;
não foi chamado nenhum serviço de build, upload, merge ou publicação. Configurações
externas do dashboard Codemagic não foram auditadas por ausência de acesso.
