--
-- PostgreSQL database dump
--


-- Dumped from database version 18.4 (Debian 18.4-1.pgdg13+1)
-- Dumped by pg_dump version 18.4 (Debian 18.4-1.pgdg13+1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: oban_job_state; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.oban_job_state AS ENUM (
    'available',
    'suspended',
    'scheduled',
    'executing',
    'retryable',
    'completed',
    'discarded',
    'cancelled'
);


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: api_key_vaults; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.api_key_vaults (
    api_key_id uuid NOT NULL,
    vault_id uuid NOT NULL
);


--
-- Name: api_keys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.api_keys (
    id uuid DEFAULT uuidv7() NOT NULL,
    user_id uuid NOT NULL,
    key_hash text NOT NULL,
    name text,
    last_used timestamp(0) without time zone,
    created_at timestamp(0) without time zone NOT NULL
);

ALTER TABLE ONLY public.api_keys FORCE ROW LEVEL SECURITY;


--
-- Name: attachments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.attachments (
    id uuid DEFAULT uuidv7() NOT NULL,
    user_id uuid NOT NULL,
    mime_type text,
    size_bytes bigint,
    mtime double precision,
    deleted_at timestamp(0) without time zone,
    created_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    content_hash text,
    storage_key character varying(255),
    vault_id uuid NOT NULL,
    encryption_version integer DEFAULT 0 NOT NULL,
    content_nonce bytea,
    path_ciphertext bytea NOT NULL,
    path_nonce bytea NOT NULL,
    path_hmac bytea NOT NULL,
    dek_version integer DEFAULT 1 NOT NULL,
    dek_version_pending integer
);

ALTER TABLE ONLY public.attachments FORCE ROW LEVEL SECURITY;


--
-- Name: chunks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chunks (
    id uuid DEFAULT uuidv7() NOT NULL,
    note_id uuid NOT NULL,
    user_id uuid NOT NULL,
    "position" smallint NOT NULL,
    heading_path text,
    char_start integer NOT NULL,
    char_end integer NOT NULL,
    qdrant_point_id uuid NOT NULL,
    created_at timestamp(0) without time zone NOT NULL,
    vault_id uuid NOT NULL
);

ALTER TABLE ONLY public.chunks FORCE ROW LEVEL SECURITY;


--
-- Name: client_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.client_logs (
    id uuid DEFAULT uuidv7() NOT NULL,
    user_id uuid NOT NULL,
    ts timestamp(0) without time zone NOT NULL,
    level text DEFAULT 'info'::text,
    category text DEFAULT ''::text,
    message text DEFAULT ''::text,
    stack text,
    plugin_version text DEFAULT ''::text,
    platform text DEFAULT ''::text,
    created_at timestamp(0) without time zone NOT NULL
);


--
-- Name: client_origin_stats; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.client_origin_stats (
    user_id uuid NOT NULL,
    day date NOT NULL,
    fingerprint_class character varying(255) NOT NULL,
    request_count bigint DEFAULT 0 NOT NULL,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: device_authorizations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.device_authorizations (
    id uuid DEFAULT uuidv7() NOT NULL,
    device_code character varying(255) NOT NULL,
    user_code character varying(255) NOT NULL,
    client_id character varying(255) NOT NULL,
    user_id uuid,
    vault_id uuid,
    status character varying(255) DEFAULT 'pending'::character varying NOT NULL,
    expires_at timestamp(0) without time zone NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL
);


--
-- Name: device_refresh_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.device_refresh_tokens (
    id uuid DEFAULT uuidv7() NOT NULL,
    token_hash character varying(255) NOT NULL,
    user_id uuid NOT NULL,
    vault_id uuid NOT NULL,
    expires_at timestamp(0) without time zone NOT NULL,
    revoked_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    family_id uuid,
    CONSTRAINT device_refresh_tokens_family_id_not_null CHECK ((family_id IS NOT NULL))
);


--
-- Name: email_suppressions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_suppressions (
    id uuid DEFAULT uuidv7() NOT NULL,
    email character varying(255) NOT NULL,
    reason character varying(255) NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    CONSTRAINT reason_must_be_valid CHECK (((reason)::text = ANY (ARRAY[('bounced'::character varying)::text, ('complained'::character varying)::text])))
);


--
-- Name: instance_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.instance_settings (
    id uuid DEFAULT uuidv7() NOT NULL,
    registration_mode text DEFAULT 'invite_only'::text NOT NULL,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    bootstrap_completed_at timestamp with time zone
);


--
-- Name: invites; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.invites (
    id uuid DEFAULT uuidv7() NOT NULL,
    token_hash text NOT NULL,
    created_by uuid NOT NULL,
    label text,
    max_uses bigint DEFAULT 1 NOT NULL,
    use_count bigint DEFAULT 0 NOT NULL,
    expires_at timestamp with time zone,
    revoked_at timestamp with time zone,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: notes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notes (
    id uuid DEFAULT uuidv7() NOT NULL,
    user_id uuid NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    content_hash text,
    mtime double precision,
    deleted_at timestamp without time zone,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    embed_hash text,
    vault_id uuid NOT NULL,
    content_ciphertext bytea NOT NULL,
    content_nonce bytea NOT NULL,
    title_ciphertext bytea NOT NULL,
    title_nonce bytea NOT NULL,
    tags_ciphertext bytea NOT NULL,
    tags_nonce bytea NOT NULL,
    path_ciphertext bytea NOT NULL,
    path_nonce bytea NOT NULL,
    path_hmac bytea NOT NULL,
    folder_ciphertext bytea NOT NULL,
    folder_nonce bytea NOT NULL,
    folder_hmac bytea NOT NULL,
    tags_hmac bytea[] DEFAULT ARRAY[]::bytea[],
    dek_version integer DEFAULT 1 NOT NULL
);

ALTER TABLE ONLY public.notes FORCE ROW LEVEL SECURITY;


--
-- Name: oauth_authorization_codes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.oauth_authorization_codes (
    id uuid DEFAULT uuidv7() NOT NULL,
    code_hash character varying(255) NOT NULL,
    client_id uuid NOT NULL,
    user_id uuid NOT NULL,
    redirect_uri character varying(255) NOT NULL,
    code_challenge character varying(255) NOT NULL,
    code_challenge_method character varying(255) DEFAULT 'S256'::character varying NOT NULL,
    scope character varying(255),
    vault_id uuid,
    state character varying(255),
    expires_at timestamp(0) without time zone NOT NULL,
    consumed_at timestamp(0) without time zone,
    inserted_at timestamp without time zone NOT NULL
);


--
-- Name: oauth_clients; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.oauth_clients (
    client_id uuid DEFAULT gen_random_uuid() NOT NULL,
    client_secret_hash character varying(255),
    redirect_uris character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    client_name character varying(255),
    scope character varying(255),
    grant_types character varying(255)[] DEFAULT ARRAY['authorization_code'::character varying, 'refresh_token'::character varying] NOT NULL,
    response_types character varying(255)[] DEFAULT ARRAY['code'::character varying] NOT NULL,
    token_endpoint_auth_method character varying(255) DEFAULT 'none'::character varying NOT NULL,
    software_id character varying(255),
    software_version character varying(255),
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    kind character varying(255) DEFAULT 'mcp'::character varying NOT NULL,
    first_user_agent text,
    first_ip text,
    logo_uri text,
    tos_uri text,
    policy_uri text,
    CONSTRAINT oauth_clients_kind_check CHECK (((kind)::text = ANY (ARRAY[('mcp'::character varying)::text, ('obsidian'::character varying)::text])))
);


--
-- Name: oauth_refresh_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.oauth_refresh_tokens (
    id uuid DEFAULT uuidv7() NOT NULL,
    token_hash character varying(255) NOT NULL,
    family_id uuid NOT NULL,
    client_id uuid NOT NULL,
    user_id uuid NOT NULL,
    vault_id uuid,
    scope character varying(255),
    expires_at timestamp(0) without time zone NOT NULL,
    revoked_at timestamp(0) without time zone,
    consumed_at timestamp(0) without time zone,
    inserted_at timestamp without time zone NOT NULL,
    last_used_at timestamp without time zone,
    last_used_ip text
);


--
-- Name: oban_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.oban_jobs (
    id bigint NOT NULL,
    state public.oban_job_state DEFAULT 'available'::public.oban_job_state NOT NULL,
    queue text DEFAULT 'default'::text NOT NULL,
    worker text NOT NULL,
    args jsonb DEFAULT '{}'::jsonb NOT NULL,
    errors jsonb[] DEFAULT ARRAY[]::jsonb[] NOT NULL,
    attempt integer DEFAULT 0 NOT NULL,
    max_attempts integer DEFAULT 20 NOT NULL,
    inserted_at timestamp without time zone DEFAULT timezone('UTC'::text, now()) NOT NULL,
    scheduled_at timestamp without time zone DEFAULT timezone('UTC'::text, now()) NOT NULL,
    attempted_at timestamp without time zone,
    completed_at timestamp without time zone,
    attempted_by text[],
    discarded_at timestamp without time zone,
    priority integer DEFAULT 0 NOT NULL,
    tags text[] DEFAULT ARRAY[]::text[],
    meta jsonb DEFAULT '{}'::jsonb,
    cancelled_at timestamp without time zone,
    CONSTRAINT attempt_range CHECK (((attempt >= 0) AND (attempt <= max_attempts))),
    CONSTRAINT positive_max_attempts CHECK ((max_attempts > 0)),
    CONSTRAINT queue_length CHECK (((char_length(queue) > 0) AND (char_length(queue) < 128))),
    CONSTRAINT worker_length CHECK (((char_length(worker) > 0) AND (char_length(worker) < 128)))
);


--
-- Name: TABLE oban_jobs; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.oban_jobs IS '14';


--
-- Name: oban_jobs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.oban_jobs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: oban_jobs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.oban_jobs_id_seq OWNED BY public.oban_jobs.id;


--
-- Name: oban_peers; Type: TABLE; Schema: public; Owner: -
--

CREATE UNLOGGED TABLE public.oban_peers (
    name text NOT NULL,
    node text NOT NULL,
    started_at timestamp without time zone NOT NULL,
    expires_at timestamp without time zone NOT NULL
);


--
-- Name: password_reset_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.password_reset_tokens (
    id uuid DEFAULT uuidv7() NOT NULL,
    user_id uuid NOT NULL,
    token_hash text NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    used_at timestamp with time zone,
    created_by uuid,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: plans; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.plans (
    id uuid DEFAULT uuidv7() NOT NULL,
    name text NOT NULL,
    limits jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: refresh_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.refresh_tokens (
    id uuid DEFAULT uuidv7() NOT NULL,
    user_id uuid NOT NULL,
    token_hash character varying(255) NOT NULL,
    family_id character varying(255) NOT NULL,
    expires_at timestamp(0) without time zone NOT NULL,
    revoked_at timestamp(0) without time zone,
    created_at timestamp(0) without time zone NOT NULL
);


--
-- Name: storage_objects; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.storage_objects (
    storage_key text NOT NULL,
    data bytea NOT NULL,
    byte_size bigint NOT NULL,
    inserted_at timestamp without time zone NOT NULL
);


--
-- Name: subscriptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.subscriptions (
    id uuid DEFAULT uuidv7() NOT NULL,
    user_id uuid NOT NULL,
    tier character varying(255) DEFAULT 'trial'::character varying NOT NULL,
    status character varying(255) DEFAULT 'trialing'::character varying NOT NULL,
    current_period_end timestamp(0) without time zone,
    created_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    paddle_customer_id character varying(255) NOT NULL,
    paddle_subscription_id character varying(255),
    custom_data jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: system_canaries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.system_canaries (
    id uuid DEFAULT uuidv7() NOT NULL,
    wrapped_dek bytea NOT NULL,
    dek_sha256 bytea NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: terms_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.terms_versions (
    id uuid DEFAULT uuidv7() NOT NULL,
    document character varying(255) NOT NULL,
    version character varying(255) NOT NULL,
    content_hash character varying(255) NOT NULL,
    material boolean DEFAULT true NOT NULL,
    effective_date date,
    changelog text,
    inserted_at timestamp without time zone NOT NULL,
    CONSTRAINT document_must_be_valid CHECK (((document)::text = ANY (ARRAY[('terms_of_service'::character varying)::text, ('privacy_policy'::character varying)::text])))
);


--
-- Name: usage_meters; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.usage_meters (
    user_id uuid NOT NULL,
    lifetime_embed_tokens bigint DEFAULT 0 NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    last_active_at timestamp without time zone,
    active_conversation_started_at timestamp without time zone,
    active_conversation_query_count integer DEFAULT 0 NOT NULL,
    conversations_today integer DEFAULT 0 NOT NULL,
    conversations_day_key date,
    queries_today integer DEFAULT 0 NOT NULL,
    queries_day_key date,
    notes_count bigint DEFAULT 0 NOT NULL
);


--
-- Name: user_agreements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_agreements (
    id uuid DEFAULT uuidv7() NOT NULL,
    user_id uuid NOT NULL,
    document text NOT NULL,
    version text NOT NULL,
    accepted_at timestamp(0) without time zone DEFAULT now() NOT NULL,
    ip_address text,
    user_agent text,
    content_hash text
);

ALTER TABLE ONLY public.user_agreements FORCE ROW LEVEL SECURITY;


--
-- Name: user_limit_overrides; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_limit_overrides (
    id uuid DEFAULT uuidv7() NOT NULL,
    user_id uuid NOT NULL,
    key character varying(255) NOT NULL,
    value jsonb NOT NULL,
    reason character varying(255) NOT NULL,
    set_by character varying(255) NOT NULL,
    set_at timestamp(0) without time zone DEFAULT now() NOT NULL,
    expires_at timestamp(0) without time zone
);


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id uuid DEFAULT uuidv7() NOT NULL,
    email text NOT NULL,
    display_name text,
    created_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    external_id text,
    plan_id uuid,
    password_hash character varying(255),
    role character varying(255) DEFAULT 'member'::character varying NOT NULL,
    encrypted_dek bytea,
    dek_version integer DEFAULT 1 NOT NULL,
    key_provider character varying(255) DEFAULT 'local'::character varying NOT NULL,
    dek_rotation_locked_at timestamp without time zone,
    normalized_email text,
    phone_verified_at timestamp without time zone,
    deleted_at timestamp without time zone,
    inactivity_warning_60_at timestamp without time zone,
    inactivity_warning_80_at timestamp without time zone,
    suspended_at timestamp with time zone
);


--
-- Name: vaults; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vaults (
    id uuid DEFAULT uuidv7() NOT NULL,
    user_id uuid NOT NULL,
    description text,
    slug text NOT NULL,
    client_id text,
    is_default boolean DEFAULT false NOT NULL,
    deleted_at timestamp(0) without time zone,
    created_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    name_ciphertext bytea NOT NULL,
    name_nonce bytea NOT NULL,
    name_hmac bytea NOT NULL,
    dek_version integer DEFAULT 1 NOT NULL
);

ALTER TABLE ONLY public.vaults FORCE ROW LEVEL SECURITY;


--
-- Name: oban_jobs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oban_jobs ALTER COLUMN id SET DEFAULT nextval('public.oban_jobs_id_seq'::regclass);


--
-- Name: api_key_vaults api_key_vaults_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_key_vaults
    ADD CONSTRAINT api_key_vaults_pkey PRIMARY KEY (api_key_id, vault_id);


--
-- Name: api_keys api_keys_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_keys
    ADD CONSTRAINT api_keys_pkey PRIMARY KEY (id);


--
-- Name: attachments attachments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attachments
    ADD CONSTRAINT attachments_pkey PRIMARY KEY (id);


--
-- Name: chunks chunks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chunks
    ADD CONSTRAINT chunks_pkey PRIMARY KEY (id);


--
-- Name: client_logs client_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.client_logs
    ADD CONSTRAINT client_logs_pkey PRIMARY KEY (id);


--
-- Name: client_origin_stats client_origin_stats_user_id_day_fingerprint_class_index; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.client_origin_stats
    ADD CONSTRAINT client_origin_stats_user_id_day_fingerprint_class_index PRIMARY KEY (user_id, day, fingerprint_class);


--
-- Name: device_authorizations device_authorizations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_authorizations
    ADD CONSTRAINT device_authorizations_pkey PRIMARY KEY (id);


--
-- Name: device_refresh_tokens device_refresh_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_refresh_tokens
    ADD CONSTRAINT device_refresh_tokens_pkey PRIMARY KEY (id);


--
-- Name: email_suppressions email_suppressions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_suppressions
    ADD CONSTRAINT email_suppressions_pkey PRIMARY KEY (id);


--
-- Name: instance_settings instance_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.instance_settings
    ADD CONSTRAINT instance_settings_pkey PRIMARY KEY (id);


--
-- Name: invites invites_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invites
    ADD CONSTRAINT invites_pkey PRIMARY KEY (id);


--
-- Name: oban_jobs non_negative_priority; Type: CHECK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.oban_jobs
    ADD CONSTRAINT non_negative_priority CHECK ((priority >= 0)) NOT VALID;


--
-- Name: notes notes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notes
    ADD CONSTRAINT notes_pkey PRIMARY KEY (id);


--
-- Name: oauth_authorization_codes oauth_authorization_codes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oauth_authorization_codes
    ADD CONSTRAINT oauth_authorization_codes_pkey PRIMARY KEY (id);


--
-- Name: oauth_clients oauth_clients_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oauth_clients
    ADD CONSTRAINT oauth_clients_pkey PRIMARY KEY (client_id);


--
-- Name: oauth_refresh_tokens oauth_refresh_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oauth_refresh_tokens
    ADD CONSTRAINT oauth_refresh_tokens_pkey PRIMARY KEY (id);


--
-- Name: oban_jobs oban_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oban_jobs
    ADD CONSTRAINT oban_jobs_pkey PRIMARY KEY (id);


--
-- Name: oban_peers oban_peers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oban_peers
    ADD CONSTRAINT oban_peers_pkey PRIMARY KEY (name);


--
-- Name: password_reset_tokens password_reset_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.password_reset_tokens
    ADD CONSTRAINT password_reset_tokens_pkey PRIMARY KEY (id);


--
-- Name: plans plans_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plans
    ADD CONSTRAINT plans_pkey PRIMARY KEY (id);


--
-- Name: refresh_tokens refresh_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.refresh_tokens
    ADD CONSTRAINT refresh_tokens_pkey PRIMARY KEY (id);


--
-- Name: storage_objects storage_objects_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.storage_objects
    ADD CONSTRAINT storage_objects_pkey PRIMARY KEY (storage_key);


--
-- Name: subscriptions subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT subscriptions_pkey PRIMARY KEY (id);


--
-- Name: system_canaries system_canaries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_canaries
    ADD CONSTRAINT system_canaries_pkey PRIMARY KEY (id);


--
-- Name: terms_versions terms_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.terms_versions
    ADD CONSTRAINT terms_versions_pkey PRIMARY KEY (id);


--
-- Name: usage_meters usage_meters_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usage_meters
    ADD CONSTRAINT usage_meters_pkey PRIMARY KEY (user_id);


--
-- Name: user_agreements user_agreements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_agreements
    ADD CONSTRAINT user_agreements_pkey PRIMARY KEY (id);


--
-- Name: user_limit_overrides user_limit_overrides_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_limit_overrides
    ADD CONSTRAINT user_limit_overrides_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: vaults vaults_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vaults
    ADD CONSTRAINT vaults_pkey PRIMARY KEY (id);


--
-- Name: api_key_vaults_vault_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX api_key_vaults_vault_id_index ON public.api_key_vaults USING btree (vault_id);


--
-- Name: api_keys_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX api_keys_user_id_index ON public.api_keys USING btree (user_id);


--
-- Name: attachments_user_id_vault_id_path_hmac_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX attachments_user_id_vault_id_path_hmac_index ON public.attachments USING btree (user_id, vault_id, path_hmac) WHERE (deleted_at IS NULL);


--
-- Name: attachments_vault_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX attachments_vault_id_index ON public.attachments USING btree (vault_id);


--
-- Name: chunks_note_id_position_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX chunks_note_id_position_index ON public.chunks USING btree (note_id, "position");


--
-- Name: chunks_vault_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX chunks_vault_id_index ON public.chunks USING btree (vault_id);


--
-- Name: client_origin_stats_day_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX client_origin_stats_day_index ON public.client_origin_stats USING btree (day);


--
-- Name: device_authorizations_device_code_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX device_authorizations_device_code_index ON public.device_authorizations USING btree (device_code);


--
-- Name: device_authorizations_expires_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX device_authorizations_expires_at_index ON public.device_authorizations USING btree (expires_at);


--
-- Name: device_authorizations_user_code_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX device_authorizations_user_code_index ON public.device_authorizations USING btree (user_code);


--
-- Name: device_authorizations_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX device_authorizations_user_id_index ON public.device_authorizations USING btree (user_id);


--
-- Name: device_authorizations_vault_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX device_authorizations_vault_id_index ON public.device_authorizations USING btree (vault_id);


--
-- Name: device_refresh_tokens_family_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX device_refresh_tokens_family_id_index ON public.device_refresh_tokens USING btree (family_id);


--
-- Name: device_refresh_tokens_token_hash_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX device_refresh_tokens_token_hash_index ON public.device_refresh_tokens USING btree (token_hash);


--
-- Name: device_refresh_tokens_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX device_refresh_tokens_user_id_index ON public.device_refresh_tokens USING btree (user_id);


--
-- Name: device_refresh_tokens_vault_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX device_refresh_tokens_vault_id_index ON public.device_refresh_tokens USING btree (vault_id);


--
-- Name: email_suppressions_email_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX email_suppressions_email_index ON public.email_suppressions USING btree (email);


--
-- Name: idx_api_keys_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_api_keys_hash ON public.api_keys USING btree (key_hash);


--
-- Name: idx_attachments_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_attachments_user ON public.attachments USING btree (user_id);


--
-- Name: idx_chunks_note; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_chunks_note ON public.chunks USING btree (note_id);


--
-- Name: idx_chunks_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_chunks_user ON public.chunks USING btree (user_id);


--
-- Name: idx_client_logs_user_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_client_logs_user_created ON public.client_logs USING btree (user_id, created_at);


--
-- Name: idx_client_logs_user_level; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_client_logs_user_level ON public.client_logs USING btree (user_id, level);


--
-- Name: idx_notes_embed_pending; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_notes_embed_pending ON public.notes USING btree (embed_hash) WHERE ((deleted_at IS NULL) AND ((embed_hash IS NULL) OR (embed_hash <> content_hash)));


--
-- Name: idx_notes_user_deleted; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_notes_user_deleted ON public.notes USING btree (user_id, deleted_at) WHERE (deleted_at IS NOT NULL);


--
-- Name: idx_notes_user_updated; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_notes_user_updated ON public.notes USING btree (user_id, updated_at);


--
-- Name: idx_oauth_refresh_tokens_user_client_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_oauth_refresh_tokens_user_client_active ON public.oauth_refresh_tokens USING btree (user_id, client_id) WHERE ((revoked_at IS NULL) AND (consumed_at IS NULL));


--
-- Name: invites_created_by_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX invites_created_by_index ON public.invites USING btree (created_by);


--
-- Name: invites_token_hash_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX invites_token_hash_index ON public.invites USING btree (token_hash);


--
-- Name: notes_tags_hmac_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX notes_tags_hmac_index ON public.notes USING gin (tags_hmac);


--
-- Name: notes_user_id_vault_id_folder_hmac_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX notes_user_id_vault_id_folder_hmac_index ON public.notes USING btree (user_id, vault_id, folder_hmac);


--
-- Name: notes_user_id_vault_id_path_hmac_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX notes_user_id_vault_id_path_hmac_index ON public.notes USING btree (user_id, vault_id, path_hmac) WHERE (deleted_at IS NULL);


--
-- Name: notes_vault_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX notes_vault_id_index ON public.notes USING btree (vault_id);


--
-- Name: oauth_authorization_codes_client_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oauth_authorization_codes_client_id_index ON public.oauth_authorization_codes USING btree (client_id);


--
-- Name: oauth_authorization_codes_code_hash_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX oauth_authorization_codes_code_hash_index ON public.oauth_authorization_codes USING btree (code_hash);


--
-- Name: oauth_authorization_codes_expires_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oauth_authorization_codes_expires_at_index ON public.oauth_authorization_codes USING btree (expires_at);


--
-- Name: oauth_authorization_codes_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oauth_authorization_codes_user_id_index ON public.oauth_authorization_codes USING btree (user_id);


--
-- Name: oauth_authorization_codes_vault_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oauth_authorization_codes_vault_id_index ON public.oauth_authorization_codes USING btree (vault_id);


--
-- Name: oauth_refresh_tokens_expires_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oauth_refresh_tokens_expires_at_index ON public.oauth_refresh_tokens USING btree (expires_at);


--
-- Name: oauth_refresh_tokens_family_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oauth_refresh_tokens_family_id_index ON public.oauth_refresh_tokens USING btree (family_id);


--
-- Name: oauth_refresh_tokens_token_hash_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX oauth_refresh_tokens_token_hash_index ON public.oauth_refresh_tokens USING btree (token_hash);


--
-- Name: oauth_refresh_tokens_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oauth_refresh_tokens_user_id_index ON public.oauth_refresh_tokens USING btree (user_id);


--
-- Name: oauth_refresh_tokens_vault_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oauth_refresh_tokens_vault_id_index ON public.oauth_refresh_tokens USING btree (vault_id);


--
-- Name: oban_jobs_args_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oban_jobs_args_index ON public.oban_jobs USING gin (args);


--
-- Name: oban_jobs_meta_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oban_jobs_meta_index ON public.oban_jobs USING gin (meta);


--
-- Name: oban_jobs_state_cancelled_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oban_jobs_state_cancelled_at_index ON public.oban_jobs USING btree (state, cancelled_at);


--
-- Name: oban_jobs_state_discarded_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oban_jobs_state_discarded_at_index ON public.oban_jobs USING btree (state, discarded_at);


--
-- Name: oban_jobs_state_queue_priority_scheduled_at_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oban_jobs_state_queue_priority_scheduled_at_id_index ON public.oban_jobs USING btree (state, queue, priority, scheduled_at, id);


--
-- Name: password_reset_tokens_created_by_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX password_reset_tokens_created_by_index ON public.password_reset_tokens USING btree (created_by);


--
-- Name: password_reset_tokens_token_hash_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX password_reset_tokens_token_hash_index ON public.password_reset_tokens USING btree (token_hash);


--
-- Name: password_reset_tokens_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX password_reset_tokens_user_id_index ON public.password_reset_tokens USING btree (user_id);


--
-- Name: plans_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX plans_name_index ON public.plans USING btree (name);


--
-- Name: refresh_tokens_family_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX refresh_tokens_family_id_index ON public.refresh_tokens USING btree (family_id);


--
-- Name: refresh_tokens_token_hash_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX refresh_tokens_token_hash_index ON public.refresh_tokens USING btree (token_hash);


--
-- Name: refresh_tokens_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX refresh_tokens_user_id_index ON public.refresh_tokens USING btree (user_id);


--
-- Name: subscriptions_paddle_customer_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX subscriptions_paddle_customer_id_index ON public.subscriptions USING btree (paddle_customer_id);


--
-- Name: subscriptions_paddle_subscription_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX subscriptions_paddle_subscription_id_index ON public.subscriptions USING btree (paddle_subscription_id);


--
-- Name: subscriptions_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX subscriptions_user_id_index ON public.subscriptions USING btree (user_id);


--
-- Name: system_canaries_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX system_canaries_inserted_at_index ON public.system_canaries USING btree (inserted_at);


--
-- Name: terms_versions_document_version_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX terms_versions_document_version_index ON public.terms_versions USING btree (document, version);


--
-- Name: usage_meters_last_active_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX usage_meters_last_active_at_index ON public.usage_meters USING btree (last_active_at);


--
-- Name: user_agreements_user_document_version_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX user_agreements_user_document_version_unique ON public.user_agreements USING btree (user_id, document, version);


--
-- Name: user_agreements_user_id_document_accepted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_agreements_user_id_document_accepted_at_index ON public.user_agreements USING btree (user_id, document, accepted_at);


--
-- Name: user_limit_overrides_expires_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_limit_overrides_expires_at_index ON public.user_limit_overrides USING btree (expires_at) WHERE (expires_at IS NOT NULL);


--
-- Name: user_limit_overrides_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_limit_overrides_user_id_index ON public.user_limit_overrides USING btree (user_id);


--
-- Name: user_limit_overrides_user_id_key_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX user_limit_overrides_user_id_key_index ON public.user_limit_overrides USING btree (user_id, key);


--
-- Name: users_clerk_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX users_clerk_id_index ON public.users USING btree (external_id) WHERE (external_id IS NOT NULL);


--
-- Name: users_deleted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX users_deleted_at_index ON public.users USING btree (deleted_at);


--
-- Name: users_email_lower_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX users_email_lower_index ON public.users USING btree (lower(email));


--
-- Name: users_normalized_email_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX users_normalized_email_index ON public.users USING btree (normalized_email);


--
-- Name: users_plan_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX users_plan_id_index ON public.users USING btree (plan_id);


--
-- Name: vaults_user_id_client_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX vaults_user_id_client_id_index ON public.vaults USING btree (user_id, client_id) WHERE ((client_id IS NOT NULL) AND (deleted_at IS NULL));


--
-- Name: vaults_user_id_default_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX vaults_user_id_default_index ON public.vaults USING btree (user_id) WHERE ((is_default = true) AND (deleted_at IS NULL));


--
-- Name: vaults_user_id_name_hmac_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vaults_user_id_name_hmac_index ON public.vaults USING btree (user_id, name_hmac);


--
-- Name: vaults_user_id_slug_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX vaults_user_id_slug_index ON public.vaults USING btree (user_id, slug) WHERE (deleted_at IS NULL);


--
-- Name: api_key_vaults api_key_vaults_api_key_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_key_vaults
    ADD CONSTRAINT api_key_vaults_api_key_id_fkey FOREIGN KEY (api_key_id) REFERENCES public.api_keys(id) ON DELETE CASCADE;


--
-- Name: api_key_vaults api_key_vaults_vault_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_key_vaults
    ADD CONSTRAINT api_key_vaults_vault_id_fkey FOREIGN KEY (vault_id) REFERENCES public.vaults(id) ON DELETE CASCADE;


--
-- Name: api_keys api_keys_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_keys
    ADD CONSTRAINT api_keys_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: attachments attachments_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attachments
    ADD CONSTRAINT attachments_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: attachments attachments_vault_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attachments
    ADD CONSTRAINT attachments_vault_id_fkey FOREIGN KEY (vault_id) REFERENCES public.vaults(id) ON DELETE CASCADE;


--
-- Name: chunks chunks_note_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chunks
    ADD CONSTRAINT chunks_note_id_fkey FOREIGN KEY (note_id) REFERENCES public.notes(id) ON DELETE CASCADE;


--
-- Name: chunks chunks_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chunks
    ADD CONSTRAINT chunks_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: chunks chunks_vault_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chunks
    ADD CONSTRAINT chunks_vault_id_fkey FOREIGN KEY (vault_id) REFERENCES public.vaults(id) ON DELETE CASCADE;


--
-- Name: client_logs client_logs_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.client_logs
    ADD CONSTRAINT client_logs_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: client_origin_stats client_origin_stats_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.client_origin_stats
    ADD CONSTRAINT client_origin_stats_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: device_authorizations device_authorizations_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_authorizations
    ADD CONSTRAINT device_authorizations_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: device_authorizations device_authorizations_vault_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_authorizations
    ADD CONSTRAINT device_authorizations_vault_id_fkey FOREIGN KEY (vault_id) REFERENCES public.vaults(id) ON DELETE CASCADE;


--
-- Name: device_refresh_tokens device_refresh_tokens_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_refresh_tokens
    ADD CONSTRAINT device_refresh_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: device_refresh_tokens device_refresh_tokens_vault_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_refresh_tokens
    ADD CONSTRAINT device_refresh_tokens_vault_id_fkey FOREIGN KEY (vault_id) REFERENCES public.vaults(id) ON DELETE CASCADE;


--
-- Name: invites invites_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invites
    ADD CONSTRAINT invites_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: notes notes_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notes
    ADD CONSTRAINT notes_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: notes notes_vault_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notes
    ADD CONSTRAINT notes_vault_id_fkey FOREIGN KEY (vault_id) REFERENCES public.vaults(id) ON DELETE CASCADE;


--
-- Name: oauth_authorization_codes oauth_authorization_codes_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oauth_authorization_codes
    ADD CONSTRAINT oauth_authorization_codes_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: oauth_authorization_codes oauth_authorization_codes_vault_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oauth_authorization_codes
    ADD CONSTRAINT oauth_authorization_codes_vault_id_fkey FOREIGN KEY (vault_id) REFERENCES public.vaults(id) ON DELETE CASCADE;


--
-- Name: oauth_refresh_tokens oauth_refresh_tokens_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oauth_refresh_tokens
    ADD CONSTRAINT oauth_refresh_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: oauth_refresh_tokens oauth_refresh_tokens_vault_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oauth_refresh_tokens
    ADD CONSTRAINT oauth_refresh_tokens_vault_id_fkey FOREIGN KEY (vault_id) REFERENCES public.vaults(id) ON DELETE CASCADE;


--
-- Name: password_reset_tokens password_reset_tokens_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.password_reset_tokens
    ADD CONSTRAINT password_reset_tokens_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: password_reset_tokens password_reset_tokens_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.password_reset_tokens
    ADD CONSTRAINT password_reset_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: refresh_tokens refresh_tokens_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.refresh_tokens
    ADD CONSTRAINT refresh_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: subscriptions subscriptions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT subscriptions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: usage_meters usage_meters_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usage_meters
    ADD CONSTRAINT usage_meters_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: user_agreements user_agreements_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_agreements
    ADD CONSTRAINT user_agreements_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: user_limit_overrides user_limit_overrides_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_limit_overrides
    ADD CONSTRAINT user_limit_overrides_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: users users_plan_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_plan_id_fkey FOREIGN KEY (plan_id) REFERENCES public.plans(id);


--
-- Name: vaults vaults_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vaults
    ADD CONSTRAINT vaults_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: api_keys; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.api_keys ENABLE ROW LEVEL SECURITY;

--
-- Name: attachments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.attachments ENABLE ROW LEVEL SECURITY;

--
-- Name: chunks; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.chunks ENABLE ROW LEVEL SECURITY;

--
-- Name: notes; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.notes ENABLE ROW LEVEL SECURITY;

--
-- Name: api_keys tenant_isolation_api_keys; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation_api_keys ON public.api_keys USING (((user_id)::text = ( SELECT current_setting('app.current_tenant'::text, true) AS current_setting))) WITH CHECK (((user_id)::text = ( SELECT current_setting('app.current_tenant'::text, true) AS current_setting)));


--
-- Name: attachments tenant_isolation_attachments; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation_attachments ON public.attachments USING (((user_id)::text = ( SELECT current_setting('app.current_tenant'::text, true) AS current_setting))) WITH CHECK (((user_id)::text = ( SELECT current_setting('app.current_tenant'::text, true) AS current_setting)));


--
-- Name: chunks tenant_isolation_chunks; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation_chunks ON public.chunks USING (((user_id)::text = ( SELECT current_setting('app.current_tenant'::text, true) AS current_setting))) WITH CHECK (((user_id)::text = ( SELECT current_setting('app.current_tenant'::text, true) AS current_setting)));


--
-- Name: notes tenant_isolation_notes; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation_notes ON public.notes USING (((user_id)::text = ( SELECT current_setting('app.current_tenant'::text, true) AS current_setting))) WITH CHECK (((user_id)::text = ( SELECT current_setting('app.current_tenant'::text, true) AS current_setting)));


--
-- Name: user_agreements tenant_isolation_user_agreements; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation_user_agreements ON public.user_agreements USING (((user_id)::text = ( SELECT current_setting('app.current_tenant'::text, true) AS current_setting))) WITH CHECK (((user_id)::text = ( SELECT current_setting('app.current_tenant'::text, true) AS current_setting)));


--
-- Name: vaults tenant_isolation_vaults; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation_vaults ON public.vaults USING (((user_id)::text = ( SELECT current_setting('app.current_tenant'::text, true) AS current_setting))) WITH CHECK (((user_id)::text = ( SELECT current_setting('app.current_tenant'::text, true) AS current_setting)));


--
-- Name: user_agreements; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.user_agreements ENABLE ROW LEVEL SECURITY;

--
-- Name: vaults; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.vaults ENABLE ROW LEVEL SECURITY;

--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA public TO engram_app;


--
-- Name: TABLE api_key_vaults; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.api_key_vaults TO engram_app;


--
-- Name: TABLE api_keys; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.api_keys TO engram_app;


--
-- Name: TABLE attachments; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.attachments TO engram_app;


--
-- Name: TABLE chunks; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.chunks TO engram_app;


--
-- Name: TABLE client_logs; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.client_logs TO engram_app;


--
-- Name: TABLE client_origin_stats; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.client_origin_stats TO engram_app;


--
-- Name: TABLE device_authorizations; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.device_authorizations TO engram_app;


--
-- Name: TABLE device_refresh_tokens; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.device_refresh_tokens TO engram_app;


--
-- Name: TABLE email_suppressions; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.email_suppressions TO engram_app;


--
-- Name: TABLE instance_settings; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.instance_settings TO engram_app;


--
-- Name: TABLE invites; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.invites TO engram_app;


--
-- Name: TABLE notes; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.notes TO engram_app;


--
-- Name: TABLE oauth_authorization_codes; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.oauth_authorization_codes TO engram_app;


--
-- Name: TABLE oauth_clients; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.oauth_clients TO engram_app;


--
-- Name: TABLE oauth_refresh_tokens; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.oauth_refresh_tokens TO engram_app;


--
-- Name: TABLE oban_jobs; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.oban_jobs TO engram_app;


--
-- Name: SEQUENCE oban_jobs_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.oban_jobs_id_seq TO engram_app;


--
-- Name: TABLE oban_peers; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.oban_peers TO engram_app;


--
-- Name: TABLE password_reset_tokens; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.password_reset_tokens TO engram_app;


--
-- Name: TABLE plans; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.plans TO engram_app;


--
-- Name: TABLE refresh_tokens; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.refresh_tokens TO engram_app;


--
-- Name: TABLE storage_objects; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.storage_objects TO engram_app;


--
-- Name: TABLE subscriptions; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.subscriptions TO engram_app;


--
-- Name: TABLE system_canaries; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.system_canaries TO engram_app;


--
-- Name: TABLE terms_versions; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.terms_versions TO engram_app;


--
-- Name: TABLE usage_meters; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.usage_meters TO engram_app;


--
-- Name: TABLE user_agreements; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.user_agreements TO engram_app;


--
-- Name: TABLE user_limit_overrides; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.user_limit_overrides TO engram_app;


--
-- Name: TABLE users; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.users TO engram_app;


--
-- Name: TABLE vaults; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.vaults TO engram_app;


--
-- PostgreSQL database dump complete
--


