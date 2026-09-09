SET ROLE plaa_owner;
CREATE FUNCTION ingest.claim(q jsonb, k text) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,ingest,pg_temp AS $$
DECLARE m ingest.source_manifest; body jsonb=q-'import_batch'-'actor'; h text;
BEGIN
 IF q->>'source' IS NULL OR q->>'source_ref' IS NULL OR q->>'occurred_at' IS NULL OR q->>'revision' IS NULL OR nullif(btrim(q->>'actor'),'') IS NULL THEN RAISE EXCEPTION 'missing source provenance'; END IF;
 h=encode(public.digest(body::text,'sha256'),'hex');
 INSERT INTO ingest.source_manifest(kind,source,source_ref,source_revision,source_occurred_at,content_hash,payload,import_batch,actor)
 VALUES(k,q->>'source',q->>'source_ref',(q->>'revision')::int,(q->>'occurred_at')::timestamptz,h,body,q->>'import_batch',q->>'actor')
 ON CONFLICT(source,source_ref) DO NOTHING RETURNING * INTO m;
 IF m.manifest_id IS NULL THEN
 SELECT * INTO STRICT m FROM ingest.source_manifest WHERE source=q->>'source' AND source_ref=q->>'source_ref';
 IF m.content_hash<>h OR m.kind<>k THEN RAISE EXCEPTION 'source payload conflict: %/%',q->>'source',q->>'source_ref' USING ERRCODE='23505'; END IF;
 END IF; RETURN m.manifest_id;
END $$;

CREATE FUNCTION plaa.maintain_region(code text, label text, active boolean, actor text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,plaa,pg_temp AS $$
BEGIN
 IF nullif(btrim(actor),'') IS NULL OR nullif(btrim(code),'') IS NULL OR nullif(btrim(label),'') IS NULL THEN RAISE EXCEPTION 'required reference provenance'; END IF;
 INSERT INTO plaa.region(region_code,name,is_active,updated_by) VALUES(code,label,active,actor)
 ON CONFLICT(region_code) DO UPDATE SET name=excluded.name,is_active=excluded.is_active,updated_by=excluded.updated_by;
END $$;
CREATE FUNCTION plaa.maintain_asset(code text,label text,u text,active boolean,actor text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,plaa,pg_temp AS $$
BEGIN
 IF nullif(btrim(actor),'') IS NULL OR nullif(btrim(code),'') IS NULL OR nullif(btrim(u),'') IS NULL THEN RAISE EXCEPTION 'required reference provenance'; END IF;
 INSERT INTO plaa.asset(asset_code,name,default_unit,is_active,updated_by) VALUES(code,label,u,active,actor)
 ON CONFLICT(asset_code) DO UPDATE SET name=excluded.name,is_active=excluded.is_active,updated_by=excluded.updated_by;
 IF (SELECT default_unit FROM plaa.asset WHERE asset_code=code)<>u THEN RAISE EXCEPTION 'unit change requires reviewed source migration'; END IF;
END $$;
CREATE FUNCTION plaa.create_member(label text,region text,onboarded timestamptz) RETURNS bigint LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,plaa,pg_temp AS $$
 INSERT INTO plaa.member(display_name,region_code,onboarded_at) VALUES(label,region,onboarded) RETURNING aa_id;
$$;
CREATE FUNCTION plaa.set_member_status(id bigint,state plaa.member_status) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,plaa,pg_temp AS $$
BEGIN UPDATE plaa.member SET status=state WHERE aa_id=id; IF NOT FOUND THEN RAISE EXCEPTION 'unknown member'; END IF; END $$;
CREATE FUNCTION plaa.add_identity(id bigint,kind text,value text,start_date date,end_date date,is_verified boolean) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,plaa,pg_temp AS $$
DECLARE result bigint;
BEGIN
 -- Opaque identifiers retain case; email lower/trim does not establish verification.
 INSERT INTO plaa.member_identity(aa_id,id_type,id_value,valid_from,valid_to,verified)
 VALUES(id,kind,CASE WHEN kind='email' THEN lower(btrim(value)) ELSE btrim(value) END,start_date,end_date,is_verified) RETURNING member_identity_id INTO result; RETURN result;
END $$;
CREATE FUNCTION plaa.close_identity(id bigint,end_date date) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,plaa,pg_temp AS $$
BEGIN UPDATE plaa.member_identity SET valid_to=end_date WHERE member_identity_id=id AND valid_to IS NULL; IF NOT FOUND THEN RAISE EXCEPTION 'identity not open'; END IF; END $$;
CREATE FUNCTION plaa.resolve_identity(kind text,value text,event_date date) RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,plaa,pg_temp AS $$
 SELECT aa_id FROM plaa.member_identity WHERE id_type=kind AND id_value=CASE WHEN kind='email' THEN lower(btrim(value)) ELSE btrim(value) END AND daterange(valid_from,valid_to,'[)') @> event_date AND verified;
$$;
CREATE FUNCTION plaa.create_category(code text,label text) RETURNS bigint LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,plaa,pg_temp AS $$
 INSERT INTO plaa.category(code,name) VALUES(code,label) RETURNING category_id;
$$;
CREATE FUNCTION plaa.create_activity(code text,label text,category bigint,cadence plaa.activity_cadence,verification plaa.verification_method,description text) RETURNS bigint LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,plaa,pg_temp AS $$
 INSERT INTO plaa.activity(code,name,category_id,cadence,verification,description) VALUES(code,label,category,cadence,verification,description) RETURNING activity_id;
$$;
CREATE FUNCTION plaa.configure_round(q jsonb) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,plaa,pg_temp AS $$
DECLARE id bigint; x jsonb;
BEGIN
 INSERT INTO plaa.round(round_number,period,plaa_pool,narrative,header_description)
 VALUES((q->>'number')::int,daterange((q->>'start')::date,(q->>'end')::date,'[)'),plaa.exact((q->>'pool')::numeric,20,8),q->>'narrative',q->>'header') RETURNING round_id INTO id;
 FOR x IN SELECT value FROM jsonb_array_elements(q->'allocations') LOOP
 INSERT INTO plaa.round_category_allocation(round_id,category_id,weight,plaa_allocated) VALUES(id,(x->>'category')::bigint,plaa.exact((x->>'weight')::numeric,7,6),plaa.exact((x->>'amount')::numeric,20,8));
 END LOOP;
 FOR x IN SELECT value FROM jsonb_array_elements(q->'activities') LOOP INSERT INTO plaa.round_activity VALUES(id,x::text::bigint); END LOOP;
 FOR x IN SELECT value FROM jsonb_array_elements(q->'regions') LOOP INSERT INTO plaa.round_region VALUES(id,x#>>'{}'); END LOOP;
 RETURN id;
END $$;
CREATE FUNCTION plaa.set_round_state(id bigint,state plaa.round_status,narrative text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,plaa,pg_temp AS $$
DECLARE old plaa.round_status;
BEGIN SELECT status INTO STRICT old FROM plaa.round WHERE round_id=id FOR UPDATE;
 IF NOT ((old='draft' AND state='open') OR (old='open' AND state='closed') OR old=state) THEN RAISE EXCEPTION 'invalid round transition'; END IF;
 UPDATE plaa.round SET status=state,narrative=set_round_state.narrative WHERE round_id=id;
END $$;
CREATE FUNCTION plaa.add_point_value(activity bigint,start_date date,end_date date,points numeric,minimum numeric,maximum numeric) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,plaa,pg_temp AS $$
DECLARE id bigint;
BEGIN
 PERFORM 1 FROM plaa.activity WHERE activity_id=add_point_value.activity FOR UPDATE;
 INSERT INTO plaa.activity_point_value(activity_id,valid_from,valid_to,points_default,points_min,points_max)
 VALUES(activity,start_date,end_date,CASE WHEN points IS NOT NULL THEN plaa.exact(points,14,2) END,CASE WHEN minimum IS NOT NULL THEN plaa.exact(minimum,14,2) END,CASE WHEN maximum IS NOT NULL THEN plaa.exact(maximum,14,2) END) RETURNING activity_point_value_id INTO id; RETURN id;
END $$;
CREATE FUNCTION plaa.succeed_point_value(predecessor bigint,boundary date,points numeric,minimum numeric,maximum numeric) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,plaa,pg_temp AS $$
DECLARE a bigint;
BEGIN
 SELECT activity_id INTO STRICT a FROM plaa.activity_point_value WHERE activity_point_value_id=predecessor;
 PERFORM 1 FROM plaa.activity WHERE activity_id=a FOR UPDATE;
 UPDATE plaa.activity_point_value SET valid_to=boundary WHERE activity_point_value_id=predecessor;
 RETURN plaa.add_point_value(a,boundary,NULL,points,minimum,maximum);
END $$;
CREATE FUNCTION ingest.land_submission(q jsonb) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,plaa,ingest,pg_temp AS $$
DECLARE m bigint; id bigint;
BEGIN m=ingest.claim(q,'submission');
 INSERT INTO ingest.raw_submission(source,source_ref,payload,manifest_id) VALUES((q->>'source')::plaa.submission_source,q->>'source_ref',q,m) ON CONFLICT(manifest_id) DO NOTHING;
 SELECT raw_id INTO STRICT id FROM ingest.raw_submission WHERE manifest_id=m; RETURN id;
END $$;
CREATE FUNCTION ingest.process_submission(raw bigint) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,plaa,ingest,pg_temp AS $$
DECLARE r ingest.raw_submission; q jsonb; member_id bigint; id bigint;
BEGIN
 SELECT * INTO STRICT r FROM ingest.raw_submission WHERE raw_id=raw FOR UPDATE; q=r.payload;
 SELECT submission_id INTO id FROM plaa.activity_submission WHERE manifest_id=r.manifest_id; IF FOUND THEN RETURN id; END IF;
 member_id=plaa.resolve_identity(q->>'id_type',q->>'id_value',((q->>'occurred_at')::timestamptz AT TIME ZONE 'UTC')::date);
 IF member_id IS NULL THEN UPDATE ingest.raw_submission SET error='unresolved verified event-time identity' WHERE raw_id=raw; RETURN NULL; END IF;
 INSERT INTO plaa.activity_submission(aa_id,activity_id,round_id,source,source_ref,evidence_url,payload,submitted_at,manifest_id,status)
 VALUES(member_id,(q->>'activity')::bigint,(q->>'round')::bigint,r.source,r.source_ref,q->>'evidence_url',q,(q->>'occurred_at')::timestamptz,r.manifest_id,'pending_review') RETURNING submission_id INTO id;
 UPDATE ingest.raw_submission SET processed_at=clock_timestamp(),error=NULL WHERE raw_id=raw; RETURN id;
END $$;
CREATE FUNCTION plaa.review_submission(id bigint,decision plaa.submission_status,reviewer text,note text) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,plaa,pg_temp AS $$
DECLARE s plaa.activity_submission; v plaa.activity_point_value; result bigint;
BEGIN
 IF nullif(btrim(reviewer),'') IS NULL OR decision NOT IN ('accepted','rejected','duplicate','withdrawn') THEN RAISE EXCEPTION 'review decision/provenance required'; END IF;
 SELECT * INTO STRICT s FROM plaa.activity_submission WHERE submission_id=id FOR UPDATE;
 IF s.status=decision THEN SELECT point_event_id INTO result FROM plaa.point_event WHERE submission_id=id AND event_type='collected'; RETURN result; END IF;
 IF s.status NOT IN ('received','pending_review') THEN RAISE EXCEPTION 'review is final; use correction'; END IF;
 IF decision='accepted' THEN
 PERFORM 1 FROM plaa.activity WHERE activity_id=s.activity_id FOR UPDATE;
 SELECT * INTO STRICT v FROM plaa.activity_point_value WHERE activity_id=s.activity_id AND daterange(valid_from,valid_to,'[)') @> (s.submitted_at AT TIME ZONE 'UTC')::date;
 IF v.points_default IS NULL OR v.points_default=0 THEN RAISE EXCEPTION 'source-confirmed variable award requires separate approved adapter'; END IF;
 INSERT INTO plaa.point_event(aa_id,round_id,activity_id,submission_id,source,source_ref,source_effect,source_occurred_at,activity_point_value_id,points,event_type,created_by,manifest_id)
 VALUES(s.aa_id,s.round_id,s.activity_id,id,s.source,s.source_ref,'receiver_credit',s.submitted_at,v.activity_point_value_id,v.points_default,'collected',reviewer,s.manifest_id) RETURNING point_event_id INTO result;
 END IF;
 UPDATE plaa.activity_submission SET status=decision,reviewed_by=reviewer,reviewed_at=clock_timestamp(),review_note=note WHERE submission_id=id; RETURN result;
END $$;
CREATE FUNCTION plaa.import_kudos(q jsonb) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,plaa,ingest,pg_temp AS $$
DECLARE m bigint; p plaa.kudos_policy; v plaa.activity_point_value; n numeric; id bigint; d date=((q->>'occurred_at')::timestamptz AT TIME ZONE 'UTC')::date;
BEGIN
 SELECT * INTO STRICT p FROM plaa.kudos_policy WHERE policy_version=q->>'policy_version' AND daterange(valid_from,valid_to,'[)') @> d;
 IF p.synthetic_only AND q->>'source'<>'synthetic' THEN RAISE EXCEPTION 'synthetic policy cannot authorize production'; END IF;
 m=ingest.claim(q,'kudos'); SELECT point_event_id INTO id FROM plaa.point_event WHERE manifest_id=m AND source_effect='receiver_credit'; IF FOUND THEN RETURN id; END IF;
 n=plaa.exact((q->>'points')::numeric,14,2);
 PERFORM 1 FROM plaa.activity WHERE activity_id=(q->>'activity')::bigint FOR UPDATE;
 SELECT * INTO STRICT v FROM plaa.activity_point_value WHERE activity_id=(q->>'activity')::bigint AND daterange(valid_from,valid_to,'[)') @> d;
 IF n<=0 OR (v.points_min IS NOT NULL AND n<v.points_min) OR (v.points_max IS NOT NULL AND n>v.points_max) OR (q->>'receiver')::bigint=(q->>'giver')::bigint THEN RAISE EXCEPTION 'invalid kudos amount/participants'; END IF;
 INSERT INTO plaa.point_event(aa_id,round_id,activity_id,source,source_ref,source_effect,source_occurred_at,activity_point_value_id,points,event_type,created_by,manifest_id)
 VALUES((q->>'receiver')::bigint,(q->>'round')::bigint,v.activity_id,q->>'source',q->>'source_ref','receiver_credit',(q->>'occurred_at')::timestamptz,v.activity_point_value_id,n,'kudos_received',q->>'actor',m) RETURNING point_event_id INTO id;
 IF p.mode='paired' THEN
 INSERT INTO plaa.point_event(aa_id,round_id,activity_id,source,source_ref,source_effect,source_occurred_at,activity_point_value_id,points,event_type,created_by,manifest_id)
 VALUES((q->>'giver')::bigint,(q->>'round')::bigint,v.activity_id,q->>'source',q->>'source_ref','giver_debit',(q->>'occurred_at')::timestamptz,v.activity_point_value_id,-n,'kudos_given',q->>'actor',m);
 END IF; RETURN id;
END $$;
CREATE FUNCTION plaa.correct_point(q jsonb) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,plaa,ingest,pg_temp AS $$
DECLARE m bigint; o plaa.point_event; id bigint; n numeric;
BEGIN
 m=ingest.claim(q,'point_correction'); SELECT correction_id INTO id FROM plaa.point_correction_manifest WHERE manifest_id=m; IF FOUND THEN RETURN id; END IF;
 SELECT * INTO STRICT o FROM plaa.point_event WHERE point_event_id=(q->>'original')::bigint FOR UPDATE;
 n=plaa.exact((q->>'replacement_points')::numeric,14,2);
 INSERT INTO plaa.point_correction_manifest(manifest_id,original_event_id,correction_version,reason) VALUES(m,o.point_event_id,(q->>'revision')::int,q->>'reason') RETURNING correction_id INTO id;
 INSERT INTO plaa.point_event(aa_id,round_id,activity_id,source,source_ref,source_effect,source_occurred_at,activity_point_value_id,points,event_type,reverses_event_id,created_by,manifest_id)
 VALUES(o.aa_id,o.round_id,o.activity_id,q->>'source',q->>'source_ref','reversal',o.source_occurred_at,o.activity_point_value_id,-o.points,'reversal',o.point_event_id,q->>'actor',m);
 IF n<>0 THEN
 INSERT INTO plaa.point_event(aa_id,round_id,activity_id,source,source_ref,source_effect,source_occurred_at,points,event_type,created_by,manifest_id,note)
 VALUES(o.aa_id,o.round_id,o.activity_id,q->>'source',q->>'source_ref','replacement',o.source_occurred_at,n,'adjustment',q->>'actor',m,q->>'reason');
 END IF; RETURN id;
END $$;
RESET ROLE;
