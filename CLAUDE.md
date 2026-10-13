# Sistema ERP — Guia do Projeto

ERP multi-empresa (SaaS multi-tenant) voltado ao mercado brasileiro.
Papel de referência: `docs/role-erp-database-architect.md`.

## Regras inegociáveis de banco de dados

1. **Integridade referencial rigorosa**: toda relação tem FK; regras de negócio
   simples viram `CHECK`; unicidade de negócio vira `UNIQUE` (sempre escopada por
   `tenant_id`).
2. **Colunas de auditoria em toda tabela de negócio**:
   `tenant_id, created_at, updated_at, created_by, updated_by, is_active`.
   Preenchidas por trigger (`core.fn_colunas_auditoria`) — a aplicação não precisa
   (nem consegue) forjá-las.
3. **Valores monetários e quantidades sempre exatos** (`NUMERIC`), via domínios:
   `core.dinheiro` (18,2), `core.valor_unitario` (18,6), `core.quantidade` (18,6),
   `core.aliquota` (9,4). **Nunca** `float`/`real`/`double precision`/`money`.
4. **Migrations completas em PostgreSQL** em `db/migrations/VNNNN__descricao.sql`.
   Migration aplicada é imutável (o runner valida checksum) — corrija com uma nova.

## Convenções

- Identificadores em português, `snake_case`; tabelas no plural.
- Um schema por bounded context: `core`, `cadastro` (futuros: `estoque`,
  `compras`, `vendas`, `financeiro`, `contabil`, `fiscal`, `rh`).
- PK `id UUID DEFAULT core.uuid_v7()` (ordenável no tempo, bom para índices).
- Toda tabela multi-tenant tem `UNIQUE (tenant_id, id)` e as FKs entre tabelas
  de tenant são **compostas** `(tenant_id, x_id)` — impossível referenciar
  registro de outro tenant.
- Toda nova tabela chama `CALL core.aplicar_padroes('schema.tabela')`, que liga:
  trigger de auditoria, log de auditoria, FKs de `created_by/updated_by`,
  Row Level Security por tenant e grants para o role `erp_app`.
- Exclusão lógica (`is_active = false`); o role da aplicação não tem `DELETE`.
- Toda FK tem índice (o PostgreSQL não cria automaticamente).
- Eventos entre contextos via outbox transacional (`core.outbox_eventos`).

## Exceções documentadas à regra de auditoria

- `core.tenants` — é o próprio tenant (não tem `tenant_id`).
- `core.permissoes` — catálogo global de permissões do sistema.
- `core.audit_log` — log append-only (tem `tenant_id`, `alterado_em`, `alterado_por`).
- `public.schema_migrations` — controle do runner.

## Comandos

```bash
docker compose up -d                         # Postgres 16 local
export DATABASE_URL=postgres://erp:erp@localhost:5432/erp
./db/migrate.sh                              # aplica migrations pendentes
./db/test.sh                                 # testes de integridade (SQL)
```
