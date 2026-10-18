# Parte B — confirmação nativa do backend para finish (somente proposta)

**Não implementada. Exige nova autorização.** Nenhum frontend/backend Lovable,
endpoint, token, assinatura, autenticação ou regra de concessão foi alterado.

## Contrato conhecido e informação faltante

O contrato nativo verificável neste repositório é:

1. `purchase` retorna `signedTransaction` (JWS StoreKit) e `transactionId` string.
2. `restore`/`sync` retornam `entitlements` com JWS, transactionId e originalTransactionId.
3. O frontend envia o JWS ao backend para validação e concessão de acesso.
4. Somente após sucesso confirmado, o frontend envia `finish` com `transactionId`.

Os itens 3 e 4 são uma obrigação documentada do frontend, não uma prova nativa de
sua execução. O código web e o backend não estão neste repositório. Não foram
consultados ou modificados na Lovable. Não se conhece a rota real, o esquema de
autenticação nem a resposta de validação/provisionamento. Nenhuma rota é presumida.

Antes de implementar B, consultar em modo leitura e com acesso autorizado:

- A função do Reader que posta `purchase`, processa o JWS e envia `finish`.
- O contrato real de validação Apple: autenticação, request/response, erros,
  idempotência, recuperação e confirmação de concessão efetiva.
- Como o backend associa a transação Apple à conta DIASFITNESS, evita reatribuição
  a outra conta e valida produto, ambiente Apple, bundle e revogação.
- Se existe consulta autenticada de status de uma transação já validada e
  provisionada, e se ela pode ser usada com segurança por um cliente nativo.

## Solução mínima condicional

Preferir reutilizar uma consulta autenticada existente. Antes de chamar
`Transaction.finish()`, o nativo consultaria o status de autorização dessa mesma
transação diretamente no backend, pela origem HTTPS Reader, sem aceitar um
`validated: true` do JavaScript como evidência. A forma de autenticação depende
do contrato real; não se presume que cookies da WKWebView sejam compartilhados
com URLSession nem se copia credencial sem análise explícita.

A confirmação precisa vincular de forma inequívoca: transaction ID exato,
original transaction ID quando aplicável, Product ID da transação verificada,
app/bundle e ambiente Apple, conta DIASFITNESS autenticada e estado de validação/
concessão concluída. O backend deve derivar e conferir esses dados do JWS e da
sessão, não confiar apenas nos valores declarados pelo JavaScript. A resposta
precisa ser atual e resistente a reutilização em outra transação ou conta; uma
nova consulta no momento de finish é a opção mínima quando já suportada.

Se já houver esse contrato e autenticação utilizável pelo nativo, pode bastar
uma alteração iOS, preservando o payload atual de finish. **Isso não está
confirmado.** Se não houver, B exige uma extensão do backend existente e
possivelmente do frontend/autenticação na Lovable. Qualquer extensão deverá ser
proposta com base no código real e aprovada separadamente. Uma autorização
assinada transportada pelo frontend seria uma alternativa mais ampla, exigindo
contrato e gestão de chaves; não é proposta como mecanismo já existente.

Não há mudança proposta à decisão de conceder cursos: B apenas verificaria o
resultado da decisão existente, antes de finalizar na Apple.

## Recuperação e falhas

- Timeout, ausência de autenticação, resposta negativa/inconsistente ou falha de
  rede: não finalizar. Manter a transação recuperável no StoreKit.
- Após reinício, recuperar JWS por restore/sync e reenviar ao mesmo fluxo backend,
  idempotente por transação. A autorização precisa poder ser obtida novamente.
- Troca de conta: não finalizar usando uma aprovação emitida para a conta anterior.
- Backend concedeu acesso, mas a resposta se perdeu: consultar/repetir a validação
  idempotente, sem nova compra nem nova concessão.
- Finish executou, mas o callback se perdeu: reconciliar com o estado durável do
  backend e StoreKit. Entitlements não consumíveis ainda podem ser recuperados;
  consumíveis finalizados não reaparecem em unfinished. Não interpretar a ausência
  como necessidade de cobrar novamente.
- Não introduzir finalização automática nem usar falha de callback como autorização.

## Risco residual ao entregar A primeiro

A Parte A continua exigindo transação Apple verificada e não finalizada, origem
Reader e proteção contra concorrência/duplicidade. Porém JavaScript executado
nesse domínio — inclusive em caso de comprometimento — ainda pode pedir finish
antecipadamente para uma transação elegível sem comprovar a validação e concessão
pelo backend. A ampliação dinâmica abrange todos os produtos StoreKit do app; o
catálogo ativo e a conta DIASFITNESS não são comprovados pelo nativo.

Isso não concede acesso no backend por si só, mas pode retirar uma compra de
unfinished antes da reconciliação. O risco é especialmente relevante para
consumíveis, cuja recuperação após finalização depende do registro backend.
Portanto A não deve ser apresentada como proteção nativa contra desvio dessa
ordem. A garantia adicional permanece pendente da Parte B, do contrato real e
de nova autorização.
