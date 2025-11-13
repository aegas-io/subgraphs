-- Initialize PostgreSQL for Graph Node
CREATE EXTENSION pg_trgm;
CREATE EXTENSION btree_gist;
CREATE EXTENSION postgres_fdw;
CREATE EXTENSION pg_stat_statements;
GRANT USAGE ON FOREIGN DATA WRAPPER postgres_fdw TO "graph-node";
