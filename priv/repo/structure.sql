--
-- PostgreSQL database dump
--


-- Dumped from database version 16.13
-- Dumped by pg_dump version 16.13

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
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
    api_key_id bigint NOT NULL,
    vault_id bigint NOT NULL
);


--
-- Name: api_keys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.api_keys (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    key_hash text NOT NULL,
    name text,
    last_used timestamp(0) without time zone,
    created_at timestamp(0) without time zone NOT NULL
);

ALTER TABLE ONLY public.api_keys FORCE ROW LEVEL SECURITY;


--
-- Name: api_keys_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.api_keys_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: api_keys_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.api_keys_id_seq OWNED BY public.api_keys.id;


--
-- Name: attachments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.attachments (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    mime_type text,
    size_bytes bigint,
    mtime double precision,
    deleted_at timestamp(0) without time zone,
    created_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    content_hash text,
    storage_key character varying(255),
    vault_id bigint NOT NULL,
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
-- Name: attachments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.attachments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: attachments_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.attachments_id_seq OWNED BY public.attachments.id;


--
-- Name: chunks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chunks (
    id bigint NOT NULL,
    note_id bigint NOT NULL,
    user_id bigint NOT NULL,
    "position" smallint NOT NULL,
    heading_path text,
    char_start integer NOT NULL,
    char_end integer NOT NULL,
    qdrant_point_id uuid NOT NULL,
    created_at timestamp(0) without time zone NOT NULL,
    vault_id bigint NOT NULL
);

ALTER TABLE ONLY public.chunks FORCE ROW LEVEL SECURITY;


--
-- Name: chunks_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.chunks_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: chunks_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.chunks_id_seq OWNED BY public.chunks.id;


--
-- Name: client_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.client_logs (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
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
-- Name: client_logs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.client_logs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: client_logs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.client_logs_id_seq OWNED BY public.client_logs.id;


--
-- Name: client_origin_stats; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.client_origin_stats (
    user_id bigint NOT NULL,
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
    id bigint NOT NULL,
    device_code character varying(255) NOT NULL,
    user_code character varying(255) NOT NULL,
    client_id character varying(255) NOT NULL,
    user_id bigint,
    vault_id bigint,
    status character varying(255) DEFAULT 'pending'::character varying NOT NULL,
    expires_at timestamp(0) without time zone NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    vault_name character varying(255),
    viewer_user_id bigint
);


--
-- Name: device_authorizations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.device_authorizations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: device_authorizations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.device_authorizations_id_seq OWNED BY public.device_authorizations.id;


--
-- Name: device_refresh_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.device_refresh_tokens (
    id bigint NOT NULL,
    token_hash character varying(255) NOT NULL,
    user_id bigint NOT NULL,
    vault_id bigint NOT NULL,
    expires_at timestamp(0) without time zone NOT NULL,
    revoked_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    family_id uuid,
    CONSTRAINT device_refresh_tokens_family_id_not_null CHECK ((family_id IS NOT NULL))
);


--
-- Name: device_refresh_tokens_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.device_refresh_tokens_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: device_refresh_tokens_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.device_refresh_tokens_id_seq OWNED BY public.device_refresh_tokens.id;


--
-- Name: email_suppressions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_suppressions (
    id bigint NOT NULL,
    email character varying(255) NOT NULL,
    reason character varying(255) NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    CONSTRAINT reason_must_be_valid CHECK (((reason)::text = ANY (ARRAY[('bounced'::character varying)::text, ('complained'::character varying)::text])))
);


--
-- Name: email_suppressions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.email_suppressions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: email_suppressions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.email_suppressions_id_seq OWNED BY public.email_suppressions.id;


--
-- Name: instance_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.instance_settings (
    id bigint NOT NULL,
    registration_mode text DEFAULT 'invite_only'::text NOT NULL,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    bootstrap_completed_at timestamp with time zone,
    CONSTRAINT singleton CHECK ((id = 1))
);


--
-- Name: instance_settings_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.instance_settings ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.instance_settings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: invites; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.invites (
    id bigint NOT NULL,
    token_hash text NOT NULL,
    created_by bigint NOT NULL,
    label text,
    max_uses bigint DEFAULT 1 NOT NULL,
    use_count bigint DEFAULT 0 NOT NULL,
    expires_at timestamp with time zone,
    revoked_at timestamp with time zone,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: invites_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.invites ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.invites_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: notes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notes (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    content_hash text,
    mtime double precision,
    deleted_at timestamp without time zone,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    embed_hash text,
    vault_id bigint NOT NULL,
    content_ciphertext bytea,
    content_nonce bytea,
    title_ciphertext bytea,
    title_nonce bytea,
    tags_ciphertext bytea,
    tags_nonce bytea,
    path_ciphertext bytea,
    path_nonce bytea,
    path_hmac bytea,
    folder_ciphertext bytea NOT NULL,
    folder_nonce bytea NOT NULL,
    folder_hmac bytea NOT NULL,
    tags_hmac bytea[] DEFAULT ARRAY[]::bytea[],
    dek_version integer DEFAULT 1 NOT NULL,
    kind text DEFAULT 'note'::text NOT NULL
);

ALTER TABLE ONLY public.notes FORCE ROW LEVEL SECURITY;


--
-- Name: notes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.notes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: notes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.notes_id_seq OWNED BY public.notes.id;


--
-- Name: oauth_authorization_codes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.oauth_authorization_codes (
    id bigint NOT NULL,
    code_hash character varying(255) NOT NULL,
    client_id uuid NOT NULL,
    user_id bigint NOT NULL,
    redirect_uri character varying(255) NOT NULL,
    code_challenge character varying(255) NOT NULL,
    code_challenge_method character varying(255) DEFAULT 'S256'::character varying NOT NULL,
    scope character varying(255),
    vault_id bigint,
    state character varying(255),
    expires_at timestamp(0) without time zone NOT NULL,
    consumed_at timestamp(0) without time zone,
    inserted_at timestamp without time zone NOT NULL
);


--
-- Name: oauth_authorization_codes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.oauth_authorization_codes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: oauth_authorization_codes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.oauth_authorization_codes_id_seq OWNED BY public.oauth_authorization_codes.id;


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
    id bigint NOT NULL,
    token_hash character varying(255) NOT NULL,
    family_id uuid NOT NULL,
    client_id uuid NOT NULL,
    user_id bigint NOT NULL,
    vault_id bigint,
    scope character varying(255),
    expires_at timestamp(0) without time zone NOT NULL,
    revoked_at timestamp(0) without time zone,
    consumed_at timestamp(0) without time zone,
    inserted_at timestamp without time zone NOT NULL,
    last_used_at timestamp without time zone,
    last_used_ip text
);


--
-- Name: oauth_refresh_tokens_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.oauth_refresh_tokens_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: oauth_refresh_tokens_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.oauth_refresh_tokens_id_seq OWNED BY public.oauth_refresh_tokens.id;


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
-- Name: onboarding_actions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.onboarding_actions (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    action character varying(255) NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE ONLY public.onboarding_actions FORCE ROW LEVEL SECURITY;


--
-- Name: onboarding_actions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.onboarding_actions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: onboarding_actions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.onboarding_actions_id_seq OWNED BY public.onboarding_actions.id;


--
-- Name: password_reset_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.password_reset_tokens (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    token_hash text NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    used_at timestamp with time zone,
    created_by bigint,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: password_reset_tokens_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.password_reset_tokens ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.password_reset_tokens_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: plans; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.plans (
    id bigint NOT NULL,
    name text NOT NULL,
    limits jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: plans_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.plans_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: plans_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.plans_id_seq OWNED BY public.plans.id;


--
-- Name: refresh_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.refresh_tokens (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    token_hash character varying(255) NOT NULL,
    family_id character varying(255) NOT NULL,
    expires_at timestamp(0) without time zone NOT NULL,
    revoked_at timestamp(0) without time zone,
    created_at timestamp(0) without time zone NOT NULL
);


--
-- Name: refresh_tokens_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.refresh_tokens_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: refresh_tokens_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.refresh_tokens_id_seq OWNED BY public.refresh_tokens.id;


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version bigint NOT NULL,
    inserted_at timestamp(0) without time zone
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
    id bigint NOT NULL,
    user_id bigint NOT NULL,
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
-- Name: subscriptions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.subscriptions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: subscriptions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.subscriptions_id_seq OWNED BY public.subscriptions.id;


--
-- Name: system_canaries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.system_canaries (
    id bigint NOT NULL,
    wrapped_dek bytea NOT NULL,
    dek_sha256 bytea NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: system_canaries_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.system_canaries_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: system_canaries_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.system_canaries_id_seq OWNED BY public.system_canaries.id;


--
-- Name: terms_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.terms_versions (
    id bigint NOT NULL,
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
-- Name: terms_versions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.terms_versions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: terms_versions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.terms_versions_id_seq OWNED BY public.terms_versions.id;


--
-- Name: usage_meters; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.usage_meters (
    user_id bigint NOT NULL,
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
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    document text NOT NULL,
    version text NOT NULL,
    accepted_at timestamp(0) without time zone DEFAULT now() NOT NULL,
    ip_address text,
    user_agent text,
    content_hash text
);

ALTER TABLE ONLY public.user_agreements FORCE ROW LEVEL SECURITY;


--
-- Name: user_agreements_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.user_agreements_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: user_agreements_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.user_agreements_id_seq OWNED BY public.user_agreements.id;


--
-- Name: user_limit_overrides; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_limit_overrides (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    key character varying(255) NOT NULL,
    value jsonb NOT NULL,
    reason character varying(255) NOT NULL,
    set_by character varying(255) NOT NULL,
    set_at timestamp(0) without time zone DEFAULT now() NOT NULL,
    expires_at timestamp(0) without time zone
);


--
-- Name: user_limit_overrides_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.user_limit_overrides_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: user_limit_overrides_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.user_limit_overrides_id_seq OWNED BY public.user_limit_overrides.id;


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id bigint NOT NULL,
    email text NOT NULL,
    display_name text,
    created_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    external_id text,
    plan_id bigint,
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
    suspended_at timestamp with time zone,
    onboarding_profile jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: users_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.users_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: users_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.users_id_seq OWNED BY public.users.id;


--
-- Name: vaults; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vaults (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
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
-- Name: vaults_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.vaults_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: vaults_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.vaults_id_seq OWNED BY public.vaults.id;


--
-- Name: api_keys id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_keys ALTER COLUMN id SET DEFAULT nextval('public.api_keys_id_seq'::regclass);


--
-- Name: attachments id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attachments ALTER COLUMN id SET DEFAULT nextval('public.attachments_id_seq'::regclass);


--
-- Name: chunks id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chunks ALTER COLUMN id SET DEFAULT nextval('public.chunks_id_seq'::regclass);


--
-- Name: client_logs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.client_logs ALTER COLUMN id SET DEFAULT nextval('public.client_logs_id_seq'::regclass);


--
-- Name: device_authorizations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_authorizations ALTER COLUMN id SET DEFAULT nextval('public.device_authorizations_id_seq'::regclass);


--
-- Name: device_refresh_tokens id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_refresh_tokens ALTER COLUMN id SET DEFAULT nextval('public.device_refresh_tokens_id_seq'::regclass);


--
-- Name: email_suppressions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_suppressions ALTER COLUMN id SET DEFAULT nextval('public.email_suppressions_id_seq'::regclass);


--
-- Name: notes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notes ALTER COLUMN id SET DEFAULT nextval('public.notes_id_seq'::regclass);


--
-- Name: oauth_authorization_codes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oauth_authorization_codes ALTER COLUMN id SET DEFAULT nextval('public.oauth_authorization_codes_id_seq'::regclass);


--
-- Name: oauth_refresh_tokens id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oauth_refresh_tokens ALTER COLUMN id SET DEFAULT nextval('public.oauth_refresh_tokens_id_seq'::regclass);


--
-- Name: oban_jobs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oban_jobs ALTER COLUMN id SET DEFAULT nextval('public.oban_jobs_id_seq'::regclass);


--
-- Name: onboarding_actions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.onboarding_actions ALTER COLUMN id SET DEFAULT nextval('public.onboarding_actions_id_seq'::regclass);


--
-- Name: plans id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plans ALTER COLUMN id SET DEFAULT nextval('public.plans_id_seq'::regclass);


--
-- Name: refresh_tokens id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.refresh_tokens ALTER COLUMN id SET DEFAULT nextval('public.refresh_tokens_id_seq'::regclass);


--
-- Name: subscriptions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscriptions ALTER COLUMN id SET DEFAULT nextval('public.subscriptions_id_seq'::regclass);


--
-- Name: system_canaries id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_canaries ALTER COLUMN id SET DEFAULT nextval('public.system_canaries_id_seq'::regclass);


--
-- Name: terms_versions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.terms_versions ALTER COLUMN id SET DEFAULT nextval('public.terms_versions_id_seq'::regclass);


--
-- Name: user_agreements id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_agreements ALTER COLUMN id SET DEFAULT nextval('public.user_agreements_id_seq'::regclass);


--
-- Name: user_limit_overrides id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_limit_overrides ALTER COLUMN id SET DEFAULT nextval('public.user_limit_overrides_id_seq'::regclass);


--
-- Name: users id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users ALTER COLUMN id SET DEFAULT nextval('public.users_id_seq'::regclass);


--
-- Name: vaults id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vaults ALTER COLUMN id SET DEFAULT nextval('public.vaults_id_seq'::regclass);


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
-- Name: notes notes_kind_shape_check; Type: CHECK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.notes
    ADD CONSTRAINT notes_kind_shape_check CHECK ((((kind = 'note'::text) AND (path_hmac IS NOT NULL) AND (content_ciphertext IS NOT NULL) AND (title_ciphertext IS NOT NULL) AND (tags_ciphertext IS NOT NULL) AND (folder_hmac IS NOT NULL)) OR ((kind = 'folder'::text) AND (path_hmac IS NULL) AND (content_ciphertext IS NULL) AND (title_ciphertext IS NULL) AND (tags_ciphertext IS NULL) AND (folder_hmac IS NOT NULL)))) NOT VALID;


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
-- Name: onboarding_actions onboarding_actions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.onboarding_actions
    ADD CONSTRAINT onboarding_actions_pkey PRIMARY KEY (id);


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
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


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
-- Name: device_authorizations_pending_user_code_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX device_authorizations_pending_user_code_index ON public.device_authorizations USING btree (user_code) WHERE ((status)::text = 'pending'::text);


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
-- Name: device_authorizations_viewer_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX device_authorizations_viewer_user_id_index ON public.device_authorizations USING btree (viewer_user_id);


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

CREATE INDEX idx_notes_embed_pending ON public.notes USING btree (embed_hash) WHERE ((deleted_at IS NULL) AND (kind = 'note'::text) AND ((embed_hash IS NULL) OR (embed_hash <> content_hash)));


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
-- Name: notes_user_vault_folder_marker; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX notes_user_vault_folder_marker ON public.notes USING btree (user_id, vault_id, folder_hmac) WHERE ((deleted_at IS NULL) AND (kind = 'folder'::text));


--
-- Name: notes_user_vault_path_v2; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX notes_user_vault_path_v2 ON public.notes USING btree (user_id, vault_id, path_hmac) WHERE ((deleted_at IS NULL) AND (kind = 'note'::text));


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
-- Name: onboarding_actions_user_id_action_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX onboarding_actions_user_id_action_index ON public.onboarding_actions USING btree (user_id, action);


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
-- Name: device_authorizations device_authorizations_viewer_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_authorizations
    ADD CONSTRAINT device_authorizations_viewer_user_id_fkey FOREIGN KEY (viewer_user_id) REFERENCES public.users(id) ON DELETE SET NULL;


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
-- Name: onboarding_actions onboarding_actions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.onboarding_actions
    ADD CONSTRAINT onboarding_actions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


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
-- Name: onboarding_actions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.onboarding_actions ENABLE ROW LEVEL SECURITY;

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
-- Name: onboarding_actions tenant_isolation_onboarding_actions; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation_onboarding_actions ON public.onboarding_actions USING (((user_id)::text = ( SELECT current_setting('app.current_tenant'::text, true) AS current_setting))) WITH CHECK (((user_id)::text = ( SELECT current_setting('app.current_tenant'::text, true) AS current_setting)));


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
-- PostgreSQL database dump complete
--


--
-- PostgreSQL database dump
--


-- Dumped from database version 16.13
-- Dumped by pg_dump version 16.13

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Data for Name: schema_migrations; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.schema_migrations (version, inserted_at) FROM stdin;
20260602000000	2026-06-05 00:07:34
20260603000000	2026-06-05 00:07:35
20260603000010	2026-06-05 00:07:35
20260604000000	2026-06-05 00:07:35
20260604010000	2026-06-05 00:07:35
20260604020000	2026-06-05 00:07:35
20260605000353	2026-06-05 00:07:35
\.


--
-- PostgreSQL database dump complete
--


