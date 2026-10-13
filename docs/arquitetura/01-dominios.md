# Arquitetura de Domínios (DDD)

## Estilo: monólito modular

Começamos com um **monólito modular**: um deploy, um banco PostgreSQL, um schema
por bounded context. Módulos só conversam por (a) API interna explícita ou
(b) eventos de domínio via outbox. Nenhum módulo escreve em tabela de outro.
Isso preserva as transações ACID locais (estoque e financeiro) e mantém aberta a
extração para microsserviços quando houver motivo real (escala, time, deploy).

## Bounded contexts

| Contexto | Schema | Responsabilidade |
|---|---|---|
| Core / Plataforma | `core` | Tenants, empresas (estabelecimentos), usuários, RBAC, auditoria, outbox |
| Cadastros | `cadastro` | Parceiros (clientes/fornecedores/transportadoras), produtos, unidades |
| Suprimentos | `estoque`, `compras` | Saldos, lotes/validade, valoração (Custo Médio/PEPS), ordens de compra, recebimento por XML de NF-e |
| Vendas | `vendas` | Orçamentos, pedidos, faturamento, tabelas de preço |
| Financeiro | `financeiro` | Contas a pagar/receber, caixa, bancos, conciliação (OFX, CNAB 240/400), PIX, boletos |
| Contábil | `contabil` | Plano de contas, centros de custo, lançamentos (partidas dobradas), DRE |
| Fiscal | `fiscal` | NF-e, NFC-e, NFS-e, MDF-e, cálculo de ICMS/ICMS-ST/IPI/PIS/COFINS/ISS e IBS/CBS (reforma tributária), SPED |
| RH | `rh` | Colaboradores, folha, eSocial (fase posterior) |

## Fluxo principal de eventos: venda

```
vendas.PedidoFaturado
   ├─► fiscal: calcula tributos, emite NF-e ─► fiscal.NFeAutorizada
   │                                               │
   │      (NF-e rejeitada ─► fiscal.NFeRejeitada ─► vendas reabre o faturamento)
   │                                               ▼
   ├─► estoque: baixa saldo (lote/PEPS ou custo médio) ─► estoque.SaidaRegistrada
   ├─► financeiro: gera títulos a receber (parcelas) ─► financeiro.TituloGerado
   └─► contabil: lança receita, CMV e impostos
```

Decisão importante: a **baixa de estoque e os títulos só se efetivam após a NF-e
autorizada** (ou em contingência), porque nota rejeitada não pode deixar estoque
e financeiro inconsistentes. O pedido fica em estado `faturando` até lá.

## Fluxo de compra

```
compras.XmlNFeImportado ─► compras.RecebimentoConferido
   ├─► estoque: entrada (recalcula custo médio / cria camada PEPS, lote, validade)
   ├─► financeiro: títulos a pagar (das duplicatas do XML)
   └─► fiscal: escrituração de entrada (créditos de ICMS/PIS/COFINS)
```

## Outbox transacional

Cada módulo grava o evento em `core.outbox_eventos` **na mesma transação** da
mudança de estado. Um worker publica os eventos pendentes (fila: RabbitMQ/Redis)
e marca `publicado_em`. Consumidores devem ser idempotentes (chave = `id` do evento).

## Concorrência (estoque e financeiro)

- Saldos de estoque: `SELECT ... FOR UPDATE` na linha de saldo (produto+depósito+lote),
  sempre na mesma ordem de chaves para evitar deadlocks; `CHECK (saldo >= 0)` como
  última barreira contra estoque negativo.
- Baixas financeiras: bloqueio da linha do título + `CHECK (valor_pago <= valor)`.
- Versão otimista (`updated_at`) para edição de cadastros em telas.

## Multi-tenancy

- Banco compartilhado, `tenant_id` em toda tabela de negócio.
- **Row Level Security** em todas as tabelas de tenant: a aplicação conecta com o
  role `erp_app` e, no início de cada transação, executa
  `SET LOCAL app.tenant_id = '<uuid>'` e `SET LOCAL app.user_id = '<uuid>'`.
- FKs compostas `(tenant_id, id)` garantem que nem um bug de aplicação consegue
  ligar dados de tenants diferentes.
- Login: o tenant é resolvido pelo slug (subdomínio) via
  `core.fn_resolver_tenant(slug)` antes de haver contexto de tenant.
