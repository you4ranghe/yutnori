-- ============================================================
-- 윷놀이 온라인 - Supabase 스키마
-- Supabase 대시보드 > SQL Editor 에 이 파일 전체를 붙여넣고 Run 하세요.
-- 여러 번 실행해도 안전합니다. (기능 추가 후 다시 실행해도 됩니다)
-- ============================================================

create extension if not exists pgcrypto;

-- ---------- 프로필 (이름 · 프로필 사진) ----------
create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  nickname   text not null default '',
  avatar     text,                               -- 작은 정사각 이미지(data URI, 약 10KB)
  updated_at timestamptz not null default now()
);

-- ---------- 방 ----------
create table if not exists public.rooms (
  id          uuid primary key default gen_random_uuid(),
  code        text unique not null,
  host        uuid not null,
  status      text not null default 'waiting',   -- waiting | playing | finished
  game_state  jsonb,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- ---------- 참가자 ----------
create table if not exists public.players (
  id         uuid primary key default gen_random_uuid(),
  room_id    uuid not null references public.rooms(id) on delete cascade,
  user_id    uuid not null,
  nickname   text not null,
  team       int  not null default 0,            -- 0=파란팀, 1=빨간팀
  joined_at  timestamptz not null default now(),
  unique (room_id, user_id)
);
alter table public.players add column if not exists avatar text;

-- ---------- 채팅 ----------
create table if not exists public.messages (
  id         bigserial primary key,
  room_id    uuid not null references public.rooms(id) on delete cascade,
  user_id    uuid not null,
  nickname   text not null,
  text       text not null,
  created_at timestamptz not null default now()
);
create index if not exists messages_room_idx on public.messages (room_id, id);

-- ---------- RLS: 읽기는 로그인(익명 포함) 사용자 누구나, 쓰기는 RPC 함수로만 ----------
alter table public.profiles enable row level security;
alter table public.rooms    enable row level security;
alter table public.players  enable row level security;
alter table public.messages enable row level security;

drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated using (true);
drop policy if exists rooms_select    on public.rooms;
create policy rooms_select    on public.rooms    for select to authenticated using (true);
drop policy if exists players_select  on public.players;
create policy players_select  on public.players  for select to authenticated using (true);
drop policy if exists messages_select on public.messages;
create policy messages_select on public.messages for select to authenticated using (true);

-- ---------- Realtime 발행 ----------
do $$
begin
  begin alter publication supabase_realtime add table public.rooms;    exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.players;  exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.messages; exception when duplicate_object then null; end;
end $$;

-- ---------- 컴퓨터(AI) 플레이어의 고정 uid ----------
-- 사람이 없는 팀을 컴퓨터가 맡을 때 사용. 실제 계정이 아니므로 방장이 대신 진행한다.
create or replace function public._ai_uid() returns uuid
language sql immutable as $$ select '00000000-0000-0000-0000-00000000c0de'::uuid $$;

-- ---------- 헬퍼: 현재 차례인 플레이어의 uid ----------
create or replace function public._thrower(st jsonb) returns uuid
language sql immutable as $$
  select (
    st->'teams'->((st->>'cur')::int)->'players'
      ->((st->'teams'->((st->>'cur')::int)->>'pIdx')::int)->>'uid'
  )::uuid
$$;

-- ---------- 헬퍼: 오래된 방 청소 (방 생성 시마다 실행되므로 pg_cron 불필요) ----------
create or replace function public._cleanup_rooms() returns void
language sql security definer set search_path = public as $$
  delete from rooms
   where created_at < now() - interval '24 hours'
      or (status = 'finished' and updated_at < now() - interval '1 hour');
$$;

-- ---------- 프로필 저장 ----------
create or replace function public.save_profile(p_nickname text, p_avatar text)
returns void language plpgsql security definer set search_path = public as $$
declare v_nick text;
begin
  if auth.uid() is null then raise exception '로그인이 필요해요'; end if;
  v_nick := left(trim(coalesce(p_nickname,'')), 10);
  if v_nick = '' then raise exception '이름을 입력해 주세요'; end if;
  if p_avatar is not null and length(p_avatar) > 300000 then
    raise exception '사진 용량이 너무 커요';
  end if;

  insert into profiles (id, nickname, avatar)
       values (auth.uid(), v_nick, p_avatar)
  on conflict (id) do update
     set nickname = excluded.nickname, avatar = excluded.avatar, updated_at = now();

  -- 참가 중인 방에도 즉시 반영
  update players set nickname = v_nick, avatar = p_avatar where user_id = auth.uid();
end $$;

-- ---------- 방 만들기 ----------
create or replace function public.create_room(p_nickname text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_code text;
  v_room uuid;
  v_nick text := left(trim(coalesce(p_nickname,'')), 10);
begin
  if auth.uid() is null then raise exception '로그인이 필요해요'; end if;
  if v_nick = '' then raise exception '이름을 입력해 주세요'; end if;

  perform _cleanup_rooms();

  insert into profiles (id, nickname) values (auth.uid(), v_nick)
    on conflict (id) do update set nickname = excluded.nickname, updated_at = now();

  loop
    select string_agg(substr('ABCDEFGHJKMNPQRSTUVWXYZ23456789', 1 + floor(random()*31)::int, 1), '')
      into v_code from generate_series(1, 6);
    exit when not exists (select 1 from rooms where code = v_code);
  end loop;

  insert into rooms (code, host) values (v_code, auth.uid()) returning id into v_room;
  insert into players (room_id, user_id, nickname, team, avatar)
       values (v_room, auth.uid(), v_nick, 0, (select avatar from profiles where id = auth.uid()));

  return jsonb_build_object('room_id', v_room, 'code', v_code);
end $$;

-- ---------- 방 참가 (초대 코드) ----------
create or replace function public.join_room(p_code text, p_nickname text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  r rooms%rowtype;
  v_team int;
  v_nick text := left(trim(coalesce(p_nickname,'')), 10);
  v_av   text;
begin
  if auth.uid() is null then raise exception '로그인이 필요해요'; end if;
  if v_nick = '' then raise exception '이름을 입력해 주세요'; end if;

  select * into r from rooms where code = upper(trim(p_code));
  if not found then raise exception '방을 찾을 수 없어요. 코드를 확인해 주세요'; end if;

  insert into profiles (id, nickname) values (auth.uid(), v_nick)
    on conflict (id) do update set nickname = excluded.nickname, updated_at = now();
  select avatar into v_av from profiles where id = auth.uid();

  -- 이미 참가한 방이면 그대로 재입장 (새로고침/재접속)
  if exists (select 1 from players where room_id = r.id and user_id = auth.uid()) then
    update players set nickname = v_nick, avatar = v_av
     where room_id = r.id and user_id = auth.uid();
    return jsonb_build_object('room_id', r.id, 'code', r.code, 'status', r.status);
  end if;

  -- 진행 중인 게임에는 참가할 수 없음 (관전만 가능)
  if r.status = 'playing' then raise exception '게임이 진행 중이라 관전만 할 수 있어요'; end if;
  if (select count(*) from players where room_id = r.id) >= 12 then
    raise exception '정원(12명)이 가득 찼어요';
  end if;

  -- 인원이 적은 팀으로 자동 배정 (대기실에서 바꿀 수 있음)
  select case when count(*) filter (where team = 0) <= count(*) filter (where team = 1)
              then 0 else 1 end
    into v_team from players where room_id = r.id;

  insert into players (room_id, user_id, nickname, team, avatar)
       values (r.id, auth.uid(), v_nick, v_team, v_av);

  return jsonb_build_object('room_id', r.id, 'code', r.code, 'status', r.status);
end $$;

-- ---------- 팀 바꾸기 (대기 중에만) ----------
create or replace function public.set_team(p_room_id uuid, p_team int)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_team not in (0, 1) then raise exception '잘못된 팀이에요'; end if;
  update players set team = p_team
   where room_id = p_room_id and user_id = auth.uid()
     and exists (select 1 from rooms where id = p_room_id and status = 'waiting');
end $$;

-- ---------- 게임 시작 / 다시 시작 (방장 전용) ----------
create or replace function public.start_game(p_room_id uuid, p_state jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare r rooms%rowtype;
begin
  select * into r from rooms where id = p_room_id for update;
  if not found then raise exception '방을 찾을 수 없어요'; end if;
  if r.host <> auth.uid() then raise exception '방장만 시작할 수 있어요'; end if;
  -- 사람이 한 명이라도 있으면 시작 가능 (빈 팀은 컴퓨터가 맡을 수 있음)
  if not exists (select 1 from players where room_id = p_room_id) then
    raise exception '참가자가 없어요';
  end if;

  update rooms set status = 'playing', game_state = p_state, updated_at = now()
   where id = p_room_id;
end $$;

-- ---------- 윷 던지기: 결과는 서버에서 생성 (조작 방지) ----------
create or replace function public.throw_sticks(p_room_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  r       rooms%rowtype;
  st      jsonb;
  v_turn  uuid;
  v_faces jsonb;
begin
  select * into r from rooms where id = p_room_id and status = 'playing';
  if not found then raise exception '진행 중인 게임이 아니에요'; end if;
  st := r.game_state;
  if st is null then raise exception '진행 중인 게임이 아니에요'; end if;
  v_turn := _thrower(st);
  -- 내 차례이거나, 컴퓨터 차례를 방장이 대신 진행하는 경우만 허용
  if v_turn is distinct from auth.uid()
     and not (v_turn = _ai_uid() and r.host = auth.uid()) then
    raise exception '지금은 내 차례가 아니에요';
  end if;
  if st->>'phase' <> 'throw' or (st->>'throwsLeft')::int <= 0 then
    raise exception '지금은 던질 수 없어요';
  end if;
  if st->'winner' <> 'null'::jsonb then raise exception '이미 끝난 게임이에요'; end if;

  -- 윷가락 4개: true=배(평평한 면 위), 원본 게임과 같은 확률(57%)
  select jsonb_agg(random() < 0.57) into v_faces from generate_series(1, 4);
  return jsonb_build_object('faces', v_faces);
end $$;

-- ---------- 상태 저장: 현재 차례인 사람만 가능 ----------
create or replace function public.push_state(p_room_id uuid, p_state jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  r      rooms%rowtype;
  st     jsonb;
  v_turn uuid;
begin
  select * into r from rooms where id = p_room_id for update;
  if not found then raise exception '방을 찾을 수 없어요'; end if;
  st := r.game_state;
  if st is null then raise exception '진행 중인 게임이 아니에요'; end if;
  v_turn := _thrower(st);
  if v_turn is distinct from auth.uid()
     and not (v_turn = _ai_uid() and r.host = auth.uid()) then
    raise exception '지금은 내 차례가 아니에요';
  end if;
  if (p_state->>'ver')::int <= (st->>'ver')::int then raise exception '오래된 상태예요'; end if;

  update rooms
     set game_state = p_state,
         status = case when p_state->'winner' <> 'null'::jsonb then 'finished' else status end,
         updated_at = now()
   where id = p_room_id;
end $$;

-- ---------- 상태 강제 저장 (방장 전용): 자리 비운 사람 차례 넘기기 용 ----------
create or replace function public.force_state(p_room_id uuid, p_state jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare r rooms%rowtype;
begin
  select * into r from rooms where id = p_room_id for update;
  if not found then raise exception '방을 찾을 수 없어요'; end if;
  if r.host <> auth.uid() then raise exception '방장만 할 수 있어요'; end if;
  update rooms set game_state = p_state, updated_at = now() where id = p_room_id;
end $$;

-- ---------- 채팅 보내기 ----------
create or replace function public.send_message(p_room_id uuid, p_text text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_text text := left(trim(coalesce(p_text,'')), 200);
  v_nick text;
begin
  if auth.uid() is null then raise exception '로그인이 필요해요'; end if;
  if v_text = '' then return; end if;

  -- 참가자 우선, 없으면 관전자(프로필 이름)로 허용
  select nickname into v_nick from players
   where room_id = p_room_id and user_id = auth.uid();
  if v_nick is null then
    select nickname into v_nick from profiles where id = auth.uid();
  end if;
  if v_nick is null or v_nick = '' then raise exception '먼저 이름을 정해 주세요'; end if;

  -- 도배 방지
  if exists (select 1 from messages
              where room_id = p_room_id and user_id = auth.uid()
                and created_at > now() - interval '400 milliseconds') then
    return;
  end if;

  insert into messages (room_id, user_id, nickname, text)
       values (p_room_id, auth.uid(), v_nick, v_text);

  -- 방마다 최근 100개만 보관
  delete from messages
   where room_id = p_room_id
     and id <= (select max(id) - 100 from messages where room_id = p_room_id);
end $$;

-- ---------- 방 나가기 ----------
-- 게임 중에 나가면: 그 팀에 아무도 안 남으면 상대 팀 승리로 종료,
--                  한 명이라도 남아 있으면 (2:1 처럼) 계속 진행.
create or replace function public.leave_room(p_room_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  r       rooms%rowtype;
  st      jsonb;
  arr     jsonb;
  ti      int;
  n0      int;
  n1      int;
  was_turn boolean := false;
  v_nick  text;
  v_host  uuid;
begin
  select * into r from rooms where id = p_room_id for update;
  if not found then return; end if;

  -- 관전자는 참가자 목록에 없으므로 아무것도 바꾸지 않음
  select nickname into v_nick from players
   where room_id = p_room_id and user_id = auth.uid();
  if v_nick is null then return; end if;

  -- 대기 중: 방장이 나가면 방 자체를 닫음
  if r.status = 'waiting' then
    if r.host = auth.uid() then
      delete from rooms where id = p_room_id;
      return;
    end if;
    delete from players where room_id = p_room_id and user_id = auth.uid();
    if not exists (select 1 from players where room_id = p_room_id) then
      delete from rooms where id = p_room_id;
    end if;
    return;
  end if;

  -- 진행 중: 게임 상태에서 나간 사람을 빼고 승패/차례를 정리
  st := r.game_state;
  if r.status = 'playing' and st is not null then
    was_turn := (_thrower(st) = auth.uid());

    for ti in 0..1 loop
      select coalesce(jsonb_agg(e.v), '[]'::jsonb) into arr
        from jsonb_array_elements(st->'teams'->ti->'players') as e(v)
       where e.v->>'uid' <> auth.uid()::text;
      st := jsonb_set(st, array['teams', ti::text, 'players'], arr);
    end loop;

    n0 := jsonb_array_length(st->'teams'->0->'players');
    n1 := jsonb_array_length(st->'teams'->1->'players');

    st := jsonb_set(st, '{ver}', to_jsonb(coalesce((st->>'ver')::int, 1) + 1));
    st := jsonb_set(st, '{ev}', jsonb_build_object(
            'type','leave','by',auth.uid(),'name',v_nick,
            'ended', (n0 = 0 or n1 = 0)));

    if n0 = 0 or n1 = 0 then
      -- 한 팀이 통째로 비었으면 상대 팀 승리로 종료
      st := jsonb_set(st, '{winner}', to_jsonb(case when n0 = 0 then 1 else 0 end));
      st := jsonb_set(st, '{winBy}', '"leave"'::jsonb);
      st := jsonb_set(st, '{phase}', '"throw"'::jsonb);
      st := jsonb_set(st, '{pending}', '[]'::jsonb);
      update rooms set game_state = st, status = 'finished', updated_at = now()
       where id = p_room_id;
    else
      -- 남은 사람들끼리 계속 진행
      st := jsonb_set(st, '{teams,0,pIdx}', to_jsonb(least((st->'teams'->0->>'pIdx')::int, n0 - 1)));
      st := jsonb_set(st, '{teams,1,pIdx}', to_jsonb(least((st->'teams'->1->>'pIdx')::int, n1 - 1)));
      if was_turn then
        -- 나간 사람 차례였다면 상대에게 넘김
        st := jsonb_set(st, '{cur}',        to_jsonb(1 - (st->>'cur')::int));
        st := jsonb_set(st, '{phase}',      '"throw"'::jsonb);
        st := jsonb_set(st, '{throwsLeft}', '1'::jsonb);
        st := jsonb_set(st, '{pending}',    '[]'::jsonb);
        st := jsonb_set(st, '{sel}',        '0'::jsonb);
      end if;
      update rooms set game_state = st, updated_at = now() where id = p_room_id;
    end if;
  end if;

  delete from players where room_id = p_room_id and user_id = auth.uid();

  -- 방장이 나갔으면 남은 사람 중 가장 먼저 들어온 사람이 방장을 이어받음
  if r.host = auth.uid() then
    select user_id into v_host from players
     where room_id = p_room_id order by joined_at limit 1;
    if v_host is not null then
      update rooms set host = v_host where id = p_room_id;
    end if;
  end if;

  if not exists (select 1 from players where room_id = p_room_id) then
    delete from rooms where id = p_room_id;
  end if;
end $$;

-- ---------- 함수 실행 권한: 로그인(익명 포함) 사용자만 ----------
revoke execute on all functions in schema public from anon;
grant execute on function
  public.save_profile(text, text),
  public.create_room(text),
  public.join_room(text, text),
  public.set_team(uuid, int),
  public.start_game(uuid, jsonb),
  public.throw_sticks(uuid),
  public.push_state(uuid, jsonb),
  public.force_state(uuid, jsonb),
  public.send_message(uuid, text),
  public.leave_room(uuid)
to authenticated;

-- ============================================================
-- (선택) pg_cron 으로 매일 새벽 자동 청소를 추가하고 싶다면 아래 주석 해제
-- 기본으로도 방 생성 시마다 _cleanup_rooms() 가 돌기 때문에 없어도 됩니다.
-- ============================================================
-- create extension if not exists pg_cron;
-- select cron.schedule('yut-cleanup', '0 4 * * *', $$ select public._cleanup_rooms() $$);
