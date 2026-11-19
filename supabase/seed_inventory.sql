insert into public.inventory (
  organization_id,
  sku,
  name,
  description,
  unit,
  quantity_on_hand,
  unit_cost,
  unit_price,
  reorder_level
)
select
  organization.id,
  service.sku,
  service.name,
  service.description,
  service.unit,
  0,
  service.unit_cost,
  service.unit_price,
  0
from public.organizations as organization
cross join (
  values
    ('IT-MSS-001', 'Managed IT Support', 'Monthly remote and on-site managed IT support for a business.', 'month', 40.00, 120.00),
    ('IT-HSP-001', 'IT Help Desk Support', 'Per-incident help desk and end-user technical support.', 'ticket', 20.00, 65.00),
    ('IT-RMS-001', 'Remote Monitoring', 'Monitoring and alerting of servers, workstations, and network devices.', 'month', 25.00, 75.00),
    ('IT-NSS-001', 'Network Support', 'Troubleshooting and support for switches, routers, Wi-Fi, and cabling.', 'hour', 35.00, 95.00),
    ('IT-SRV-001', 'Server Administration', 'Server installation, patching, backup checks, and administration.', 'hour', 45.00, 125.00),
    ('IT-CLD-001', 'Cloud Services Setup', 'Setup and configuration of cloud tenants, users, email, and storage.', 'project', 300.00, 750.00),
    ('IT-M365-001', 'Microsoft 365 Administration', 'Microsoft 365 tenant, license, user, security, and email administration.', 'month', 30.00, 90.00),
    ('IT-BKP-001', 'Backup Management', 'Backup configuration, monitoring, testing, and recovery assistance.', 'month', 35.00, 100.00),
    ('IT-SEC-001', 'Cybersecurity Assessment', 'Security review covering accounts, endpoints, network, and backup controls.', 'project', 500.00, 1500.00),
    ('IT-VUL-001', 'Vulnerability Scan', 'Internal or external vulnerability scanning and remediation report.', 'project', 250.00, 700.00),
    ('IT-BCP-001', 'Business Continuity Planning', 'Business continuity and disaster recovery planning workshop.', 'project', 400.00, 1200.00),
    ('IT-DES-001', 'Workstation Setup', 'New workstation setup, configuration, and user onboarding.', 'each', 60.00, 180.00),
    ('IT-DST-001', 'Software Deployment', 'Package, test, and deploy approved business software.', 'project', 200.00, 600.00),
    ('IT-WAV-001', 'Wi-Fi Assessment', 'Wireless site survey, coverage analysis, and optimization report.', 'project', 250.00, 800.00),
    ('IT-DRL-001', 'IT Advisory Consulting', 'Technology planning, vendor review, and IT advisory consultation.', 'hour', 50.00, 150.00),
    ('IT-DOC-001', 'IT Documentation', 'Create or update network diagrams, procedures, and asset documentation.', 'hour', 35.00, 100.00),
    ('IT-ONB-001', 'Employee IT Onboarding', 'User account, device, application, and access setup for a new employee.', 'each', 40.00, 125.00),
    ('IT-OFF-001', 'Employee IT Offboarding', 'Secure account disablement, device return, and access review.', 'each', 30.00, 100.00)
) as service(sku, name, description, unit, unit_cost, unit_price)
on conflict (organization_id, sku) do update
set
  name = excluded.name,
  description = excluded.description,
  unit = excluded.unit,
  unit_cost = excluded.unit_cost,
  unit_price = excluded.unit_price,
  is_active = true;
