
SET statement_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SET check_function_bodies = false;
SET client_min_messages = warning;






CREATE VIEW person2 AS
    SELECT person.id, person.first_name, person.last_name FROM red.person;



