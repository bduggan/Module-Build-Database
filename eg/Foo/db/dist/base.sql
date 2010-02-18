--
-- PostgreSQL database dump
--

SET statement_timeout = 0;
SET client_encoding = 'SQL_ASCII';
SET standard_conforming_strings = off;
SET check_function_bodies = false;
SET client_min_messages = warning;
SET escape_string_warning = off;

--
-- Name: doo; Type: SCHEMA; Schema: -; Owner: -
--



SET search_path = doo, pg_catalog;

SET default_tablespace = '';

SET default_with_oids = false;

--
-- Name: one; Type: TABLE; Schema: doo; Owner: -; Tablespace: 
--

CREATE TABLE one (
    x integer
);


--
-- Name: three; Type: TABLE; Schema: doo; Owner: -; Tablespace: 
--

CREATE TABLE three (
    foo integer,
    bar integer,
    baz character varying
);


--
-- Name: TABLE three; Type: COMMENT; Schema: doo; Owner: -
--

COMMENT ON TABLE three IS 'this is the THREE table';


--
-- Name: COLUMN three.bar; Type: COMMENT; Schema: doo; Owner: -
--

COMMENT ON COLUMN three.bar IS 'this is the three.bar field';


--
-- Name: COLUMN three.baz; Type: COMMENT; Schema: doo; Owner: -
--

COMMENT ON COLUMN three.baz IS 'this is the bas field';


--
-- Name: two; Type: TABLE; Schema: doo; Owner: -; Tablespace: 
--

CREATE TABLE two (
    y character varying(20)
);


--
-- PostgreSQL database dump complete
--

