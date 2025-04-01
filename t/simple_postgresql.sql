CREATE TABLE simple(
    simple_id   INTEGER         NOT NULL PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    name        VARCHAR(128)    NOT NULL,
    uuid        UUID            DEFAULT NULL,
    data        JSONB           DEFAULT NULL,
    added       TIMESTAMPTZ(6)  DEFAULT NOW(),
    skip        INTEGER         DEFAULT NULL,

    UNIQUE(name),
    UNIQUE(uuid)
);

CREATE TABLE simple2(
    simple2_id   INTEGER         NOT NULL PRIMARY KEY
);
