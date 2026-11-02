-- =============================================================================
-- Analysis dashboard access alignment
--
-- The analysis dashboard menu used to default to viewer, but its data APIs/RLS
-- are available from reviewer and above. If an existing tenant override still
-- grants viewer access, it causes viewers to enter the page and see empty charts.
-- Keep existing stricter overrides (editor/owner/admin) as-is.
-- =============================================================================

UPDATE public.menu_role_overrides
SET required_role = 'reviewer',
    updated_at = now()
WHERE menu_path IN (
    '/analysis-dashboard',
    '/analytics',
    '/analytics/heatmap',
    '/analytics/kpi'
)
  AND required_role = 'viewer';
