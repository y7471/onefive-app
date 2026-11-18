-- 원파이브: 🔒 운영진 (운영진 코드 · 운영진 바로가기)
-- 새 Supabase 프로젝트 → SQL Editor 에 통째로 붙여 넣고 Run 을 누르세요. (다시 실행해도 괜찮아요)
--
--  · 로그인 대신 '운영진 코드'로 운영진을 구분해요. 코드는 그대로 저장하지 않고 암호화(해시)해서 저장해요.
--  · 대표 운영자(owner)는 앱에서 운영진을 임명(코드 발급)·해임할 수 있어요. 운영진(staff)은 바로가기만 보고 고칠 수 있어요.
--  · 코드를 계속 틀리면(10분 동안 10번) 그 접속 주소는 잠시 막혀요.
--  · 저장하는 개인정보: 운영진의 이름(별칭 권장)뿐이에요. 해임하면 바로 지워져요.
--
--  ⚠️ 맨 아래 '대표 운영자 정하기'의 코드를 꼭 바꿔서 실행하세요. 그 코드는 저(Claude)를 포함해 아무에게도 보내지 마세요.

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.of_admins (
  id bigint generated always as identity primary key,
  name text not null check (char_length(name) between 1 and 20),
  role text not null check (role in ('owner', 'staff')),
  code_hash text not null,
  created_at timestamptz not null default now()
);
create table if not exists public.of_links (
  id bigint generated always as identity primary key,
  label text not null check (char_length(label) between 1 and 30),
  url text not null check (url ~ '^https://' and char_length(url) <= 500),
  sort int not null default 0,
  updated_at timestamptz not null default now()
);
create table if not exists public.of_tries (ip text not null, at timestamptz not null default now());
create index if not exists of_tries_ip_at on public.of_tries (ip, at);

alter table public.of_admins enable row level security;
alter table public.of_links enable row level security;
alter table public.of_tries enable row level security;
revoke all on public.of_admins, public.of_links, public.of_tries from anon, authenticated;

-- 접속 주소 (코드를 계속 틀리는 것을 막는 데만 써요. 10분 뒤 지워져요)
create or replace function public.of__ip() returns text language sql stable set search_path = '' as $$
  select coalesce(nullif(btrim(split_part(coalesce(current_setting('request.headers', true)::json ->> 'x-forwarded-for', ''), ',', 1)), ''), 'unknown');
$$;

-- 코드 확인 → 운영진 한 줄 (틀리면 기록하고 빈 값)
-- ※ 오류를 내면(raise) 틀린 기록까지 같이 취소돼서, 틀렸을 때는 오류 대신 빈 값을 돌려줘요.
create or replace function public.of__auth(p_code text) returns public.of_admins
language plpgsql security definer set search_path = '' as $$
declare a public.of_admins; v_ip text := public.of__ip();
begin
  delete from public.of_tries where at < now() - interval '10 minutes';
  if (select count(*) from public.of_tries t where t.ip = v_ip) >= 10 then a.name := '__locked__'; return a; end if;
  select * into a from public.of_admins x
   where x.code_hash = extensions.crypt(coalesce(p_code, ''), x.code_hash) limit 1;
  if a.id is null then insert into public.of_tries (ip) values (v_ip); end if;
  return a;
end $$;
-- 확인 실패를 앱에 알려 줄 말
create or replace function public.of__deny(a public.of_admins) returns jsonb language sql immutable set search_path = '' as $$
  select case when a.name = '__locked__' then '{"error":"too many tries"}'::jsonb else '{"error":"bad code"}'::jsonb end;
$$;

-- 새 코드 만들기 (헷갈리는 글자 0·O·1·I·L 은 빼요) : 4-4 형식 예) K7PX-3MQA
create or replace function public.of__newcode() returns text language plpgsql set search_path = '' as $$
declare abc text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; b bytea := extensions.gen_random_bytes(8); s text := ''; i int;
begin
  for i in 0..7 loop s := s || substr(abc, 1 + (get_byte(b, i) % length(abc)), 1); if i = 3 then s := s || '-'; end if; end loop;
  return s;
end $$;

-- 들어가기: 이름과 역할
create or replace function public.of_login(p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a public.of_admins := public.of__auth(p_code);
begin
  if a.id is null then return public.of__deny(a); end if;
  return jsonb_build_object('name', a.name, 'role', a.role);
end $$;

-- 바로가기 보기
create or replace function public.of_links_get(p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a public.of_admins := public.of__auth(p_code);
begin
  if a.id is null then return public.of__deny(a); end if;
  return jsonb_build_object('links', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'label', l.label, 'url', l.url) order by l.sort, l.id) from public.of_links l), '[]'::jsonb));
end $$;

-- 바로가기 더하기·고치기 (p_id 가 없으면 새로 더해요)
create or replace function public.of_link_save(p_code text, p_id bigint, p_label text, p_url text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a public.of_admins := public.of__auth(p_code);
begin
  if a.id is null then return public.of__deny(a); end if;
  if coalesce(p_url, '') !~ '^https://[^[:space:]]+$' or char_length(p_url) > 500 then return '{"error":"bad url"}'; end if;
  if char_length(btrim(coalesce(p_label, ''))) not between 1 and 30 then return '{"error":"bad label"}'; end if;
  if p_id is null then
    if (select count(*) from public.of_links) >= 30 then return '{"error":"too many links"}'; end if;
    insert into public.of_links (label, url, sort) values (btrim(p_label), btrim(p_url), (select coalesce(max(sort), 0) + 1 from public.of_links));
  else
    update public.of_links set label = btrim(p_label), url = btrim(p_url), updated_at = now() where id = p_id;
  end if;
  return '{"ok":true}';
end $$;

create or replace function public.of_link_delete(p_code text, p_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a public.of_admins := public.of__auth(p_code);
begin
  if a.id is null then return public.of__deny(a); end if;
  delete from public.of_links where id = p_id; return '{"ok":true}';
end $$;

-- (대표) 운영진 명단
create or replace function public.of_staff_list(p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a public.of_admins := public.of__auth(p_code);
begin
  if a.id is null then return public.of__deny(a); end if;
  if a.role <> 'owner' then return '{"error":"owner only"}'; end if;
  return jsonb_build_object('staff', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name, 'role', x.role, 'at', x.created_at, 'me', x.id = a.id) order by (x.role = 'owner') desc, x.created_at) from public.of_admins x), '[]'::jsonb));
end $$;

-- (대표) 운영진 임명 → 새 코드를 한 번만 돌려줘요 (다시 볼 수 없어요)
create or replace function public.of_staff_add(p_code text, p_name text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a public.of_admins := public.of__auth(p_code); c text;
begin
  if a.id is null then return public.of__deny(a); end if;
  if a.role <> 'owner' then return '{"error":"owner only"}'; end if;
  if char_length(btrim(coalesce(p_name, ''))) not between 1 and 20 then return '{"error":"bad name"}'; end if;
  if (select count(*) from public.of_admins) >= 30 then return '{"error":"too many staff"}'; end if;
  c := public.of__newcode();
  insert into public.of_admins (name, role, code_hash) values (btrim(p_name), 'staff', extensions.crypt(c, extensions.gen_salt('bf')));
  return jsonb_build_object('code', c);
end $$;

-- (대표) 해임: 그 코드는 바로 못 써요 (이름도 함께 지워져요)
create or replace function public.of_staff_remove(p_code text, p_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a public.of_admins := public.of__auth(p_code);
begin
  if a.id is null then return public.of__deny(a); end if;
  if a.role <> 'owner' then return '{"error":"owner only"}'; end if;
  delete from public.of_admins where id = p_id and role = 'staff';
  return '{"ok":true}';
end $$;

-- (대표) 운영진 코드 다시 만들기 (잃어버렸거나 새어 나갔을 때) → 새 코드를 한 번만 돌려줘요
create or replace function public.of_staff_recode(p_code text, p_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a public.of_admins := public.of__auth(p_code); c text := public.of__newcode();
begin
  if a.id is null then return public.of__deny(a); end if;
  if a.role <> 'owner' then return '{"error":"owner only"}'; end if;
  update public.of_admins set code_hash = extensions.crypt(c, extensions.gen_salt('bf')) where id = p_id and role = 'staff';
  if not found then return '{"error":"no staff"}'; end if;
  return jsonb_build_object('code', c);
end $$;

-- 대표 운영자 정하기 (SQL Editor 에서만 실행돼요. 앱에서는 부를 수 없어요)
create or replace function public.of_set_owner(p_name text, p_code text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if char_length(coalesce(p_code, '')) < 8 then raise exception '대표 코드는 8글자 이상으로 정해 주세요'; end if;
  if p_code = '여기에-나만-아는-코드' then raise exception '맨 아래 대표 코드를 나만 아는 값으로 바꾼 뒤 다시 실행해 주세요'; end if;
  delete from public.of_admins where role = 'owner';
  insert into public.of_admins (name, role, code_hash) values (btrim(p_name), 'owner', extensions.crypt(p_code, extensions.gen_salt('bf')));
end $$;

-- 권한: 앱(anon)은 아래 함수만 부를 수 있어요
do $$ declare f text; begin
  foreach f in array array['of__ip()', 'of__auth(text)', 'of__deny(public.of_admins)', 'of__newcode()', 'of_set_owner(text,text)',
    'of_login(text)', 'of_links_get(text)', 'of_link_save(text,bigint,text,text)', 'of_link_delete(text,bigint)',
    'of_staff_list(text)', 'of_staff_add(text,text)', 'of_staff_remove(text,bigint)', 'of_staff_recode(text,bigint)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
  foreach f in array array['of_login(text)', 'of_links_get(text)', 'of_link_save(text,bigint,text,text)', 'of_link_delete(text,bigint)',
    'of_staff_list(text)', 'of_staff_add(text,text)', 'of_staff_remove(text,bigint)', 'of_staff_recode(text,bigint)'] loop
    execute format('grant execute on function public.%s to anon, authenticated', f);
  end loop;
end $$;

-- ───────────────────────────────────────────────
-- 👑 대표 운영자 정하기: 아래 두 값을 바꾸고 실행하세요.
--    · 이름: 앱에 보일 이름 (별칭도 좋아요)
--    · 코드: 8글자 이상, 나만 아는 값 (다른 비밀번호와 다르게). 이 코드는 아무에게도 보내지 마세요.
--    대표 코드를 잊어버리면 이 줄만 새 코드로 다시 실행하면 돼요.
select public.of_set_owner('대표 운영자', '여기에-나만-아는-코드');
