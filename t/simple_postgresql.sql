CREATE TABLE simple(
    simple_id   INTEGER         NOT NULL PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    name        VARCHAR(128)    NOT NULL,
    uuid        UUID            DEFAULT NULL,
    added       TIMESTAMPTZ(6)  DEFAULT NOW(),

    UNIQUE(name),
    UNIQUE(uuid)
);
