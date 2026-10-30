-- 문서 만들기(office-mcp) 보정: office-mcp 가 채운 HWPX·DOCX 와 미리보기 HTML 을 올리는 스토리지 버킷
-- deep_research_files · deepagent_files 가 설치본에 없어 generate_docx/generate_hwpx 가 다 채운 뒤
-- 「Bucket not found」로 「DOCX 업로드 실패」가 된다(services/office-mcp mcp_server.py SUPABASE_BUCKET·DEEPAGENT_BUCKET).
-- 결과는 공개 URL 로 돌려주므로 files 버킷처럼 공개로 만든다(이름은 uuid 라 추측할 수 없다).
INSERT INTO storage.buckets (id, name, public)
VALUES ('deep_research_files', 'deep_research_files', true),
       ('deepagent_files', 'deepagent_files', true)
ON CONFLICT (id) DO NOTHING;
