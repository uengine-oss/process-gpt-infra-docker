-- 스킬 올리기(스킬 목록 관리 › 스킬 추가)가 업로드 뒤 tenants.skills 에 이름을 등록한다.
-- 새로 설치한 DB 에는 이 열이 없어(volumes/db/migration.sql 에만 있음) 업로드가 「Upload failed」로 끝났다.
ALTER TABLE public.tenants ADD COLUMN IF NOT EXISTS skills text[];
