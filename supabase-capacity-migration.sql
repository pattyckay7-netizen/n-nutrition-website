-- N-NUTRITION appointment capacity migration
-- Safe to run on the existing appointments table. Does not delete or alter appointment records.
-- Enforces at most 3 appointments per date, including simultaneous submissions.
-- Exposes only daily booking counts to the public calendar; never exposes visitor details.

create or replace function public.enforce_three_appointments_per_day()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_count integer;
begin
  if new.appointment_date < current_date then
    raise exception using errcode = '22023', message = 'APPOINTMENT_DATE_IN_PAST';
  end if;

  -- Serialize inserts for the same date; the transaction lock releases automatically at commit/rollback.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('public.appointments:' || new.appointment_date::text, 0)
  );

  select count(*)::integer
    into current_count
    from public.appointments as a
   where a.appointment_date = new.appointment_date;

  if current_count >= 3 then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_DATE_FULL';
  end if;

  return new;
end;
$$;

drop trigger if exists appointments_limit_three_per_day on public.appointments;
create trigger appointments_limit_three_per_day
before insert on public.appointments
for each row execute function public.enforce_three_appointments_per_day();

-- This function returns dates and counts only, not names, phone numbers, or ID numbers.
create or replace function public.get_appointment_day_counts(
  p_start_date date,
  p_end_date date
)
returns table(appointment_date date, booking_count integer)
language sql
stable
security definer
set search_path = ''
as $$
  select a.appointment_date, count(*)::integer
    from public.appointments as a
   where a.appointment_date between p_start_date and p_end_date
   group by a.appointment_date
   order by a.appointment_date;
$$;

revoke all on function public.get_appointment_day_counts(date, date) from public;
grant execute on function public.get_appointment_day_counts(date, date) to anon, authenticated;

revoke all on function public.enforce_three_appointments_per_day() from public, anon, authenticated;

-- Refresh the API schema cache so the new RPC is immediately discoverable.
notify pgrst, 'reload schema';
