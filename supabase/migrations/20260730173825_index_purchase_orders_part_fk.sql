-- Cover the purchase_orders.part_id foreign key for joins and FK checks.
CREATE INDEX IF NOT EXISTS idx_purchase_orders_part
  ON public.purchase_orders(part_id);
