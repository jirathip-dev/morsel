-- Morsel: day-scoped tools bucket meal days, summaries, weight/energy day
-- totals, and streaks in the user's LOCAL day. profiles.timezone is the
-- stored IANA preference; a day-tool call's explicit timezone wins, then
-- this column, then UTC.
--
-- Nullable on purpose: NULL means "UTC as today" (v0.1 backward compatible),
-- and every existing profile row predates the zone concept.
alter table public.profiles
  add column if not exists timezone text;

-- IANA shape guard (authoritative IANA validation happens server-side with
-- Intl before any write): NULL/absent (default, means UTC), the fixed 'UTC'
-- alias, or an Area/Location name with at least one '/' separator whose
-- segments are letters/digits/'_'/'-'/'+' (e.g. Asia/Bangkok, Etc/GMT+7,
-- America/Argentina/Buenos_Aires).
alter table public.profiles
  add constraint profiles_timezone_check
  check (
    timezone is null
    or timezone = 'UTC'
    or timezone ~ '^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)+$'
  );
