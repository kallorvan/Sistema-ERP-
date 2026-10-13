-- =============================================================================
-- V0003 - Cadastros base: unidades de medida, parceiros (clientes/fornecedores/
--         transportadoras), endereços e produtos
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Unidades de medida
-- -----------------------------------------------------------------------------
CREATE TABLE cadastro.unidades_medida (
    id              uuid        PRIMARY KEY DEFAULT core.uuid_v7(),
    tenant_id       uuid        NOT NULL REFERENCES core.tenants (id),
    sigla           varchar(6)  NOT NULL CHECK (sigla ~ '^[A-Z0-9]{1,6}$'),  -- uCom da NF-e
    descricao       varchar(60) NOT NULL,
    casas_decimais  smallint    NOT NULL DEFAULT 0 CHECK (casas_decimais BETWEEN 0 AND 6),
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    created_by      uuid,
    updated_by      uuid,
    is_active       boolean     NOT NULL DEFAULT true,
    CONSTRAINT unidades_medida_tenant_id_uk UNIQUE (tenant_id, id),
    CONSTRAINT unidades_medida_sigla_uk     UNIQUE (tenant_id, sigla)
);
CALL core.aplicar_padroes('cadastro.unidades_medida');

-- -----------------------------------------------------------------------------
-- Parceiros de negócio (um cadastro único, com papéis)
-- -----------------------------------------------------------------------------
CREATE TABLE cadastro.parceiros (
    id                  uuid         PRIMARY KEY DEFAULT core.uuid_v7(),
    tenant_id           uuid         NOT NULL REFERENCES core.tenants (id),
    codigo              varchar(20)  NOT NULL,
    tipo_pessoa         char(1)      NOT NULL CHECK (tipo_pessoa IN ('F','J','E')), -- Física, Jurídica, Estrangeiro
    documento           varchar(20),  -- CPF, CNPJ ou identificação estrangeira; sem máscara
    nome                varchar(150) NOT NULL CHECK (btrim(nome) <> ''),       -- razão social / nome
    nome_fantasia       varchar(150),
    eh_cliente          boolean      NOT NULL DEFAULT false,
    eh_fornecedor       boolean      NOT NULL DEFAULT false,
    eh_transportadora   boolean      NOT NULL DEFAULT false,
    -- indIEDest da NF-e: 1 contribuinte ICMS, 2 contribuinte isento, 9 não contribuinte
    indicador_ie        smallint     NOT NULL DEFAULT 9 CHECK (indicador_ie IN (1,2,9)),
    inscricao_estadual  varchar(14)  CHECK (inscricao_estadual ~ '^[0-9]{2,14}$'),
    inscricao_municipal varchar(20),
    email               citext       CHECK (email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
    telefone            varchar(14)  CHECK (telefone ~ '^[0-9]{6,14}$'),
    limite_credito      core.dinheiro NOT NULL DEFAULT 0 CHECK (limite_credito >= 0),
    observacoes         text,
    created_at          timestamptz  NOT NULL DEFAULT now(),
    updated_at          timestamptz  NOT NULL DEFAULT now(),
    created_by          uuid,
    updated_by          uuid,
    is_active           boolean      NOT NULL DEFAULT true,
    CONSTRAINT parceiros_tenant_id_uk UNIQUE (tenant_id, id),
    CONSTRAINT parceiros_codigo_uk    UNIQUE (tenant_id, codigo),
    CONSTRAINT parceiros_papel_ck     CHECK (eh_cliente OR eh_fornecedor OR eh_transportadora),
    CONSTRAINT parceiros_documento_ck CHECK (
           (tipo_pessoa = 'F' AND documento IS NOT NULL AND core.fn_valida_cpf(documento))
        OR (tipo_pessoa = 'J' AND documento IS NOT NULL AND core.fn_valida_cnpj(documento))
        OR (tipo_pessoa = 'E')),
    CONSTRAINT parceiros_ie_ck CHECK (
           (indicador_ie = 1 AND inscricao_estadual IS NOT NULL)
        OR (indicador_ie IN (2,9))),
    CONSTRAINT parceiros_estrangeiro_ie_ck CHECK (tipo_pessoa <> 'E' OR indicador_ie = 9)
);
CREATE UNIQUE INDEX parceiros_documento_uk ON cadastro.parceiros (tenant_id, documento)
    WHERE documento IS NOT NULL AND tipo_pessoa IN ('F','J');
CREATE INDEX parceiros_nome_trgm_ix ON cadastro.parceiros USING gin (nome gin_trgm_ops);
CALL core.aplicar_padroes('cadastro.parceiros');

CREATE TABLE cadastro.parceiro_enderecos (
    id               uuid        PRIMARY KEY DEFAULT core.uuid_v7(),
    tenant_id        uuid        NOT NULL REFERENCES core.tenants (id),
    parceiro_id      uuid        NOT NULL,
    tipo             varchar(10) NOT NULL CHECK (tipo IN ('principal','cobranca','entrega','retirada')),
    logradouro       varchar(60) NOT NULL,
    numero           varchar(60) NOT NULL,
    complemento      varchar(60),
    bairro           varchar(60) NOT NULL,
    codigo_municipio core.codigo_ibge_munic,  -- '9999999' para exterior (padrão NF-e)
    municipio        varchar(60) NOT NULL,
    uf               core.uf     NOT NULL,
    cep              core.cep,
    codigo_pais      char(4)     NOT NULL DEFAULT '1058' CHECK (codigo_pais ~ '^[0-9]{4}$'), -- tabela BACEN
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    updated_by       uuid,
    is_active        boolean     NOT NULL DEFAULT true,
    CONSTRAINT parceiro_enderecos_tenant_id_uk UNIQUE (tenant_id, id),
    CONSTRAINT parceiro_enderecos_parceiro_fk  FOREIGN KEY (tenant_id, parceiro_id)
        REFERENCES cadastro.parceiros (tenant_id, id),
    CONSTRAINT parceiro_enderecos_brasil_ck CHECK (
           (codigo_pais = '1058' AND uf <> 'EX' AND cep IS NOT NULL AND codigo_municipio IS NOT NULL)
        OR (codigo_pais <> '1058' AND uf = 'EX'))
);
CREATE INDEX parceiro_enderecos_parceiro_ix ON cadastro.parceiro_enderecos (tenant_id, parceiro_id);
CREATE UNIQUE INDEX parceiro_enderecos_principal_uk ON cadastro.parceiro_enderecos (tenant_id, parceiro_id)
    WHERE tipo = 'principal' AND is_active;
CALL core.aplicar_padroes('cadastro.parceiro_enderecos');

-- -----------------------------------------------------------------------------
-- Produtos e serviços
-- -----------------------------------------------------------------------------
CREATE TABLE cadastro.produtos (
    id                 uuid          PRIMARY KEY DEFAULT core.uuid_v7(),
    tenant_id          uuid          NOT NULL REFERENCES core.tenants (id),
    codigo             varchar(60)   NOT NULL,  -- cProd da NF-e
    descricao          varchar(120)  NOT NULL CHECK (btrim(descricao) <> ''),  -- xProd (máx. 120)
    -- Tipo do item (SPED, registro 0200)
    tipo_item          char(2)       NOT NULL CHECK (tipo_item IN ('00','01','02','03','04','05','06','07','08','09','10','99')),
    unidade_id         uuid          NOT NULL,
    ncm                char(8)       CHECK (ncm ~ '^[0-9]{8}$'),
    cest               char(7)       CHECK (cest ~ '^[0-9]{7}$'),
    gtin               varchar(14)   CHECK (gtin ~ '^([0-9]{8}|[0-9]{12,14})$'),
    -- Origem da mercadoria (CST ICMS, 1º dígito): 0 a 8
    origem             smallint      NOT NULL DEFAULT 0 CHECK (origem BETWEEN 0 AND 8),
    preco_venda        core.valor_unitario NOT NULL DEFAULT 0 CHECK (preco_venda >= 0),
    peso_liquido_kg    NUMERIC(15,4) CHECK (peso_liquido_kg >= 0),
    peso_bruto_kg      NUMERIC(15,4) CHECK (peso_bruto_kg >= 0),
    controla_estoque   boolean       NOT NULL DEFAULT true,
    controla_lote      boolean       NOT NULL DEFAULT false,
    controla_validade  boolean       NOT NULL DEFAULT false,
    metodo_valoracao   varchar(5)    NOT NULL DEFAULT 'MEDIO' CHECK (metodo_valoracao IN ('MEDIO','PEPS')),
    created_at         timestamptz   NOT NULL DEFAULT now(),
    updated_at         timestamptz   NOT NULL DEFAULT now(),
    created_by         uuid,
    updated_by         uuid,
    is_active          boolean       NOT NULL DEFAULT true,
    CONSTRAINT produtos_tenant_id_uk UNIQUE (tenant_id, id),
    CONSTRAINT produtos_codigo_uk    UNIQUE (tenant_id, codigo),
    CONSTRAINT produtos_unidade_fk   FOREIGN KEY (tenant_id, unidade_id)
        REFERENCES cadastro.unidades_medida (tenant_id, id),
    -- Mercadorias exigem NCM; serviço (09) não movimenta estoque
    CONSTRAINT produtos_ncm_ck       CHECK (tipo_item = '09' OR ncm IS NOT NULL),
    CONSTRAINT produtos_servico_ck   CHECK (tipo_item <> '09' OR NOT controla_estoque),
    CONSTRAINT produtos_validade_ck  CHECK (NOT controla_validade OR controla_lote),
    CONSTRAINT produtos_lote_ck      CHECK (NOT controla_lote OR controla_estoque),
    CONSTRAINT produtos_peso_ck      CHECK (peso_bruto_kg IS NULL OR peso_liquido_kg IS NULL
                                            OR peso_bruto_kg >= peso_liquido_kg)
);
CREATE INDEX produtos_unidade_ix ON cadastro.produtos (tenant_id, unidade_id);
CREATE INDEX produtos_ncm_ix     ON cadastro.produtos (tenant_id, ncm);
CREATE UNIQUE INDEX produtos_gtin_uk ON cadastro.produtos (tenant_id, gtin) WHERE gtin IS NOT NULL;
CREATE INDEX produtos_descricao_trgm_ix ON cadastro.produtos USING gin (descricao gin_trgm_ops);
CALL core.aplicar_padroes('cadastro.produtos');
