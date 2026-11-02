-- DataObjectReference의 첨부 위젯을 속성 스키마 기반 Supabase Storage 업로드로 전환한다.
-- 테넌트별 행은 런타임 시드로 생성되므로, 여기서는 이미 생성된 행만 안전하게 갱신한다.
UPDATE public.task_property_schema
   SET property_label = CASE WHEN property_label = '첨부 자료' THEN '첨부 파일' ELSE property_label END,
       property_type = 'file',
       description = COALESCE(description, 'Supabase Storage에 업로드하는 데이터 객체 파일'),
       config = COALESCE(config, '{}'::jsonb)
                || jsonb_build_object(
                    'widget', 'file',
                    'binding', 'taskForm.dataAttachmentFile',
                    'file', COALESCE(config->'file', '{}'::jsonb)
                        || jsonb_build_object(
                            'bucket', COALESCE(config->'file'->>'bucket', 'files'),
                            'path_prefix', COALESCE(config->'file'->>'path_prefix', 'data-objects'),
                            'accept', COALESCE(config->'file'->>'accept', ''),
                            'max_size_mb', config->'file'->'max_size_mb',
                            'name_strategy', COALESCE(config->'file'->>'name_strategy', 'uuid'),
                            'multiple', CASE
                                WHEN config->'file'->>'multiple' IN ('true', 'false')
                                THEN (config->'file'->>'multiple')::boolean
                                ELSE false
                            END
                        )
                )
 WHERE COALESCE(task_type, applies_to) = 'bpmn:DataObjectReference'
   AND property_key = 'attachment';

COMMENT ON COLUMN public.task_property_schema.property_type IS
    'string | textarea | number | boolean | select | multiselect | date | daterange | user | url | db-select | formula | file | table';
