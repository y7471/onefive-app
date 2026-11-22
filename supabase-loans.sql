-- 원파이브: 📦 물품 대여 기록 (운영진만)
-- 새 Supabase 프로젝트 → SQL Editor 에 통째로 붙여 넣고 Run 을 누르세요. (다시 실행해도 괜찮아요)
-- ※ supabase-admin.sql (운영진) 을 먼저 실행했어야 해요.
--
--  · 어떤 부서의 누가, 어떤 물품을, 언제 가져갔는지 · 언제 반납했는지를 기록해요.
--  · 운영진 코드가 있어야만 보고, 쓰고, 고칠 수 있어요.
--  · 반납한 기록은 반납한 날부터 1년이 지나면 자동으로 지워져요. (빌려 간 사람 이름이 개인정보라서)

create table if not exists public.of_loans (
  id bigint generated always as identity primary key,
  dept text not null check (char_length(dept) between 1 and 30),      -- 부서
  who text not null check (char_length(who) between 1 and 20),        -- 가져간 사람
  item text not null check (char_length(item) between 1 and 80),     -- 물품
  out_date date not null,                                               -- 가져간 날
  due_date date,                                                        -- 반납 예정일 (선택)
  memo text check (char_length(memo) <= 200),                           -- 메모 (선택)
  returned_at date,                                                     -- 반납한 날 (없으면 대여 중)
  out_by text not null,                                                 -- 기록한 운영진
  returned_by text,                                                     -- 반납 확인한 운영진
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.of_loans enable row level security;
revoke all on public.of_loans from anon, authenticated;

-- 목록: 대여 중 먼저, 그다음 최근 반납 (반납 1년 지난 기록은 지워요)
create or replace function public.of_loans_get(p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a public.of_admins := public.of__auth(p_code);
begin
  if a.id is null then return public.of__deny(a); end if;
  delete from public.of_loans where returned_at is not null and returned_at < (now() at time zone 'Asia/Seoul')::date - 365;
  return jsonb_build_object('loans', coalesce((select jsonb_agg(jsonb_build_object(
      'id', l.id, 'dept', l.dept, 'who', l.who, 'item', l.item, 'out', l.out_date, 'due', l.due_date, 'memo', l.memo,
      'ret', l.returned_at, 'out_by', l.out_by, 'ret_by', l.returned_by)
    order by (l.returned_at is null) desc, coalesce(l.returned_at, l.out_date) desc, l.id desc)
    from (select * from public.of_loans order by (returned_at is null) desc, coalesce(returned_at, out_date) desc limit 300) l), '[]'::jsonb));
end $$;

-- 기록하기·고치기 (p_id 가 없으면 새로)
create or replace function public.of_loan_save(p_code text, p_id bigint, p_dept text, p_who text, p_item text, p_out date, p_due date, p_memo text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a public.of_admins := public.of__auth(p_code);
begin
  if a.id is null then return public.of__deny(a); end if;
  if char_length(btrim(coalesce(p_dept, ''))) not between 1 and 30 then return '{"error":"bad dept"}'; end if;
  if char_length(btrim(coalesce(p_who, ''))) not between 1 and 20 then return '{"error":"bad who"}'; end if;
  if char_length(btrim(coalesce(p_item, ''))) not between 1 and 80 then return '{"error":"bad item"}'; end if;
  if p_out is null then return '{"error":"bad date"}'; end if;
  if p_due is not null and p_due < p_out then return '{"error":"bad due"}'; end if;
  if char_length(coalesce(p_memo, '')) > 200 then return '{"error":"bad memo"}'; end if;
  if p_id is null then
    if (select count(*) from public.of_loans where returned_at is null) >= 500 then return '{"error":"too many"}'; end if;
    insert into public.of_loans (dept, who, item, out_date, due_date, memo, out_by)
    values (btrim(p_dept), btrim(p_who), btrim(p_item), p_out, p_due, nullif(btrim(coalesce(p_memo, '')), ''), a.name);
  else
    update public.of_loans set dept = btrim(p_dept), who = btrim(p_who), item = btrim(p_item), out_date = p_out, due_date = p_due,
      memo = nullif(btrim(coalesce(p_memo, '')), ''), updated_at = now() where id = p_id;
  end if;
  return '{"ok":true}';
end $$;

-- 반납 확인 / 반납 취소
create or replace function public.of_loan_return(p_code text, p_id bigint, p_back boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a public.of_admins := public.of__auth(p_code);
begin
  if a.id is null then return public.of__deny(a); end if;
  if p_back then
    update public.of_loans set returned_at = (now() at time zone 'Asia/Seoul')::date, returned_by = a.name, updated_at = now() where id = p_id;
  else
    update public.of_loans set returned_at = null, returned_by = null, updated_at = now() where id = p_id;
  end if;
  return '{"ok":true}';
end $$;

-- 지우기 (잘못 적었을 때)
create or replace function public.of_loan_delete(p_code text, p_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a public.of_admins := public.of__auth(p_code);
begin
  if a.id is null then return public.of__deny(a); end if;
  delete from public.of_loans where id = p_id; return '{"ok":true}';
end $$;

revoke all on function public.of_loans_get(text) from public, anon, authenticated;
revoke all on function public.of_loan_save(text,bigint,text,text,text,date,date,text) from public, anon, authenticated;
revoke all on function public.of_loan_return(text,bigint,boolean) from public, anon, authenticated;
revoke all on function public.of_loan_delete(text,bigint) from public, anon, authenticated;
grant execute on function public.of_loans_get(text) to anon, authenticated;
grant execute on function public.of_loan_save(text,bigint,text,text,text,date,date,text) to anon, authenticated;
grant execute on function public.of_loan_return(text,bigint,boolean) to anon, authenticated;
grant execute on function public.of_loan_delete(text,bigint) to anon, authenticated;
