CREATE TABLE example(
    id      INTEGER         NOT NULL PRIMARY KEY AUTOINCREMENT,
    name    VARCHAR(128)    NOT NULL,
    UNIQUE(name)
);
