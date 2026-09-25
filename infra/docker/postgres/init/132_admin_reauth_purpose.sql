-- Feature 132: ADMIN STEP-UP RE-AUTH — one new `verification_codes.purpose` value.
--
-- Ban, permanent delete, and a role change touching root/admin now require the acting admin to have
-- proved possession of their own phone in the last five minutes. That proof rides the ordinary OTP
-- machinery — same generation, same hashing, same brute-force cap, same expiry — under a purpose of
-- its own so an `admin_reauth` code can never be spent as a LOGIN and a login code can never be
-- spent as a step-up.
--
-- The column is a CHECK-constrained text, so a new value needs the constraint rebuilt. Idempotent:
-- the constraint is dropped by name (IF EXISTS) and re-added with the widened list, so a re-run is a
-- no-op and a fresh database gets the same shape as an upgraded one.

ALTER TABLE verification_codes DROP CONSTRAINT IF EXISTS verification_codes_purpose_check;

ALTER TABLE verification_codes
  ADD CONSTRAINT verification_codes_purpose_check
  CHECK (purpose IN ('login', 'signup', 'email_verify', 'phone_verify', 'admin_reauth'));
