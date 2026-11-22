-- 원파이브: ✅ 출석부 (운영진만)
-- 새 Supabase 프로젝트 → SQL Editor 에 통째로 붙여 넣고 Run 을 누르세요. (다시 실행해도 괜찮아요)
-- ※ supabase-admin.sql (운영진) 을 먼저 실행했어야 해요.
--
--  · 운영진이 단원 이름을 등록하고, 매주 일요일(주일)마다 출석·결석을 체크해요.
--  · 출석률 = 출석 ÷ (출석 + 결석). 체크하지 않은 주일은 계산에서 빠져요.
--  · 단원을 지우면 그 사람의 출석 기록도 함께 지워져요. (쉬는 단원은 '쉼'으로 숨길 수 있어요)

create table if not exists public.of_att_members (
  id bigint generated always as identity primary key,
  name text not null check (char_length(name) between 1 and 20),
  note text check (char_length(note) <= 30),            -- 부서·역할 등 (선택)
  active boolean not null default true,                  -- false 면 '쉼' (출석 체크 목록에서 숨김)
  created_at timestamptz not null default now()
);
create table if not exists public.of_att (
  member_id bigint not null references public.of_att_members(id) on delete cascade,
  d date not null check (extract(dow from d) = 0),       -- 일요일만
  present boolean not null,
  by_name text,
  updated_at timestamptz not null default now(),
  primary key (member_id, d)
);
create index if not exists of_att_d on public.of_att (d);
alter table public.of_att_members enable row level security;
alter table public.of_att enable row level security;
revoke all on public.of_att_members, public.of_att from anon, authenticated;

-- 단원 목록
create or replace function public.of_att_members(p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a public.of_admins := public.of__auth(p_code);
begin
  if a.id is null then return public.of__deny(a); end if;
  return jsonb_build_object('members', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'name', m.name, 'note', m.note, 'active', m.active)
    order by m.active desc, m.name) from public.of_att_members m), '[]'::jsonb));
end $$;

-- 단원 등록·고치기 (p_id 가 없으면 새로)
create or replace function public.of_att_member_save(p_code text, p_id bigint, p_name text, p_note text, p_active boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a public.of_admins := public.of__auth(p_code);
begin
  if a.id is null then return public.of__deny(a); end if;
  if char_length(btrim(coalesce(p_name, ''))) not between 1 and 20 then return '{"error":"bad name"}'; end if;
  if char_length(coalesce(p_note, '')) > 30 then return '{"error":"bad note"}'; end if;
  if p_id is null then
    if (select count(*) from public.of_att_members) >= 300 then return '{"error":"too many"}'; end if;
    insert into public.of_att_members (name, note) values (btrim(p_name), nullif(btrim(coalesce(p_note, '')), ''));
  else
    update public.of_att_members set name = btrim(p_name), note = nullif(btrim(coalesce(p_note, '')), ''), active = coalesce(p_active, active) where id = p_id;
  end if;
  return '{"ok":true}';
end $$;

-- 단원 지우기 (출석 기록도 함께 지워져요)
create or replace function public.of_att_member_delete(p_code text, p_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a public.of_admins := public.of__auth(p_code);
begin
  if a.id is null then return public.of__deny(a); end if;
  delete from public.of_att_members where id = p_id; return '{"ok":true}';
end $$;

-- 그날(주일) 출석 체크 현황
create or replace function public.of_att_day(p_code text, p_d date) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a public.of_admins := public.of__auth(p_code);
begin
  if a.id is null then return public.of__deny(a); end if;
  return jsonb_build_object('marks', coalesce((select jsonb_object_agg(t.member_id::text, t.present) from public.of_att t where t.d = p_d), '{}'::jsonb),
    'days', coalesce((select jsonb_agg(x.d order by x.d desc) from (select distinct d from public.of_att where d > p_d - 120 and d <= p_d + 120) x), '[]'::jsonb));
end $$;

-- 체크하기: p_present = true(출석) / false(결석) / null(체크 지우기). p_ids 가 여러 명이면 한꺼번에
create or replace function public.of_att_mark(p_code text, p_d date, p_ids bigint[], p_present boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a public.of_admins := public.of__auth(p_code);
begin
  if a.id is null then return public.of__deny(a); end if;
  if p_d is null or extract(dow from p_d) <> 0 then return '{"error":"not sunday"}'; end if;
  if p_d > (now() at time zone 'Asia/Seoul')::date + 6 then return '{"error":"future"}'; end if;
  if p_present is null then
    delete from public.of_att where d = p_d and member_id = any(p_ids);
  else
    insert into public.of_att (member_id, d, present, by_name)
      select m.id, p_d, p_present, a.name from public.of_att_members m where m.id = any(p_ids)
    on conflict (member_id, d) do update set present = excluded.present, by_name = excluded.by_name, updated_at = now();
  end if;
  return '{"ok":true}';
end $$;

-- 출석률: 기간(p_from ~ p_to) 동안 단원별 출석·결석 수
create or replace function public.of_att_stats(p_code text, p_from date, p_to date) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a public.of_admins := public.of__auth(p_code);
begin
  if a.id is null then return public.of__deny(a); end if;
  return jsonb_build_object(
    'days', (select count(distinct d) from public.of_att where d between p_from and p_to),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'name', m.name, 'note', m.note, 'active', m.active, 'p', s.p, 'a', s.a) order by m.name)
      from public.of_att_members m
      join (select member_id, count(*) filter (where present) p, count(*) filter (where not present) a
              from public.of_att where d between p_from and p_to group by member_id) s on s.member_id = m.id), '[]'::jsonb));
end $$;

do $$ declare f text; begin
  foreach f in array array['of_att_members(text)', 'of_att_member_save(text,bigint,text,text,boolean)', 'of_att_member_delete(text,bigint)',
    'of_att_day(text,date)', 'of_att_mark(text,date,bigint[],boolean)', 'of_att_stats(text,date,date)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to anon, authenticated', f);
  end loop;
end $$;
