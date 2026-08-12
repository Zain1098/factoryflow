-- Keep master-data reads company-scoped, but allow writes only to the
-- factory Admin/Owner authorization ceiling.
--
-- Forward-safe: no rows are changed. To mitigate/rollback, recreate the prior
-- *_write policies without the get_my_role() predicate.

DO $$
DECLARE
  master_table text;
BEGIN
  FOREACH master_table IN ARRAY ARRAY[
    'parts',
    'machines',
    'operators',
    'suppliers',
    'vendors',
    'customers',
    'vehicles',
    'drivers'
  ]
  LOOP
    EXECUTE format(
      'DROP POLICY IF EXISTS %I ON public.%I',
      master_table || '_read',
      master_table
    );
    EXECUTE format(
      'DROP POLICY IF EXISTS %I ON public.%I',
      master_table || '_write',
      master_table
    );
    EXECUTE format(
      'CREATE POLICY %I ON public.%I '
      'FOR SELECT TO authenticated '
      'USING (factory_id IN (SELECT public.get_my_workspace_ids()))',
      master_table || '_read',
      master_table
    );
    EXECUTE format(
      'CREATE POLICY %I ON public.%I '
      'FOR ALL TO authenticated '
      'USING ('
      '  factory_id IN (SELECT public.get_my_workspace_ids()) '
      '  AND (SELECT public.get_my_role()) = ''Admin'''
      ') '
      'WITH CHECK ('
      '  factory_id IN (SELECT public.get_my_workspace_ids()) '
      '  AND (SELECT public.get_my_role()) = ''Admin'''
      ')',
      master_table || '_write',
      master_table
    );
  END LOOP;
END
$$;

REVOKE INSERT, UPDATE, DELETE ON TABLE
  public.parts,
  public.machines,
  public.operators,
  public.suppliers,
  public.vendors,
  public.customers,
  public.vehicles,
  public.drivers
FROM anon;
