-- Production posting must be one server-side transaction: the production
-- event and every resulting stock movement either all commit or none commit.
-- This migration is forward-only and keeps the legacy ledger RPC available
-- for sync queue items created by older app versions.

ALTER TABLE public.stock_ledger
  DROP CONSTRAINT IF EXISTS stock_ledger_stage_check;

ALTER TABLE public.stock_ledger
  ADD CONSTRAINT stock_ledger_stage_check CHECK (
    stage IN (
      'raw_material',
      'bp_stock',
      'bp_rejected',
      'production_rejected',
      'quality_hold',
      'at_faco',
      'pending_ap',
      'approved_ap',
      'ap_rejected',
      'rtv_stock'
    )
    OR (
      stage LIKE 'production_wip_%'
      AND length(stage) > length('production_wip_')
    )
  );

CREATE INDEX IF NOT EXISTS idx_productions_factory_batch_machine
  ON public.productions(factory_id, batch_number, machine_id);

CREATE INDEX IF NOT EXISTS idx_stock_ledger_factory_part_stage_created
  ON public.stock_ledger(factory_id, part_id, stage, created_at DESC);

-- Backward-compatible server-authoritative ledger writer. Authorization is
-- workspace-membership aware while retaining the users.factory_id fallback
-- during the workspace migration.
CREATE OR REPLACE FUNCTION public.write_stock_ledger_entry(
  p_id uuid,
  p_factory_id uuid,
  p_part_id uuid,
  p_stage text,
  p_direction text,
  p_qty numeric,
  p_ref_table text,
  p_ref_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor_role text;
  v_current_balance numeric := 0;
  v_next_balance numeric;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  SELECT wm.role
    INTO v_actor_role
  FROM public.workspace_members AS wm
  WHERE wm.workspace_id = p_factory_id
    AND wm.user_id = auth.uid()
    AND wm.status = 'active'
  LIMIT 1;

  IF v_actor_role IS NULL THEN
    SELECT u.role
      INTO v_actor_role
    FROM public.users AS u
    WHERE u.id = auth.uid()
      AND u.factory_id = p_factory_id
      AND COALESCE(u.active, true)
    LIMIT 1;
  END IF;

  IF lower(COALESCE(v_actor_role, '')) NOT IN (
    'owner',
    'admin',
    'production incharge',
    'store',
    'quality inspector'
  ) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  IF p_id IS NULL
    OR p_factory_id IS NULL
    OR p_part_id IS NULL
    OR p_ref_id IS NULL
    OR p_qty IS NULL
    OR p_qty <= 0
    OR COALESCE(p_ref_table, '') = ''
    OR COALESCE(p_direction, '') NOT IN ('IN', 'OUT')
    OR COALESCE(p_stage, '') = ''
    OR (
      p_stage NOT IN (
        'raw_material',
        'bp_stock',
        'bp_rejected',
        'production_rejected',
        'quality_hold',
        'at_faco',
        'pending_ap',
        'approved_ap',
        'ap_rejected',
        'rtv_stock'
      )
      AND NOT (
        p_stage LIKE 'production_wip_%'
        AND length(p_stage) > length('production_wip_')
      )
    )
  THEN
    RAISE EXCEPTION 'invalid ledger entry';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.parts AS p
    WHERE p.id = p_part_id
      AND p.factory_id = p_factory_id
  ) THEN
    RAISE EXCEPTION 'part does not belong to this factory';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.stock_ledger AS sl WHERE sl.id = p_id
  ) THEN
    RETURN jsonb_build_object('success', true, 'idempotent', true);
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended(
      'ledger|' || p_factory_id::text || '|' || p_part_id::text || '|' || p_stage,
      0
    )
  );

  IF EXISTS (
    SELECT 1 FROM public.stock_ledger AS sl WHERE sl.id = p_id
  ) THEN
    RETURN jsonb_build_object('success', true, 'idempotent', true);
  END IF;

  SELECT sl.running_balance
    INTO v_current_balance
  FROM public.stock_ledger AS sl
  WHERE sl.factory_id = p_factory_id
    AND sl.part_id = p_part_id
    AND sl.stage = p_stage
  ORDER BY sl.created_at DESC, sl.id DESC
  LIMIT 1;

  v_current_balance := COALESCE(v_current_balance, 0);
  v_next_balance := CASE
    WHEN p_direction = 'IN' THEN v_current_balance + p_qty
    ELSE v_current_balance - p_qty
  END;

  IF v_next_balance < 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'conflict', true,
      'error', 'Insufficient stock for this movement'
    );
  END IF;

  INSERT INTO public.stock_ledger (
    id,
    factory_id,
    date,
    time,
    part_id,
    stage,
    direction,
    qty,
    ref_table,
    ref_id,
    running_balance
  ) VALUES (
    p_id,
    p_factory_id,
    CURRENT_DATE,
    LOCALTIME,
    p_part_id,
    p_stage,
    p_direction,
    p_qty,
    p_ref_table,
    p_ref_id,
    v_next_balance
  );

  INSERT INTO public.audit_log (
    factory_id,
    table_name,
    record_id,
    action,
    old_value_json,
    new_value_json,
    changed_by,
    changed_at
  ) VALUES (
    p_factory_id,
    'stock_ledger',
    p_id,
    'INSERT',
    NULL,
    jsonb_build_object(
      'part_id', p_part_id,
      'stage', p_stage,
      'direction', p_direction,
      'qty', p_qty,
      'running_balance', v_next_balance
    ),
    auth.uid(),
    now()
  );

  RETURN jsonb_build_object(
    'success', true,
    'idempotent', false,
    'running_balance', v_next_balance
  );
END;
$$;

REVOKE ALL ON FUNCTION public.write_stock_ledger_entry(
  uuid, uuid, uuid, text, text, numeric, text, uuid
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.write_stock_ledger_entry(
  uuid, uuid, uuid, text, text, numeric, text, uuid
) TO authenticated;

CREATE OR REPLACE FUNCTION public.post_production_stage(p_command jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_production jsonb;
  v_entries jsonb;
  v_entry jsonb;
  v_prepared_entries jsonb := '[]'::jsonb;
  v_balances jsonb := '{}'::jsonb;
  v_seen_ids uuid[] := ARRAY[]::uuid[];
  v_actor_role text;
  v_command_id uuid;
  v_production_id uuid;
  v_factory_id uuid;
  v_part_id uuid;
  v_machine_id uuid;
  v_operator_id uuid;
  v_ledger_id uuid;
  v_entry_factory_id uuid;
  v_entry_part_id uuid;
  v_entry_ref_id uuid;
  v_batch_number text;
  v_stage text;
  v_direction text;
  v_date date;
  v_time time;
  v_created_at timestamptz;
  v_production_qty numeric;
  v_reject_qty numeric;
  v_qty numeric;
  v_current_balance numeric;
  v_next_balance numeric;
  v_total_in numeric := 0;
  v_total_out numeric := 0;
  v_all_ledger_rows_exist boolean;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  IF p_command IS NULL
    OR jsonb_typeof(p_command) <> 'object'
    OR jsonb_typeof(p_command->'production') <> 'object'
    OR jsonb_typeof(p_command->'ledger_entries') <> 'array'
  THEN
    RAISE EXCEPTION 'invalid production command';
  END IF;

  IF COALESCE(p_command->>'device_id', '') = ''
    OR COALESCE(p_command->>'app_version', '') = ''
    OR COALESCE((p_command->>'schema_version')::integer, 0) <> 1
  THEN
    RAISE EXCEPTION 'unsupported production command envelope';
  END IF;

  v_production := p_command->'production';
  v_entries := p_command->'ledger_entries';
  v_command_id := (p_command->>'command_id')::uuid;
  v_production_id := (v_production->>'id')::uuid;
  v_factory_id := (v_production->>'factory_id')::uuid;
  v_part_id := (v_production->>'part_id')::uuid;
  v_machine_id := (v_production->>'machine_id')::uuid;
  v_operator_id := NULLIF(v_production->>'operator_id', '')::uuid;
  v_batch_number := btrim(v_production->>'batch_number');
  v_date := (v_production->>'date')::date;
  v_time := NULLIF(v_production->>'time', '')::time;
  v_created_at := COALESCE(
    NULLIF(v_production->>'created_at', '')::timestamptz,
    now()
  );
  v_production_qty := (v_production->>'production_qty')::numeric;
  v_reject_qty := COALESCE(
    NULLIF(v_production->>'bp_reject_qty', '')::numeric,
    0
  );

  IF v_command_id IS NULL
    OR v_production_id IS NULL
    OR v_factory_id IS NULL
    OR v_part_id IS NULL
    OR v_machine_id IS NULL
    OR v_date IS NULL
    OR v_production_qty IS NULL
    OR v_command_id <> v_production_id
    OR COALESCE(p_command->>'factory_id', '') = ''
    OR (p_command->>'factory_id')::uuid <> v_factory_id
    OR COALESCE(p_command->>'user_id', '') = ''
    OR (p_command->>'user_id')::uuid <> auth.uid()
    OR COALESCE(v_production->>'created_by', '') = ''
    OR (v_production->>'created_by')::uuid <> auth.uid()
    OR COALESCE(v_batch_number, '') = ''
    OR v_production_qty <= 0
    OR v_reject_qty < 0
    OR v_reject_qty > v_production_qty
    OR jsonb_array_length(v_entries) = 0
  THEN
    RAISE EXCEPTION 'invalid production command';
  END IF;

  SELECT wm.role
    INTO v_actor_role
  FROM public.workspace_members AS wm
  WHERE wm.workspace_id = v_factory_id
    AND wm.user_id = auth.uid()
    AND wm.status = 'active'
  LIMIT 1;

  IF v_actor_role IS NULL THEN
    SELECT u.role
      INTO v_actor_role
    FROM public.users AS u
    WHERE u.id = auth.uid()
      AND u.factory_id = v_factory_id
      AND COALESCE(u.active, true)
    LIMIT 1;
  END IF;

  IF lower(COALESCE(v_actor_role, '')) NOT IN (
    'owner',
    'admin',
    'production incharge'
  ) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.parts AS p
    WHERE p.id = v_part_id
      AND p.factory_id = v_factory_id
      AND COALESCE(p.active, true)
  ) OR NOT EXISTS (
    SELECT 1
    FROM public.machines AS m
    WHERE m.id = v_machine_id
      AND m.factory_id = v_factory_id
      AND COALESCE(m.active, true)
  ) OR (
    v_operator_id IS NOT NULL
    AND NOT EXISTS (
      SELECT 1
      FROM public.operators AS o
      WHERE o.id = v_operator_id
        AND o.factory_id = v_factory_id
        AND COALESCE(o.active, true)
    )
  ) THEN
    RAISE EXCEPTION 'production master data does not belong to this factory';
  END IF;

  -- Serialize the same batch/machine stage across devices. This also makes a
  -- retry wait for the first call to commit before checking idempotency.
  PERFORM pg_advisory_xact_lock(
    hashtextextended(
      'production|' || v_factory_id::text || '|' ||
      v_batch_number || '|' || v_machine_id::text,
      0
    )
  );

  -- A retry after a committed call is successful only when every ledger row
  -- from the same command is also present. This detects legacy partial data.
  IF EXISTS (
    SELECT 1
    FROM public.productions AS p
    WHERE p.id = v_production_id
  ) THEN
    SELECT bool_and(
      EXISTS (
        SELECT 1
        FROM public.stock_ledger AS sl
        WHERE sl.id = (item->>'id')::uuid
          AND sl.factory_id = v_factory_id
          AND sl.ref_table = 'productions'
          AND sl.ref_id = v_production_id
      )
    )
      INTO v_all_ledger_rows_exist
    FROM jsonb_array_elements(v_entries) AS items(item);

    IF EXISTS (
      SELECT 1
      FROM public.productions AS p
      WHERE p.id = v_production_id
        AND p.factory_id = v_factory_id
        AND p.batch_number = v_batch_number
        AND p.machine_id = v_machine_id
        AND p.part_id = v_part_id
    ) AND COALESCE(v_all_ledger_rows_exist, false) THEN
      RETURN jsonb_build_object(
        'success', true,
        'idempotent', true,
        'production_id', v_production_id
      );
    END IF;

    RETURN jsonb_build_object(
      'success', false,
      'conflict', true,
      'error', 'Production command ID already exists with incomplete or different data'
    );
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.productions AS p
    WHERE p.factory_id = v_factory_id
      AND p.batch_number = v_batch_number
      AND p.machine_id = v_machine_id
      AND p.id <> v_production_id
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'conflict', true,
      'error', 'This production stage is already completed for the batch'
    );
  END IF;

  -- Validate all ledger rows before any insert.
  FOR v_entry IN
    SELECT item FROM jsonb_array_elements(v_entries) AS items(item)
  LOOP
    v_ledger_id := (v_entry->>'id')::uuid;
    v_entry_factory_id := (v_entry->>'factory_id')::uuid;
    v_entry_part_id := (v_entry->>'part_id')::uuid;
    v_entry_ref_id := (v_entry->>'ref_id')::uuid;
    v_stage := v_entry->>'stage';
    v_direction := v_entry->>'direction';
    v_qty := (v_entry->>'qty')::numeric;

    IF v_ledger_id IS NULL
      OR v_entry_factory_id IS NULL
      OR v_entry_part_id IS NULL
      OR v_entry_ref_id IS NULL
      OR COALESCE(v_stage, '') = ''
      OR v_qty IS NULL
      OR v_ledger_id = ANY(v_seen_ids)
      OR v_entry_factory_id <> v_factory_id
      OR v_entry_part_id <> v_part_id
      OR v_entry_ref_id <> v_production_id
      OR COALESCE(v_entry->>'ref_table', '') <> 'productions'
      OR v_qty <= 0
      OR COALESCE(v_direction, '') NOT IN ('IN', 'OUT')
      OR (
        v_stage NOT IN (
          'raw_material',
          'bp_stock',
          'bp_rejected',
          'production_rejected',
          'quality_hold',
          'at_faco',
          'pending_ap',
          'approved_ap',
          'ap_rejected',
          'rtv_stock'
        )
        AND NOT (
          v_stage LIKE 'production_wip_%'
          AND length(v_stage) > length('production_wip_')
        )
      )
    THEN
      RAISE EXCEPTION 'invalid production ledger entry';
    END IF;

    IF EXISTS (
      SELECT 1 FROM public.stock_ledger AS sl WHERE sl.id = v_ledger_id
    ) THEN
      RETURN jsonb_build_object(
        'success', false,
        'conflict', true,
        'error', 'A production ledger ID already belongs to another command'
      );
    END IF;

    v_seen_ids := array_append(v_seen_ids, v_ledger_id);
    IF v_direction = 'IN' THEN
      v_total_in := v_total_in + v_qty;
    ELSE
      v_total_out := v_total_out + v_qty;
    END IF;
  END LOOP;

  IF v_total_out <> v_production_qty
    OR v_total_in <> v_production_qty
  THEN
    RAISE EXCEPTION 'production quantities do not balance';
  END IF;

  -- Lock every affected balance in deterministic stage order.
  FOR v_stage IN
    SELECT DISTINCT item->>'stage'
    FROM jsonb_array_elements(v_entries) AS items(item)
    ORDER BY 1
  LOOP
    PERFORM pg_advisory_xact_lock(
      hashtextextended(
        'ledger|' || v_factory_id::text || '|' ||
        v_part_id::text || '|' || v_stage,
        0
      )
    );
  END LOOP;

  -- Calculate every running balance in memory first. Returning a conflict at
  -- this point leaves the database untouched.
  FOR v_entry IN
    SELECT item FROM jsonb_array_elements(v_entries) AS items(item)
  LOOP
    v_stage := v_entry->>'stage';
    v_direction := v_entry->>'direction';
    v_qty := (v_entry->>'qty')::numeric;

    IF v_balances ? v_stage THEN
      v_current_balance := (v_balances->>v_stage)::numeric;
    ELSE
      SELECT sl.running_balance
        INTO v_current_balance
      FROM public.stock_ledger AS sl
      WHERE sl.factory_id = v_factory_id
        AND sl.part_id = v_part_id
        AND sl.stage = v_stage
      ORDER BY sl.created_at DESC, sl.id DESC
      LIMIT 1;
      v_current_balance := COALESCE(v_current_balance, 0);
    END IF;

    v_next_balance := CASE
      WHEN v_direction = 'IN' THEN v_current_balance + v_qty
      ELSE v_current_balance - v_qty
    END;

    IF v_next_balance < 0 THEN
      RETURN jsonb_build_object(
        'success', false,
        'conflict', true,
        'error', 'Insufficient stock for production stage ' || v_stage
      );
    END IF;

    v_balances := jsonb_set(
      v_balances,
      ARRAY[v_stage],
      to_jsonb(v_next_balance),
      true
    );
    v_prepared_entries := v_prepared_entries || jsonb_build_array(
      v_entry || jsonb_build_object('running_balance', v_next_balance)
    );
  END LOOP;

  INSERT INTO public.productions (
    id,
    factory_id,
    batch_number,
    date,
    time,
    shift_id,
    part_id,
    machine_id,
    operator_id,
    machine_status_id,
    production_qty,
    bp_reject_qty,
    remarks,
    created_by,
    created_at
  ) VALUES (
    v_production_id,
    v_factory_id,
    v_batch_number,
    v_date,
    v_time,
    NULLIF(v_production->>'shift_id', ''),
    v_part_id,
    v_machine_id,
    v_operator_id,
    NULLIF(v_production->>'machine_status_id', ''),
    v_production_qty,
    v_reject_qty,
    NULLIF(v_production->>'remarks', ''),
    auth.uid(),
    v_created_at
  );

  INSERT INTO public.audit_log (
    factory_id,
    table_name,
    record_id,
    action,
    old_value_json,
    new_value_json,
    changed_by,
    changed_at,
    device
  ) VALUES (
    v_factory_id,
    'productions',
    v_production_id,
    'INSERT',
    NULL,
    v_production,
    auth.uid(),
    now(),
    p_command->>'device_id'
  );

  FOR v_entry IN
    SELECT item FROM jsonb_array_elements(v_prepared_entries) AS items(item)
  LOOP
    v_ledger_id := (v_entry->>'id')::uuid;
    v_stage := v_entry->>'stage';
    v_direction := v_entry->>'direction';
    v_qty := (v_entry->>'qty')::numeric;
    v_next_balance := (v_entry->>'running_balance')::numeric;

    INSERT INTO public.stock_ledger (
      id,
      factory_id,
      date,
      time,
      part_id,
      stage,
      direction,
      qty,
      ref_table,
      ref_id,
      running_balance,
      created_at
    ) VALUES (
      v_ledger_id,
      v_factory_id,
      v_date,
      v_time,
      v_part_id,
      v_stage,
      v_direction,
      v_qty,
      'productions',
      v_production_id,
      v_next_balance,
      clock_timestamp()
    );

    INSERT INTO public.audit_log (
      factory_id,
      table_name,
      record_id,
      action,
      old_value_json,
      new_value_json,
      changed_by,
      changed_at,
      device
    ) VALUES (
      v_factory_id,
      'stock_ledger',
      v_ledger_id,
      'INSERT',
      NULL,
      jsonb_build_object(
        'part_id', v_part_id,
        'stage', v_stage,
        'direction', v_direction,
        'qty', v_qty,
        'running_balance', v_next_balance,
        'ref_table', 'productions',
        'ref_id', v_production_id
      ),
      auth.uid(),
      now(),
      p_command->>'device_id'
    );
  END LOOP;

  RETURN jsonb_build_object(
    'success', true,
    'idempotent', false,
    'production_id', v_production_id,
    'ledger_count', jsonb_array_length(v_prepared_entries)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.post_production_stage(jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.post_production_stage(jsonb) TO authenticated;

COMMENT ON FUNCTION public.post_production_stage(jsonb) IS
  'Atomically and idempotently posts one production stage and its stock ledger movements.';
