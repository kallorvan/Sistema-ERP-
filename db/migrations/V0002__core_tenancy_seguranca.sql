-- =============================================================================
-- V0002 - Core: tenants, usuários, empresas, RBAC e outbox de eventos
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Tenants (exceção documentada: a própria linha é o tenant, sem tenant_id)
-- -----------------------------------------------------------------------------
CREATE TABLE core.tenants (
    id          uuid         PRIMARY KEY DEFAULT core.uuid_v7(),
    nome        varchar(150) NOT NULL CHECK (btrim(nome) <> ''),
    slug        varchar(63)  NOT NULL,
    plano       varchar(30)  NOT NULL DEFAULT 'basico'
                CHECK (plano IN ('basico','profissional','enterprise')),
    created_at  timestamptz  NOT NULL DEFAULT now(),
    updated_at  timestamptz  NOT NULL DEFAULT now(),
    created_by  uuid,
    updated_by  uuid,
    is_active   boolean      NOT NULL DEFAULT true,
    CONSTRAINT tenants_slug_uk UNIQUE (slug),
    CONSTRAINT tenants_slug_ck CHECK (slug ~ '^[a-z0-9]([a-z0-9-]{1,61}[a-z0-9])$')
);

-- -----------------------------------------------------------------------------
-- Usuários
-- -----------------------------------------------------------------------------
CREATE TABLE core.usuarios (
    id                  uuid         PRIMARY KEY DEFAULT core.uuid_v7(),
    tenant_id           uuid         NOT NULL REFERENCES core.tenants (id),
    nome                varchar(150) NOT NULL CHECK (btrim(nome) <> ''),
    email               citext       NOT NULL CHECK (email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
    senha_hash          text         CHECK (senha_hash IS NULL OR senha_hash LIKE '$argon2%'),
    mfa_habilitado      boolean      NOT NULL DEFAULT false,
    mfa_segredo_cifrado bytea,
    tentativas_falhas   smallint     NOT NULL DEFAULT 0 CHECK (tentativas_falhas >= 0),
    bloqueado_ate       timestamptz,
    ultimo_login_em     timestamptz,
    created_at          timestamptz  NOT NULL DEFAULT now(),
    updated_at          timestamptz  NOT NULL DEFAULT now(),
    created_by          uuid,
    updated_by          uuid,
    is_active           boolean      NOT NULL DEFAULT true,
    CONSTRAINT usuarios_tenant_id_uk UNIQUE (tenant_id, id),
    CONSTRAINT usuarios_email_uk     UNIQUE (tenant_id, email),
    CONSTRAINT usuarios_mfa_ck       CHECK (NOT mfa_habilitado OR mfa_segredo_cifrado IS NOT NULL)
);

-- -----------------------------------------------------------------------------
-- Procedimento que aplica os padrões do projeto a uma tabela
-- -----------------------------------------------------------------------------
CREATE PROCEDURE core.aplicar_padroes(
    p_tabela       regclass,
    p_multi_tenant boolean DEFAULT true,
    p_auditar      boolean DEFAULT true,
    p_grants       text    DEFAULT 'SELECT, INSERT, UPDATE'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_rel text := (SELECT relname FROM pg_class WHERE oid = p_tabela);
BEGIN
    EXECUTE format(
        'CREATE TRIGGER trg_00_colunas_auditoria BEFORE INSERT OR UPDATE ON %s
         FOR EACH ROW EXECUTE FUNCTION core.fn_colunas_auditoria(%L)',
        p_tabela, CASE WHEN p_multi_tenant THEN 'tenant' ELSE 'global' END);

    IF p_auditar THEN
        EXECUTE format(
            'CREATE TRIGGER trg_zz_audit_log AFTER INSERT OR UPDATE OR DELETE ON %s
             FOR EACH ROW EXECUTE FUNCTION core.fn_audit_log()', p_tabela);
    END IF;

    EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I FOREIGN KEY (created_by) REFERENCES core.usuarios (id)',
                   p_tabela, v_rel || '_created_by_fk');
    EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I FOREIGN KEY (updated_by) REFERENCES core.usuarios (id)',
                   p_tabela, v_rel || '_updated_by_fk');

    IF p_multi_tenant THEN
        EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', p_tabela);
        EXECUTE format(
            'CREATE POLICY isolamento_tenant ON %s
             USING (tenant_id = core.current_tenant_id())
             WITH CHECK (tenant_id = core.current_tenant_id())', p_tabela);
    END IF;

    EXECUTE format('GRANT %s ON %s TO erp_app', p_grants, p_tabela);
END
$$;

CALL core.aplicar_padroes('core.tenants', p_multi_tenant => false, p_grants => 'SELECT');
ALTER TABLE core.tenants ENABLE ROW LEVEL SECURITY;
CREATE POLICY isolamento_tenant ON core.tenants FOR SELECT USING (id = core.current_tenant_id());

CALL core.aplicar_padroes('core.usuarios');

-- Resolução do tenant no login (antes de existir app.tenant_id)
CREATE FUNCTION core.fn_resolver_tenant(p_slug text) RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, core AS $$
    SELECT id FROM core.tenants WHERE slug = lower(p_slug) AND is_active;
$$;
REVOKE ALL ON FUNCTION core.fn_resolver_tenant(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.fn_resolver_tenant(text) TO erp_app;

-- -----------------------------------------------------------------------------
-- Empresas / estabelecimentos (matriz e filiais) — emitentes de documentos fiscais
-- -----------------------------------------------------------------------------
CREATE TABLE core.empresas (
    id                   uuid         PRIMARY KEY DEFAULT core.uuid_v7(),
    tenant_id            uuid         NOT NULL REFERENCES core.tenants (id),
    matriz_id            uuid,
    razao_social         varchar(150) NOT NULL CHECK (btrim(razao_social) <> ''),
    nome_fantasia        varchar(150),
    cnpj                 char(14)     NOT NULL CHECK (core.fn_valida_cnpj(cnpj)),
    inscricao_estadual   varchar(14)  CHECK (inscricao_estadual ~ '^([0-9]{2,14}|ISENTO)$'),
    inscricao_municipal  varchar(20),
    -- CRT da NF-e: 1 Simples Nacional, 2 Simples (excesso sublimite), 3 Regime Normal, 4 MEI
    regime_tributario    smallint     NOT NULL CHECK (regime_tributario IN (1,2,3,4)),
    cnae_principal       char(7)      CHECK (cnae_principal ~ '^[0-9]{7}$'),
    logradouro           varchar(60)  NOT NULL,
    numero               varchar(60)  NOT NULL,
    complemento          varchar(60),
    bairro               varchar(60)  NOT NULL,
    codigo_municipio     core.codigo_ibge_munic NOT NULL,
    municipio            varchar(60)  NOT NULL,
    uf                   core.uf      NOT NULL CHECK (uf <> 'EX'),
    cep                  core.cep     NOT NULL,
    telefone             varchar(14)  CHECK (telefone ~ '^[0-9]{6,14}$'),
    email                citext,
    created_at           timestamptz  NOT NULL DEFAULT now(),
    updated_at           timestamptz  NOT NULL DEFAULT now(),
    created_by           uuid,
    updated_by           uuid,
    is_active            boolean      NOT NULL DEFAULT true,
    CONSTRAINT empresas_tenant_id_uk UNIQUE (tenant_id, id),
    CONSTRAINT empresas_cnpj_uk      UNIQUE (tenant_id, cnpj),
    CONSTRAINT empresas_matriz_fk    FOREIGN KEY (tenant_id, matriz_id) REFERENCES core.empresas (tenant_id, id),
    CONSTRAINT empresas_matriz_ck    CHECK (matriz_id IS DISTINCT FROM id)
);
CREATE INDEX empresas_matriz_ix ON core.empresas (tenant_id, matriz_id) WHERE matriz_id IS NOT NULL;
CALL core.aplicar_padroes('core.empresas');

-- -----------------------------------------------------------------------------
-- RBAC: permissões (catálogo global) -> papéis (por tenant) -> usuários
-- -----------------------------------------------------------------------------
CREATE TABLE core.permissoes (
    id          uuid         PRIMARY KEY DEFAULT core.uuid_v7(),
    codigo      varchar(100) NOT NULL,
    modulo      varchar(30)  NOT NULL,
    descricao   varchar(200) NOT NULL,
    created_at  timestamptz  NOT NULL DEFAULT now(),
    updated_at  timestamptz  NOT NULL DEFAULT now(),
    created_by  uuid,
    updated_by  uuid,
    is_active   boolean      NOT NULL DEFAULT true,
    CONSTRAINT permissoes_codigo_uk UNIQUE (codigo),
    -- formato: modulo.recurso.acao  (ex.: financeiro.titulo.baixar)
    CONSTRAINT permissoes_codigo_ck CHECK (codigo ~ '^[a-z_]+\.[a-z_]+\.[a-z_]+$'),
    CONSTRAINT permissoes_modulo_ck CHECK (split_part(codigo, '.', 1) = modulo)
);
CALL core.aplicar_padroes('core.permissoes', p_multi_tenant => false, p_grants => 'SELECT');

CREATE TABLE core.papeis (
    id          uuid         PRIMARY KEY DEFAULT core.uuid_v7(),
    tenant_id   uuid         NOT NULL REFERENCES core.tenants (id),
    codigo      varchar(50)  NOT NULL CHECK (codigo ~ '^[a-z0-9_]+$'),
    nome        varchar(100) NOT NULL,
    descricao   varchar(300),
    created_at  timestamptz  NOT NULL DEFAULT now(),
    updated_at  timestamptz  NOT NULL DEFAULT now(),
    created_by  uuid,
    updated_by  uuid,
    is_active   boolean      NOT NULL DEFAULT true,
    CONSTRAINT papeis_tenant_id_uk UNIQUE (tenant_id, id),
    CONSTRAINT papeis_codigo_uk    UNIQUE (tenant_id, codigo)
);
CALL core.aplicar_padroes('core.papeis');

CREATE TABLE core.papel_permissoes (
    id            uuid        PRIMARY KEY DEFAULT core.uuid_v7(),
    tenant_id     uuid        NOT NULL REFERENCES core.tenants (id),
    papel_id      uuid        NOT NULL,
    permissao_id  uuid        NOT NULL REFERENCES core.permissoes (id),
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    created_by    uuid,
    updated_by    uuid,
    is_active     boolean     NOT NULL DEFAULT true,
    CONSTRAINT papel_permissoes_uk       UNIQUE (tenant_id, papel_id, permissao_id),
    CONSTRAINT papel_permissoes_papel_fk FOREIGN KEY (tenant_id, papel_id) REFERENCES core.papeis (tenant_id, id)
);
CREATE INDEX papel_permissoes_permissao_ix ON core.papel_permissoes (permissao_id);
CALL core.aplicar_padroes('core.papel_permissoes');

-- empresa_id NULL = papel vale para todas as empresas do tenant (escopo por filial)
CREATE TABLE core.usuario_papeis (
    id          uuid        PRIMARY KEY DEFAULT core.uuid_v7(),
    tenant_id   uuid        NOT NULL REFERENCES core.tenants (id),
    usuario_id  uuid        NOT NULL,
    papel_id    uuid        NOT NULL,
    empresa_id  uuid,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    created_by  uuid,
    updated_by  uuid,
    is_active   boolean     NOT NULL DEFAULT true,
    CONSTRAINT usuario_papeis_uk         UNIQUE NULLS NOT DISTINCT (tenant_id, usuario_id, papel_id, empresa_id),
    CONSTRAINT usuario_papeis_usuario_fk FOREIGN KEY (tenant_id, usuario_id) REFERENCES core.usuarios (tenant_id, id),
    CONSTRAINT usuario_papeis_papel_fk   FOREIGN KEY (tenant_id, papel_id)   REFERENCES core.papeis (tenant_id, id),
    CONSTRAINT usuario_papeis_empresa_fk FOREIGN KEY (tenant_id, empresa_id) REFERENCES core.empresas (tenant_id, id)
);
CREATE INDEX usuario_papeis_papel_ix   ON core.usuario_papeis (tenant_id, papel_id);
CREATE INDEX usuario_papeis_empresa_ix ON core.usuario_papeis (tenant_id, empresa_id) WHERE empresa_id IS NOT NULL;
CALL core.aplicar_padroes('core.usuario_papeis');

-- Permissões efetivas do usuário corrente (para checagem na API e em funções SQL)
CREATE FUNCTION core.fn_tem_permissao(p_codigo text, p_empresa_id uuid DEFAULT NULL) RETURNS boolean
LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1
          FROM core.usuario_papeis   up
          JOIN core.papeis           pa ON pa.tenant_id = up.tenant_id AND pa.id = up.papel_id AND pa.is_active
          JOIN core.papel_permissoes pp ON pp.tenant_id = pa.tenant_id AND pp.papel_id = pa.id AND pp.is_active
          JOIN core.permissoes       pe ON pe.id = pp.permissao_id AND pe.is_active
         WHERE up.usuario_id = core.current_user_id()
           AND up.is_active
           AND pe.codigo = p_codigo
           AND (up.empresa_id IS NULL OR up.empresa_id = p_empresa_id)
    );
$$;

-- -----------------------------------------------------------------------------
-- Outbox transacional de eventos de domínio
-- -----------------------------------------------------------------------------
CREATE TABLE core.outbox_eventos (
    id            uuid         PRIMARY KEY DEFAULT core.uuid_v7(),
    tenant_id     uuid         NOT NULL REFERENCES core.tenants (id),
    agregado_tipo varchar(60)  NOT NULL,
    agregado_id   uuid         NOT NULL,
    tipo_evento   varchar(100) NOT NULL CHECK (tipo_evento ~ '^[a-z_]+\.[A-Za-z]+$'), -- ex.: vendas.PedidoFaturado
    versao        smallint     NOT NULL DEFAULT 1 CHECK (versao > 0),
    payload       jsonb        NOT NULL,
    publicado_em  timestamptz,
    tentativas    smallint     NOT NULL DEFAULT 0 CHECK (tentativas >= 0),
    ultimo_erro   text,
    created_at    timestamptz  NOT NULL DEFAULT now(),
    updated_at    timestamptz  NOT NULL DEFAULT now(),
    created_by    uuid,
    updated_by    uuid,
    is_active     boolean      NOT NULL DEFAULT true
);
CREATE INDEX outbox_eventos_pendentes_ix ON core.outbox_eventos (created_at) WHERE publicado_em IS NULL;
CREATE INDEX outbox_eventos_agregado_ix  ON core.outbox_eventos (tenant_id, agregado_tipo, agregado_id);
CALL core.aplicar_padroes('core.outbox_eventos', p_auditar => false, p_grants => 'INSERT');
