CREATE TYPE color AS ENUM(
    'red',
    'green',
    'blue'
);

CREATE TABLE lights(
    light_id    SERIAL          NOT NULL PRIMARY KEY,
    light_uuid  UUID            NOT NULL,
    stamp       TIMESTAMPTZ(6)  NOT NULL DEFAULT NOW(),
    color       color           NOT NULL DEFAULT 'red'
);

CREATE TABLE aliases(
    alias_id    SERIAL  NOT NULL PRIMARY KEY,
    light_id    INTEGER NOT NULL REFERENCES lights(light_id),
    name        TEXT    NOT NULL
);

CREATE VIEW light_by_name AS
    SELECT a.name       AS name,
           a.alias_id   AS alias_id,
           l.light_id   AS light_id,
           l.light_uuid AS light_uuid,
           l.stamp      AS stamp,
           l.color      AS color
      FROM aliases AS a
      JOIN lights  AS l USING(light_id);

