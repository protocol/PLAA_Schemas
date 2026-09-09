-- FICTIONAL ONLY. Fresh disposable test database; IDs come from generated keys.
-- Owner installs explicit synthetic-only policy examples, not production economics.
BEGIN;
SET LOCAL ROLE plaa_owner;
INSERT INTO plaa.kudos_policy(policy_version,mode,owner_approval,valid_from,synthetic_only) VALUES
 ('synthetic-receiver-v1','receiver_only','synthetic-test-approval','2026-01-01',true),
 ('synthetic-paired-v1','paired','synthetic-test-approval','2026-01-01',true);
INSERT INTO export.release_contract VALUES ('synthetic-pending-v1','multi-round coarse candidate',5,'distinct numeric participant internally only','withhold related totals','UNAPPROVED','synthetic adversarial examples only','consumer approval absent',NULL,NULL,'pending',now());
SET LOCAL ROLE plaa_admin;
SELECT plaa.maintain_region('TEST-NORTH','Synthetic North',true,'fixture-operator');
SELECT plaa.maintain_asset('TEST-ASSET','Synthetic Asset','units',true,'fixture-operator');
SELECT plaa.create_member('Synthetic Member '||n,'TEST-NORTH','2026-01-01') FROM generate_series(1,8) n;
SELECT plaa.add_identity(n,'directory_uid','synthetic-subject-'||n,'2020-01-01',NULL,true) FROM generate_series(1,8) n;
SELECT plaa.create_category('synthetic-learning','Synthetic Learning');
SELECT plaa.create_category('synthetic-service','Synthetic Service');
SELECT plaa.create_activity('synthetic-article','Synthetic Article',1,'repeatable','submission','Fictional evidence review');
SELECT plaa.create_activity('synthetic-kudos','Synthetic Kudos',2,'repeatable','auto_tracked','Policy-gated synthetic effects');
SELECT plaa.add_point_value(1,'2026-01-01',NULL,10,10,10);
SELECT plaa.add_point_value(2,'2026-01-01',NULL,NULL,10,100);
SELECT plaa.configure_round('{
 "number":1,"start":"2026-08-01","end":"2026-09-01","pool":"1000",
 "narrative":"Synthetic monthly close; not program policy","header":"Example only",
 "allocations":[{"category":1,"weight":"0.6","amount":"600"},{"category":2,"weight":"0.4","amount":"400"}],
 "activities":[1,2],"regions":["TEST-NORTH"]
}');
SELECT plaa.set_round_state(1,'open','Synthetic round open');
SET LOCAL ROLE plaa_ingest;
SELECT ingest.land_submission('{
 "source":"bot","source_ref":"synthetic-submission-1","revision":1,"occurred_at":"2026-08-10T12:00:00Z",
 "actor":"fixture-bot","import_batch":"synthetic-batch-A","id_type":"directory_uid","id_value":"synthetic-subject-1",
 "activity":1,"round":1,"evidence_url":"https://example.invalid/synthetic-evidence","payload":{"text":"Fictional article"}
}');
SELECT ingest.process_submission(1);
SET LOCAL ROLE plaa_admin;
SELECT plaa.review_submission(1,'accepted','fixture-reviewer','Synthetic accepted evidence');
-- A used open schedule is closed atomically with an adjacent successor.
SELECT plaa.succeed_point_value(1,'2026-08-20',20,20,20);
SELECT plaa.correct_point('{
 "source":"synthetic","source_ref":"point-correction-1","revision":1,"occurred_at":"2026-08-21T12:00:00Z","actor":"fixture-reviewer",
 "original":1,"replacement_points":"12","reason":"Source-backed synthetic historical correction, not repricing"
}');
SET LOCAL ROLE plaa_ingest;
SELECT plaa.import_kudos('{
 "source":"synthetic","source_ref":"kudos-receiver-1","revision":1,"occurred_at":"2026-08-11T12:00:00Z","actor":"fixture-bot",
 "policy_version":"synthetic-receiver-v1","receiver":2,"giver":1,"round":1,"activity":2,"points":"10"
}');
SELECT plaa.import_kudos('{
 "source":"synthetic","source_ref":"kudos-paired-1","revision":1,"occurred_at":"2026-08-12T12:00:00Z","actor":"fixture-bot",
 "policy_version":"synthetic-paired-v1","receiver":3,"giver":2,"round":1,"activity":2,"points":"20"
}');
SET LOCAL ROLE plaa_admin;
SELECT plaa.set_round_state(1,'closed','Synthetic confirmed allocations only');
SELECT plaa.settle('{
 "source":"synthetic","source_ref":"ia-close-1","revision":1,"occurred_at":"2026-09-01T00:00:00Z","actor":"fixture-closer",
 "round":1,"allocation_source":"incentivized_activities","policy_version":"source-confirmed-v1","effective_at":"2026-08-31T23:00:00Z",
 "inputs":{"event_ids":[1,2,3,4,5,6],"cutoff":"2099-01-01T00:00:00Z","allocation_version":"synthetic-confirmed-input-1"},
 "categories":[
  {"category":1,"expected_predecessor":null,"total_points":"12","distributed":"100","issuances":[{"aa_id":1,"amount":"60"},{"aa_id":2,"amount":"40"}]},
  {"category":2,"expected_predecessor":null,"total_points":"10","distributed":"50","issuances":[{"aa_id":3,"amount":"50"}]}
 ]
}');
SELECT plaa.settle('{
 "source":"synthetic","source_ref":"ir-close-1","revision":1,"occurred_at":"2026-09-01T00:00:00Z","actor":"fixture-closer",
 "round":1,"allocation_source":"infra_rewards","policy_version":"source-confirmed-v1","effective_at":"2026-08-31T23:00:00Z",
 "inputs":{"event_ids":[],"cutoff":"2099-01-01T00:00:00Z","allocation_version":"synthetic-ir-source-1"},
 "expected_predecessor":null,"distributed":"25","issuances":[{"aa_id":1,"amount":"25"}]
}');
SELECT plaa.post_confirmed_entry('{
 "source":"synthetic","source_ref":"opening-adjustment-1","revision":1,"occurred_at":"2026-08-01T00:00:00Z","actor":"fixture-closer",
 "policy_version":"source-confirmed-v1","reason":"Synthetic source-backed opening adjustment, not reconstructed history",
 "aa_id":1,"round":1,"entry_type":"adjustment","amount":"5","effective_at":"2026-08-01T00:00:00Z"
}');
SELECT plaa.revise_holding('{
 "source":"synthetic-team","source_ref":"holding-aug-r1","revision":1,"occurred_at":"2026-08-31T00:00:00Z","actor":"fixture-team",
 "month":"2026-08-01","asset":"TEST-ASSET","quantity":"123.12345678","unit":"units","predecessor":null
}');
SELECT plaa.revise_holding('{
 "source":"synthetic-team","source_ref":"holding-aug-r2","revision":2,"occurred_at":"2026-09-02T00:00:00Z","actor":"fixture-team",
 "month":"2026-08-01","asset":"TEST-ASSET","quantity":"124.12345678","unit":"units","predecessor":1
}');
SELECT plaa.revise_valuation('{
 "source":"synthetic-trust","source_ref":"valuation-aug-r1","revision":1,"occurred_at":"2026-08-31T00:00:00Z","actor":"fixture-trust-importer",
 "month":"2026-08-01","trust_value":"1000000.12345678","nav":"2.12345678","received_at":"2026-09-01T00:00:00Z","predecessor":null
}');
SELECT plaa.revise_valuation('{
 "source":"synthetic-trust","source_ref":"valuation-aug-r2","revision":2,"occurred_at":"2026-09-02T00:00:00Z","actor":"fixture-trust-importer",
 "month":"2026-08-01","trust_value":"1000001.12345678","nav":"2.22345678","received_at":"2026-09-02T00:00:00Z","predecessor":1
}');
SELECT plaa.record_auction('{
 "source":"synthetic","source_ref":"auction-1","revision":1,"occurred_at":"2026-08-25T00:00:00Z","actor":"fixture-importer",
 "round":1,"number":1,"opened_at":"2026-08-25T00:00:00Z","closed_at":"2026-08-28T00:00:00Z","payload":{"label":"No fills implied"}
}');
SET LOCAL ROLE plaa_ingest;
SELECT plaa.record_bid('{
 "source":"synthetic","source_ref":"bid-1","revision":1,"occurred_at":"2026-08-26T00:00:00Z","actor":"fixture-importer",
 "auction":1,"aa_id":1,"price":"2","quantity":"3","source_amount":"7","format":"quantity-v1","payload":{"reported_amount":"7"}
}');
SELECT plaa.record_bid('{
 "source":"synthetic","source_ref":"bid-2","revision":1,"occurred_at":"2026-08-26T00:00:00Z","actor":"fixture-importer",
 "auction":1,"aa_id":2,"price":"2","quantity":"3","source_amount":null,"format":"quantity-v1","payload":{}
}');
SELECT ingest.stage_crosswalk('{
 "source":"synthetic-legacy","source_ref":"crosswalk-1","revision":1,"occurred_at":"2026-01-01T00:00:00Z","actor":"fixture-triage",
 "legacy_type":"legacy_member_uid","legacy_value":"synthetic-legacy-001"
}');
SET LOCAL ROLE plaa_admin;
SELECT ingest.review_crosswalk(1,1,'fixture-triage','Synthetic source evidence; not a Directory credential');
COMMIT;
-- Approved release tables deliberately have NO fixture rows: publication is gated.
-- Binding is a trusted-backend operation, followed by an invoker/RLS member read.
BEGIN;
SET LOCAL ROLE plaa_backend;
SELECT plaa.bind_directory('synthetic-subject-1','synthetic-request-example');
SET LOCAL ROLE plaa_member_reader;
SELECT * FROM plaa.v_member_balance;
COMMIT;
