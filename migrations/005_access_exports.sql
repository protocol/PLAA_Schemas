SET ROLE plaa_owner;
CREATE FUNCTION plaa.post_confirmed_entry(q jsonb) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,plaa,ingest,pg_temp AS $$
DECLARE m bigint; id bigint; o plaa.plaa_ledger_entry; n numeric;
BEGIN
 IF q->>'policy_version' IS DISTINCT FROM 'source-confirmed-v1' OR nullif(q->>'reason','') IS NULL THEN RAISE EXCEPTION 'confirmed source and reason required'; END IF;
 m=ingest.claim(q,'confirmed_entry'); SELECT entry_id INTO id FROM plaa.plaa_ledger_entry WHERE manifest_id=m; IF FOUND THEN RETURN id; END IF;
 n=plaa.exact((q->>'amount')::numeric,20,8);
 IF q->>'entry_type'='reversal' THEN
 SELECT * INTO STRICT o FROM plaa.plaa_ledger_entry WHERE entry_id=(q->>'original')::bigint FOR UPDATE;
 IF o.settlement_batch_id IS NOT NULL THEN RAISE EXCEPTION 'use atomic settlement correction'; END IF;
 INSERT INTO plaa.plaa_ledger_entry(aa_id,round_id,entry_type,amount,effective_at,source_ref,reverses_entry_id,note,created_by,manifest_id)
 VALUES((q->>'aa_id')::bigint,o.round_id,'reversal',n,o.effective_at,'manifest:'||m,o.entry_id,q->>'reason',q->>'actor',m) RETURNING entry_id INTO id;
 ELSE
 IF q->>'entry_type' NOT IN ('adjustment','redemption') THEN RAISE EXCEPTION 'only source-confirmed adjustment/redemption'; END IF;
 INSERT INTO plaa.plaa_ledger_entry(aa_id,round_id,entry_type,amount,effective_at,source_ref,note,created_by,manifest_id)
 VALUES((q->>'aa_id')::bigint,(q->>'round')::bigint,(q->>'entry_type')::plaa.plaa_entry_type,n,(q->>'effective_at')::timestamptz,'manifest:'||m,q->>'reason',q->>'actor',m) RETURNING entry_id INTO id;
 END IF; RETURN id;
END $$;

-- Protected binding keyed by actual backend and actual transaction, not user-set GUCs.
CREATE TABLE plaa.request_context (
 backend_pid int NOT NULL, transaction_id bigint NOT NULL,
 aa_id bigint NOT NULL REFERENCES plaa.member, directory_subject text NOT NULL,
 request_id text NOT NULL CHECK(btrim(request_id)<>''), bound_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 PRIMARY KEY(backend_pid,transaction_id)
);
CREATE FUNCTION plaa.bind_directory(subject text,request text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,plaa,pg_temp AS $$
DECLARE id bigint;
BEGIN
 SELECT i.aa_id INTO STRICT id FROM plaa.member_identity i JOIN plaa.member m USING(aa_id)
 WHERE i.id_type='directory_uid' AND i.id_value=subject AND i.verified AND daterange(i.valid_from,i.valid_to,'[)') @> (clock_timestamp() AT TIME ZONE 'UTC')::date AND m.status='active';
 DELETE FROM plaa.request_context WHERE backend_pid=pg_backend_pid() AND transaction_id<>txid_current();
 INSERT INTO plaa.request_context(backend_pid,transaction_id,aa_id,directory_subject,request_id) VALUES(pg_backend_pid(),txid_current(),id,subject,request);
END $$;
CREATE FUNCTION plaa.current_member() RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,plaa,pg_temp AS $$
 SELECT aa_id FROM plaa.request_context WHERE backend_pid=pg_backend_pid() AND transaction_id=txid_current();
$$;

-- All member-grain and sensitive landing/audit paths force RLS, including owner paths.
-- The non-login migration owner has an explicit policy for narrow definer operations.
DO $$ DECLARE r record; BEGIN
 FOR r IN SELECT schemaname,tablename FROM pg_tables WHERE schemaname IN ('plaa','ingest') LOOP
 EXECUTE format('ALTER TABLE %I.%I ENABLE ROW LEVEL SECURITY',r.schemaname,r.tablename);
 EXECUTE format('ALTER TABLE %I.%I FORCE ROW LEVEL SECURITY',r.schemaname,r.tablename);
 EXECUTE format('CREATE POLICY owner_access ON %I.%I TO plaa_owner USING(true) WITH CHECK(true)',r.schemaname,r.tablename);
 END LOOP;
 FOR r IN SELECT unnest(ARRAY['member','member_identity','activity_submission','point_event','plaa_ledger_entry','buyback_bid']) AS name LOOP
 EXECUTE format('CREATE POLICY self_read ON plaa.%I FOR SELECT TO plaa_member_reader USING(aa_id=plaa.current_member())',r.name);
 END LOOP;
 FOR r IN SELECT unnest(ARRAY['region','category','activity','activity_point_value','round','round_activity','round_region','round_category_allocation']) AS name LOOP
 EXECUTE format('CREATE POLICY catalog_read ON plaa.%I FOR SELECT TO plaa_member_reader USING(true)',r.name);
 END LOOP;
END $$;

-- Candidate contracts are records for review, NOT a runnable privacy release engine.
CREATE TABLE export.release_contract (
 contract_version text PRIMARY KEY, grain text NOT NULL, k int NOT NULL CHECK(k>=5),
 distinct_contributor_definition text NOT NULL, complementary_suppression text NOT NULL,
 rounding_policy text NOT NULL, differencing_suite text NOT NULL, utility_threshold text NOT NULL,
 product_approval text, infra_approval text, status text NOT NULL CHECK(status='pending'),
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE export.round_summary(round_number int PRIMARY KEY,plaa_pool numeric(20,8),total_points numeric(14,2),participants bigint CHECK(participants>=5),regions_count int,activities_live int);
CREATE TABLE export.round_category_metrics(round_number int,category_code text,points numeric(14,2),plaa_distributed numeric(20,8),distinct_contributors bigint CHECK(distinct_contributors>=5),PRIMARY KEY(round_number,category_code));
CREATE TABLE export.activity_engagement(round_number int,activity_code text,submission_count bigint,acceptance_rate numeric(7,6),distinct_participants bigint CHECK(distinct_participants>=5),PRIMARY KEY(round_number,activity_code));
CREATE TABLE export.buyback_bid_summary(auction_number int PRIMARY KEY,bid_count bigint,total_rights numeric(20,8),total_source_amount_usd numeric(20,8),distinct_bidders bigint CHECK(distinct_bidders>=5));
CREATE TABLE export.trust_holdings(month date,asset_code text,quantity numeric(24,8),unit text,PRIMARY KEY(month,asset_code));
CREATE TABLE export.program_growth(month date PRIMARY KEY,cumulative_onboarded bigint,active_participants bigint,retention_rate numeric(7,6));
CREATE TABLE export.trust_valuation(month date PRIMARY KEY,nav_usd_per_plaa numeric(20,8),trust_value_usd numeric(24,8));
CREATE TRIGGER audit_write AFTER INSERT OR UPDATE OR DELETE ON export.release_contract FOR EACH ROW EXECUTE FUNCTION plaa.audit_write();
CREATE TRIGGER immutable BEFORE UPDATE OR DELETE OR TRUNCATE ON export.release_contract FOR EACH STATEMENT EXECUTE FUNCTION plaa.immutable();
CREATE FUNCTION export.build_release(contract_version text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,export,pg_temp AS $$
BEGIN RAISE EXCEPTION 'no approved executable release contract; reviewed contract-specific migration required' USING ERRCODE='42501'; END $$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA plaa,ingest,export FROM PUBLIC;
REVOKE ALL ON SCHEMA plaa,ingest,export FROM PUBLIC;
GRANT USAGE ON SCHEMA plaa TO plaa_admin,plaa_ingest,plaa_backend,plaa_member_reader;
GRANT USAGE ON SCHEMA ingest TO plaa_admin,plaa_ingest;
GRANT USAGE ON SCHEMA export TO plaa_aggregate_builder,plaa_export_reader;
GRANT SELECT ON plaa.member,plaa.member_identity,plaa.activity_submission,plaa.point_event,plaa.plaa_ledger_entry,plaa.buyback_bid,
 plaa.region,plaa.category,plaa.activity,plaa.activity_point_value,plaa.round,plaa.round_activity,plaa.round_region,plaa.round_category_allocation,
 plaa.v_member_balance,plaa.v_member_round_points,plaa.v_quantity_bid TO plaa_member_reader;
GRANT EXECUTE ON FUNCTION plaa.current_member(),plaa.balance_as_of(timestamptz,timestamptz) TO plaa_member_reader;
GRANT EXECUTE ON FUNCTION plaa.bind_directory(text,text) TO plaa_backend;
GRANT EXECUTE ON FUNCTION ingest.land_submission(jsonb),ingest.process_submission(bigint),plaa.import_kudos(jsonb),plaa.record_bid(jsonb) TO plaa_ingest;
GRANT EXECUTE ON FUNCTION plaa.maintain_region(text,text,boolean,text),plaa.maintain_asset(text,text,text,boolean,text),
 plaa.create_member(text,text,timestamptz),plaa.set_member_status(bigint,plaa.member_status),plaa.add_identity(bigint,text,text,date,date,boolean),plaa.close_identity(bigint,date),plaa.resolve_identity(text,text,date),
 plaa.create_category(text,text),plaa.create_activity(text,text,bigint,plaa.activity_cadence,plaa.verification_method,text),plaa.configure_round(jsonb),plaa.set_round_state(bigint,plaa.round_status,text),
 plaa.add_point_value(bigint,date,date,numeric,numeric,numeric),plaa.succeed_point_value(bigint,date,numeric,numeric,numeric),
 plaa.review_submission(bigint,plaa.submission_status,text,text),plaa.correct_point(jsonb),plaa.settle(jsonb),plaa.revise_holding(jsonb),plaa.revise_valuation(jsonb),plaa.record_auction(jsonb),plaa.post_confirmed_entry(jsonb) TO plaa_admin;
GRANT EXECUTE ON FUNCTION export.build_release(text) TO plaa_aggregate_builder;
GRANT SELECT ON export.round_summary,export.round_category_metrics,export.activity_engagement,export.buyback_bid_summary,export.trust_holdings,export.program_growth,export.trust_valuation TO plaa_export_reader;
-- Bounded admin inspection: no arbitrary query/table selector or generic DML.
CREATE FUNCTION plaa.review_queue() RETURNS TABLE(submission_id bigint,aa_id bigint,status plaa.submission_status,review_note text) LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,plaa,pg_temp AS $$
 SELECT submission_id,aa_id,status,review_note FROM plaa.activity_submission WHERE status IN ('received','pending_review') ORDER BY submission_id LIMIT 100;
$$;
CREATE FUNCTION plaa.audit_page(after_id bigint) RETURNS SETOF plaa.audit_log LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,plaa,pg_temp AS $$
 SELECT * FROM plaa.audit_log WHERE audit_id>after_id ORDER BY audit_id LIMIT 100;
$$;
CREATE FUNCTION ingest.triage_queue() RETURNS SETOF ingest.raw_submission LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,ingest,pg_temp AS $$
 SELECT * FROM ingest.raw_submission WHERE error IS NOT NULL ORDER BY raw_id LIMIT 100;
$$;
GRANT EXECUTE ON FUNCTION plaa.review_queue(),plaa.audit_page(bigint),ingest.triage_queue() TO plaa_admin;
RESET ROLE;
