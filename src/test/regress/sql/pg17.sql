--
-- PG17
--
SHOW server_version \gset
SELECT substring(:'server_version', '\d+')::int >= 17 AS server_version_ge_17
\gset

-- PG17 has the capabilty to pull up a correlated ANY subquery to a join if
-- the subquery only refers to its immediate parent query. Previously, the
-- subquery needed to be implemented as a SubPlan node, typically as a
-- filter on a scan or join node. This PG17 capability enables Citus to
-- run queries with correlated subqueries in certain cases, as shown here.
-- Relevant PG commit:
-- https://git.postgresql.org/gitweb/?p=postgresql.git;a=commitdiff;h=9f1337639

-- This feature is tested for all PG versions, not just PG17; each test query with
-- a correlated subquery should fail with PG version < 17.0, but the test query
-- rewritten to reflect how PG17 optimizes it should succeed with PG < 17.0

CREATE SCHEMA pg17_corr_subq_folding;
SET search_path TO pg17_corr_subq_folding;
SET citus.next_shard_id TO 20240017;
SET citus.shard_count TO 2;
SET citus.shard_replication_factor TO 1;

CREATE TABLE test (x int, y int);
SELECT create_distributed_table('test', 'x');
INSERT INTO test VALUES (1,1), (2,2);

-- Query 1: WHERE clause has a correlated subquery with a UNION. PG17 can plan
-- this as a nested loop join with the subquery as the inner. The correlation
-- is on the distribution column so the join can be pushed down by Citus.
explain (costs off)
SELECT *
FROM test a
WHERE x IN (SELECT x FROM test b UNION SELECT y FROM test c WHERE a.x = c.x)
ORDER BY 1,2;

SET client_min_messages TO DEBUG2;
SELECT *
FROM test a
WHERE x IN (SELECT x FROM test b UNION SELECT y FROM test c WHERE a.x = c.x)
ORDER BY 1,2;
RESET client_min_messages;

-- Query 1 rewritten with subquery pulled up to a join, as done by PG17 planner;
-- this query can be run without issues by Citus with older (pre PG17) PGs.
explain (costs off)
SELECT a.*
FROM test a JOIN LATERAL (SELECT x FROM test b UNION SELECT y FROM test c WHERE a.x = c.x) dt1 ON a.x = dt1.x
ORDER BY 1,2;

SET client_min_messages TO DEBUG2;
SELECT a.*
FROM test a JOIN LATERAL (SELECT x FROM test b UNION SELECT y FROM test c WHERE a.x = c.x) dt1 ON a.x = dt1.x
ORDER BY 1,2;
RESET client_min_messages;

CREATE TABLE users (user_id int, time int, dept int, info bigint);
CREATE TABLE events (user_id int, time int, event_type int, payload text);
select create_distributed_table('users', 'user_id');
select create_distributed_table('events', 'user_id');

insert into users
select i, 2021 + (i % 3), i % 5, 99999 * i from generate_series(1, 10) i;

insert into events
select i % 10 + 1, 2021 + (i % 3), i %11, md5((i*i)::text) from generate_series(1, 100) i;

-- Query 2. In Citus correlated subqueries can not be used in the WHERE
-- clause but if the subquery can be pulled up to a join it becomes possible
-- for Citus to run the query, per this example. Pre PG17 the suqbuery
-- was implemented as a SubPlan filter on the events table scan.
EXPLAIN (costs off)
WITH event_id
     AS(SELECT user_id AS events_user_id,
                time    AS events_time,
                event_type
         FROM   events)
SELECT Count(*)
FROM   event_id
WHERE  (events_user_id) IN (SELECT user_id
                          FROM   users
                          WHERE  users.time = events_time);

SET client_min_messages TO DEBUG2;
WITH event_id
     AS(SELECT user_id AS events_user_id,
                time    AS events_time,
                event_type
         FROM   events)
SELECT Count(*)
FROM   event_id
WHERE  (events_user_id) IN (SELECT user_id
                          FROM   users
                          WHERE  users.time = events_time);
RESET client_min_messages;

-- Query 2 rewritten with subquery pulled up to a join, as done by pg17 planner. Citus
-- Citus is able to run this query with previous pg versions. Note that the CTE can be
-- disregarded because it is inlined, being only referenced once.
EXPLAIN (COSTS OFF)
SELECT Count(*)
FROM (SELECT user_id AS events_user_id,
                time    AS events_time,
                event_type FROM   events) dt1
INNER JOIN (SELECT distinct user_id, time FROM   users) dt
    ON events_user_id = dt.user_id and events_time = dt.time;

SET client_min_messages TO DEBUG2;
SELECT Count(*)
FROM (SELECT user_id AS events_user_id,
                time    AS events_time,
                event_type FROM   events) dt1
INNER JOIN (SELECT distinct user_id, time FROM   users) dt
    ON events_user_id = dt.user_id and events_time = dt.time;
RESET client_min_messages;

-- Query 3: another example where recursive planning was prevented due to
-- correlated subqueries, but with PG17 folding the subquery to a join it is
-- possible for Citus to plan and run the query.
EXPLAIN (costs off)
SELECT dept, sum(user_id) FROM
(SELECT users.dept, users.user_id
FROM users, events as d1
WHERE d1.user_id = users.user_id
	AND users.dept IN (3,4)
	AND users.user_id IN
	(SELECT s2.user_id FROM users as s2
		GROUP BY d1.user_id, s2.user_id)) dt
GROUP BY dept;

SET client_min_messages TO DEBUG2;
SELECT dept, sum(user_id) FROM
(SELECT users.dept, users.user_id
FROM users, events as d1
WHERE d1.user_id = users.user_id
	AND users.dept IN (3,4)
	AND users.user_id IN
	(SELECT s2.user_id FROM users as s2
		GROUP BY d1.user_id, s2.user_id)) dt
GROUP BY dept;
RESET client_min_messages;

-- Query 3 rewritten in a similar way to how the PG17 pulls up the subquery;
-- the join is on the distribution key so Citus can push down.
EXPLAIN (costs off)
SELECT dept, sum(user_id) FROM
(SELECT users.dept, users.user_id
FROM users, events as d1
     JOIN LATERAL (SELECT s2.user_id FROM users as s2
		   GROUP BY s2.user_id HAVING d1.user_id IS NOT NULL) as d2 ON 1=1
WHERE d1.user_id = users.user_id
      AND users.dept IN (3,4)
	AND users.user_id = d2.user_id) dt
GROUP BY dept;

SET client_min_messages TO DEBUG2;
SELECT dept, sum(user_id) FROM
(SELECT users.dept, users.user_id
FROM users, events as d1
     JOIN LATERAL (SELECT s2.user_id FROM users as s2
		   GROUP BY s2.user_id HAVING d1.user_id IS NOT NULL) as d2 ON 1=1
WHERE d1.user_id = users.user_id
      AND users.dept IN (3,4)
	AND users.user_id = d2.user_id) dt
GROUP BY dept;
RESET client_min_messages;

RESET search_path;
DROP SCHEMA pg17_corr_subq_folding CASCADE;

\if :server_version_ge_17
\else
\q
\endif

-- PG17-specific tests go here.
--
CREATE SCHEMA pg17;
SET search_path to pg17;

-- Test specifying access method on partitioned tables. PG17 feature, added by:
-- https://git.postgresql.org/gitweb/?p=postgresql.git;a=commitdiff;h=374c7a229
-- The following tests were failing tests in tableam but will pass on PG >= 17.
-- There is some set-up duplication of tableam, and this test can be returned
-- to tableam when 17 is the minimum supported PG version.

SELECT public.run_command_on_coordinator_and_workers($Q$
        SET citus.enable_ddl_propagation TO off;
        CREATE FUNCTION fake_am_handler(internal)
        RETURNS table_am_handler
        AS 'citus'
        LANGUAGE C;
        CREATE ACCESS METHOD fake_am TYPE TABLE HANDLER fake_am_handler;
$Q$);

-- Since Citus assumes access methods are part of the extension, make fake_am
-- owned manually to be able to pass checks on Citus while distributing tables.
ALTER EXTENSION citus ADD ACCESS METHOD fake_am;

CREATE TABLE test_partitioned(id int, p int, val int)
PARTITION BY RANGE (p) USING fake_am;

-- Test that children inherit access method from parent
CREATE TABLE test_partitioned_p1 PARTITION OF test_partitioned
        FOR VALUES FROM (1) TO (10);
CREATE TABLE test_partitioned_p2 PARTITION OF test_partitioned
        FOR VALUES FROM (11) TO (20);

INSERT INTO test_partitioned VALUES (1, 5, -1), (2, 15, -2);
INSERT INTO test_partitioned VALUES (3, 6, -6), (4, 16, -4);

SELECT count(1) FROM test_partitioned_p1;
SELECT count(1) FROM test_partitioned_p2;

-- Both child table partitions inherit fake_am
SELECT c.relname, am.amname FROM pg_class c, pg_am am
WHERE c.relam = am.oid AND c.oid IN ('test_partitioned_p1'::regclass, 'test_partitioned_p2'::regclass)
ORDER BY c.relname;

-- Clean up
DROP TABLE test_partitioned;
ALTER EXTENSION citus DROP ACCESS METHOD fake_am;
SELECT public.run_command_on_coordinator_and_workers($Q$
        RESET citus.enable_ddl_propagation;
$Q$);

-- End of testing specifying access method on partitioned tables.

-- MAINTAIN privilege tests

CREATE ROLE regress_maintain;
CREATE ROLE regress_no_maintain;

ALTER ROLE regress_maintain WITH login;
GRANT USAGE ON SCHEMA pg17 TO regress_maintain;
ALTER ROLE regress_no_maintain WITH login;
GRANT USAGE ON SCHEMA pg17 TO regress_no_maintain;

SET citus.shard_count TO 1; -- For consistent remote command logging
CREATE TABLE dist_test(a int, b int);
SELECT create_distributed_table('dist_test', 'a');
INSERT INTO dist_test SELECT i % 10, i FROM generate_series(1, 100) t(i);

SET citus.log_remote_commands TO on;

SET citus.grep_remote_commands = '%maintain%';
GRANT MAINTAIN ON dist_test TO regress_maintain;
RESET citus.grep_remote_commands;

SET ROLE regress_no_maintain;
-- Current role does not have MAINTAIN privileges on dist_test
ANALYZE dist_test;
VACUUM dist_test;

SET ROLE regress_maintain;
-- Current role has MAINTAIN privileges on dist_test
ANALYZE dist_test;
VACUUM dist_test;

-- Take away regress_maintain's MAINTAIN privileges on dist_test
RESET ROLE;
SET citus.grep_remote_commands = '%maintain%';
REVOKE MAINTAIN ON dist_test FROM regress_maintain;
RESET citus.grep_remote_commands;

SET ROLE regress_maintain;
-- Current role does not have MAINTAIN privileges on dist_test
ANALYZE dist_test;
VACUUM dist_test;

RESET ROLE;

-- End of MAINTAIN privilege tests

-- Partitions inherit identity column

RESET citus.log_remote_commands;

-- PG17 added support for identity columns in partioned tables:
-- https://git.postgresql.org/gitweb/?p=postgresql.git;a=commitdiff;h=699586315
-- In particular, partitions with their own identity columns are not allowed.
-- Citus does not need to propagate identity columns in partitions; the identity
-- is inherited by PG17 behavior, as shown in this test.

CREATE TABLE partitioned_table (
    a bigint GENERATED BY DEFAULT AS IDENTITY (START WITH 10 INCREMENT BY 10),
    c int
)
PARTITION BY RANGE (c);
CREATE TABLE pt_1 PARTITION OF partitioned_table FOR VALUES FROM (1) TO (50);

SELECT create_distributed_table('partitioned_table', 'a');

CREATE TABLE pt_2 PARTITION OF partitioned_table FOR VALUES FROM (50) TO (1000);

-- (1) The partitioned table has pt_1 and pt_2 as its partitions
\d+ partitioned_table;

-- (2) The partitions have the same identity column as the parent table;
-- This is PG17 behavior for support for identity in partitioned tables.
\d pt_1;
\d pt_2;

-- Attaching a partition inherits the identity column from the parent table
CREATE TABLE pt_3 (a bigint not null, c int);
ALTER TABLE partitioned_table ATTACH PARTITION pt_3 FOR VALUES FROM (1000) TO (2000);

\d+ partitioned_table;
\d pt_3;

-- Partition pt_4 has its own identity column, which is not allowed in PG17
-- and will produce an error on attempting to attach it to the partitioned table
CREATE TABLE pt_4 (a bigint GENERATED BY DEFAULT AS IDENTITY (START WITH 10 INCREMENT BY 10), c int);
ALTER TABLE partitioned_table ATTACH PARTITION pt_4 FOR VALUES FROM (2000) TO (3000);

\c - - - :worker_1_port

SET search_path TO pg17;
-- Show that DDL for partitioned_table has correctly propagated to the worker node;
-- (1) The partitioned table has pt_1, pt_2 and pt_3 as its partitions
\d+ partitioned_table;

-- (2) The partititions have the same identity column as the parent table
\d pt_1;
\d pt_2;
\d pt_3;

\c - - - :master_port
SET search_path TO pg17;

-- Test detaching a partition with an identity column
ALTER TABLE partitioned_table DETACH PARTITION pt_3;

-- partitioned_table has pt_1, pt_2 as its partitions
-- and pt_3 does not have an identity column
\d+ partitioned_table;
\d pt_3;

-- Verify that the detach has propagated to the worker node
\c - - - :worker_1_port
SET search_path TO pg17;

\d+ partitioned_table;
\d pt_3;

\c - - - :master_port
SET search_path TO pg17;

CREATE TABLE alt_test (a int, b date, c int) PARTITION BY RANGE(c);
SELECT create_distributed_table('alt_test', 'a');

CREATE TABLE alt_test_pt_1 PARTITION OF alt_test FOR VALUES FROM (1) TO (50);
CREATE TABLE alt_test_pt_2 PARTITION OF alt_test FOR VALUES FROM (50) TO (100);

-- Citus does not support adding an identity column for a distributed table (#6738)
-- Attempting to add a column with identity produces an error
ALTER TABLE alt_test ADD COLUMN d bigint GENERATED BY DEFAULT AS IDENTITY (START WITH 10 INCREMENT BY 10);

-- alter table set identity is currently not supported, so adding identity to
-- an existing column generates an error
ALTER TABLE alt_test ALTER COLUMN a SET GENERATED BY DEFAULT SET INCREMENT BY 2 SET START WITH 75 RESTART;

-- Verify that the identity column was not added, on coordinator and worker nodes
\d+ alt_test;
\d alt_test_pt_1;
\d alt_test_pt_2;

\c - - - :worker_1_port
SET search_path TO pg17;

\d+ alt_test;
\d alt_test_pt_1;
\d alt_test_pt_2;

\c - - - :master_port
SET search_path TO pg17;

DROP TABLE alt_test;
CREATE TABLE alt_test (a bigint GENERATED BY DEFAULT AS IDENTITY (START WITH 10 INCREMENT BY 10),
                     b int,
                     c int)
PARTITION BY RANGE(c);

SELECT create_distributed_table('alt_test', 'b');
CREATE TABLE alt_test_pt_1 PARTITION OF alt_test FOR VALUES FROM (1) TO (50);
CREATE TABLE alt_test_pt_2 PARTITION OF alt_test FOR VALUES FROM (50) TO (100);

-- Dropping of the identity property from a column is currently not supported;
-- Attempting to drop identity produces an error
ALTER TABLE alt_test ALTER COLUMN a DROP IDENTITY;

-- Verify that alt_test still has identity on column a
\d+ alt_test;
\d alt_test_pt_1;
\d alt_test_pt_2;

\c - - - :worker_1_port
SET search_path TO pg17;

\d+ alt_test;
\d alt_test_pt_1;
\d alt_test_pt_2

\c - - - :master_port
SET search_path TO pg17;

-- Repeat testing of partitions with identity column on a citus local table

CREATE TABLE local_partitioned_table (
    a bigint GENERATED BY DEFAULT AS IDENTITY (START WITH 10 INCREMENT BY 10),
    c int
)
PARTITION BY RANGE (c);
CREATE TABLE lpt_1 PARTITION OF local_partitioned_table FOR VALUES FROM (1) TO (50);

SELECT citus_add_local_table_to_metadata('local_partitioned_table');

-- Can create tables as partitions and attach tables as partitions to a citus local table:
CREATE TABLE lpt_2 PARTITION OF local_partitioned_table FOR VALUES FROM (50) TO (1000);

CREATE TABLE lpt_3 (a bigint not null, c int);
ALTER TABLE local_partitioned_table ATTACH PARTITION lpt_3 FOR VALUES FROM (1000) TO (2000);

-- The partitions have the same identity column as the parent table, on coordinator and worker nodes
\d+ local_partitioned_table;
\d lpt_1;
\d lpt_2;
\d lpt_3;

\c - - - :worker_1_port
SET search_path TO pg17;

\d+ local_partitioned_table;
\d lpt_1;
\d lpt_2;
\d lpt_3;

\c - - - :master_port
SET search_path TO pg17;

-- Test detaching a partition with an identity column from a citus local table
ALTER TABLE local_partitioned_table DETACH PARTITION lpt_3;

\d+ local_partitioned_table;
\d lpt_3;

\c - - - :worker_1_port
SET search_path TO pg17;

\d+ local_partitioned_table;
\d lpt_3;

\c - - - :master_port
SET search_path TO pg17;

DROP TABLE partitioned_table;
DROP TABLE local_partitioned_table;
DROP TABLE lpt_3;
DROP TABLE pt_3;
DROP TABLE pt_4;
DROP TABLE alt_test;

-- End of partition with identity columns testing

-- Correlated sublinks are now supported as of PostgreSQL 17, resolving issue #4470.
-- Enable DEBUG-level logging to capture detailed execution plans

-- Create the tables
CREATE TABLE postgres_table (key int, value text, value_2 jsonb);
CREATE TABLE reference_table (key int, value text, value_2 jsonb);
SELECT create_reference_table('reference_table');
CREATE TABLE distributed_table (key int, value text, value_2 jsonb);
SELECT create_distributed_table('distributed_table', 'key');

-- Insert test data
INSERT INTO postgres_table SELECT i, i::varchar(256), '{}'::jsonb FROM generate_series(1, 10) i;
INSERT INTO reference_table SELECT i, i::varchar(256), '{}'::jsonb FROM generate_series(1, 10) i;
INSERT INTO distributed_table SELECT i, i::varchar(256), '{}'::jsonb FROM generate_series(1, 10) i;

-- Set local table join policy to auto before running the tests
SET citus.local_table_join_policy TO 'auto';
SET client_min_messages TO DEBUG1;

-- Correlated sublinks are supported in PostgreSQL 17
SELECT COUNT(*) FROM distributed_table d1 JOIN postgres_table USING (key)
WHERE d1.key IN (SELECT key FROM distributed_table WHERE d1.key = key AND key = 5);

SELECT COUNT(*) FROM distributed_table d1 JOIN postgres_table USING (key)
WHERE d1.key IN (SELECT key FROM distributed_table WHERE d1.key = key AND key = 5);

SET citus.local_table_join_policy TO 'prefer-distributed';
SELECT COUNT(*) FROM distributed_table d1 JOIN postgres_table USING (key)
WHERE d1.key IN (SELECT key FROM distributed_table WHERE d1.key = key AND key = 5);

RESET citus.local_table_join_policy;
RESET client_min_messages;
DROP TABLE reference_table;
-- End for Correlated sublinks are now supported as of PostgreSQL 17, resolving issue #4470.

-- Test for exclusion constraints on partitioned and distributed partitioned tables in Citus environment
-- Step 1: Create a distributed partitioned table
\c - - :master_host :master_port
SET search_path TO pg17;
CREATE TABLE distributed_partitioned_table (
    id serial NOT NULL,
    partition_col int NOT NULL,
    PRIMARY KEY (id, partition_col)
) PARTITION BY RANGE (partition_col);
-- Add partitions to the distributed partitioned table
CREATE TABLE distributed_partitioned_table_p1 PARTITION OF distributed_partitioned_table
FOR VALUES FROM (1) TO (100);
CREATE TABLE distributed_partitioned_table_p2 PARTITION OF distributed_partitioned_table
FOR VALUES FROM (100) TO (200);
-- Distribute the table
SELECT create_distributed_table('distributed_partitioned_table', 'id');

-- Step 2: Create a partitioned Citus local table
CREATE TABLE local_partitioned_table (
    id serial NOT NULL,
    partition_col int NOT NULL,
    PRIMARY KEY (id, partition_col)
) PARTITION BY RANGE (partition_col);
-- Add partitions to the local partitioned table
CREATE TABLE local_partitioned_table_p1 PARTITION OF local_partitioned_table
FOR VALUES FROM (1) TO (100);
CREATE TABLE local_partitioned_table_p2 PARTITION OF local_partitioned_table
FOR VALUES FROM (100) TO (200);
SELECT citus_add_local_table_to_metadata('local_partitioned_table');

-- Verify the Citus tables
SELECT table_name, citus_table_type FROM pg_catalog.citus_tables
WHERE table_name::regclass::text LIKE '%_partitioned_table' ORDER BY 1;

-- Step 3: Add an exclusion constraint with a name to the distributed partitioned table
ALTER TABLE distributed_partitioned_table ADD CONSTRAINT dist_exclude_named EXCLUDE USING btree (id WITH =, partition_col WITH =);

-- Step 4: Verify propagation of exclusion constraint to worker nodes
\c - - :public_worker_1_host :worker_1_port
SET search_path TO pg17;
SELECT conname FROM pg_constraint WHERE conrelid = 'pg17.distributed_partitioned_table'::regclass AND conname = 'dist_exclude_named';

-- Step 5: Add an exclusion constraint with a name to the Citus local partitioned table
\c - - :master_host :master_port
SET search_path TO pg17;
ALTER TABLE local_partitioned_table ADD CONSTRAINT local_exclude_named EXCLUDE USING btree (partition_col WITH =);

-- Step 6: Verify the exclusion constraint on the local partitioned table
SELECT conname, contype FROM pg_constraint WHERE conname = 'local_exclude_named' AND contype = 'x';

-- Step 7: Add exclusion constraints without names to both tables
ALTER TABLE distributed_partitioned_table ADD EXCLUDE USING btree (id WITH =, partition_col WITH =);
ALTER TABLE local_partitioned_table ADD EXCLUDE USING btree (partition_col WITH =);

-- Step 8: Verify the unnamed exclusion constraints were added
SELECT conname, contype FROM pg_constraint WHERE conrelid = 'local_partitioned_table'::regclass AND contype = 'x';
\c - - :public_worker_1_host :worker_1_port
SET search_path TO pg17;
SELECT conname, contype FROM pg_constraint WHERE conrelid = 'pg17.distributed_partitioned_table'::regclass AND contype = 'x';

-- Step 9: Drop the exclusion constraints from both tables
\c - - :master_host :master_port
SET search_path TO pg17;
ALTER TABLE distributed_partitioned_table DROP CONSTRAINT dist_exclude_named;
ALTER TABLE local_partitioned_table DROP CONSTRAINT local_exclude_named;

-- Step 10: Verify the constraints were dropped
SELECT * FROM pg_constraint WHERE conname = 'dist_exclude_named' AND contype = 'x';
SELECT * FROM pg_constraint WHERE conname = 'local_exclude_named' AND contype = 'x';

-- Step 11: Clean up - Drop the tables
DROP TABLE distributed_partitioned_table CASCADE;
DROP TABLE local_partitioned_table CASCADE;
-- End of Test for exclusion constraints on partitioned and distributed partitioned tables in Citus environment

-- Propagate SET STATISTICS DEFAULT
-- Relevant PG commit:
-- https://github.com/postgres/postgres/commit/4f622503d
SET citus.next_shard_id TO 25122024;

CREATE TABLE tbl (c1 int, c2 int);
SELECT citus_add_local_table_to_metadata('tbl');
CREATE INDEX tbl_idx ON tbl (c1, (c1+0)) INCLUDE (c2);

-- Citus currently doesn't support ALTER TABLE ALTER COLUMN SET STATISTICS anyway
ALTER TABLE tbl ALTER COLUMN 1 SET STATISTICS 100;
ALTER TABLE tbl ALTER COLUMN 1 SET STATISTICS DEFAULT;
ALTER TABLE tbl ALTER COLUMN 1 SET STATISTICS -1;

-- Citus propagates ALTER INDEX ALTER COLUMN SET STATISTICS DEFAULT to the nodes and shards
SET citus.log_remote_commands TO true;
SET citus.grep_remote_commands = '%STATISTICS%';

ALTER INDEX tbl_idx ALTER COLUMN 2 SET STATISTICS 1000;
\d+ tbl_idx
\d+ tbl_idx_25122024
ALTER INDEX tbl_idx ALTER COLUMN 2 SET STATISTICS DEFAULT;
\d+ tbl_idx
\d+ tbl_idx_25122024
ALTER INDEX tbl_idx ALTER COLUMN 2 SET STATISTICS -1;
\d+ tbl_idx
\d+ tbl_idx_25122024

-- End of testing SET STATISTICS DEFAULT

-- COPY ON_ERROR option
-- Error out for Citus tables because we don't support it yet
-- Relevant PG17 commits:
-- https://github.com/postgres/postgres/commit/9e2d87011
-- https://github.com/postgres/postgres/commit/b725b7eec

CREATE TABLE check_ign_err (n int, m int[], k int);
SELECT create_distributed_table('check_ign_err', 'n');

COPY check_ign_err FROM STDIN WITH (on_error stop);
COPY check_ign_err FROM STDIN WITH (ON_ERROR ignore);
COPY check_ign_err FROM STDIN WITH (on_error ignore, log_verbosity verbose);
COPY check_ign_err FROM STDIN WITH (log_verbosity verbose, on_error ignore);
COPY check_ign_err FROM STDIN WITH (log_verbosity verbose);

-- End of Test for COPY ON_ERROR option

-- Test FORCE_NOT_NULL and FORCE_NULL options
-- FORCE_NULL * and FORCE_NOT_NULL * options for COPY FROM were added in PG17
-- Same tests as in PG copy2.sql, we just distribute the table first
-- Relevant PG17 commit: https://github.com/postgres/postgres/commit/f6d4c9cf1

CREATE TABLE forcetest (
    a INT NOT NULL,
    b TEXT NOT NULL,
    c TEXT,
    d TEXT,
    e TEXT
);
\pset null NULL

SELECT create_distributed_table('forcetest', 'a');

-- should succeed with no effect ("b" remains an empty string, "c" remains NULL)
-- expected output for inserted row in test:
-- b |  c
-----+------
--   | NULL
--(1 row)

BEGIN;
COPY forcetest (a, b, c) FROM STDIN WITH (FORMAT csv, FORCE_NOT_NULL(b), FORCE_NULL(c));
1,,""
\.
COMMIT;
SELECT b, c FROM forcetest WHERE a = 1;

-- should succeed, FORCE_NULL and FORCE_NOT_NULL can be both specified
-- expected output for inserted row in test:
-- c |  d
-----+------
--   | NULL
--(1 row)

BEGIN;
COPY forcetest (a, b, c, d) FROM STDIN WITH (FORMAT csv, FORCE_NOT_NULL(c,d), FORCE_NULL(c,d));
2,'a',,""
\.
COMMIT;
SELECT c, d FROM forcetest WHERE a = 2;

-- should succeed with no effect ("b" remains an empty string, "c" remains NULL)
-- expected output for inserted row in test:
-- b |  c
-----+------
--   | NULL
--(1 row)

BEGIN;
COPY forcetest (a, b, c) FROM STDIN WITH (FORMAT csv, FORCE_NOT_NULL *, FORCE_NULL *);
4,,""
\.
COMMIT;
SELECT b, c FROM forcetest WHERE a = 4;

-- should succeed with effect ("b" remains an empty string)
-- expected output for inserted row in test:
-- b | c
-----+---
--   |
--(1 row)

BEGIN;
COPY forcetest (a, b, c) FROM STDIN WITH (FORMAT csv, FORCE_NOT_NULL *);
5,,""
\.
COMMIT;
SELECT b, c FROM forcetest WHERE a = 5;

-- should succeed with effect ("c" remains NULL)
-- expected output for inserted row in test:
-- b |  c
-----+------
-- b | NULL
--(1 row)

BEGIN;
COPY forcetest (a, b, c) FROM STDIN WITH (FORMAT csv, FORCE_NULL *);
6,"b",""
\.
COMMIT;
SELECT b, c FROM forcetest WHERE a = 6;

\pset null ''

-- End of Testing FORCE_NOT_NULL and FORCE_NULL options

-- Test for ALTER TABLE SET ACCESS METHOD DEFAULT
-- Step 1: Local table setup (non-distributed)
CREATE TABLE test_local_table (id int);

SELECT citus_add_local_table_to_metadata('test_local_table');

-- Step 2: Attempt to set access method to DEFAULT on a Citus local table (should fail)
ALTER TABLE test_local_table SET ACCESS METHOD DEFAULT;

-- Step 3: Setup: create and distribute a table
CREATE TABLE test_alter_access_method (id int);
SELECT create_distributed_table('test_alter_access_method', 'id');

-- Step 4: Attempt to set access method to DEFAULT on a distributed table (should fail with your custom error)
ALTER TABLE test_alter_access_method SET ACCESS METHOD DEFAULT;

-- Step 5: Create and distribute a partitioned table
CREATE TABLE test_partitioned_alter (id int, val text) PARTITION BY RANGE (id);
CREATE TABLE test_partitioned_alter_part1 PARTITION OF test_partitioned_alter FOR VALUES FROM (1) TO (100);
SELECT create_distributed_table('test_partitioned_alter', 'id');

-- Step 6: Attempt to set access method to DEFAULT on a partitioned, distributed table (should fail)
ALTER TABLE test_partitioned_alter SET ACCESS METHOD DEFAULT;

-- Cleanup
DROP TABLE test_local_table CASCADE;
DROP TABLE test_alter_access_method CASCADE;
DROP TABLE test_partitioned_alter CASCADE;
-- End of Test for ALTER TABLE SET ACCESS METHOD DEFAULT

-- Test for ALTER TABLE ... ALTER COLUMN ... SET EXPRESSION

-- Step 1: Local table setup (non-distributed)
CREATE TABLE test_local_table_expr (id int, col int);

SELECT citus_add_local_table_to_metadata('test_local_table_expr');

-- Step 2: Attempt to set expression on a Citus local table (should fail)
ALTER TABLE test_local_table_expr ALTER COLUMN col SET EXPRESSION AS (id * 4);

-- Step 3: Create and distribute a table
CREATE TABLE test_distributed_table_expr (id int, col int);
SELECT create_distributed_table('test_distributed_table_expr', 'id');

-- Step 4: Attempt to set expression on a distributed table (should fail)
ALTER TABLE test_distributed_table_expr ALTER COLUMN col SET EXPRESSION AS (id * 4);

-- Step 5: Create and distribute a partitioned table
CREATE TABLE test_partitioned_expr (id int, val text) PARTITION BY RANGE (id);
CREATE TABLE test_partitioned_expr_part1 PARTITION OF test_partitioned_expr
  FOR VALUES FROM (1) TO (100);
SELECT create_distributed_table('test_partitioned_expr', 'id');

-- Step 6: Attempt to set expression on a partitioned, distributed table (should fail)
ALTER TABLE test_partitioned_expr ALTER COLUMN val SET EXPRESSION AS (id * 4);

-- Cleanup
DROP TABLE test_local_table_expr CASCADE;
DROP TABLE test_distributed_table_expr CASCADE;
DROP TABLE test_partitioned_expr CASCADE;
-- End of Test for ALTER TABLE ... ALTER COLUMN ... SET EXPRESSION
RESET citus.grep_remote_commands;
RESET citus.log_remote_commands;
SET citus.shard_replication_factor TO 1;
SET citus.next_shard_id TO 27122024;

-- PG17 has added support for AT LOCAL operator
-- it converts the given time type to
-- time stamp with the session's TimeZone value as time zone.
-- Here we add tests that validate that we can use AT LOCAL at INSERT commands
-- Relevant PG commit:
-- https://github.com/postgres/postgres/commit/97957fdba

CREATE TABLE test_at_local (id int, time_example timestamp with time zone);
SELECT create_distributed_table('test_at_local', 'id');

BEGIN;
SET LOCAL TimeZone TO 'Europe/Tirane';
SELECT timestamp '2001-02-16 20:38:40' AT LOCAL;
-- verify that we evaluate AT LOCAL at the coordinator and then perform the insert remotely
SET citus.log_remote_commands TO on;
INSERT INTO test_at_local VALUES (1, timestamp '2001-02-16 20:38:40' AT LOCAL);
ROLLBACK;

-- End of Testing AT LOCAL option

-- interval can have infinite values
-- Relevant PG17 commit: https://github.com/postgres/postgres/commit/519fc1bd9
-- disallow those in create_time_partitions

-- test create_time_partitions with infinity values
CREATE TABLE date_partitioned_table(
 measureid integer,
 eventdate date,
 measure_data jsonb) PARTITION BY RANGE(eventdate);

SELECT create_time_partitions('date_partitioned_table', INTERVAL 'infinity', '2022-01-01', '2021-01-01');
SELECT create_time_partitions('date_partitioned_table', INTERVAL '-infinity', '2022-01-01', '2021-01-01');

-- end of testing interval with infinite values

-- various jsonpath methods were added in PG17
-- relevant PG commit: https://github.com/postgres/postgres/commit/66ea94e8e
-- here we add the same test as in pg15_jsonpath.sql for the new additions

CREATE TABLE jsonpath_test (id serial, sample text);
SELECT create_distributed_table('jsonpath_test', 'id');

\COPY jsonpath_test(sample) FROM STDIN
$.bigint().integer().number().decimal()
$.boolean()
$.date()
$.decimal(4,2)
$.string()
$.time()
$.time(6)
$.time_tz()
$.time_tz(4)
$.timestamp()
$.timestamp(2)
$.timestamp_tz()
$.timestamp_tz(0)
\.

-- Cast the text into jsonpath on the worker nodes.
SELECT sample, sample::jsonpath FROM jsonpath_test ORDER BY id;

-- Pull the data, and cast on the coordinator node
WITH samples as (SELECT id, sample FROM jsonpath_test OFFSET 0)
SELECT sample, sample::jsonpath FROM samples ORDER BY id;

-- End of testing jsonpath methods

-- xmltext() function added in PG17, test with columnar and distributed table
-- Relevant PG17 commit: https://github.com/postgres/postgres/commit/526fe0d79
CREATE TABLE test_xml (id int, a xml) USING columnar;
-- expected to insert x&lt;P&gt;73&lt;/P&gt;0.42truej
INSERT INTO test_xml VALUES (1, xmltext('x'|| '<P>73</P>'::xml || .42 || true || 'j'::char));
SELECT * FROM test_xml ORDER BY 1;

SELECT create_distributed_table('test_xml', 'id');
-- expected to insert foo &amp; &lt;&quot;bar&quot;&gt;
INSERT INTO test_xml VALUES (2, xmltext('foo & <"bar">'));
SELECT * FROM test_xml ORDER BY 1;

-- end of xmltest() testing with Citus

--
-- random(min, max) to generate random numbers in a specified range
-- adding here the same tests as the ones with random() in aggregate_support.sql
-- Relevant PG commit: https://github.com/postgres/postgres/commit/e6341323a
--

CREATE TABLE dist_table (dist_col int, agg_col numeric);
SELECT create_distributed_table('dist_table', 'dist_col');

CREATE TABLE ref_table (int_col int);
SELECT create_reference_table('ref_table');

-- Test the cases where the worker agg exec. returns no tuples.

SELECT PERCENTILE_DISC(.25) WITHIN GROUP (ORDER BY agg_col)
FROM (SELECT *, random(0, 1) FROM dist_table) a;

SELECT PERCENTILE_DISC((2 > random(0, 1))::int::numeric / 10)
       WITHIN GROUP (ORDER BY agg_col)
FROM dist_table
LEFT JOIN ref_table ON TRUE;

-- run the same queries after loading some data

INSERT INTO dist_table VALUES (2, 11.2), (3, NULL), (6, 3.22), (3, 4.23), (5, 5.25),
                              (4, 63.4), (75, NULL), (80, NULL), (96, NULL), (8, 1078), (0, 1.19);

SELECT PERCENTILE_DISC(.25) WITHIN GROUP (ORDER BY agg_col)
FROM (SELECT *, random(0, 1) FROM dist_table) a;

SELECT PERCENTILE_DISC((2 > random_normal(0, 1))::int::numeric / 10)
       WITHIN GROUP (ORDER BY agg_col)
FROM dist_table
LEFT JOIN ref_table ON TRUE;

-- End of random(min, max) testing with Citus

-- Test: Access Method Behavior for Partitioned Tables
-- This test verifies the ability to specify and modify table access methods for partitioned tables
-- using CREATE TABLE ... USING and ALTER TABLE ... SET ACCESS METHOD, including distributed tables.

-- Step 1: Create a partitioned table with a specified access method
CREATE TABLE test_partitioned_alter (id INT PRIMARY KEY, value TEXT)
PARTITION BY RANGE (id)
USING heap;

-- Step 2: Create partitions for the partitioned table
CREATE TABLE test_partition_1 PARTITION OF test_partitioned_alter
  FOR VALUES FROM (0) TO (100);

CREATE TABLE test_partition_2 PARTITION OF test_partitioned_alter
  FOR VALUES FROM (100) TO (200);

-- Step 3: Distribute the partitioned table
SELECT create_distributed_table('test_partitioned_alter', 'id');

-- Step 4: Verify that the table and partitions are created and distributed correctly on the coordinator
SELECT relname, relam
FROM pg_class
WHERE relname = 'test_partitioned_alter';

SELECT relname, relam
FROM pg_class
WHERE relname IN ('test_partition_1', 'test_partition_2')
ORDER BY relname;

-- Step 4 (Repeat on a Worker Node): Verify that the table and partitions are created correctly
\c - - - :worker_1_port
SET search_path TO pg17;

-- Verify the table's access method on the worker node
SELECT relname, relam
FROM pg_class
WHERE relname = 'test_partitioned_alter';

-- Verify the partitions' access methods on the worker node
SELECT relname, relam
FROM pg_class
WHERE relname IN ('test_partition_1', 'test_partition_2')
ORDER BY relname;

\c - - - :master_port
SET search_path TO pg17;

-- Step 5: Test ALTER TABLE ... SET ACCESS METHOD to a different method
ALTER TABLE test_partitioned_alter SET ACCESS METHOD columnar;

-- Verify the access method in the distributed parent and existing partitions
-- Note: Specifying an access method for a partitioned table lets the value be used for all
-- future partitions created under it, closely mirroring the behavior of the TABLESPACE
-- option for partitioned tables. Existing partitions are not modified.
-- Reference: https://git.postgresql.org/gitweb/?p=postgresql.git;a=commitdiff;h=374c7a2290429eac3217b0c7b0b485db9c2bcc72

-- Verify the parent table's access method
SELECT relname, relam
FROM pg_class
WHERE relname = 'test_partitioned_alter';

-- Verify the partitions' access methods
SELECT relname, relam
FROM pg_class
WHERE relname IN ('test_partition_1', 'test_partition_2')
ORDER BY relname;

-- Step 6: Verify the change is applied to future partitions
CREATE TABLE test_partition_3 PARTITION OF test_partitioned_alter
  FOR VALUES FROM (200) TO (300);

SELECT relname, relam
FROM pg_class
WHERE relname = 'test_partition_3';

-- Step 6 (Repeat on a Worker Node): Verify that the new partition is created correctly
\c - - - :worker_1_port
SET search_path TO pg17;

-- Verify the new partition's access method on the worker node
SELECT relname, relam
FROM pg_class
WHERE relname = 'test_partition_3';

\c - - - :master_port
SET search_path TO pg17;

-- Clean up
DROP TABLE test_partitioned_alter CASCADE;

-- End of Test: Access Method Behavior for Partitioned Tables

-- Test for REINDEX support in event triggers for Citus-related objects
-- Create a test table with a distributed setup
CREATE TABLE reindex_test (id SERIAL PRIMARY KEY, data TEXT);
SELECT create_distributed_table('reindex_test', 'id');

-- Create an index to test REINDEX functionality
CREATE INDEX reindex_test_data_idx ON reindex_test (data);

-- Create event triggers to capture REINDEX events (start and end)
CREATE OR REPLACE FUNCTION log_reindex_events() RETURNS event_trigger LANGUAGE plpgsql AS $$
DECLARE
    command_tag TEXT;
    command_object JSONB;
BEGIN
    command_tag := tg_tag;
    command_object := jsonb_build_object(
        'object_type', tg_event,
        'command_tag', command_tag,
        'query', current_query()
    );
    RAISE NOTICE 'Event Trigger Log: %', command_object::TEXT;
END;
$$;

CREATE EVENT TRIGGER reindex_event_trigger
    ON ddl_command_start
    WHEN TAG IN ('REINDEX')
EXECUTE FUNCTION log_reindex_events();

CREATE EVENT TRIGGER reindex_event_trigger_end
    ON ddl_command_end
    WHEN TAG IN ('REINDEX')
EXECUTE FUNCTION log_reindex_events();

-- Insert some data to create index bloat
INSERT INTO reindex_test (data)
SELECT 'value_' || g.i
FROM generate_series(1, 10000) g(i);

-- Perform REINDEX TABLE ... CONCURRENTLY and verify event trigger logs
REINDEX TABLE CONCURRENTLY reindex_test;

-- Perform REINDEX INDEX ... CONCURRENTLY and verify event trigger logs
REINDEX INDEX CONCURRENTLY reindex_test_data_idx;

-- Cleanup
DROP EVENT TRIGGER reindex_event_trigger;
DROP EVENT TRIGGER reindex_event_trigger_end;
DROP TABLE reindex_test CASCADE;

-- End of test for REINDEX support in event triggers for Citus-related objects
-- Propagate EXPLAIN MEMORY
-- Relevant PG commit: https://github.com/postgres/postgres/commit/5de890e36
-- Propagate EXPLAIN SERIALIZE
-- Relevant PG commit: https://github.com/postgres/postgres/commit/06286709e

SET citus.next_shard_id TO 12242024;
CREATE TABLE int8_tbl(q1 int8, q2 int8);
SELECT create_distributed_table('int8_tbl', 'q1');
INSERT INTO int8_tbl VALUES
  ('  123   ','  456'),
  ('123   ','4567890123456789'),
  ('4567890123456789','123'),
  (+4567890123456789,'4567890123456789'),
  ('+4567890123456789','-4567890123456789');

-- memory tests, same as postgres tests, we just distributed the table
-- we can see the memory used separately per each task in worker nodes

SET citus.log_remote_commands TO true;

-- for explain analyze, we run worker_save_query_explain_analyze query
-- for regular explain, we run EXPLAIN query
-- therefore let's grep the commands based on the shard id
SET citus.grep_remote_commands TO '%12242024%';

select public.explain_filter('explain (memory) select * from int8_tbl i8');
select public.explain_filter('explain (memory, analyze) select * from int8_tbl i8');
select public.explain_filter('explain (memory, summary, format yaml) select * from int8_tbl i8');
select public.explain_filter('explain (memory, analyze, format json) select * from int8_tbl i8');
prepare int8_query as select * from int8_tbl i8;
select public.explain_filter('explain (memory) execute int8_query');

-- serialize tests, same as postgres tests, we just distributed the table
select public.explain_filter('explain (analyze, serialize, buffers, format yaml) select * from int8_tbl i8');
select public.explain_filter('explain (analyze,serialize) select * from int8_tbl i8');
select public.explain_filter('explain (analyze,serialize text,buffers,timing off) select * from int8_tbl i8');
select public.explain_filter('explain (analyze,serialize binary,buffers,timing) select * from int8_tbl i8');
-- this tests an edge case where we have no data to return
select public.explain_filter('explain (analyze,serialize) create temp table explain_temp as select * from int8_tbl i8');

RESET citus.log_remote_commands;
-- End of EXPLAIN MEMORY SERIALIZE tests
-- Add support for MERGE ... WHEN NOT MATCHED BY SOURCE.
-- Relevant PG commit:
-- https://github.com/postgres/postgres/commit/0294df2f1

SET citus.next_shard_id TO 1072025;

-- Regular Postgres tables
CREATE TABLE postgres_target_1 (tid integer, balance float, val text);
CREATE TABLE postgres_target_2 (tid integer, balance float, val text);
CREATE TABLE postgres_source (sid integer, delta float);
INSERT INTO postgres_target_1 SELECT id, id * 100, 'initial' FROM generate_series(1,15,2) AS id;
INSERT INTO postgres_target_2 SELECT id, id * 100, 'initial' FROM generate_series(1,15,2) AS id;
INSERT INTO postgres_source SELECT id, id * 10  FROM generate_series(1,14) AS id;

-- Citus local tables
CREATE TABLE citus_local_target (tid integer, balance float, val text);
CREATE TABLE citus_local_source (sid integer, delta float);
SELECT citus_add_local_table_to_metadata('citus_local_target');
SELECT citus_add_local_table_to_metadata('citus_local_source');
INSERT INTO citus_local_target SELECT id, id * 100, 'initial' FROM generate_series(1,15,2) AS id;
INSERT INTO citus_local_source SELECT id, id * 10  FROM generate_series(1,14) AS id;
-- Citus distributed tables
CREATE TABLE citus_distributed_target (tid integer, balance float, val text);
CREATE TABLE citus_distributed_source (sid integer, delta float);
SELECT create_distributed_table('citus_distributed_target', 'tid');
SELECT create_distributed_table('citus_distributed_source', 'sid');
INSERT INTO citus_distributed_target SELECT id, id * 100, 'initial' FROM generate_series(1,15,2) AS id;
INSERT INTO citus_distributed_source SELECT id, id * 10  FROM generate_series(1,14) AS id;
-- Citus reference tables
CREATE TABLE citus_reference_target (tid integer, balance float, val text);
CREATE TABLE citus_reference_source (sid integer, delta float);
SELECT create_reference_table('citus_reference_target');
SELECT create_reference_table('citus_reference_source');
INSERT INTO citus_reference_target SELECT id, id * 100, 'initial' FROM generate_series(1,15,2) AS id;
INSERT INTO citus_reference_source SELECT id, id * 10  FROM generate_series(1,14) AS id;

-- Try all combinations of tables with two queries:
-- 1: Simple Merge
-- 2: Merge with a constant qual

-- Run the merge queries with the postgres tables
-- to save the expected output

-- try simple MERGE
MERGE INTO postgres_target_1 t
  USING postgres_source s
  ON t.tid = s.sid
  WHEN MATCHED THEN
    UPDATE SET balance = balance + delta, val = val || ' updated by merge'
  WHEN NOT MATCHED THEN
    INSERT VALUES (sid, delta, 'inserted by merge')
  WHEN NOT MATCHED BY SOURCE THEN
    UPDATE SET val = val || ' not matched by source';
SELECT * FROM postgres_target_1 ORDER BY tid, val;

-- same with a constant qual
MERGE INTO postgres_target_2 t
  USING postgres_source s
  ON t.tid = s.sid AND tid = 1
  WHEN MATCHED THEN
    UPDATE SET balance = balance + delta, val = val || ' updated by merge'
  WHEN NOT MATCHED THEN
    INSERT VALUES (sid, delta, 'inserted by merge')
  WHEN NOT MATCHED BY SOURCE THEN
    UPDATE SET val = val || ' not matched by source';
SELECT * FROM postgres_target_2 ORDER BY tid, val;

-- function to compare the output from Citus tables
-- with the expected output from Postgres tables

CREATE OR REPLACE FUNCTION compare_tables(table1 TEXT, table2 TEXT) RETURNS BOOLEAN AS $$
DECLARE ret BOOL;
BEGIN
EXECUTE 'select count(*) = 0 from ((
  SELECT * FROM ' || table1 ||
  ' EXCEPT
  SELECT * FROM ' || table2 || ' )
 UNION ALL (
  SELECT * FROM ' || table2 ||
  ' EXCEPT
  SELECT * FROM ' || table1 || ' ))' INTO ret;
RETURN ret;
END
$$ LANGUAGE PLPGSQL;

-- Local-Local
-- Let's also print the command here
-- try simple MERGE
BEGIN;
SET citus.log_local_commands TO on;
MERGE INTO citus_local_target t
  USING citus_local_source s
  ON t.tid = s.sid
  WHEN MATCHED THEN
    UPDATE SET balance = balance + delta, val = val || ' updated by merge'
  WHEN NOT MATCHED THEN
    INSERT VALUES (sid, delta, 'inserted by merge')
  WHEN NOT MATCHED BY SOURCE THEN
    UPDATE SET val = val || ' not matched by source';
SELECT compare_tables('citus_local_target', 'postgres_target_1');
ROLLBACK;

-- same with a constant qual
BEGIN;
MERGE INTO citus_local_target t
  USING citus_local_source s
  ON t.tid = s.sid AND tid = 1
  WHEN MATCHED THEN
    UPDATE SET balance = balance + delta, val = val || ' updated by merge'
  WHEN NOT MATCHED BY TARGET THEN
    INSERT VALUES (sid, delta, 'inserted by merge')
  WHEN NOT MATCHED BY SOURCE THEN
    UPDATE SET val = val || ' not matched by source';
SELECT compare_tables('citus_local_target', 'postgres_target_2');
ROLLBACK;

-- Local-Reference
-- try simple MERGE
BEGIN;
MERGE INTO citus_local_target t
  USING citus_reference_source s
  ON t.tid = s.sid
  WHEN MATCHED THEN
    UPDATE SET balance = balance + delta, val = val || ' updated by merge'
  WHEN NOT MATCHED BY TARGET THEN
    INSERT VALUES (sid, delta, 'inserted by merge')
  WHEN NOT MATCHED BY SOURCE THEN
    UPDATE SET val = val || ' not matched by source';
SELECT compare_tables('citus_local_target', 'postgres_target_1');
ROLLBACK;

-- same with a constant qual
BEGIN;
MERGE INTO citus_local_target t
  USING citus_reference_source s
  ON t.tid = s.sid AND tid = 1
  WHEN MATCHED THEN
    UPDATE SET balance = balance + delta, val = val || ' updated by merge'
  WHEN NOT MATCHED THEN
    INSERT VALUES (sid, delta, 'inserted by merge')
  WHEN NOT MATCHED BY SOURCE THEN
    UPDATE SET val = val || ' not matched by source';
SELECT compare_tables('citus_local_target', 'postgres_target_2');
ROLLBACK;

-- Local-Distributed - Merge currently not supported, Feature in development.
-- try simple MERGE
MERGE INTO citus_local_target t
  USING citus_distributed_source s
  ON t.tid = s.sid
  WHEN MATCHED THEN
    UPDATE SET balance = balance + delta, val = val || ' updated by merge'
  WHEN NOT MATCHED THEN
    INSERT VALUES (sid, delta, 'inserted by merge')
  WHEN NOT MATCHED BY SOURCE THEN
    UPDATE SET val = val || ' not matched by source';

-- Distributed-Local
-- try simple MERGE
BEGIN;
MERGE INTO citus_distributed_target t
  USING citus_local_source s
  ON t.tid = s.sid
  WHEN MATCHED THEN
    UPDATE SET balance = balance + delta, val = val || ' updated by merge'
  WHEN NOT MATCHED THEN
    INSERT VALUES (sid, delta, 'inserted by merge')
  WHEN NOT MATCHED BY SOURCE THEN
    UPDATE SET val = val || ' not matched by source';
SELECT compare_tables('citus_distributed_target', 'postgres_target_1');
ROLLBACK;

-- same with a constant qual
BEGIN;
MERGE INTO citus_distributed_target t
  USING citus_local_source s
  ON t.tid = s.sid AND tid = 1
  WHEN MATCHED THEN
    UPDATE SET balance = balance + delta, val = val || ' updated by merge'
  WHEN NOT MATCHED BY TARGET THEN
    INSERT VALUES (sid, delta, 'inserted by merge')
  WHEN NOT MATCHED BY SOURCE THEN
    UPDATE SET val = val || ' not matched by source';
SELECT compare_tables('citus_distributed_target', 'postgres_target_2');
ROLLBACK;

-- Distributed-Distributed
-- try simple MERGE
BEGIN;
MERGE INTO citus_distributed_target t
  USING citus_distributed_source s
  ON t.tid = s.sid
  WHEN MATCHED THEN
    UPDATE SET balance = balance + delta, val = val || ' updated by merge'
  WHEN NOT MATCHED THEN
    INSERT VALUES (sid, delta, 'inserted by merge')
  WHEN NOT MATCHED BY SOURCE THEN
    UPDATE SET val = val || ' not matched by source';
SELECT compare_tables('citus_distributed_target', 'postgres_target_1');
ROLLBACK;

-- same with a constant qual
BEGIN;
MERGE INTO citus_distributed_target t
  USING citus_distributed_source s
  ON t.tid = s.sid AND tid = 1
  WHEN MATCHED THEN
    UPDATE SET balance = balance + delta, val = val || ' updated by merge'
  WHEN NOT MATCHED THEN
    INSERT VALUES (sid, delta, 'inserted by merge')
  WHEN NOT MATCHED BY SOURCE THEN
    UPDATE SET val = val || ' not matched by source';
SELECT compare_tables('citus_distributed_target', 'postgres_target_2');
ROLLBACK;

-- Distributed-Reference
-- try simple MERGE
BEGIN;
MERGE INTO citus_distributed_target t
  USING citus_reference_source s
  ON t.tid = s.sid
  WHEN MATCHED THEN
    UPDATE SET balance = balance + delta, val = val || ' updated by merge'
  WHEN NOT MATCHED THEN
    INSERT VALUES (sid, delta, 'inserted by merge')
  WHEN NOT MATCHED BY SOURCE THEN
    UPDATE SET val = val || ' not matched by source';
SELECT compare_tables('citus_distributed_target', 'postgres_target_1');
ROLLBACK;

-- same with a constant qual
BEGIN;
MERGE INTO citus_distributed_target t
  USING citus_reference_source s
  ON t.tid = s.sid AND tid = 1
  WHEN MATCHED THEN
    UPDATE SET balance = balance + delta, val = val || ' updated by merge'
  WHEN NOT MATCHED THEN
    INSERT VALUES (sid, delta, 'inserted by merge')
  WHEN NOT MATCHED BY SOURCE THEN
    UPDATE SET val = val || ' not matched by source';
SELECT compare_tables('citus_distributed_target', 'postgres_target_2');
ROLLBACK;

-- Reference-N/A - Reference table as target is not allowed in Merge
-- try simple MERGE
MERGE INTO citus_reference_target t
  USING citus_distributed_source s
  ON t.tid = s.sid
  WHEN MATCHED THEN
    UPDATE SET balance = balance + delta, val = val || ' updated by merge'
  WHEN NOT MATCHED THEN
    INSERT VALUES (sid, delta, 'inserted by merge')
  WHEN NOT MATCHED BY SOURCE THEN
    UPDATE SET val = val || ' not matched by source';

-- Test Distributed-reference and distributed-local when the source table has fewer rows
-- than distributed target; this tests that MERGE with NOT MATCHED BY SOURCE needs to run
-- on all shards of the distributed target, regardless of whether or not the reshuffled
-- source table has data in the corresponding shard.

-- Re-populate the Postgres tables;
DELETE FROM postgres_source;
DELETE FROM postgres_target_1;
DELETE FROM postgres_target_2;

-- This time, the source table has fewer rows
INSERT INTO postgres_target_1 SELECT id, id * 100, 'initial' FROM generate_series(1,15,2) AS id;
INSERT INTO postgres_target_2 SELECT id, id * 100, 'initial' FROM generate_series(1,15,2) AS id;
INSERT INTO postgres_source SELECT id, id * 10  FROM generate_series(1,4) AS id;

-- try simple MERGE
MERGE INTO postgres_target_1 t
  USING postgres_source s
  ON t.tid = s.sid
  WHEN MATCHED THEN
    UPDATE SET balance = balance + delta, val = val || ' updated by merge'
  WHEN NOT MATCHED THEN
    INSERT VALUES (sid, delta, 'inserted by merge')
  WHEN NOT MATCHED BY SOURCE THEN
    UPDATE SET val = val || ' not matched by source';
SELECT * FROM postgres_target_1 ORDER BY tid, val;

-- same with a constant qual
MERGE INTO postgres_target_2 t
  USING postgres_source s
  ON t.tid = s.sid AND tid = 1
  WHEN MATCHED THEN
    UPDATE SET balance = balance + delta, val = val || ' updated by merge'
  WHEN NOT MATCHED THEN
    INSERT VALUES (sid, delta, 'inserted by merge')
  WHEN NOT MATCHED BY SOURCE THEN
    UPDATE SET val = val || ' not matched by source';
SELECT * FROM postgres_target_2 ORDER BY tid, val;

-- Re-populate the Citus tables; this time, the source table has fewer rows
DELETE FROM citus_local_source;
DELETE FROM citus_reference_source;
INSERT INTO citus_reference_source SELECT id, id * 10  FROM generate_series(1,4) AS id;
INSERT INTO citus_local_source SELECT id, id * 10  FROM generate_series(1,4) AS id;

SET citus.shard_count to 32;
CREATE TABLE citus_distributed_target32 (tid integer, balance float, val text);
SELECT create_distributed_table('citus_distributed_target32', 'tid');
INSERT INTO citus_distributed_target32 SELECT id, id * 100, 'initial' FROM generate_series(1,15,2) AS id;

-- Distributed-Local
-- try simple MERGE
BEGIN;
MERGE INTO citus_distributed_target32 t
  USING citus_local_source s
  ON t.tid = s.sid
  WHEN MATCHED THEN
    UPDATE SET balance = balance + delta, val = val || ' updated by merge'
  WHEN NOT MATCHED THEN
    INSERT VALUES (sid, delta, 'inserted by merge')
  WHEN NOT MATCHED BY SOURCE THEN
    UPDATE SET val = val || ' not matched by source';
SELECT compare_tables('citus_distributed_target32', 'postgres_target_1');
ROLLBACK;

-- same with a constant qual
BEGIN;
MERGE INTO citus_distributed_target32 t
  USING citus_local_source s
  ON t.tid = s.sid AND tid = 1
  WHEN MATCHED THEN
    UPDATE SET balance = balance + delta, val = val || ' updated by merge'
  WHEN NOT MATCHED BY TARGET THEN
    INSERT VALUES (sid, delta, 'inserted by merge')
  WHEN NOT MATCHED BY SOURCE THEN
    UPDATE SET val = val || ' not matched by source';
SELECT compare_tables('citus_distributed_target32', 'postgres_target_2');
ROLLBACK;

-- Distributed-Reference
-- try simple MERGE
BEGIN;
MERGE INTO citus_distributed_target32 t
  USING citus_reference_source s
  ON t.tid = s.sid
  WHEN MATCHED THEN
    UPDATE SET balance = balance + delta, val = val || ' updated by merge'
  WHEN NOT MATCHED THEN
    INSERT VALUES (sid, delta, 'inserted by merge')
  WHEN NOT MATCHED BY SOURCE THEN
    UPDATE SET val = val || ' not matched by source';
SELECT compare_tables('citus_distributed_target32', 'postgres_target_1');
ROLLBACK;

-- same with a constant qual
BEGIN;
MERGE INTO citus_distributed_target32 t
  USING citus_reference_source s
  ON t.tid = s.sid AND tid = 1
  WHEN MATCHED THEN
    UPDATE SET balance = balance + delta, val = val || ' updated by merge'
  WHEN NOT MATCHED THEN
    INSERT VALUES (sid, delta, 'inserted by merge')
  WHEN NOT MATCHED BY SOURCE THEN
    UPDATE SET val = val || ' not matched by source';
SELECT compare_tables('citus_distributed_target32', 'postgres_target_2');
ROLLBACK;

-- Test that MERGE with NOT MATCHED BY SOURCE runs on all shards of
-- a distributed table when the source is a repartition query with
-- rows that do not match the distributed target

set citus.shard_count = 32;

CREATE TABLE dist_target (tid integer, balance float);
CREATE TABLE dist_src1(sid integer, tid integer, val float);
CREATE TABLE dist_src2(sid integer);
CREATE TABLE dist_ref(sid integer);

INSERT INTO dist_target SELECT id, 0 FROM generate_series(1,9,2) AS id;
INSERT INTO dist_src1 SELECT id, id%3 + 1, id*10  FROM generate_series(1,15) AS id;
INSERT INTO dist_src2 SELECT id  FROM generate_series(1,100) AS id;
INSERT INTO dist_ref SELECT id  FROM generate_series(1,10) AS id;

-- Run a MERGE command with dist_target as target and an aggregating query
-- as source; note that at this point all tables are vanilla Postgres tables
BEGIN;
SELECT * FROM dist_target ORDER BY tid;
MERGE INTO dist_target t
USING (SELECT dt.tid, avg(dt.val) as av, min(dt.val) as m, max(dt.val) as x
       FROM dist_src1 dt INNER JOIN dist_src2 dt2 on dt.sid=dt2.sid
          INNER JOIN dist_ref dr ON dt.sid=dr.sid
	GROUP BY dt.tid) dv ON (t.tid=dv.tid)
WHEN MATCHED THEN
         UPDATE SET balance = dv.av
WHEN NOT MATCHED THEN
	INSERT (tid, balance) VALUES (dv.tid, dv.m)
WHEN NOT MATCHED BY SOURCE THEN
        UPDATE SET balance = 99.95;
SELECT * FROM dist_target ORDER BY tid;
ROLLBACK;

-- Distribute the tables
SELECT create_distributed_table('dist_target', 'tid');
SELECT create_distributed_table('dist_src1', 'sid');
SELECT create_distributed_table('dist_src2', 'sid');
SELECT create_reference_table('dist_ref');

-- Re-run the merge; the target is now distributed and the source is a
-- distributed query that is repartitioned.
BEGIN;
SELECT * FROM dist_target ORDER BY tid;
MERGE INTO dist_target t
USING (SELECT dt.tid, avg(dt.val) as av, min(dt.val) as m, max(dt.val) as x
       FROM dist_src1 dt INNER JOIN dist_src2 dt2 on dt.sid=dt2.sid
          INNER JOIN dist_ref dr ON dt.sid=dr.sid
	GROUP BY dt.tid) dv ON (t.tid=dv.tid)
WHEN MATCHED THEN
         UPDATE SET balance = dv.av
WHEN NOT MATCHED THEN
	INSERT (tid, balance) VALUES (dv.tid, dv.m)
WHEN NOT MATCHED BY SOURCE THEN
        UPDATE SET balance = 99.95;

-- Data in dist_target is as it was with vanilla Postgres tables:
SELECT * FROM dist_target ORDER BY tid;
ROLLBACK;

-- Reset shard_count for the DEBUG output in the following test

SET citus.shard_count to 4;
-- Complex repartition query example with a mix of tables
-- Example from blog post
-- https://www.citusdata.com/blog/2023/07/27/how-citus-12-supports-postgres-merge

-- Contains information about the machines in the manufacturing facility
CREATE TABLE machines (
    machine_id NUMERIC PRIMARY KEY,
    machine_name VARCHAR(100),
    location VARCHAR(50),
    status VARCHAR(20)
);
SELECT create_reference_table('machines');

-- Holds data on the various sensors installed on each machine
CREATE TABLE sensors (
    sensor_id NUMERIC PRIMARY KEY,
    sensor_name VARCHAR(100),
    machine_id NUMERIC,
    sensor_type VARCHAR(50)
);
SELECT create_distributed_table('sensors', 'sensor_id');

-- Stores real-time readings from the sensors
CREATE TABLE sensor_readings (
    reading_id NUMERIC ,
    sensor_id NUMERIC,
    reading_value NUMERIC,
    reading_timestamp TIMESTAMP
);
SELECT create_distributed_table('sensor_readings', 'sensor_id');

-- Holds real-time sensor readings for machines on 'Production Floor 1'
CREATE TABLE real_sensor_readings (
    real_reading_id NUMERIC ,
    sensor_id NUMERIC,
    reading_value NUMERIC,
    reading_timestamp TIMESTAMP
);
SELECT create_distributed_table('real_sensor_readings', 'sensor_id');

-- Insert data into the machines table
INSERT INTO machines (machine_id, machine_name, location, status)
VALUES
    (1, 'Machine A', 'Production Floor 1', 'Active'),
    (2, 'Machine B', 'Production Floor 2', 'Active'),
    (3, 'Machine C', 'Production Floor 1', 'Inactive');

-- Insert data into the sensors table
INSERT INTO sensors (sensor_id, sensor_name, machine_id, sensor_type)
VALUES
    (1, 'Temperature Sensor 1', 1, 'Temperature'),
    (2, 'Pressure Sensor 1', 1, 'Pressure'),
    (3, 'Temperature Sensor 2', 2, 'Temperature'),
    (4, 'Vibration Sensor 1', 3, 'Vibration');

-- Insert data into the real_sensor_readings table
INSERT INTO real_sensor_readings (real_reading_id, sensor_id, reading_value, reading_timestamp)
VALUES
    (1, 1, 35.6, TIMESTAMP '2023-07-20 10:15:00'),
    (2, 1, 36.8, TIMESTAMP '2023-07-20 10:30:00'),
    (3, 2, 100.5, TIMESTAMP '2023-07-20 10:15:00'),
    (4, 2, 101.2, TIMESTAMP '2023-07-20 10:30:00'),
    (5, 3, 36.2, TIMESTAMP '2023-07-20 10:15:00'),
    (6, 3, 36.5, TIMESTAMP '2023-07-20 10:30:00'),
    (7, 4, 0.02, TIMESTAMP '2023-07-20 10:15:00'),
    (8, 4, 0.03, TIMESTAMP '2023-07-20 10:30:00');

-- Insert DUMMY data to use for WHEN NOT MATCHED BY SOURCE
INSERT INTO sensor_readings VALUES (0, 0, 0, TIMESTAMP '2023-07-20 10:15:00');

SET client_min_messages TO DEBUG1;
-- Complex merge query which needs repartitioning
MERGE INTO sensor_readings SR
USING (SELECT
rsr.sensor_id,
AVG(rsr.reading_value) AS average_reading,
MAX(rsr.reading_timestamp) AS last_reading_timestamp,
MAX(rsr.real_reading_id) AS rid
FROM sensors s
INNER JOIN machines m ON s.machine_id = m.machine_id
INNER JOIN real_sensor_readings rsr ON s.sensor_id = rsr.sensor_id
WHERE m.location = 'Production Floor 1'
GROUP BY rsr.sensor_id
) NEW_READINGS

ON (SR.sensor_id = NEW_READINGS.sensor_id)

-- Existing reading, update it
WHEN MATCHED THEN
UPDATE SET reading_value = NEW_READINGS.average_reading, reading_timestamp = NEW_READINGS.last_reading_timestamp

-- New reading, record it
WHEN NOT MATCHED BY TARGET THEN
INSERT (reading_id, sensor_id, reading_value, reading_timestamp)
VALUES (NEW_READINGS.rid,  NEW_READINGS.sensor_id,
NEW_READINGS.average_reading, NEW_READINGS.last_reading_timestamp)

-- Target has dummy entry not matched by source
-- dummy move change reading_value to 100 to notice the change
WHEN NOT MATCHED BY SOURCE THEN
UPDATE SET reading_value = 100;

RESET client_min_messages;

-- Expected output is:
--  reading_id | sensor_id |     reading_value      |  reading_timestamp
-- ------------+-----------+------------------------+---------------------
--           0 |         0 |                    100 | 2023-07-20 10:15:00
--           2 |         1 |    36.2000000000000000 | 2023-07-20 10:30:00
--           4 |         2 |   100.8500000000000000 | 2023-07-20 10:30:00
--           8 |         4 | 0.02500000000000000000 | 2023-07-20 10:30:00
SELECT * FROM sensor_readings ORDER BY 1;

-- End of MERGE ... WHEN NOT MATCHED BY SOURCE tests

-- Issue #7846: Test crash scenarios with MERGE on non-distributed and distributed tables
-- Step 1: Connect to a worker node to verify shard visibility
\c postgresql://postgres@localhost::worker_1_port/regression?application_name=psql
SET search_path TO pg17;

-- Step 2: Create and test a non-distributed table
CREATE TABLE non_dist_table_12345 (id INTEGER);

-- Test MERGE on the non-distributed table
MERGE INTO non_dist_table_12345 AS target_0
USING pg_catalog.pg_class AS ref_0
ON target_0.id = ref_0.relpages
WHEN NOT MATCHED THEN DO NOTHING;

-- Step 3: Switch back to the coordinator for distributed table operations
\c postgresql://postgres@localhost::master_port/regression?application_name=psql
SET search_path TO pg17;

-- Step 4: Create and test a distributed table
CREATE TABLE dist_table_67890 (id INTEGER);
SELECT create_distributed_table('dist_table_67890', 'id');

-- Test MERGE on the distributed table
MERGE INTO dist_table_67890 AS target_0
USING pg_catalog.pg_class AS ref_0
ON target_0.id = ref_0.relpages
WHEN NOT MATCHED THEN DO NOTHING;

\c - - - :master_port
-- End of Issue #7846

\set VERBOSITY terse
SET client_min_messages TO WARNING;
DROP SCHEMA pg17 CASCADE;
\set VERBOSITY default
RESET client_min_messages;

DROP ROLE regress_maintain;
DROP ROLE regress_no_maintain;
