-- Synthetic seed for the provenance_02 checks (fake suppliers/invoices).
insert into suppliers (id, name, aliases) values (1, 'Supplier A', '{"Supplier A Pty","Supplier A Trading"}'), (2, 'Supplier B', '{}');
insert into stock_items (id, name, department) values (10, 'Item X', 'Grocer');
insert into processed_invoices (source_id, supplier, invoice_number, invoice_date, note, booked_count, department) values
 ('s1', 'Supplier A',         '00123', '2026-10-01', 'INVOICE', 2, 'Grocer'),
 ('s2', 'Supplier A Pty',     '00123', '2026-10-01', 'INVOICE', 2, 'Grocer'),
 ('s3', 'Supplier A',         '123',   '2026-10-05', 'INVOICE', 1, 'Grocer'),
 ('s4', 'Supplier A Trading', '00123', '2026-10-06', 'CREDIT',  0, 'Grocer'),
 ('s5', 'Supplier B',         null,    '2026-10-07', 'INVOICE', 1, 'Grocer'),
 ('s6', 'Supplier B',         '00123', '2026-10-07', 'DUPLICATE of processed_invoices.id 1', 0, 'Grocer');
insert into stock_ledger (stock_item_id, qty_base, movement_type, source) values (10, 5, 'delivery', 'invoice:s1'), (10, 5, 'delivery', 'invoice:s2');
