# Sistema ERP

ERP SaaS multi-tenant para o mercado brasileiro: fiscal (NF-e/NFC-e/NFS-e, SPED),
financeiro, estoque, compras, vendas e contábil.

- Convenções e regras do projeto: [`CLAUDE.md`](CLAUDE.md)
- Arquitetura de domínios e fluxos de eventos: [`docs/arquitetura/01-dominios.md`](docs/arquitetura/01-dominios.md)

## Banco de dados (PostgreSQL 16+)

```bash
docker compose up -d
export DATABASE_URL=postgres://erp:erp@localhost:5432/erp
./db/migrate.sh   # aplica db/migrations/V*.sql
./db/test.sh      # testes de integridade (RLS, FKs, CHECKs, auditoria)
```

| Migration | Conteúdo |
|---|---|
| V0001 | Extensões, schemas, role `erp_app`, domínios exatos (dinheiro/quantidade/alíquota), UUID v7, validação CPF/CNPJ (incl. alfanumérico), triggers de auditoria e `audit_log` |
| V0002 | Tenants, usuários, empresas/filiais, RBAC (permissões → papéis → usuários, com escopo por filial), outbox de eventos |
| V0003 | Unidades de medida, parceiros (clientes/fornecedores/transportadoras) e endereços, produtos (NCM, CEST, GTIN, origem, lote/validade, método de valoração) |

## Roadmap

1. **Fundação** (concluído): core, segurança, cadastros base
2. Estoque: depósitos, lotes/validade, movimentos, saldos, custo médio e camadas PEPS
3. Financeiro: plano de contas, centros de custo, títulos a pagar/receber, baixas, contas bancárias
4. Fiscal: regras tributárias, cálculo de impostos, documentos fiscais (NF-e)
5. Compras e Vendas, com integração por eventos
6. Backend (API) e Frontend
