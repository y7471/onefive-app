-- 원파이브: 🎮 온라인 게임방 (각자 폰으로 같이 하기) — 마피아·라이어·OX·왕좌 카드·말씀 암호·익명 질문
-- 새 Supabase 프로젝트 → SQL Editor 에 통째로 붙여 넣고 Run 을 누르세요. (다시 실행해도 괜찮아요)
-- 로그인은 쓰지 않아요. 게임방은 폰마다 만든 임시 번호(토큰)로만 구분하고, 끝난 방은 자동으로 지워져요.

-- 원파이브: 온라인 게임방 (각자 폰으로 같이 하기)
-- Supabase → SQL Editor 에 통째로 붙여 넣고 Run 을 누르세요. (한 번만 하면 돼요. 다시 실행해도 괜찮아요)
-- 가입하지 않아도 닉네임만으로 들어올 수 있어요. 폰마다 무작위 '열쇠(token)'를 만들어 그걸로 본인을 구분해요.
-- 마피아·라이어의 비밀(역할·제시어)은 서버에서 나누고, 각자에게 자기 것만 보내요. 표는 아무도 직접 볼 수 없어요.

-- 1) 표 -------------------------------------------------------------------
create table if not exists public.gr_rooms (
  code text primary key,                              -- 입장 코드 4자리
  host int not null default 1,                        -- 방장 번호
  game text,                                          -- 'ox' | 'liar' | 'mafia' | null(대기실)
  phase text not null default 'lobby',
  step int not null default 0,
  opts jsonb not null default '{}',                   -- 게임 설정
  pub jsonb not null default '{}',                    -- 모두에게 보이는 정보
  sec jsonb not null default '{}',                    -- 서버만 아는 비밀 (정답·제시어·밤 선택)
  deadline timestamptz,
  ver int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists public.gr_players (
  code text not null references public.gr_rooms(code) on delete cascade,
  pid int not null,                                   -- 1번, 2번 … (입장 순서)
  token uuid not null,                                -- 폰마다 만든 열쇠 (절대 밖으로 안 내보내요)
  name text not null check (char_length(name) between 1 and 10),
  role text,
  priv jsonb not null default '{}',                   -- 나만 보는 정보
  alive boolean not null default true,
  score int not null default 0,
  act jsonb, act_at timestamptz,                      -- 이번 차례에 고른 것
  joined_at timestamptz not null default now(),
  seen_at timestamptz not null default now(),
  primary key (code, pid),
  unique (code, token)
);
alter table public.gr_rooms enable row level security;
alter table public.gr_players enable row level security;
revoke all on public.gr_rooms, public.gr_players from anon, authenticated;

-- 2) 내부 도우미 -----------------------------------------------------------
create or replace function public.gr__me(p_code text, p_token uuid) returns public.gr_players
language plpgsql security definer set search_path = '' as $$
declare r public.gr_players;
begin
  select * into r from public.gr_players where code = p_code and token = p_token;
  if not found then raise exception 'not in room'; end if;
  return r;
end $$;

create or replace function public.gr__name(p_name text) returns text
language plpgsql immutable as $$
declare n text := btrim(regexp_replace(coalesce(p_name, ''), '[[:cntrl:]<>]', '', 'g'));
begin
  if char_length(n) < 1 or char_length(n) > 10 then raise exception 'bad name'; end if;
  return n;
end $$;

-- 마피아 승패: 'cit' 시민 승 / 'maf' 마피아 승 / null 계속
create or replace function public.gr__mafia_win(p_code text) returns text
language plpgsql security definer set search_path = '' as $$
declare m int; o int; w text;
begin
  select count(*) filter (where role = 'maf'), count(*) filter (where role not in ('maf','mod'))
    into m, o from public.gr_players where code = p_code and alive and role is not null;
  if m = 0 then w := 'cit'; elsif m >= o then w := 'maf'; end if;
  if w is not null then
    update public.gr_rooms set phase = 'end', deadline = null, pub = pub || jsonb_build_object('winner', w) where code = p_code;
  end if;
  return w;
end $$;

-- 경찰 조사 결과를 모든 경찰 폰에 넣어요
create or replace function public.gr__police(p_code text, p_t int) returns void
language plpgsql security definer set search_path = '' as $$
declare d int; isMaf boolean;
begin
  select (pub->>'day')::int into d from public.gr_rooms where code = p_code;
  select role = 'maf' into isMaf from public.gr_players where code = p_code and pid = p_t;
  update public.gr_players set priv = jsonb_set(priv, '{checks}', coalesce(priv->'checks', '[]'::jsonb)
         || jsonb_build_array(jsonb_build_object('day', d, 'pid', p_t, 'maf', coalesce(isMaf, false))))
   where code = p_code and role = 'pol';
  update public.gr_rooms set sec = sec || jsonb_build_object('checked', p_t) where code = p_code;
end $$;

-- 오래된 방 청소: 마지막 활동 후 3시간 지난 방 (마니또 방은 14일) 을 지워요.
-- 방을 만들 때마다 실행되고, 매일 새벽 3시에 앱 서버(/api/cleanup)가 한 번 더 실행해요.
create or replace function public.gr_cleanup() returns int
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  delete from public.gr_rooms where (game is distinct from 'manito' and updated_at < now() - interval '3 hours')
                                 or updated_at < now() - interval '14 days';
  get diagnostics n = row_count;
  return n;
end $$;

-- 3) 방 만들기 · 들어가기 · 나가기 -----------------------------------------------
create or replace function public.gr_create(p_token uuid, p_name text) returns text
language plpgsql security definer set search_path = '' as $$
declare c text; n text := public.gr__name(p_name); tries int := 0;
begin
  if p_token is null then raise exception 'no token'; end if;
  perform public.gr_cleanup();   -- 오래된 방 청소
  if (select count(*) from public.gr_rooms) >= 800 then raise exception 'busy'; end if;
  loop
    c := (1000 + floor(random() * 9000))::int::text;
    exit when not exists (select 1 from public.gr_rooms where code = c);
    tries := tries + 1; if tries > 50 then raise exception 'busy'; end if;
  end loop;
  insert into public.gr_rooms (code) values (c);
  insert into public.gr_players (code, pid, token, name) values (c, 1, p_token, n);
  return c;
end $$;

create or replace function public.gr_join(p_code text, p_token uuid, p_name text) returns int
language plpgsql security definer set search_path = '' as $$
declare rm public.gr_rooms; n text := public.gr__name(p_name); p int;
begin
  select * into rm from public.gr_rooms where code = btrim(p_code) for update;
  if not found then raise exception 'no room'; end if;
  select pid into p from public.gr_players where code = rm.code and token = p_token;
  if found then   -- 다시 들어온 사람: 이름만 새로
    update public.gr_players set name = n, seen_at = now() where code = rm.code and pid = p;
  else
    if rm.phase <> 'lobby' then raise exception 'started'; end if;
    if (select count(*) from public.gr_players where code = rm.code) >= 16 then raise exception 'full'; end if;
    select min(g) into p from generate_series(1, 16) g where g not in (select pid from public.gr_players where code = rm.code);
    insert into public.gr_players (code, pid, token, name) values (rm.code, p, p_token, n);
  end if;
  update public.gr_rooms set ver = ver + 1, updated_at = now() where code = rm.code;
  return p;
end $$;

create or replace function public.gr_leave(p_code text, p_token uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare me public.gr_players := public.gr__me(p_code, p_token); h int;
begin
  delete from public.gr_players where code = p_code and pid = me.pid;
  select min(pid) into h from public.gr_players where code = p_code;
  if h is null then delete from public.gr_rooms where code = p_code; return; end if;
  update public.gr_rooms set host = case when host = me.pid then h else host end, ver = ver + 1, updated_at = now() where code = p_code;
end $$;

-- 4) 지금 상태 보기 (나에게 보여도 되는 것만) ------------------------------------
create or replace function public.gr_state(p_code text, p_token uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare me public.gr_players; rm public.gr_rooms; v_all boolean; v_maf boolean; v_mod boolean;
        pl jsonb; x jsonb := '{}'; st text; ar int; ac int; nh int;
begin
  me := public.gr__me(p_code, p_token);
  update public.gr_players set seen_at = now() where code = p_code and pid = me.pid;
  select * into rm from public.gr_rooms where code = p_code;
  -- 방장이 40초 넘게 안 보이면, 지금 접속해 있는 가장 앞 번호가 방장이 돼요 (진행자 모드 마피아 중에는 바꾸지 않아요)
  if rm.host <> me.pid and not (rm.game = 'mafia' and rm.phase <> 'lobby' and rm.opts->>'mode' = 'mod')
     and not exists (select 1 from public.gr_players where code = p_code and pid = rm.host and seen_at > now() - interval '40 seconds') then
    select min(pid) into nh from public.gr_players where code = p_code and seen_at > now() - interval '20 seconds';
    if nh is not null then update public.gr_rooms set host = nh, ver = ver + 1 where code = p_code returning * into rm; end if;
  end if;
  v_mod := rm.game = 'mafia' and me.role = 'mod';
  v_maf := rm.game = 'mafia' and me.role = 'maf';
  -- 모두 보기: 게임이 끝났을 때 · 진행자 · 마피아 게임에서 탈락한 사람(유령)
  v_all := rm.phase = 'end' or v_mod or (rm.game = 'mafia' and rm.phase <> 'lobby' and me.role is not null and not me.alive);
  select coalesce(jsonb_agg(jsonb_build_object(
           'pid', p.pid, 'name', p.name, 'alive', p.alive, 'score', p.score,
           'online', p.seen_at > now() - interval '20 seconds',
           'acted', rm.phase in ('q', 'vote') and p.act is not null,
           'role', case when p.pid = me.pid or v_all or (v_maf and p.role = 'maf')
                          or (rm.game = 'mafia' and p.role = 'mod')
                          or (rm.game = 'mafia' and not p.alive and rm.opts->>'reveal' = 'on') then p.role end
         ) order by p.pid), '[]') into pl
    from public.gr_players p where p.code = p_code;
  -- 마피아끼리는 밤에 서로 누구를 골랐는지 보여요
  if v_maf and rm.phase = 'night' then
    x := x || jsonb_build_object('picks', (select coalesce(jsonb_agg(jsonb_build_object('pid', pid, 't', act->'t') order by pid), '[]')
                                             from public.gr_players where code = p_code and role = 'maf' and alive and act is not null));
  end if;
  -- 진행자는 밤 선택과 투표 현황을 모두 봐요
  if v_mod then
    x := x || jsonb_build_object('sec', rm.sec);
    if rm.phase = 'vote' then
      x := x || jsonb_build_object('votes', (select coalesce(jsonb_object_agg(pid::text, act->'t'), '{}') from public.gr_players where code = p_code and act is not null));
    end if;
  end if;
  -- 진행자 없는 마피아: 방장 폰이 다음 단계로 넘어가도 되는지만 알려줘요 (누가 무엇을 골랐는지는 알려주지 않아요)
  if rm.game = 'mafia' and rm.opts->>'mode' = 'auto' and rm.phase = 'night' and me.pid = rm.host then
    st := case rm.step when 1 then 'maf' when 2 then 'doc' when 3 then 'pol' end;
    if st is null then
      x := x || jsonb_build_object('ready', now() >= rm.deadline);
    else
      select count(*), count(*) filter (where act is not null) into ar, ac
        from public.gr_players where code = p_code and alive and role = st;
      x := x || jsonb_build_object('ready', now() >= rm.deadline
            or (ar > 0 and ac >= case when st = 'maf' then ar else 1 end and now() >= (rm.pub->>'stepAt')::timestamptz + interval '3 seconds')
            or (ar = 0 and now() >= (rm.pub->>'stepAt')::timestamptz + interval '9 seconds'));
    end if;
  end if;
  return jsonb_build_object('code', rm.code, 'host', rm.host, 'game', rm.game, 'phase', rm.phase, 'step', rm.step,
    'opts', rm.opts, 'pub', rm.pub, 'deadline', rm.deadline, 'now', now(), 'ver', rm.ver,
    'me', jsonb_build_object('pid', me.pid, 'name', me.name, 'role', me.role, 'priv', me.priv, 'alive', me.alive, 'act', me.act, 'score', me.score),
    'players', pl, 'x', x);
end $$;

-- 5) 게임 시작 (방장만) ------------------------------------------------------------
create or replace function public.gr_start(p_code text, p_token uuid, p_game text, p_opts jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare me public.gr_players := public.gr__me(p_code, p_token); rm public.gr_rooms; n int; k int; w text; c text;
        v_mode text; v_maf int; v_pol int; v_doc int; v_talk int; o jsonb := coalesce(p_opts, '{}');
begin
  select * into rm from public.gr_rooms where code = p_code for update;
  if rm.host <> me.pid then raise exception 'host only'; end if;
  select count(*) into n from public.gr_players where code = p_code;
  if p_game = 'ox' then
    update public.gr_players set alive = true, score = 0, act = null, act_at = null, priv = '{}', role = null where code = p_code;
    update public.gr_rooms set game = 'ox', phase = 'intro', step = 0, pub = '{}', sec = '{}', deadline = null,
      opts = jsonb_build_object('total', least(greatest(coalesce((o->>'total')::int, 10), 3), 30),
                                'sec', least(greatest(coalesce((o->>'sec')::int, 15), 5), 60))
     where code = p_code;
  elsif p_game = 'liar' then
    if n < 3 then raise exception 'need 3'; end if;
    select left(btrim(x->>'w'), 30), left(btrim(x->>'c'), 20) into w, c
      from jsonb_array_elements(case when jsonb_typeof(o->'words') = 'array' then o->'words' else '[]' end) x
     where coalesce(btrim(x->>'w'), '') <> '' order by random() limit 1;
    if w is null then raise exception 'no words'; end if;
    k := least(greatest(coalesce((o->>'liars')::int, 1), 1), n - 2);
    v_talk := least(greatest(coalesce((o->>'talk')::int, 0), 0), 15);
    update public.gr_players set alive = true, score = 0, act = null, act_at = null, priv = '{}', role = 'cit' where code = p_code;
    with l as materialized (select pid from public.gr_players where code = p_code order by random() limit k)
    update public.gr_players p set role = 'liar' from l where p.code = p_code and p.pid = l.pid;
    update public.gr_players set priv = case when role = 'liar' then jsonb_build_object('cat', c) else jsonb_build_object('cat', c, 'word', w) end
     where code = p_code;
    update public.gr_rooms set game = 'liar', phase = 'talk', step = 0, sec = jsonb_build_object('word', w),
      opts = jsonb_build_object('liars', k, 'talk', v_talk),
      pub = jsonb_build_object('cat', c, 'first', (select pid from public.gr_players where code = p_code order by random() limit 1)),
      deadline = case when v_talk > 0 then now() + make_interval(mins => v_talk) end
     where code = p_code;
  elsif p_game = 'mafia' then
    v_mode := case when o->>'mode' = 'mod' then 'mod' else 'auto' end;
    if v_mode = 'mod' then n := n - 1; end if;
    v_maf := least(greatest(coalesce((o->>'maf')::int, 1), 1), 5);
    v_pol := least(greatest(coalesce((o->>'pol')::int, 0), 0), 3);
    v_doc := least(greatest(coalesce((o->>'doc')::int, 0), 0), 3);
    v_talk := least(greatest(coalesce((o->>'talk')::int, 3), 1), 15);
    if n < 4 then raise exception 'need 4'; end if;
    if v_maf * 2 >= n then raise exception 'too many mafia'; end if;
    if v_maf + v_pol + v_doc >= n then raise exception 'no citizen'; end if;
    update public.gr_players set alive = true, score = 0, act = null, act_at = null, priv = '{}', role = null where code = p_code;
    if v_mode = 'mod' then update public.gr_players set role = 'mod' where code = p_code and pid = me.pid; end if;
    with s as materialized (select pid, row_number() over (order by random()) rn from public.gr_players
                             where code = p_code and (v_mode <> 'mod' or pid <> me.pid))
    update public.gr_players p set role = case when s.rn <= v_maf then 'maf' when s.rn <= v_maf + v_pol then 'pol'
                                               when s.rn <= v_maf + v_pol + v_doc then 'doc' else 'cit' end
      from s where p.code = p_code and p.pid = s.pid;
    update public.gr_rooms set game = 'mafia', phase = 'roles', step = 0, sec = '{}', deadline = null,
      opts = jsonb_build_object('mode', v_mode, 'maf', v_maf, 'pol', v_pol, 'doc', v_doc, 'talk', v_talk,
                                'reveal', case when o->>'reveal' = 'on' then 'on' else 'off' end),
      pub = jsonb_build_object('day', 0, 'log', '[]'::jsonb)
     where code = p_code;
  elsif p_game = 'manito' then
    if n < 3 then raise exception 'need 3'; end if;
    update public.gr_players set alive = true, score = 0, act = null, act_at = null, priv = '{}', role = null where code = p_code;
    -- 무작위로 한 줄로 세운 뒤 다음 사람을 챙겨요 → 나 자신은 절대 안 뽑혀요
    with o as materialized (select pid, row_number() over (order by random()) rn from public.gr_players where code = p_code),
         m as (select a.pid, b.pid t from o a join o b on b.rn = case when a.rn = n then 1 else a.rn + 1 end)
    update public.gr_players p set priv = jsonb_build_object('target', m.t,
             'mission', case when jsonb_typeof(o->'missions') = 'array' and jsonb_array_length(o->'missions') > 0
                             then left(o->'missions'->>(floor(random() * jsonb_array_length(o->'missions')))::int, 80) end)
      from m where p.code = p_code and p.pid = m.pid;
    update public.gr_rooms set game = 'manito', phase = 'secret', step = 0, sec = '{}', deadline = null,
      opts = jsonb_build_object('until', left(coalesce(o->>'until', ''), 30)), pub = '{}'
     where code = p_code;
  elsif p_game = 'vote' then
    if jsonb_typeof(o->'items') <> 'array' or jsonb_array_length(o->'items') < 2 then raise exception 'need items'; end if;
    update public.gr_players set alive = true, act = null, act_at = null, priv = '{}', role = null where code = p_code;
    update public.gr_rooms set game = 'vote', phase = 'vote', step = 0, sec = '{}', deadline = null,
      opts = jsonb_build_object('title', left(coalesce(nullif(btrim(o->>'title'), ''), '투표'), 40), 'area', left(coalesce(o->>'area', ''), 30),
                                'items', (select jsonb_agg(left(btrim(x), 30)) from (select x from jsonb_array_elements_text(o->'items') x where btrim(x) <> '' limit 10) z)),
      pub = '{}'
     where code = p_code;
  else
    raise exception 'bad game';
  end if;
  update public.gr_rooms set ver = ver + 1, updated_at = now() where code = p_code;
end $$;

-- 6) 내 선택 (OX 답, 투표, 밤에 고르기, 라이어의 제시어 맞히기) -------------------------
create or replace function public.gr_act(p_code text, p_token uuid, p_act jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare me public.gr_players := public.gr__me(p_code, p_token); rm public.gr_rooms; t int; g text;
begin
  select * into rm from public.gr_rooms where code = p_code for update;
  t := case when jsonb_typeof(p_act->'t') = 'number' then (p_act->>'t')::int end;
  if rm.game = 'ox' and rm.phase = 'q' then
    if me.act is null and p_act->>'a' in ('O', 'X') and now() <= rm.deadline + interval '1 second' then
      update public.gr_players set act = jsonb_build_object('a', p_act->>'a'), act_at = clock_timestamp() where code = p_code and pid = me.pid;
    end if;
  elsif rm.game = 'liar' and rm.phase = 'vote' then
    if t <> me.pid and exists (select 1 from public.gr_players where code = p_code and pid = t) then
      update public.gr_players set act = jsonb_build_object('t', t), act_at = now() where code = p_code and pid = me.pid;
    end if;
  elsif rm.game = 'vote' and rm.phase = 'vote' then
    if t >= 0 and t < jsonb_array_length(rm.opts->'items') then
      update public.gr_players set act = jsonb_build_object('t', t), act_at = now() where code = p_code and pid = me.pid;
    end if;
  elsif rm.game = 'liar' and rm.phase = 'guess' then
    if me.pid = (rm.pub->>'top')::int and me.role = 'liar' then
      g := left(btrim(coalesce(p_act->>'guess', '')), 30);
      if g = '' then return; end if;
      update public.gr_rooms set phase = 'end', deadline = null,
        pub = pub || jsonb_build_object('guess', g, 'word', rm.sec->>'word',
              'winner', case when regexp_replace(lower(g), '\s', '', 'g') = regexp_replace(lower(rm.sec->>'word'), '\s', '', 'g') then 'liar' else 'cit' end)
       where code = p_code;
    end if;
  elsif rm.game = 'mafia' and me.alive and me.role is not null and me.role <> 'mod' then
    if rm.phase = 'vote' then
      if t = 0 or (t <> me.pid and exists (select 1 from public.gr_players where code = p_code and pid = t and alive and role <> 'mod')) then
        update public.gr_players set act = jsonb_build_object('t', t), act_at = now() where code = p_code and pid = me.pid;
      end if;
    elsif rm.phase = 'night' and rm.opts->>'mode' = 'auto'
          and exists (select 1 from public.gr_players where code = p_code and pid = t and alive and role <> 'mod') then
      if (rm.step = 1 and me.role = 'maf') or (rm.step = 2 and me.role = 'doc') then
        update public.gr_players set act = jsonb_build_object('t', t), act_at = now() where code = p_code and pid = me.pid;
      elsif rm.step = 3 and me.role = 'pol' and not (rm.sec ? 'checked') then
        perform public.gr__police(p_code, t);
        update public.gr_players set act = jsonb_build_object('t', t), act_at = now() where code = p_code and pid = me.pid;
      end if;
    end if;
  end if;
  update public.gr_rooms set ver = ver + 1, updated_at = now() where code = p_code;
end $$;

-- 7) 방장(진행자) 명령 ----------------------------------------------------------------
create or replace function public.gr_host(p_code text, p_token uuid, p_cmd text, p_arg jsonb default '{}') returns void
language plpgsql security definer set search_path = '' as $$
declare me public.gr_players := public.gr__me(p_code, p_token); rm public.gr_rooms; a jsonb := coalesce(p_arg, '{}');
        t int; n int; mx int; top int; v_kill int; v_save int; ns int; nm text; tj jsonb;
begin
  select * into rm from public.gr_rooms where code = p_code for update;
  if rm.host <> me.pid then raise exception 'host only'; end if;
  t := case when jsonb_typeof(a->'t') = 'number' then (a->>'t')::int end;

  if p_cmd = 'lobby' then
    update public.gr_players set act = null, act_at = null, role = null, priv = '{}', alive = true where code = p_code;
    update public.gr_rooms set game = null, phase = 'lobby', step = 0, pub = '{}', sec = '{}', deadline = null where code = p_code;
  elsif p_cmd = 'kick' then
    if rm.phase = 'lobby' and t <> me.pid then delete from public.gr_players where code = p_code and pid = t; end if;
  elsif p_cmd = 'addtime' then
    if rm.deadline is not null then update public.gr_rooms set deadline = greatest(deadline, now()) + interval '30 seconds' where code = p_code; end if;
  elsif p_cmd = 'endtime' then
    if rm.deadline is not null then update public.gr_rooms set deadline = now() where code = p_code; end if;

  -- OX 퀴즈
  elsif rm.game = 'ox' and p_cmd = 'q' and rm.phase in ('intro', 'ans') then
    if coalesce(a->>'a', '') not in ('O', 'X') then raise exception 'bad q'; end if;
    n := coalesce((rm.pub->>'n')::int, 0) + 1;
    update public.gr_players set act = null, act_at = null where code = p_code;
    update public.gr_rooms set phase = 'q', pub = jsonb_build_object('n', n, 'total', rm.opts->'total', 'q', left(a->>'q', 300)),
      sec = jsonb_build_object('a', a->>'a', 'r', left(a->>'r', 80)),
      deadline = now() + make_interval(secs => (rm.opts->>'sec')::int) where code = p_code;
  elsif rm.game = 'ox' and p_cmd = 'reveal' and rm.phase = 'q' then
    -- 맞힌 사람 100점 + 빨리 맞힌 순서대로 1등 +50, 2등 +30, 3등 +10
    with r as (select pid, (act->>'a') = (rm.sec->>'a') as ok,
                      row_number() over (partition by (act->>'a') = (rm.sec->>'a') order by act_at) rk
                 from public.gr_players where code = p_code and act is not null),
         g as (select pid, ok, rk, case when ok then 100 + case rk when 1 then 50 when 2 then 30 when 3 then 10 else 0 end else 0 end gain from r)
    update public.gr_players p set act = p.act || jsonb_build_object('ok', g.ok, 'gain', g.gain, 'rk', case when g.ok then g.rk end),
           score = p.score + g.gain
      from g where p.code = p_code and p.pid = g.pid;
    update public.gr_rooms set phase = 'ans', deadline = null,
      pub = pub || jsonb_build_object('a', rm.sec->>'a', 'r', rm.sec->>'r',
        'res', (select coalesce(jsonb_agg(jsonb_build_object('pid', pid, 'a', act->>'a', 'ok', act->'ok', 'gain', act->'gain', 'rk', act->'rk') order by pid), '[]')
                  from public.gr_players where code = p_code and act is not null))
     where code = p_code;
  elsif rm.game = 'ox' and p_cmd = 'final' and rm.phase in ('ans', 'intro') then
    update public.gr_rooms set phase = 'end', deadline = null where code = p_code;

  -- 라이어 게임
  elsif rm.game = 'liar' and p_cmd = 'vote' and rm.phase = 'talk' then
    update public.gr_players set act = null, act_at = null where code = p_code;
    update public.gr_rooms set phase = 'vote', deadline = null where code = p_code;
  elsif rm.game = 'liar' and p_cmd = 'reveal' and rm.phase = 'vote' then
    select coalesce(jsonb_object_agg(pid::text, (act->>'t')::int), '{}') into tj from public.gr_players where code = p_code and act is not null;
    select max(c) into mx from (select count(*) c from public.gr_players where code = p_code and act is not null group by act->>'t') z;
    select min(tt), count(*) into top, n from (select (act->>'t')::int tt from public.gr_players
       where code = p_code and act is not null group by act->>'t' having count(*) = mx) z;
    if n <> 1 then top := null; end if;
    update public.gr_rooms set pub = pub || jsonb_build_object('votes', tj, 'top', top,
        'liars', (select jsonb_agg(pid order by pid) from public.gr_players where code = p_code and role = 'liar'),
        'caught', coalesce((select role = 'liar' from public.gr_players where code = p_code and pid = top), false))
     where code = p_code returning * into rm;
    if (rm.pub->>'caught')::boolean then
      update public.gr_rooms set phase = 'guess', deadline = now() + interval '60 seconds' where code = p_code;
    else
      update public.gr_rooms set phase = 'end', deadline = null, pub = pub || jsonb_build_object('winner', 'liar', 'word', rm.sec->>'word') where code = p_code;
    end if;
  elsif rm.game = 'liar' and p_cmd = 'skipguess' and rm.phase = 'guess' then
    update public.gr_rooms set phase = 'end', deadline = null, pub = pub || jsonb_build_object('winner', 'cit', 'word', rm.sec->>'word') where code = p_code;

  -- 마니또 공개
  elsif rm.game = 'manito' and p_cmd = 'reveal' and rm.phase = 'secret' then
    update public.gr_rooms set phase = 'end',
      pub = jsonb_build_object('pairs', (select jsonb_agg(jsonb_build_object('pid', pid, 't', (priv->>'target')::int) order by pid) from public.gr_players where code = p_code))
     where code = p_code;
  -- 투표 마감
  elsif rm.game = 'vote' and p_cmd = 'close' and rm.phase = 'vote' then
    update public.gr_rooms set phase = 'end',
      pub = jsonb_build_object('counts', (select jsonb_agg(coalesce(c, 0) order by i)
              from generate_series(0, jsonb_array_length(rm.opts->'items') - 1) i
              left join (select (act->>'t')::int tt, count(*) c from public.gr_players where code = p_code and act is not null group by 1) z on z.tt = i),
              'voters', (select count(*) from public.gr_players where code = p_code and act is not null))
     where code = p_code;

  -- 마피아 게임
  elsif rm.game = 'mafia' and p_cmd = 'night' and rm.phase in ('roles', 'voted') then
    update public.gr_players set act = null, act_at = null where code = p_code;
    update public.gr_rooms set phase = 'night', step = 0, sec = '{}', deadline = now() + interval '7 seconds',
      pub = (pub - 'news' - 'vote') || jsonb_build_object('day', coalesce((pub->>'day')::int, 0) + 1, 'stepAt', now())
     where code = p_code;
  elsif rm.game = 'mafia' and p_cmd = 'pick' and rm.phase = 'night' and rm.opts->>'mode' = 'mod' then
    if t is not null and not exists (select 1 from public.gr_players where code = p_code and pid = t and alive and role <> 'mod') then
      raise exception 'bad target';
    end if;
    if rm.step = 1 then update public.gr_rooms set sec = sec || jsonb_build_object('kill', t) where code = p_code;
    elsif rm.step = 2 then update public.gr_rooms set sec = sec || jsonb_build_object('save', t) where code = p_code;
    elsif rm.step = 3 and t is not null and not (rm.sec ? 'checked') then perform public.gr__police(p_code, t);
    end if;
  elsif rm.game = 'mafia' and p_cmd = 'next' and rm.phase = 'night' then
    if rm.opts->>'mode' = 'auto' then
      if rm.step = 1 then   -- 마피아가 가장 많이 고른 사람 (같으면 마지막에 고른 사람)
        select (act->>'t')::int into v_kill from public.gr_players where code = p_code and role = 'maf' and alive and act is not null
         group by act->>'t' order by count(*) desc, max(act_at) desc limit 1;
        update public.gr_rooms set sec = sec || jsonb_build_object('kill', v_kill) where code = p_code;
      elsif rm.step = 2 then
        select (act->>'t')::int into v_save from public.gr_players where code = p_code and role = 'doc' and alive and act is not null
         order by act_at desc limit 1;
        update public.gr_rooms set sec = sec || jsonb_build_object('save', v_save) where code = p_code;
      end if;
    end if;
    ns := case when rm.step = 0 then 1
               when rm.step = 1 and (rm.opts->>'doc')::int > 0 then 2
               when rm.step <= 2 and (rm.opts->>'pol')::int > 0 then 3
               else 9 end;
    update public.gr_players set act = null, act_at = null where code = p_code;
    if ns < 9 then
      update public.gr_rooms set step = ns, pub = pub || jsonb_build_object('stepAt', now()),
        deadline = now() + case ns when 1 then interval '40 seconds' else interval '25 seconds' end where code = p_code;
    else
      -- 아침: 밤 결과 정리
      select * into rm from public.gr_rooms where code = p_code;
      v_kill := (rm.sec->>'kill')::int; v_save := (rm.sec->>'save')::int;
      if v_kill is not null and v_kill is distinct from v_save
         and exists (select 1 from public.gr_players where code = p_code and pid = v_kill and alive) then
        update public.gr_players set alive = false, priv = priv || jsonb_build_object('dead', 'night', 'deadDay', rm.pub->'day')
         where code = p_code and pid = v_kill;
        nm := 'kill';
      elsif v_kill is not null then nm := 'saved';
      else nm := 'none'; end if;
      update public.gr_rooms set phase = 'day', step = 0, deadline = now() + make_interval(mins => (opts->>'talk')::int),
        pub = pub || jsonb_build_object('news', jsonb_build_object('k', nm, 'pid', case when nm = 'kill' then v_kill end),
                                        'log', coalesce(pub->'log', '[]') || jsonb_build_array(jsonb_build_object('day', pub->'day', 'k', nm, 'pid', case when nm = 'kill' then v_kill end)))
       where code = p_code;
      perform public.gr__mafia_win(p_code);
    end if;
  elsif rm.game = 'mafia' and p_cmd = 'vote' and rm.phase = 'day' then
    update public.gr_players set act = null, act_at = null where code = p_code;
    update public.gr_rooms set phase = 'vote', deadline = null where code = p_code;
  elsif rm.game = 'mafia' and p_cmd = 'tally' and rm.phase = 'vote' then
    select coalesce(jsonb_object_agg(pid::text, (act->>'t')::int), '{}') into tj
      from public.gr_players where code = p_code and alive and act is not null;
    select max(c) into mx from (select count(*) c from public.gr_players
       where code = p_code and alive and act is not null and (act->>'t')::int > 0 group by act->>'t') z;
    select min(tt), count(*) into top, n from (select (act->>'t')::int tt from public.gr_players
       where code = p_code and alive and act is not null and (act->>'t')::int > 0 group by act->>'t' having count(*) = mx) z;
    if n <> 1 then top := null; end if;
    if top is not null then
      update public.gr_players set alive = false, priv = priv || jsonb_build_object('dead', 'vote', 'deadDay', rm.pub->'day')
       where code = p_code and pid = top;
    end if;
    update public.gr_rooms set phase = 'voted', deadline = null,
      pub = pub || jsonb_build_object('vote', jsonb_build_object('out', top, 'votes', tj),
                                      'log', coalesce(pub->'log', '[]') || jsonb_build_array(jsonb_build_object('day', pub->'day', 'k', 'vote', 'pid', top)))
     where code = p_code;
    perform public.gr__mafia_win(p_code);
  end if;
  update public.gr_rooms set ver = ver + 1, updated_at = now() where code = p_code;
end $$;

-- 8) 사용 권한: 가입 안 한 사람(anon)도 게임방 함수만 쓸 수 있어요 ------------------------
do $$
declare f text;
begin
  foreach f in array array['gr__me(text,uuid)', 'gr__name(text)', 'gr__mafia_win(text)', 'gr__police(text,int)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
  foreach f in array array['gr_cleanup()', 'gr_create(uuid,text)', 'gr_join(text,uuid,text)', 'gr_leave(text,uuid)', 'gr_state(text,uuid)',
                           'gr_start(text,uuid,text,jsonb)', 'gr_act(text,uuid,jsonb)', 'gr_host(text,uuid,text,jsonb)'] loop
    execute format('revoke all on function public.%s from public', f);
    execute format('grant execute on function public.%s to anon, authenticated', f);
  end loop;
end $$;


-- 원파이브: 🎲 보드게임 (같이 접속해서 하기) — 1) 👑 왕좌 카드  2) 🗝️ 말씀 암호  3) 🎤 익명 질문
-- Supabase → SQL Editor 에 통째로 붙여 넣고 Run 을 누르세요. (다시 실행해도 괜찮아요)
-- supabase-games.sql(온라인 게임방)이 먼저 실행되어 있어야 해요. 같은 방(gr_rooms·gr_players)을 그대로 써요.
--
-- 👑 왕좌 카드 (신분이 바뀌는 카드 게임 · 우리가 직접 만든 이름과 규칙 설명)
--  · 카드: 숫자 1~12 (숫자 n은 n장, 모두 78장) + 와일드 2장(13). 숫자가 작을수록 센 카드예요.
--  · 앞사람과 같은 장수로, 더 작은 숫자를 내요. 못 내거나 안 내면 패스. 모두 패스하면 마지막에 낸 사람이 새로 시작해요.
--  · 와일드는 다른 숫자와 함께 내면 그 숫자가 되고, 혼자 내면 13이에요.
--  · 손패를 먼저 다 털수록 높은 신분: 👑 왕 → 🎩 재상 → 🙂 시민 → 🧹 하인 → 🧺 농부
--  · 다음 판 세금: 농부는 가장 좋은 카드 2장을 왕에게, 하인은 1장을 재상에게 (자동). 왕·재상은 원하는 카드를 같은 수만큼 돌려줘요.
--  · 혁명: 카드를 나눴을 때 와일드 2장을 다 가진 사람은 혁명을 외칠 수 있어요 → 이번 판 세금 없음. 농부가 외치면 대혁명: 신분이 거꾸로!
--  · 점수: 판마다 먼저 턴 순서대로 (사람 수 - 1)점부터 0점까지. 정한 판 수가 끝나면 점수 1등이 우승.

-- 도우미: 손패(정렬된 숫자 배열)에서 카드 빼기. 없는 카드가 있으면 null
create or replace function public.kg__take(hand jsonb, cards jsonb) returns jsonb
language plpgsql immutable as $$
declare h int[] := array(select x::int from jsonb_array_elements_text(hand) x); c int; i int;
begin
  for c in select x::int from jsonb_array_elements_text(cards) x loop
    i := array_position(h, c);
    if i is null then return null; end if;
    h := h[1:i-1] || h[i+1:];
  end loop;
  return coalesce((select jsonb_agg(v order by v) from unnest(h) v), '[]'::jsonb);
end $$;

-- 도우미: 자리 순서에서 p 다음, 아직 카드가 있는 사람
create or replace function public.kg__next(p_code text, p_pid int) returns int
language plpgsql stable security definer set search_path = '' as $$
declare rm public.gr_rooms; ord int[]; n int; i int; k int; q int;
begin
  select * into rm from public.gr_rooms where code = p_code;
  ord := array(select x::int from jsonb_array_elements_text(rm.pub->'order') x);
  n := array_length(ord, 1); i := coalesce(array_position(ord, p_pid), 0);
  for k in 1..n loop
    q := ord[((i - 1 + k) % n) + 1];
    if q <> p_pid and coalesce((rm.pub->'counts'->>q::text)::int, 0) > 0
       and exists (select 1 from public.gr_players where code = p_code and pid = q) then return q; end if;
  end loop;
  return null;
end $$;

-- 판 끝 확인: 카드가 남은 사람이 1명 이하면 판을 마쳐요
create or replace function public.kg__check_end(p_code text) returns boolean
language plpgsql security definer set search_path = '' as $$
declare rm public.gr_rooms; act int[]; outs jsonb; n int; sc jsonb; pos int; p int;
begin
  select * into rm from public.gr_rooms where code = p_code;
  act := array(select x::int from jsonb_array_elements_text(rm.pub->'order') x
               where coalesce((rm.pub->'counts'->>x)::int, 0) > 0
                 and exists (select 1 from public.gr_players where code = p_code and pid = x::int));
  if coalesce(array_length(act, 1), 0) > 1 then return false; end if;
  outs := rm.pub->'out';
  if coalesce(array_length(act, 1), 0) = 1 then outs := outs || to_jsonb(act[1]); end if;
  -- 나간 사람(방을 떠난 사람)은 맨 뒤로
  outs := outs || coalesce((select jsonb_agg(x::int) from jsonb_array_elements_text(rm.pub->'order') x where not (outs @> to_jsonb(x::int))), '[]'::jsonb);
  n := jsonb_array_length(outs); sc := coalesce(rm.pub->'scores', '{}');
  pos := 0;
  for p in select x::int from jsonb_array_elements_text(outs) x loop
    pos := pos + 1;
    sc := jsonb_set(sc, array[p::text], to_jsonb(coalesce((sc->>p::text)::int, 0) + (n - pos)));
  end loop;
  update public.gr_players g set score = coalesce((sc->>g.pid::text)::int, 0) where g.code = p_code;
  update public.gr_rooms set phase = case when (pub->>'round')::int >= (opts->>'rounds')::int then 'end' else 'roundend' end,
    pub = pub || jsonb_build_object('out', outs, 'ranks', outs, 'scores', sc, 'turn', null, 'last', null), deadline = null
   where code = p_code;
  return true;
end $$;

-- 카드 나누기 → (혁명 확인) → (세금) → 시작
create or replace function public.kg__deal(p_code text) returns void
language plpgsql security definer set search_path = '' as $$
declare rm public.gr_rooms; ord int[]; n int; deck int[] := '{}'; v int; i int; hands jsonb := '{}'; cnts jsonb := '{}'; revp int; p int;
begin
  select * into rm from public.gr_rooms where code = p_code;
  -- 지금 방에 있는 사람만, 지난 판 순위(신분) 순서로 앉아요
  ord := array(select x::int from jsonb_array_elements_text(rm.pub->'ranks') x where exists (select 1 from public.gr_players where code = p_code and pid = x::int));
  n := array_length(ord, 1);
  for v in 1..12 loop for i in 1..v loop deck := deck || v; end loop; end loop;
  deck := deck || array[13, 13];
  deck := array(select d from unnest(deck) d order by random());
  -- 농부부터 돌려 나눠서, 남는 카드는 아래 신분이 받아요
  for i in 1..array_length(deck, 1) loop
    p := ord[n - ((i - 1) % n)];
    hands := jsonb_set(hands, array[p::text], coalesce(hands->p::text, '[]'::jsonb) || to_jsonb(deck[i]));
  end loop;
  foreach p in array ord loop
    update public.gr_players set priv = jsonb_build_object('hand', (select jsonb_agg(x::int order by x::int) from jsonb_array_elements_text(hands->p::text) x)), act = null
     where code = p_code and pid = p;
    cnts := cnts || jsonb_build_object(p::text, jsonb_array_length(hands->p::text));
  end loop;
  update public.gr_rooms set pub = pub || jsonb_build_object('order', to_jsonb(ord), 'counts', cnts, 'out', '[]'::jsonb, 'last', null,
         'passes', '[]'::jsonb, 'log', '[]'::jsonb, 'rev', null, 'tax', null, 'turn', null), step = step + 1, deadline = null
   where code = p_code;
  -- 혁명: 와일드 2장을 다 가진 사람 (첫 판은 세금이 없어서 묻지 않아요)
  select g.pid into revp from public.gr_players g where g.code = p_code and (select count(*) from jsonb_array_elements_text(g.priv->'hand') x where x = '13') = 2;
  if revp is not null and (rm.pub->>'round')::int > 1 and coalesce((rm.opts->>'tax')::boolean, true) and coalesce((rm.opts->>'rev')::boolean, true) then
    update public.gr_rooms set phase = 'rev', pub = pub || jsonb_build_object('revp', revp) where code = p_code;
  else
    perform public.kg__tax(p_code, false);
  end if;
end $$;

-- 세금 걷기 (혁명이면 건너뛰어요)
create or replace function public.kg__tax(p_code text, p_skip boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare rm public.gr_rooms; ord int[]; n int; pairs jsonb := '[]'; hi int; lo int; k int; best jsonb; hh jsonb; j int; waits jsonb := '[]';
begin
  select * into rm from public.gr_rooms where code = p_code;
  ord := array(select x::int from jsonb_array_elements_text(rm.pub->'order') x); n := array_length(ord, 1);
  if not p_skip and (rm.pub->>'round')::int > 1 and coalesce((rm.opts->>'tax')::boolean, true) and n >= 3 then
    pairs := jsonb_build_array(jsonb_build_array(ord[1], ord[n], 2));
    if n >= 4 then pairs := pairs || jsonb_build_array(jsonb_build_array(ord[2], ord[n - 1], 1)); end if;
    for j in 0..jsonb_array_length(pairs) - 1 loop
      hi := (pairs->j->>0)::int; lo := (pairs->j->>1)::int; k := (pairs->j->>2)::int;
      select priv->'hand' into hh from public.gr_players where code = p_code and pid = lo;
      -- 가장 좋은 카드(작은 숫자, 와일드 제외) k장
      select jsonb_agg(x order by x) into best from (select x::int x from jsonb_array_elements_text(hh) x where x::int < 13 order by x::int limit k) z;
      if best is null then continue; end if;
      update public.gr_players set priv = priv || jsonb_build_object('hand', public.kg__take(priv->'hand', best), 'taxout', best, 'taxto', hi) where code = p_code and pid = lo;
      update public.gr_players set priv = priv || jsonb_build_object('hand', (select jsonb_agg(x::int order by x::int) from jsonb_array_elements_text((priv->'hand') || best) x),
                                     'taxin', best, 'taxfrom', lo, 'give', jsonb_array_length(best), 'giveto', lo)
       where code = p_code and pid = hi;
      waits := waits || to_jsonb(hi);
    end loop;
  end if;
  if jsonb_array_length(waits) > 0 then
    update public.gr_rooms set phase = 'tax', pub = pub || jsonb_build_object('tax', pairs, 'taxwait', waits) where code = p_code;
  else
    update public.gr_rooms set phase = 'play', pub = pub || jsonb_build_object('turn', ord[1], 'lead', ord[1]) where code = p_code;
  end if;
end $$;

-- 🗝️ 말씀 암호 (두 팀 단어 맞히기 · 성경 단어판 · 우리가 직접 만든 이름과 규칙 설명)
--  · 성경 단어 25개. 🔴팀 / 🔵팀 단어, 중립 단어, 🌑 함정 1개가 숨어 있어요. 단어 지도는 팀마다 한 명인 🧭 안내자만 봐요.
--  · 안내자가 '힌트 한 단어 + 숫자'를 주면, 같은 팀 🔍 탐정들이 단어를 골라요. 숫자 + 1개까지 고를 수 있어요.
--  · 우리 팀 단어면 계속, 중립이나 상대 팀 단어면 차례가 넘어가요. 🌑 함정을 고르면 바로 져요.
--  · 우리 팀 단어를 먼저 다 찾으면 우승!
create or replace function public.cn__start(p_code text, p_opts jsonb, p_keep boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare rm public.gr_rooms; words jsonb; ws text[]; ps int[]; teams jsonb := '{}'; i int; first text; keymap text[]; lr int; lb int; n int;
begin
  select * into rm from public.gr_rooms where code = p_code;
  -- 단어: 방장이 보낸 목록에서 25개 (2~12자, 겹치지 않게)
  ws := array(select w from (select distinct left(btrim(x), 12) w from jsonb_array_elements_text(case when jsonb_typeof(p_opts->'words') = 'array' then p_opts->'words' else '[]' end) x
                             where char_length(btrim(x)) between 1 and 12) z order by random() limit 25);
  if coalesce(array_length(ws, 1), 0) < 25 then raise exception 'need 25 words'; end if;
  -- 팀: 무작위로 번갈아 (다시 섞기가 아니면 지난 팀 유지)
  if p_keep and rm.pub ? 'teams' then teams := rm.pub->'teams';
  else
    ps := array(select pid from public.gr_players where code = p_code order by random());
    for i in 1..array_length(ps, 1) loop teams := teams || jsonb_build_object(ps[i]::text, case when i % 2 = 1 then 'r' else 'b' end); end loop;
  end if;
  -- 안내자: 팀마다 무작위 한 명
  select k::int into lr from jsonb_each_text(teams) t(k, v) where v = 'r' order by random() limit 1;
  select k::int into lb from jsonb_each_text(teams) t(k, v) where v = 'b' order by random() limit 1;
  first := case when random() < .5 then 'r' else 'b' end;
  keymap := array_fill('n'::text, array[25]);
  ps := array(select g from generate_series(1, 25) g order by random());
  for i in 1..9 loop keymap[ps[i]] := first; end loop;
  for i in 10..17 loop keymap[ps[i]] := case when first = 'r' then 'b' else 'r' end; end loop;
  keymap[ps[18]] := 'x';
  update public.gr_players set alive = true, act = null, act_at = null, role = null, priv = '{}' where code = p_code;
  update public.gr_players set priv = jsonb_build_object('leader', true, 'key', to_jsonb(keymap)) where code = p_code and pid in (lr, lb);
  update public.gr_rooms set game = 'code', phase = 'clue', step = 0, deadline = null, sec = jsonb_build_object('key', to_jsonb(keymap)),
    opts = jsonb_build_object('words', p_opts->'words'),
    pub = jsonb_build_object('words', to_jsonb(ws), 'open', to_jsonb(array_fill(null::text, array[25])), 'teams', teams,
          'leaders', jsonb_build_object('r', lr, 'b', lb), 'turn', first, 'first', first, 'clue', null, 'left', 0,
          'remain', jsonb_build_object('r', case when first = 'r' then 9 else 8 end, 'b', case when first = 'b' then 9 else 8 end),
          'log', '[]'::jsonb, 'winner', null)
   where code = p_code;
end $$;

create or replace function public.cn__act(p_code text, me public.gr_players, p_act jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare rm public.gr_rooms; a text := p_act->>'a'; myteam text; lead boolean; w text; nn int; i int; k text; other text; rem jsonb; win text; endturn boolean := false;
begin
  select * into rm from public.gr_rooms where code = p_code;
  myteam := rm.pub->'teams'->>me.pid::text; lead := coalesce((me.priv->>'leader')::boolean, false);
  other := case when rm.pub->>'turn' = 'r' then 'b' else 'r' end;
  if a = 'shuffle' then   -- 방장: 첫 힌트 전에는 팀을 다시 섞을 수 있어요
    if rm.host <> me.pid or rm.phase <> 'clue' or jsonb_array_length(rm.pub->'log') > 0 then return; end if;
    perform public.cn__start(p_code, rm.opts, false); return;
  end if;
  if rm.phase = 'clue' and a = 'clue' then
    if not lead or myteam <> rm.pub->>'turn' then return; end if;
    w := btrim(coalesce(p_act->>'w', '')); nn := coalesce((p_act->>'n')::int, -1);
    if w = '' or char_length(w) > 12 or w ~ '\s' then raise exception 'bad clue'; end if;
    if nn < 0 or nn > 9 then raise exception 'bad number'; end if;
    -- 판 위의 (아직 안 열린) 단어 그대로는 힌트로 못 써요
    if exists (select 1 from generate_series(0, 24) g where (rm.pub->'open'->>g) is null and lower(rm.pub->'words'->>g) = lower(w)) then raise exception 'clue on board'; end if;
    update public.gr_rooms set phase = 'guess', pub = pub || jsonb_build_object('clue', jsonb_build_object('w', w, 'n', nn, 'team', myteam),
           'left', case when nn = 0 then 25 else nn + 1 end,
           'log', jsonb_build_array(jsonb_build_object('t', myteam, 'clue', w, 'n', nn)) || (pub->'log'))
     where code = p_code;
  elsif rm.phase = 'guess' and a = 'pick' then
    if lead or myteam <> rm.pub->>'turn' then return; end if;
    i := (p_act->>'i')::int; if i is null or i < 0 or i > 24 or (rm.pub->'open'->>i) is not null then return; end if;
    k := rm.sec->'key'->>i; rem := rm.pub->'remain';
    if k in ('r', 'b') then rem := jsonb_set(rem, array[k], to_jsonb((rem->>k)::int - 1)); end if;
    if k = 'x' then win := other;
    elsif (rem->>myteam)::int = 0 then win := myteam;
    elsif (rem->>other)::int = 0 then win := other; end if;
    endturn := k <> myteam or (rm.pub->>'left')::int <= 1;
    update public.gr_rooms set pub = pub || jsonb_build_object(
        'open', jsonb_set(pub->'open', array[i::text], to_jsonb(k)), 'remain', rem,
        'left', (pub->>'left')::int - 1,
        'log', jsonb_build_array(jsonb_build_object('t', myteam, 'pid', me.pid, 'i', i, 'k', k)) || (pub->'log'))
     where code = p_code;
    if win is not null then
      update public.gr_rooms set phase = 'end', pub = pub || jsonb_build_object('winner', win, 'trap', k = 'x', 'key', sec->'key', 'clue', null) where code = p_code;
    elsif endturn then
      update public.gr_rooms set phase = 'clue', pub = pub || jsonb_build_object('turn', other, 'clue', null, 'left', 0) where code = p_code;
    end if;
  elsif rm.phase = 'guess' and a = 'stop' then
    if lead or myteam <> rm.pub->>'turn' then return; end if;
    update public.gr_rooms set phase = 'clue', pub = pub || jsonb_build_object('turn', other, 'clue', null, 'left', 0,
           'log', jsonb_build_array(jsonb_build_object('t', myteam, 'stop', true)) || (pub->'log')) where code = p_code;
  end if;
end $$;
revoke all on function public.cn__start(text, jsonb, boolean) from public, anon, authenticated;
revoke all on function public.cn__act(text, public.gr_players, jsonb) from public, anon, authenticated;

-- 🎤 익명 질문 (주인공 한 명에게 모두가 익명으로 질문 · 무작위 대표 질문에 말로 대답)
--  · 질문은 누가 썼는지 서버에도 남기지 않아요 (주인공·방장도 알 수 없어요). 질문 목록은 아무에게도 보이지 않고, 뽑힌 대표 질문만 보여요.
--  · 주인공은 불편한 질문을 '패스'할 수 있어요 → 바로 다른 질문이 뽑혀요.
--  · 한 사람이 주인공 한 명에게 보낼 수 있는 질문은 5개까지. 주인공이 바뀌면 질문 목록은 새로 시작해요.
create or replace function public.ak__start(p_code text, p_hot int) returns void
language plpgsql security definer set search_path = '' as $$
declare h int := p_hot; rd int;
begin
  if h is null or not exists (select 1 from public.gr_players where code = p_code and pid = h) then
    select pid into h from public.gr_players where code = p_code order by random() limit 1;
  end if;
  select coalesce((pub->>'round')::int, 0) + 1 into rd from public.gr_rooms where code = p_code;
  update public.gr_players set act = null, act_at = null, role = null, alive = true, priv = '{}' where code = p_code;
  update public.gr_rooms set game = 'ask', phase = 'ask', step = 0, deadline = null, sec = jsonb_build_object('pool', '[]'::jsonb),
    pub = jsonb_build_object('hot', h, 'cur', null, 'n', 0, 'answered', 0, 'passed', 0, 'round', rd, 'askers', 0)
   where code = p_code;
end $$;

create or replace function public.ak__pick(p_code text) returns void
language plpgsql security definer set search_path = '' as $$
declare rm public.gr_rooms; i int; n int; q text;
begin
  select * into rm from public.gr_rooms where code = p_code;
  n := jsonb_array_length(coalesce(rm.sec->'pool', '[]'));
  if n = 0 then update public.gr_rooms set pub = pub || jsonb_build_object('cur', null, 'n', 0) where code = p_code; return; end if;
  i := floor(random() * n)::int; q := rm.sec->'pool'->>i;
  update public.gr_rooms set sec = jsonb_set(sec, '{pool}', (sec->'pool') - i),
    pub = pub || jsonb_build_object('cur', q, 'n', n - 1, 'curAt', now()) where code = p_code;
end $$;

create or replace function public.ak__act(p_code text, me public.gr_players, p_act jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare rm public.gr_rooms; a text := p_act->>'a'; hot int; host boolean; t text; mine int; nh int;
begin
  select * into rm from public.gr_rooms where code = p_code;
  hot := (rm.pub->>'hot')::int; host := rm.host = me.pid;
  if rm.phase <> 'ask' then return; end if;
  if a = 'q' then                       -- 익명 질문 보내기 (주인공은 자기에게 못 보내요)
    if me.pid = hot then raise exception 'hot cannot ask'; end if;
    t := regexp_replace(btrim(coalesce(p_act->>'t', '')), '\s+', ' ', 'g');
    if char_length(t) < 2 or char_length(t) > 80 then raise exception 'bad question'; end if;
    mine := coalesce((me.priv->>'qn')::int, 0);
    if mine >= 5 then raise exception 'too many'; end if;
    update public.gr_players set priv = priv || jsonb_build_object('qn', mine + 1) where code = p_code and pid = me.pid;
    update public.gr_rooms set sec = jsonb_set(sec, '{pool}', coalesce(sec->'pool', '[]') || to_jsonb(t)),
      pub = pub || jsonb_build_object('n', jsonb_array_length(coalesce(sec->'pool', '[]')) + 1,
                                      'askers', (select count(*) from public.gr_players where code = p_code and coalesce((priv->>'qn')::int, 0) > 0))
     where code = p_code;
  elsif a = 'pick' then                 -- 다음 대표 질문 (주인공·방장)
    if not (host or me.pid = hot) then return; end if;
    if rm.pub->>'cur' is not null then update public.gr_rooms set pub = pub || jsonb_build_object('answered', (pub->>'answered')::int + 1) where code = p_code; end if;
    perform public.ak__pick(p_code);
  elsif a = 'pass' then                 -- 패스 (주인공만): 이 질문은 버리고 다른 질문으로
    if me.pid <> hot or rm.pub->>'cur' is null then return; end if;
    update public.gr_rooms set pub = pub || jsonb_build_object('passed', (pub->>'passed')::int + 1, 'cur', null) where code = p_code;
    perform public.ak__pick(p_code);
  elsif a = 'hot' then                  -- 주인공 바꾸기 (방장): 질문 목록은 새로 시작
    if not host then return; end if;
    nh := (p_act->>'pid')::int;
    if nh is null then select pid into nh from public.gr_players where code = p_code and pid <> hot order by random() limit 1; end if;
    perform public.ak__start(p_code, nh);
  elsif a = 'end' then
    if not host then return; end if;
    update public.gr_rooms set phase = 'end', sec = '{}' where code = p_code;
  end if;
end $$;
revoke all on function public.ak__start(text, int) from public, anon, authenticated;
revoke all on function public.ak__pick(text) from public, anon, authenticated;
revoke all on function public.ak__act(text, public.gr_players, jsonb) from public, anon, authenticated;

-- 게임 시작 (방장만)
create or replace function public.bg_start(p_code text, p_token uuid, p_game text, p_opts jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare me public.gr_players := public.gr__me(p_code, p_token); rm public.gr_rooms; n int; o jsonb := coalesce(p_opts, '{}'); ord jsonb;
begin
  select * into rm from public.gr_rooms where code = p_code for update;
  if rm.host <> me.pid then raise exception 'host only'; end if;
  if p_game not in ('king', 'code', 'ask') then raise exception 'unknown game'; end if;
  select count(*) into n from public.gr_players where code = p_code;
  if p_game = 'ask' then
    if n < 2 then raise exception 'need 2'; end if;
    perform public.ak__start(p_code, (o->>'hot')::int);
    update public.gr_rooms set ver = ver + 1, updated_at = now() where code = p_code;
    return;
  end if;
  if p_game = 'code' then
    if n < 4 then raise exception 'need 4'; end if;
    perform public.cn__start(p_code, o, false);
    update public.gr_rooms set ver = ver + 1, updated_at = now() where code = p_code;
    return;
  end if;
  if n < 3 then raise exception 'need 3'; end if;
  if n > 8 then raise exception 'max 8'; end if;
  select jsonb_agg(pid order by random()) into ord from public.gr_players where code = p_code;   -- 첫 판 신분은 무작위
  update public.gr_players set alive = true, score = 0, act = null, act_at = null, priv = '{}', role = null where code = p_code;
  update public.gr_rooms set game = 'king', phase = 'deal', step = 0, sec = '{}', deadline = null,
    opts = jsonb_build_object('rounds', least(greatest(coalesce((o->>'rounds')::int, 3), 1), 10),
                              'tax', coalesce((o->>'tax')::boolean, true), 'rev', coalesce((o->>'rev')::boolean, true)),
    pub = jsonb_build_object('round', 1, 'ranks', ord, 'scores', '{}'::jsonb)
   where code = p_code;
  perform public.kg__deal(p_code);
  update public.gr_rooms set ver = ver + 1, updated_at = now() where code = p_code;
end $$;

-- 행동: 카드 내기 · 패스 · 혁명 · 세금 돌려주기 · 다음 판(방장) · 건너뛰기(방장)
create or replace function public.bg_act(p_code text, p_token uuid, p_act jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare me public.gr_players := public.gr__me(p_code, p_token); rm public.gr_rooms; a text := p_act->>'a'; cards jsonb; nh jsonb;
        num int; cnt int; nw int; lst jsonb; nx int; passes jsonb; actv int; lead int; ord int[]; tgt int; waits jsonb; tp int; tm public.gr_players;
begin
  select * into rm from public.gr_rooms where code = p_code for update;
  if rm.game = 'code' then
    perform public.cn__act(p_code, me, p_act);
    update public.gr_rooms set ver = ver + 1, updated_at = now() where code = p_code;
    return;
  end if;
  if rm.game = 'ask' then
    perform public.ak__act(p_code, me, p_act);
    update public.gr_rooms set ver = ver + 1, updated_at = now() where code = p_code;
    return;
  end if;
  if rm.game <> 'king' then raise exception 'not king'; end if;

  -- 방장: 자리에 없는 사람 차례 건너뛰기
  if a = 'skip' then
    if rm.host <> me.pid or rm.phase <> 'play' then return; end if;
    tp := (rm.pub->>'turn')::int; select * into tm from public.gr_players where code = p_code and pid = tp;
    if tm.pid is null then  -- 방을 떠난 사람: 그냥 다음 사람으로
      update public.gr_rooms set pub = jsonb_set(pub, '{turn}', coalesce(to_jsonb(public.kg__next(p_code, tp)), 'null')), ver = ver + 1, updated_at = now() where code = p_code;
      return;
    end if;
    if rm.pub->'last' is null or jsonb_typeof(rm.pub->'last') = 'null' then
      -- 새로 시작할 차례면 가장 약한 카드 1장을 대신 내요
      p_act := jsonb_build_object('a', 'play', 'cards', jsonb_build_array((tm.priv->'hand'->-1)::int));
    else p_act := jsonb_build_object('a', 'pass'); end if;
    me := tm; a := p_act->>'a';
  end if;

  if a = 'next' then
    if rm.host <> me.pid or rm.phase <> 'roundend' then return; end if;
    update public.gr_rooms set pub = pub || jsonb_build_object('round', (pub->>'round')::int + 1) where code = p_code;
    perform public.kg__deal(p_code);

  elsif a = 'rev' then
    if rm.phase <> 'rev' or (rm.pub->>'revp')::int <> me.pid then return; end if;
    if coalesce((p_act->>'yes')::boolean, false) then
      ord := array(select x::int from jsonb_array_elements_text(rm.pub->'order') x);
      if ord[array_length(ord, 1)] = me.pid then   -- 대혁명: 신분이 거꾸로
        update public.gr_rooms set pub = pub || jsonb_build_object('order', (select jsonb_agg(v order by i desc) from unnest(ord) with ordinality t(v, i)), 'rev', 'big') where code = p_code;
      else
        update public.gr_rooms set pub = pub || jsonb_build_object('rev', 'small') where code = p_code;
      end if;
      perform public.kg__tax(p_code, true);
    else
      update public.gr_rooms set pub = pub || jsonb_build_object('rev', 'no') where code = p_code;
      perform public.kg__tax(p_code, false);
    end if;

  elsif a = 'give' then
    if rm.phase <> 'tax' or not (rm.pub->'taxwait' @> to_jsonb(me.pid)) then return; end if;
    cards := p_act->'cards';
    if jsonb_typeof(cards) <> 'array' or jsonb_array_length(cards) <> (me.priv->>'give')::int then raise exception 'bad give'; end if;
    nh := public.kg__take(me.priv->'hand', cards); if nh is null then raise exception 'bad cards'; end if;
    tgt := (me.priv->>'giveto')::int;
    update public.gr_players set priv = (priv - 'give') || jsonb_build_object('hand', nh, 'gave', cards) where code = p_code and pid = me.pid;
    update public.gr_players set priv = priv || jsonb_build_object('hand', (select jsonb_agg(x::int order by x::int) from jsonb_array_elements_text((priv->'hand') || cards) x), 'backin', cards)
     where code = p_code and pid = tgt;
    waits := (select coalesce(jsonb_agg(x), '[]'::jsonb) from jsonb_array_elements(rm.pub->'taxwait') x where x <> to_jsonb(me.pid));
    ord := array(select x::int from jsonb_array_elements_text(rm.pub->'order') x);
    if jsonb_array_length(waits) = 0 then
      update public.gr_rooms set phase = 'play', pub = pub || jsonb_build_object('taxwait', waits, 'turn', ord[1], 'lead', ord[1]) where code = p_code;
    else
      update public.gr_rooms set pub = pub || jsonb_build_object('taxwait', waits) where code = p_code;
    end if;

  elsif a = 'play' then
    if rm.phase <> 'play' or (rm.pub->>'turn')::int <> me.pid then return; end if;
    cards := p_act->'cards';
    if jsonb_typeof(cards) <> 'array' or jsonb_array_length(cards) < 1 then raise exception 'bad cards'; end if;
    nh := public.kg__take(me.priv->'hand', cards); if nh is null then raise exception 'bad cards'; end if;
    select count(distinct x::int) filter (where x::int < 13), max(x::int) filter (where x::int < 13) into nw, num from jsonb_array_elements_text(cards) x;
    if nw > 1 then raise exception 'mixed'; end if;
    if num is null then num := 13; end if;
    cnt := jsonb_array_length(cards); lst := rm.pub->'last';
    if lst is not null and jsonb_typeof(lst) <> 'null' then
      if cnt <> (lst->>'cnt')::int or num >= (lst->>'num')::int then raise exception 'too weak'; end if;
    end if;
    update public.gr_players set priv = priv || jsonb_build_object('hand', nh) where code = p_code and pid = me.pid;
    update public.gr_rooms set pub = pub || jsonb_build_object(
        'last', jsonb_build_object('pid', me.pid, 'num', num, 'cnt', cnt, 'cards', cards),
        'passes', '[]'::jsonb,
        'counts', jsonb_set(pub->'counts', array[me.pid::text], to_jsonb(jsonb_array_length(nh))),
        'log', (jsonb_build_array(jsonb_build_object('pid', me.pid, 'num', num, 'cnt', cnt)) || coalesce(pub->'log', '[]'::jsonb)) - 6,
        'out', case when jsonb_array_length(nh) = 0 then pub->'out' || to_jsonb(me.pid) else pub->'out' end)
     where code = p_code;
    if not public.kg__check_end(p_code) then
      nx := public.kg__next(p_code, me.pid);
      update public.gr_rooms set pub = jsonb_set(pub, '{turn}', to_jsonb(nx)) where code = p_code;
      -- 나 말고 낼 사람이 없으면(모두 다 털었으면) 바로 새 차례
      if nx is null then update public.gr_rooms set pub = pub || jsonb_build_object('turn', me.pid, 'last', null) where code = p_code; end if;
    end if;

  elsif a = 'pass' then
    if rm.phase <> 'play' or (rm.pub->>'turn')::int <> me.pid then return; end if;
    lst := rm.pub->'last';
    if lst is null or jsonb_typeof(lst) = 'null' then raise exception 'lead must play'; end if;
    passes := coalesce(rm.pub->'passes', '[]'::jsonb) || to_jsonb(me.pid);
    -- 마지막에 낸 사람을 빼고, 카드가 남은 모두가 패스했으면 그 사람이 새로 시작해요
    select count(*) into actv from jsonb_array_elements_text(rm.pub->'order') x
     where x::int <> (lst->>'pid')::int and coalesce((rm.pub->'counts'->>x)::int, 0) > 0
       and exists (select 1 from public.gr_players where code = p_code and pid = x::int) and not (passes @> to_jsonb(x::int));
    if actv = 0 then
      lead := (lst->>'pid')::int;
      if coalesce((rm.pub->'counts'->>lead::text)::int, 0) = 0 or not exists (select 1 from public.gr_players where code = p_code and pid = lead) then
        lead := public.kg__next(p_code, lead);
      end if;
      update public.gr_rooms set pub = pub || jsonb_build_object('last', null, 'passes', '[]'::jsonb, 'turn', lead, 'lead', lead,
             'log', (jsonb_build_array(jsonb_build_object('pid', lead, 'new', true)) || coalesce(pub->'log', '[]'::jsonb)) - 6) where code = p_code;
    else
      update public.gr_rooms set pub = pub || jsonb_build_object('passes', passes, 'turn', public.kg__next(p_code, me.pid)) where code = p_code;
    end if;
  end if;
  update public.gr_rooms set ver = ver + 1, updated_at = now() where code = p_code;
end $$;

revoke all on function public.kg__take(jsonb, jsonb) from public, anon, authenticated;
revoke all on function public.kg__next(text, int) from public, anon, authenticated;
revoke all on function public.kg__check_end(text) from public, anon, authenticated;
revoke all on function public.kg__deal(text) from public, anon, authenticated;
revoke all on function public.kg__tax(text, boolean) from public, anon, authenticated;
revoke all on function public.bg_start(text, uuid, text, jsonb) from public;
grant execute on function public.bg_start(text, uuid, text, jsonb) to anon, authenticated;
revoke all on function public.bg_act(text, uuid, jsonb) from public;
grant execute on function public.bg_act(text, uuid, jsonb) to anon, authenticated;
