-- Illustrative read-only VIEW to be created in the OpenG2P REGISTRY database.
-- It exposes ONLY the columns needed for the credential, keyed by phone number,
-- and limited to ACTIVE records. The plugin queries this view (never raw tables).
--
-- Notes:
--   * Alias columns to EXACTLY match the credential template's ${...} variables.
--     Postgres lowercases unquoted identifiers, so quote camelCase aliases.
--   * Format dates/timestamps as text here so the VC gets clean string values.
--   * Adjust source table/column names to your registry schema.

CREATE OR REPLACE VIEW beneficiary_vc_view AS
SELECT
    phone_number                          AS "phone",
    full_name                             AS "fullName",
    to_char(date_of_birth, 'YYYY-MM-DD')  AS "dateOfBirth",
    gender                                AS "gender",
    functional_id                         AS "functionalId"
FROM beneficiaries
WHERE status = 'active';

-- Least-privilege access for Certify:
-- CREATE USER certify_ro WITH PASSWORD '***';
-- GRANT USAGE ON SCHEMA public TO certify_ro;
-- GRANT SELECT ON beneficiary_vc_view TO certify_ro;
