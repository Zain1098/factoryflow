revoke execute on function public.audit_user_profile_changes() from public, anon, authenticated;

drop policy if exists correction_requests_write on public.correction_requests;
drop policy if exists stock_adjustments_write on public.stock_adjustments;;
