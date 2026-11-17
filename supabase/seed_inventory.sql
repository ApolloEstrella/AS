insert into public.inventory (
  organization_id,
  sku,
  name,
  description,
  unit,
  quantity_on_hand,
  unit_cost,
  unit_price
)
select
  organization.id,
  part.sku,
  part.name,
  part.description,
  part.unit,
  part.quantity_on_hand,
  part.unit_cost,
  part.unit_price
from public.organizations as organization
cross join (
  values
    ('TOY-OIL-001', 'Toyota Oil Filter', 'Engine oil filter for Toyota vehicles.', 'each', 24, 5.50, 11.00),
    ('TOY-AIR-001', 'Toyota Air Filter', 'Engine air filter for Toyota vehicles.', 'each', 18, 8.00, 16.00),
    ('TOY-BRK-001', 'Toyota Front Brake Pads', 'Front brake pad set for Toyota vehicles.', 'set', 10, 28.00, 49.00),
    ('TOY-SPK-001', 'Toyota Spark Plugs', 'Spark plug set for Toyota vehicles.', 'set', 12, 18.00, 32.00),
    ('HON-OIL-001', 'Honda Oil Filter', 'Engine oil filter for Honda vehicles.', 'each', 22, 5.00, 10.00),
    ('HON-AIR-001', 'Honda Air Filter', 'Engine air filter for Honda vehicles.', 'each', 16, 7.50, 15.00),
    ('HON-BRK-001', 'Honda Front Brake Pads', 'Front brake pad set for Honda vehicles.', 'set', 9, 27.00, 48.00),
    ('HON-SPK-001', 'Honda Spark Plugs', 'Spark plug set for Honda vehicles.', 'set', 11, 17.00, 30.00),
    ('FOR-OIL-001', 'Ford Oil Filter', 'Engine oil filter for Ford vehicles.', 'each', 20, 5.50, 11.00),
    ('FOR-AIR-001', 'Ford Air Filter', 'Engine air filter for Ford vehicles.', 'each', 15, 8.50, 17.00),
    ('FOR-BRK-001', 'Ford Front Brake Pads', 'Front brake pad set for Ford vehicles.', 'set', 8, 30.00, 54.00),
    ('FOR-SPK-001', 'Ford Spark Plugs', 'Spark plug set for Ford vehicles.', 'set', 10, 19.00, 34.00),
    ('CHE-OIL-001', 'Chevrolet Oil Filter', 'Engine oil filter for Chevrolet vehicles.', 'each', 18, 5.00, 10.00),
    ('CHE-AIR-001', 'Chevrolet Air Filter', 'Engine air filter for Chevrolet vehicles.', 'each', 14, 8.00, 16.00),
    ('CHE-BRK-001', 'Chevrolet Front Brake Pads', 'Front brake pad set for Chevrolet vehicles.', 'set', 8, 29.00, 52.00),
    ('CHE-SPK-001', 'Chevrolet Spark Plugs', 'Spark plug set for Chevrolet vehicles.', 'set', 9, 18.00, 32.00),
    ('NIS-OIL-001', 'Nissan Oil Filter', 'Engine oil filter for Nissan vehicles.', 'each', 20, 5.00, 10.00),
    ('NIS-AIR-001', 'Nissan Air Filter', 'Engine air filter for Nissan vehicles.', 'each', 15, 7.50, 15.00),
    ('NIS-BRK-001', 'Nissan Front Brake Pads', 'Front brake pad set for Nissan vehicles.', 'set', 9, 28.00, 50.00),
    ('NIS-SPK-001', 'Nissan Spark Plugs', 'Spark plug set for Nissan vehicles.', 'set', 10, 17.00, 30.00),
    ('HYU-OIL-001', 'Hyundai Oil Filter', 'Engine oil filter for Hyundai vehicles.', 'each', 18, 4.50, 9.00),
    ('HYU-AIR-001', 'Hyundai Air Filter', 'Engine air filter for Hyundai vehicles.', 'each', 14, 7.00, 14.00),
    ('HYU-BRK-001', 'Hyundai Front Brake Pads', 'Front brake pad set for Hyundai vehicles.', 'set', 8, 26.00, 47.00),
    ('HYU-SPK-001', 'Hyundai Spark Plugs', 'Spark plug set for Hyundai vehicles.', 'set', 9, 16.00, 29.00)
) as part(sku, name, description, unit, quantity_on_hand, unit_cost, unit_price)
on conflict (organization_id, sku) do nothing;
