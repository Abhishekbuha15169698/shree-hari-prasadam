create extension if not exists pgcrypto;
create table if not exists public.admin_users (user_id uuid primary key references auth.users(id) on delete cascade);
create table if not exists public.orders (
 id text primary key, created_at timestamptz not null default now(),
 customer_name text not null, customer_email text not null, customer_phone text not null,
 items jsonb not null, total_boxes integer not null, subtotal_cents integer not null,
 discount_percent integer not null, total_cents integer not null,
 status text not null default 'pending' check (status in ('pending','paid','cancelled'))
);
alter table public.orders enable row level security;
alter table public.admin_users enable row level security;
revoke all on public.orders from anon, authenticated;
revoke all on public.admin_users from anon, authenticated;
grant select on public.admin_users to authenticated;
grant select, update on public.orders to authenticated;
drop policy if exists "admins read own admin record" on public.admin_users;
create policy "admins read own admin record" on public.admin_users for select to authenticated using (user_id = (select auth.uid()));
drop policy if exists "admins read orders" on public.orders;
create policy "admins read orders" on public.orders for select to authenticated using (exists (select 1 from public.admin_users a where a.user_id = (select auth.uid())));
drop policy if exists "admins update orders" on public.orders;
create policy "admins update orders" on public.orders for update to authenticated using (exists (select 1 from public.admin_users a where a.user_id = (select auth.uid()))) with check (exists (select 1 from public.admin_users a where a.user_id = (select auth.uid())));
create or replace function public.protect_order_fields() returns trigger language plpgsql as $$
begin
 if row(old.id,old.created_at,old.customer_name,old.customer_email,old.customer_phone,old.items,old.total_boxes,old.subtotal_cents,old.discount_percent,old.total_cents) is distinct from row(new.id,new.created_at,new.customer_name,new.customer_email,new.customer_phone,new.items,new.total_boxes,new.subtotal_cents,new.discount_percent,new.total_cents) then
 raise exception 'Only status may be changed'; end if;
 return new;
end $$;
drop trigger if exists protect_order_fields on public.orders;
create trigger protect_order_fields before update on public.orders for each row execute function public.protect_order_fields();
create or replace function public.place_order(p_name text,p_email text,p_phone text,p_items jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare x jsonb; product text; qty integer; unit_cents integer; boxes integer:=0; subtotal integer:=0; discount integer; total integer; ref text; clean_items jsonb:='[]'::jsonb;
begin
 if length(trim(coalesce(p_name,''))) not between 2 and 120 or length(trim(coalesce(p_email,''))) not between 5 and 200 or p_email not like '%@%.%' or length(trim(coalesce(p_phone,''))) not between 8 and 30 then raise exception 'Please enter valid customer details';end if;
 if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 8 then raise exception 'Invalid cart';end if;
 for x in select value from jsonb_array_elements(p_items) loop
 product:=x->>'id';
 if coalesce(x->>'qty','') !~ '^[0-9]{1,3}$' then raise exception 'Invalid quantity';end if;
 qty:=(x->>'qty')::integer;
 if qty < 1 or qty > 500 then raise exception 'Quantity must be 1 to 500';end if;
 unit_cents:=case product when 'mohanthal' then 1600 when 'magaj' then 1600 when 'motichur' then 1600 when 'kajukatri' then 1800 when 'penda' then 1800 when 'mawa' then 1600 when 'kasata' then 2000 when 'mixed' then 1800 else null end;
 if unit_cents is null then raise exception 'Invalid product';end if;
 boxes:=boxes+qty;subtotal:=subtotal+qty*unit_cents;
 clean_items:=clean_items||jsonb_build_array(jsonb_build_object('id',product,'qty',qty,'unit_cents',unit_cents));
 end loop;
 if boxes>1000 then raise exception 'Please contact organiser for large orders';end if;
 discount:=case when boxes>=100 then 15 when boxes>=50 then 10 when boxes>=20 then 5 else 0 end;
 total:=subtotal-round(subtotal*discount/100.0)::integer;
 ref:='SHP-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12));
 insert into public.orders(id,customer_name,customer_email,customer_phone,items,total_boxes,subtotal_cents,discount_percent,total_cents)
 values(ref,trim(p_name),trim(p_email),trim(p_phone),clean_items,boxes,subtotal,discount,total);
 return jsonb_build_object('id',ref,'total_cents',total,'status','pending');
end $$;
revoke all on function public.place_order(text,text,text,jsonb) from public;
grant execute on function public.place_order(text,text,text,jsonb) to anon, authenticated;
