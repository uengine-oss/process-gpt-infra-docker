-- 방 참여자는 자기 방 작업 폴더(files/skills/{tenant}/{방}/) 목록을 읽는다.
-- 방은 처음 인계할 때 브랜치를 얻고, 그 첫 커밋에 방 폴더 파일 전체를 넣는다(화면 roomFolderEntries).
-- 읽기 정책이 없으면 목록이 비어 고른 파일만 첫 커밋에 들어가고, 넘긴 방의 다음 에이전트 턴이
-- 작업 폴더를 head 에 맞추며 고르지 않은 파일을 지운다. 버킷이 공개라 새로 열리는 것은 목록뿐이다.
create or replace function public.room_folder_readable(p_tenant_id text, p_room_id text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    -- 경로의 테넌트가 토큰의 테넌트이자 그 방의 테넌트이고, 내가 그 방 참여자다.
    select p_tenant_id = public.tenant_id()
       and exists (select 1 from public.chat_rooms r where r.id = p_room_id and r.tenant_id = p_tenant_id)
       and public.artifact_is_room_participant(p_room_id);
$$;
revoke all on function public.room_folder_readable(text, text) from public, anon;
grant execute on function public.room_folder_readable(text, text) to authenticated;

drop policy if exists room_folder_participant_read on storage.objects;
create policy room_folder_participant_read on storage.objects
    for select to authenticated
    using (
        bucket_id = 'files'
        and split_part(name, '/', 1) = 'skills'
        and public.room_folder_readable(split_part(name, '/', 2), split_part(name, '/', 3))
    );
